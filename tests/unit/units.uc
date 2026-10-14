// Модули Трубы без procd и сети — секунды. Всё, что можно проверить без ядра и служб:
// план, Приоритет, правила nftables и конфиг mosdns (эталоны в tests/golden + nft -c),
// чтение настроек и схема настроек, truba env, межсетевой экран зон Маршрутизации, «Проверить домен/IP» на синтетических
// Наборах правил, история скорости,
// методы ubus-API, которые читают файлы.
//   ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' -L '/repo/tests/lib/*.uc' units.uc [каталог эталонов]
// UPDATE_GOLDEN=1 — записать эталоны заново (tests/run.sh монтирует репозиторий на запись).
'use strict';

import { readfile, writefile, mkdir, popen } from 'fs';
import { cursor } from 'uci';
import * as T from 'tlib';
import * as C from 'truba.const';
import * as P from 'truba.plan';
import * as R from 'truba.render';
import * as F from 'truba.conf';
import * as N from 'truba.net';
import * as K from 'truba.check';
import * as S from 'truba.stats';
import * as DV from 'truba.devstats';
import * as DVC from 'truba.devices';

const check = T.check, same = T.same;
const GOLDEN = ARGV[0] ?? '/repo/tests/golden';
const PLUGIN = '/repo/router/truba/files/usr/share/rpcd/ucode/truba-api.uc';

// Сверка с эталоном: при расхождении — первая отличающаяся строка.
function golden(name, text) {
	let path = GOLDEN + '/' + name;
	if (getenv('UPDATE_GOLDEN')) {
		writefile(path, text);
		print('upd   эталон ', name, '\n');
		return;
	}
	let want = readfile(path);
	if (want == text)
		return check('эталон ' + name, true);
	let a = split(want ?? '', '\n'), b = split(text, '\n'), i = 0;
	while (i < length(a) && i < length(b) && a[i] == b[i])
		i++;
	check('эталон ' + name, false, want == null ? 'нет файла (UPDATE_GOLDEN=1 tests/run.sh units)'
		: sprintf('строка %d: ждали «%s», получили «%s»', i + 1, a[i] ?? '<конец>', b[i] ?? '<конец>'));
}

// Таблицу принимает ядро: nft -c проверяет её, ничего не загружая (нужен CAP_NET_ADMIN).
// Без правила socket mark: модуля nft_socket может не быть в ядре хоста (WSL).
function nft_ok(name, text) {
	writefile('/tmp/unit.nft', join('\n', filter(split(text, '\n'), l => index(l, 'socket mark') < 0)));
	let p = popen('nft -c -f /tmp/unit.nft 2>&1', 'r');
	let out = p.read('all');
	check('nft -c принимает ' + name, p.close() == 0, trim(out ?? ''));
}

function config(text) {
	mkdir('/etc/config');
	writefile('/etc/config/truba', text);
}

// ---- План: Действия Категорий текущего Режима и порядок проверки ----

let cats = [
	{ set: 'geosite', tag: 'wide',    count: 500 },
	{ set: 'geosite', tag: 'zdirect', count: 10 },
	{ set: 'geosite', tag: 'tunnel',  count: 10 },
	{ set: 'geosite', tag: 'ads',     count: 10 },
	{ set: 'geosite', tag: 'adirect', count: 10 },
	{ set: 'geosite', tag: 'unused',  count: 1 },
	{ set: 'geoip',   tag: 'ru',      count: 3 },
	{ set: 'geoip',   tag: 'private', count: 2 },
];
let rules = [
	{ mode: 'all', set: 'geosite', tag: 'wide', action: 'direct' },
	{ mode: 'all', set: 'geosite', tag: 'zdirect', action: 'direct' },
	{ mode: 'all', set: 'geosite', tag: 'tunnel', action: 'tunnel' },
	{ mode: 'all', set: 'geosite', tag: 'ads', action: 'block' },
	{ mode: 'all', set: 'geosite', tag: 'adirect', action: 'direct' },
	{ mode: 'all', set: 'geosite', tag: 'gone', action: 'tunnel' },
	{ mode: 'all', set: 'geoip', tag: 'ru', action: 'direct' },
	{ mode: 'all', set: 'geoip', tag: 'private', action: 'direct' },
	{ mode: 'selective', set: 'geosite', tag: 'unused', action: 'tunnel' },
];
let plan = P.compute({ mode: 'all', rules }, cats);
check('план: узкие раньше широких, при равенстве Блок → Туннель → Напрямую, затем по имени',
	same(map(plan.geosite, g => g.tag), [ 'ads', 'tunnel', 'adirect', 'zdirect', 'wide' ]),
	join(' ', map(plan.geosite, g => g.tag)));
check('план: Категории без Действия и другого Режима не входят', !length(filter(plan.geosite, g => g.tag == 'unused')));
check('план: пропавшая из файла Категория — в missing', same(plan.missing, [ 'geosite:gone' ]), sprintf('%J', plan.missing));
check('план: geoip по Действиям', same(plan.geoip, { block: [], tunnel: [], direct: [ 'ru', 'private' ] }));
check('план: «Всё в туннель» — по умолчанию Туннель', plan.mode_default == 'tunnel');
let sel = P.compute({ mode: 'selective', rules }, cats);
check('план: «Выборочный» — по умолчанию Напрямую, свои Действия',
	sel.mode_default == 'direct' && same(map(sel.geosite, g => g.tag + '=' + g.action), [ 'unused=tunnel' ]));
check('план: отпечаток geosite меняется с Действием',
	P.geosite_key(plan, 'h') != P.geosite_key(P.compute({ mode: 'all', rules: [ ...rules, { mode: 'all', set: 'geosite', tag: 'unused', action: 'direct' } ] }, cats), 'h'));

// ---- Приоритет: одна таблица для правил и для объяснения ----

check('Приоритет: Действия известны, наборы не повторяются',
	length(filter(P.PRIORITY, p => !(p.action in C.ACTIONS))) == 0 &&
	length(uniq(map(P.PRIORITY, p => p.set))) == length(P.PRIORITY));
check('Приоритет: первым — Блок geoip', P.PRIORITY[0].action == 'block');

// ---- Правила nftables и конфиг mosdns ----

// dns — поля, которые отличаются от обычных.
function mk(dns) {
	return {
		iface: 'awg0', dns_hijack: true, mode: 'all',
		dns: { tunnel: [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ], direct: [ 'tls+pipeline://common.dot.dns.yandex.net@77.88.8.8' ],
		       port: 5335, ttl_max: 300, cache_size: 65536, lazy_cache_ttl: 86400, set_timeout: 86400,
		       api: '127.0.0.1:5336', ...(dns ?? {}) },
	};
}
function ctx_of() {
	return {
		lan_if: [ 'br-lan' ], bypass4: [ '192.168.1.0/24', '10.77.77.0/30', '203.0.113.10/32' ],
		local4: [ '127.0.0.0/8', '192.168.1.0/24', '10.77.77.0/30', '100.64.0.1/32' ],
		socket_mark: true, vps: '203.0.113.10',
		counters: { c_tunnel_up: { packets: 3, bytes: 900 } },
		gi: { block: [], tunnel: [ '100.64.0.0/10' ], direct: [ '5.0.0.0/8', '10.0.0.0/8' ] },
		// Перенос из прежней таблицы: срок сохраняется, длиннее срока набора — укорачивается,
		// истёкший — не переносится, без срока — получает срок набора.
		gs_tunnel4: [ { ip: '198.51.100.1', expires: 100 }, { ip: '198.51.100.2', expires: 999999 }, { ip: '198.51.100.3', expires: 0 } ],
		gs_direct4: [ '198.51.100.4', { ip: '198.51.100.5', expires: null } ],
		dev_tunnel: [ 'aa:bb:cc:dd:ee:ff' ], dev_direct: [],
	};
}
let full = R.nft_full(mk(), plan, ctx_of());
golden('truba-full.nft', full);
nft_ok('полную таблицу', full);
let classify = match(full, /chain classify \{([^}]*)\}/)?.[1] ?? '';
let order = map(filter(split(classify, '\n'), l => match(l, /@/)), l => match(l, /@([a-z_0-9]+)/)[1]);
check('classify: наборы в порядке Приоритета', same(order, map(P.PRIORITY, p => p.set)), join(' ', order));
let output = match(full, /chain output \{([^}]*)\}/)?.[1] ?? '';
check('output: пакеты к IP Трубы — «Напрямую» раньше socket mark (иначе петля Туннеля)',
	index(output, 'ip daddr 203.0.113.10') >= 0 && index(output, 'ip daddr 203.0.113.10') < index(output, 'socket mark'));

// Цепочка — последняя в таблице, а в правиле есть «}».
let snat = (index(full, 'chain dns_snat') >= 0) ? substr(full, index(full, 'chain dns_snat')) : '';
check('перехват DNS: источник подменяется только у адресов вне подсетей Роутера, после перехвата (input)',
	index(snat, 'hook input') >= 0 && index(snat, 'ip saddr != @local4') >= 0 && index(snat, 'snat ip to ip daddr') >= 0, snat);
let nohijack = R.nft_full({ ...mk(), dns_hijack: false }, plan, ctx_of());
check('без перехвата DNS: нет ни перехвата, ни подмены источника, ни набора local4', !match(nohijack, /dns_hijack|dns_snat|local4/));
nft_ok('таблицу без перехвата DNS', nohijack);

let notimeout = R.nft_full(mk({ set_timeout: 0 }), plan, ctx_of());
// Только наборы gs_*: у наборов устройств dv_* свой срок (ADR 0018).
let gs_blocks = join('', map(match(notimeout, /\tset gs_[a-z0-9]+ \{[^}]*\}/g) ?? [], m => m[0]));
check('без срока: в наборах IP из DNS нет timeout и expires',
	length(gs_blocks) && !match(gs_blocks, /timeout|expires/) && index(gs_blocks, '198.51.100.1') >= 0);
nft_ok('таблицу без срока', notimeout);

let minimal = R.nft_minimal(mk(), ctx_of());
golden('truba-minimal.nft', minimal);
nft_ok('минимальную таблицу', minimal);

// Трафик по устройствам (ADR 0018): наборы dv_* — в обеих таблицах, цепочка stats есть в обеих.
let dv_decl = (n) => sprintf('\tset %s {\n\t\ttype ipv4_addr;\n\t\tflags dynamic,timeout;\n\t\ttimeout 86400s;\n\t\tsize 1024;\n\t\tcounter;\n\t}\n', n);
check('stats: шесть наборов dv_* в полной и минимальной таблице — dynamic, timeout, size, counter',
	length(C.DEV_SETS) == 6 && length(filter(C.DEV_SETS, n => index(full, dv_decl(n)) >= 0 && index(minimal, dv_decl(n)) >= 0)) == 6);
// Счётчик — раньше update: при полном наборе update прерывает правило, и без этого порядка пакет
// не попал бы в счётчик своего Действия и дошёл бы до следующих правил.
// Тело цепочки — до закрывающей строки: в правилах есть «{ ip saddr }».
let stats_body = substr(full, index(full, 'chain stats {'));
stats_body = substr(stats_body, 0, index(stats_body, '\n\t}\n'));
let stats_rules = filter(split(stats_body, '\n'), l => index(l, 'counter name') >= 0);
let stats_bad = filter(stats_rules, (l) => {
	let m = match(l, /counter name c_([a-z]+)_(up|down) update @dv_([a-z]+)_(up|down) \{ ip (saddr|daddr) \} return$/);
	return !m || m[1] != m[3] || m[2] != m[4] || m[5] != ((m[2] == 'up') ? 'saddr' : 'daddr');
});
check('stats: в каждом правиле учёта счётчик, затем update своего набора, ключ — адрес устройства',
	length(stats_rules) == 6 && !length(stats_bad), join(' | ', stats_bad));

golden('mosdns.json', sprintf('%.J\n', R.mosdns(mk(), plan, [ 'ntp.example' ])));
let noapi = R.mosdns(mk({ api: null, lazy_cache_ttl: 0 }), sel, []);
check('mosdns: без адреса API — без API, без своих хостов — без c_router',
	noapi.api == null && !length(filter(noapi.plugins, p => p.tag == 'c_router')));
check('mosdns: lazy_cache_ttl 0 — ленивый кэш выключен',
	!length(filter(noapi.plugins, p => p.tag == 'cache' && p.args?.lazy_cache_ttl)));
// Три сервера: все сразу через вложенные fallback; каждый тег объявлен раньше, чем на него ссылаются.
let three = R.mosdns(mk({ tunnel: [ 'udp://192.0.2.1', 'udp://192.0.2.2', 'udp://192.0.2.3' ] }), sel, []);
let seen = {}, refs_ok = true, servers = [];
for (let p in three.plugins) {
	for (let r in [ p.args?.primary, p.args?.secondary ])
		if (r != null && !seen[r]) refs_ok = false;
	for (let st in (p.type == 'sequence') ? p.args : [])
		if (match(st.exec ?? '', /^\$up_/) && !seen[substr(st.exec, 1)]) refs_ok = false;
	if (p.type == 'forward')
		push(servers, ...map(p.args.upstreams, u => u.addr));
	seen[p.tag] = true;
}
let top = filter(three.plugins, p => p.tag == 'up_tunnel')[0];
check('mosdns: три сервера — каждый в своём forward, все под up_tunnel, ссылки только назад',
	refs_ok && top?.type == 'fallback' && top.args.always_standby && length(filter(servers, a => index(a, 'udp://192.0.2.') == 0)) == 3);
// Поколение кэша: меняется вместе с серверами, Режимом и Действиями, но не с ttl_max.
let gen = (dns, p) => R.cache_dump(mk(dns), p ?? plan);
check('кэш: дамп по поколению — новый при смене серверов, Режима и Действия, прежний при смене ttl_max',
	match(gen(), /^\/var\/lib\/truba\/mosdns-cache-[0-9a-f]{8}\.dump$/) && gen({ ttl_max: 60 }) == gen() &&
	gen({ direct: [ 'udp://192.0.2.9' ] }) != gen() && gen(null, sel) != gen() &&
	gen(null, { ...plan, geosite: map(plan.geosite, (g, i) => i ? g : { ...g, action: (g.action == 'tunnel') ? 'direct' : 'tunnel' }) }) != gen());
check('mosdns: кэш — в цепочке каждого пути, ответ в нём свежий не дольше часа; TTL и nftset — после неё, только у Категорий',
	!length(filter(filter(three.plugins, p => p.tag == 'main')[0].args, x => x.exec == '$cache')) &&
	length(filter(three.plugins, p => match(p.tag, /^fetch_/) && p.args[0].exec == '$cache' && p.args[2].exec == 'ttl 0-3600')) == 4 &&
	filter(three.plugins, p => p.tag == 'flow_direct')[0].args[1].exec == 'ttl 0-300' &&
	length(filter(three.plugins, p => p.tag == 'flow_default')[0].args) == 1);
check('mosdns: у каждого сервера idle_timeout, один сервер — просто forward',
	length(filter(three.plugins, p => p.type == 'forward' && p.args.upstreams[0].idle_timeout != 360)) == 0 &&
	filter(three.plugins, p => p.tag == 'up_direct')[0]?.type == 'forward');

// ---- Чтение настроек: неверные значения пропускаются ----

check('адрес DNS: схемы mosdns и «@IP»', F.upstream_ok('https://1.1.1.1/dns-query') && F.upstream_ok('tls://dns.example@1.2.3.4') &&
	F.upstream_ok('tls+pipeline://dns.example@1.2.3.4') &&
	F.upstream_ok('1.1.1.1') && F.upstream_ok('udp://[2001:db8::1]:53'));
check('адрес DNS: опечатка в схеме и путь без схемы — нет', !F.upstream_ok('htps://1.1.1.1/dns-query') && !F.upstream_ok('1.1.1.1/dns-query'));

config(`
config main 'main'
	option mode 'selective'

config dns 'dns'
	option set_timeout '100'
	option port '70000'
	list tunnel_upstream 'htps://1.1.1.1/dns-query'

config watchdog 'watchdog'
	option probe '10.77.77.l'

config device
	option mac 'AA:BB:CC:DD:EE'

config device
	option mac 'AA:BB:CC:DD:EE:FF'
	option policy 'direct'
`);
let cfg = F.load();
check('настройки: срок короче 10 минут — неверный, по умолчанию сутки', cfg.dns.set_timeout == 86400);
check('настройки: пропущенное перечислено',
	same(sort(map(cfg.invalid, x => x.key)), [ 'device.mac', 'dns.port', 'dns.set_timeout', 'dns.tunnel_upstream', 'watchdog.probe' ]),
	join(' ', sort(map(cfg.invalid, x => x.key))));
check('настройки: все адреса DNS неверные — стандартные, а не mosdns без серверов',
	same(cfg.dns.tunnel, [ 'udp://10.77.77.1', 'https://1.1.1.1/dns-query' ]), sprintf('%J', cfg.dns.tunnel));
check('настройки: верный MAC — в нижнем регистре', same(cfg.devices, [ { name: '', mac: 'aa:bb:cc:dd:ee:ff', policy: 'direct' } ]));
check('настройки: API mosdns — на соседнем порту', cfg.dns.port == 5335 && cfg.dns.api == '127.0.0.1:5336');
config("config dns 'dns'\n\toption set_timeout '0'\n");
check('настройки: срок 0 — без срока', F.load().dns.set_timeout == 0);

// ---- Схема настроек (ADR 0015): умолчания и пределы — только в ней ----

let sbad = [], sdefs = true;
for (let sec, opts in F.SCHEMA ?? {})
	for (let key, o in opts)
		sdefs = same(F.check_value(sec, key, o.def, sbad), o.def) && sdefs;
check('схема: каждое умолчание проходит свою проверку', length(keys(F.SCHEMA ?? {})) == 5 && sdefs && !length(sbad), sprintf('%J', sbad));
config('');
let dcfg = F.load();
check('схема: пустой конфиг — умолчания схемы', dcfg.dns.port == F.SCHEMA?.dns?.port?.def && same(dcfg.zones, F.SCHEMA?.main?.zone?.def) &&
	same(dcfg.dns.tunnel, F.SCHEMA?.dns?.tunnel_upstream?.def) && dcfg.watchdog.handshake_max == 180);
config("config dns 'dns'\n\toption port ''\n\nconfig watchdog 'watchdog'\n\toption probe ''\n");
dcfg = F.load();
check('схема: пустая опция — умолчание, а не неверное значение', dcfg.dns.port == 5335 && dcfg.watchdog.probe == '' && !length(dcfg.invalid),
	sprintf('%J', dcfg.invalid));
// Число больше int64 int() читает как NaN, а сравнения с NaN ложны: такой порт проходил проверку.
const NINES80 = replace(sprintf('%080d', 0), /0/g, '9');
config("config dns 'dns'\n\toption port '" + NINES80 + "'\n");
dcfg = F.load();
check('схема: число больше int64 — неверное, по умолчанию', dcfg.dns.port === 5335 && dcfg.dns.api == '127.0.0.1:5336' &&
	same(dcfg.invalid, [ { key: 'dns.port', value: NINES80 } ]), sprintf('%J %J', dcfg.dns.port, dcfg.invalid));

// /etc/config/truba из пакета — полный образец настроек: совпадает со схемой в обе стороны.
// Расхождения конфига text со схемой: опции не из схемы, не равные её умолчанию, недостающие.
const PKG_CONFIG = readfile('/repo/router/truba/files/etc/config/truba');
function schema_gaps(text) {
	mkdir('/tmp/pkgconf');
	writefile('/tmp/pkgconf/truba', text);
	let pc = cursor('/tmp/pkgconf');
	pc.load('truba');
	let g = { extra: [], differ: [], absent: [] };
	for (let sec in [ 'main', 'dns', 'lists', 'watchdog' ]) {
		let s = pc.get_all('truba', sec) ?? {};
		for (let key, raw in s) {
			if (substr(key, 0, 1) == '.')
				continue;
			let o = F.SCHEMA?.[sec]?.[key];
			if (!o)
				push(g.extra, sec + '.' + key);
			else if (!same(F.check_value(sec, key, raw), o.def))
				push(g.differ, sec + '.' + key);
		}
		// Пустых значений UCI не хранит: опции с пустым умолчанием (stun, probe) в файле не видно.
		// length() у флагов и чисел — null, поэтому «пусто» — только '' и пустой список.
		for (let key, o in F.SCHEMA?.[sec] ?? {}) {
			let empty = (o.def === '' || (type(o.def) == 'array' && !length(o.def)));
			if (s[key] == null && !empty)
				push(g.absent, sec + '.' + key);
		}
	}
	return g;
}
let gaps = schema_gaps(PKG_CONFIG);
check('config/truba: каждая опция — из схемы и равна её умолчанию', !length(gaps.extra) && !length(gaps.differ),
	sprintf('нет в схеме: %J, не равны умолчанию: %J', gaps.extra, gaps.differ));
check('config/truba: каждая опция схемы есть в файле', length(keys(F.SCHEMA ?? {})) && !length(gaps.absent), join(' ', gaps.absent));
gaps = schema_gaps(replace(PKG_CONFIG, /\toption (routing|port|handshake_max) [^\n]*\n/g, ''));
check('config/truba: пропуск опции заметен — и флага, и числа', same(sort(gaps.absent), [ 'dns.port', 'main.routing', 'watchdog.handshake_max' ]),
	join(' ', gaps.absent));

// ---- truba env: значения для shell-скриптов пакета (ADR 0015) ----

function sh_env(script) {
	writefile('/tmp/env.sh', F.env_lines?.() ?? '');
	let p = popen("sh -n /tmp/env.sh && sh -c '. /tmp/env.sh; " + script + "' 2>&1", 'r');
	let out = p.read('all');
	p.close();
	return out;
}
config("config main 'main'\n\nconfig watchdog 'watchdog'\n\toption enabled '0'\n");
let eo = sh_env('printf \"%s|%s|%s|%s\" \"$TRUBA_APPLIED\" \"$TRUBA_FW_ZONE\" \"$TRUBA_IFACE\" \"$TRUBA_WATCHDOG\"');
check('env: shell принимает вывод, значения — из службы', eo == C.APPLIED_FILE + '|' + C.FW_ZONE + '|awg0|0', eo);
config("config main 'main'\n\toption iface \"x'; touch /tmp/pwned; '\"\n");
system('rm -f /tmp/pwned');
eo = sh_env('printf %s \"$TRUBA_IFACE\"');
check('env: неверное имя интерфейса — умолчание, в shell не исполняется', eo == 'awg0' && system('test -e /tmp/pwned') != 0, eo);
eo = sh_env('printf %s \"$TRUBA_NO6_SUFFIX\"');
check('env: окончание имени своих правил IPv6 — как у службы', eo == C.FW_NO6_SUFFIX && length(eo), eo);
let un = readfile('/repo/router/truba/files/usr/share/truba/uninstall.sh');
check('uninstall.sh: свои правила IPv6 — по окончанию из env, без литерала',
	index(un, '$TRUBA_NO6_SUFFIX') >= 0 && index(un, 'no_ipv6') < 0);
check('90-truba: правило IPv6 заводит не установка, а применение',
	index(readfile('/repo/router/truba/files/etc/uci-defaults/90-truba'), 'ipv6') < 0);
// reinstall.sh работает без пакета (после sysupgrade его ещё нет) — свои литералы, сверка здесь.
let ri = readfile('/repo/router/truba/files/etc/truba/reinstall.sh');
check('reinstall.sh: путь бэкапа dnsmasq и адрес mosdns — как у службы',
	index(ri, C.DNSMASQ_BACKUP) >= 0 && index(ri, C.MOSDNS_ADDR + '#${port:-' + F.SCHEMA.dns.port.def + '}') >= 0);

// Адрес Трубы внутри Туннеля — из адреса Роутера (ubus нет — из настроек).
function peer_of(addr) {
	writefile('/etc/config/network', sprintf("config interface 'awg0'\n\toption proto 'amneziawg'\n\tlist addresses '%s'\n\n" +
		"config amneziawg_awg0\n\toption endpoint_host '203.0.113.10'\n", addr));
	let t = F.tunnel_info('awg0');
	return [ t.peer, t.subnet, t.endpoint ];
}
check('Туннель /30: Роутер .2 — Труба .1', same(peer_of('10.77.77.2/30'), [ '10.77.77.1', '10.77.77.0/30', '203.0.113.10' ]));
check('Туннель /31: второй адрес', peer_of('10.0.0.0/31')[0] == '10.0.0.1');
check('Туннель /24: Роутер .1 — Труба .2, а не он сам', peer_of('10.0.0.1/24')[0] == '10.0.0.2');
check('подсети адресов Роутера: из адреса и длины префикса', '127.0.0.0/8' in F.local_subnets(), join(' ', F.local_subnets()));

// ---- Межсетевой экран зон Маршрутизации: перенаправления в truba (ADR 0014), IPv6-интернет (ADR 0016) ----

const FW_BASE = "config zone\n\toption name 'lan'\n\nconfig zone\n\toption name 'mesh'\n\n" +
	"config zone\n\toption name 'guest-net'\n\nconfig zone 'truba'\n\toption name 'truba'\n\n" +
	"config forwarding\n\toption src 'lan'\n\toption dest 'wan'\n\n";
// Перенаправления в truba: «имя:откуда».
function fwds() {
	let c = cursor(), out = [];
	c.load('firewall');
	c.foreach('firewall', 'forwarding', (f) => {
		if (f.dest == 'truba')
			push(out, (f['.anonymous'] ? '@' : f['.name']) + ':' + f.src);
	});
	return sort(out);
}
writefile('/etc/config/firewall', FW_BASE);
check('перенаправления: заведены для выбранных зон; зоны, которой нет, и самой truba — нет',
	N.zones_firewall([ 'lan', 'mesh', 'ghost', 'truba' ]) && same(fwds(), [ 'lan_truba:lan', 'mesh_truba:mesh' ]), join(' ', fwds()));
check('межсетевой экран зон: повторное применение ничего не меняет', N.zones_firewall && !N.zones_firewall([ 'lan', 'mesh' ]));
check('перенаправления: зона больше не выбрана — своё убрано', N.zones_firewall([ 'lan' ]) && same(fwds(), [ 'lan_truba:lan' ]), join(' ', fwds()));
check('перенаправления: имя секции — из имени зоны без недопустимых знаков',
	N.zones_firewall([ 'guest-net' ]) && same(fwds(), [ 'guest_net_truba:guest-net' ]), join(' ', fwds()));
writefile('/etc/config/firewall', FW_BASE + "config forwarding\n\toption src 'mesh'\n\toption dest 'truba'\n\n");
N.zones_firewall([ 'mesh' ]);
check('перенаправления: своё владельца засчитано — второе не заводится', same(fwds(), [ '@:mesh' ]), join(' ', fwds()));
check('перенаправления: своё владельца остаётся и без зоны', N.zones_firewall([ 'lan' ]) && same(fwds(), [ '@:mesh', 'lan_truba:lan' ]), join(' ', fwds()));
writefile('/etc/config/firewall', FW_BASE + "config rule 'mesh_truba'\n\toption src 'mesh'\n");
N.zones_firewall([ 'mesh' ]);
check('перенаправления: имя занято чужой секцией — она не тронута',
	cursor().get('firewall', 'mesh_truba') == 'rule' && !length(fwds()), join(' ', fwds()));
writefile('/etc/config/firewall', replace(FW_BASE, "config zone 'truba'\n\toption name 'truba'\n\n", ''));
N.zones_firewall([ 'lan' ]);
check('перенаправления: без зоны truba не заводятся', !length(fwds()));

// Свои правила IPv6: «имя:откуда», выключенное — с «:off».
function no6s() {
	let c = cursor(), out = [];
	c.load('firewall');
	c.foreach('firewall', 'rule', (r) => {
		if (substr(r['.name'], -length(C.FW_NO6_SUFFIX)) == C.FW_NO6_SUFFIX)
			push(out, r['.name'] + ':' + r.src + (r.enabled == '0' ? ':off' : ''));
	});
	return sort(out);
}
let no6 = (sid) => cursor().get_all('firewall', sid) ?? {};
let no6_ok = (r, zone) => r['.type'] == 'rule' && r.src == zone && r.dest == '*' && r.family == 'ipv6' &&
	r.proto == 'all' && r.target == 'REJECT' && same(r.dest_ip, [ '!fc00::/7', '!fe80::/10', '!ff00::/8' ]);
check('IPv6: правило без окончания имени не опознать', length(C.FW_NO6_SUFFIX ?? '') > 0);
check('IPv6: без зоны truba правило всё равно заведено', same(no6s(), [ 'lan_truba_no_ipv6:lan' ]), join(' ', no6s()));
writefile('/etc/config/firewall', FW_BASE);
N.zones_firewall([ 'lan', 'mesh', 'ghost', 'truba' ]);
check('IPv6: правило у каждой выбранной зоны; зоны, которой нет, и самой truba — нет',
	same(no6s(), [ 'lan_truba_no_ipv6:lan', 'mesh_truba_no_ipv6:mesh' ]), join(' ', no6s()));
check('IPv6: в любую зону, кроме ULA, link-local и multicast, — REJECT', no6_ok(no6('lan_truba_no_ipv6'), 'lan'),
	sprintf('%J', no6('lan_truba_no_ipv6')));
check('IPv6: зона больше не выбрана — правило убрано', N.zones_firewall([ 'lan' ]) && same(no6s(), [ 'lan_truba_no_ipv6:lan' ]), join(' ', no6s()));
check('IPv6: имя секции — из имени зоны без недопустимых знаков',
	N.zones_firewall([ 'guest-net' ]) && same(no6s(), [ 'guest_net_truba_no_ipv6:guest-net' ]), join(' ', no6s()));
function fw_edit(sid, k, v) {
	let c = cursor();
	c.load('firewall');
	v == null ? c.delete('firewall', sid, k) : c.set('firewall', sid, k, v);
	c.commit('firewall');
}
writefile('/etc/config/firewall', FW_BASE);
N.zones_firewall([ 'lan' ]);
fw_edit('lan_truba_no_ipv6', 'enabled', '0');
check('IPv6: правило, выключенное владельцем, остаётся выключенным',
	!N.zones_firewall([ 'lan' ]) && same(no6s(), [ 'lan_truba_no_ipv6:lan:off' ]), join(' ', no6s()));
fw_edit('lan_truba_no_ipv6', 'target', 'ACCEPT');
fw_edit('lan_truba_no_ipv6', 'dest_ip', null);
check('IPv6: изменённое правило применение возвращает', N.zones_firewall([ 'lan' ]) && no6_ok(no6('lan_truba_no_ipv6'), 'lan'),
	sprintf('%J', no6('lan_truba_no_ipv6')));
fw_edit('lan_truba_no_ipv6', null, null);
check('IPv6: удалённое правило применение заводит снова', N.zones_firewall([ 'lan' ]) && no6_ok(no6('lan_truba_no_ipv6'), 'lan'));
writefile('/etc/config/firewall', FW_BASE + "config redirect 'mesh_truba_no_ipv6'\n\toption src 'mesh'\n\nconfig rule 'lan_truba_no_ipv6'\n\toption src 'wan'\n");
N.zones_firewall([ 'lan', 'mesh' ]);
check('IPv6: имя занято чужой секцией — она не тронута, своего правила нет',
	no6('mesh_truba_no_ipv6')['.type'] == 'redirect' && no6('lan_truba_no_ipv6').src == 'wan' && !no6('lan_truba_no_ipv6').target,
	sprintf('%J %J', no6('mesh_truba_no_ipv6'), no6('lan_truba_no_ipv6')));

// ---- «Проверить домен/IP»: Приоритет для IP ----

let ip = '198.51.100.7', n = 0xc6336407;
let kern = (sets) => ({ bypass4: [], gs_tunnel4: [], gs_direct4: [], ...sets });
let here = [ [ n, n ] ];
let rcfg = { routing: true, devices: [ { name: 'tv', mac: 'aa:bb:cc:dd:ee:ff', policy: 'tunnel' } ] };
let v = (geoip, sets, mac, c) => K.ip_verdict(c ?? rcfg, plan, ip, n, geoip, kern(sets), mac);
let r = v([ 'ru' ], { gs_tunnel4: here });
check('IP: из DNS «Туннель» раньше geoip «Напрямую»', r.action == 'tunnel' && r.reason == 'geosite_ip' && r.sets.gi_direct);
r = v([], { gs_tunnel4: here, gs_direct4: here });
check('IP: общий IP из DNS — Туннель побеждает Напрямую', r.action == 'tunnel');
r = v([ 'ru' ], { gs_direct4: here }, 'AA:BB:CC:DD:EE:FF');
check('IP: Политика устройства раньше IP из DNS', r.action == 'tunnel' && r.reason == 'device' && r.device == 'tv');
r = v([], { bypass4: here, gs_tunnel4: here });
check('IP: адрес домашней сети — мимо Приоритета', r.action == 'direct' && r.reason == 'local');
r = v([ 'ru' ], {}, null, { routing: false, devices: [] });
check('IP: Маршрутизация выкл — наборов geoip нет, по Режиму', r.action == 'tunnel' && r.reason == 'mode' && !r.sets.gi_direct);
let bplan = { ...plan, geoip: { block: [ 'ru' ], tunnel: [], direct: [] } };
r = K.ip_verdict(rcfg, bplan, ip, n, [ 'ru' ], kern({ gs_tunnel4: here }), 'aa:bb:cc:dd:ee:ff');
check('IP: Блок geoip раньше всего', r.action == 'block' && r.reason == 'geoip_block');

// ---- «Проверить домен/IP» на синтетических Наборах правил ----
// Распаковка настоящим dat.uc в /var/lib/truba; DNS в контейнере нет — домен не резолвится,
// и итог решает Категория. IP из DNS и подсети в ядре проверяют части router.

mkdir('/etc/truba'); mkdir(C.LISTS_DIR);
writefile(C.LISTS_DIR + '/geosite.dat',
	T.geosite_cat('zwide', [ 'domain:example.com', 'domain:example.net', 'domain:example.org' ]) +
	T.geosite_cat('znarrow', [ 'domain:a.example.com' ]) +
	T.geosite_cat('zfull', [ 'full:exact.example.io' ]) +
	T.geosite_cat('zrx', [ 'regexp:^rx-[0-9]+\\.example\\.io$' ]) +
	T.geosite_cat('zkw', [ 'keyword:kwtest' ]) +
	T.geosite_cat('zmode', [ 'domain:mode.example.io' ]));
writefile(C.LISTS_DIR + '/geoip.dat', T.geoip_cat('ru', [ '5.0.0.0/8' ]) + T.geoip_cat('private', [ '192.168.0.0/16' ]));
let rule = (tag, action) => sprintf("config rule\n\toption mode 'all'\n\toption set 'geosite'\n\toption tag '%s'\n\toption action '%s'\n\n", tag, action);
config("config main 'main'\n\toption mode 'all'\n\n" + rule('zwide', 'direct') + rule('znarrow', 'tunnel') +
	rule('zfull', 'direct') + rule('zrx', 'direct') + rule('zkw', 'block') +
	"config rule\n\toption mode 'all'\n\toption set 'geoip'\n\toption tag 'ru'\n\toption action 'direct'\n");

let dom = (d) => {
	let x = K.check(d);
	return sprintf('%s/%s/%s', x.action, x.reason, x.decisive?.tag ?? '-');
};
check('домен: full: совпадает точно', dom('exact.example.io') == 'direct/geosite/zfull', dom('exact.example.io'));
check('домен: full: не совпадает с поддоменом', dom('x.exact.example.io') == 'tunnel/mode/-', dom('x.exact.example.io'));
check('домен: domain: — сам домен и поддомены', dom('example.com') == 'direct/geosite/zwide' && dom('x.y.example.net') == 'direct/geosite/zwide');
check('домен: regexp:', dom('rx-42.example.io') == 'direct/geosite/zrx' && dom('rx-x.example.io') == 'tunnel/mode/-', dom('rx-42.example.io'));
check('домен: keyword: и Блок', dom('my-kwtest.example.io') == 'block/geosite_block/zkw', dom('my-kwtest.example.io'));
check('домен: узкая Категория раньше широкой', dom('b.a.example.com') == 'tunnel/geosite/znarrow', dom('b.a.example.com'));
check('домен: Категория «По режиму» не решает', dom('mode.example.io') == 'tunnel/mode/-', dom('mode.example.io'));
let x = K.check('b.a.example.com');
check('домен: видны все совпавшие Категории', same(sort(map(x.geosite, h => h.tag)), [ 'znarrow', 'zwide' ]), sprintf('%J', x.geosite));
x = K.check('5.6.7.8');
check('IP: Категория geoip из распакованного файла', x.action == 'direct' && x.reason == 'geoip' && same(x.ips[0].geoip, [ 'ru' ]), sprintf('%J', x.ips));
// «Куда ходит сейчас» (connections): только Категории geoip с Действием — у private его нет.
let iv = K.ip_verdicts([ '5.6.7.8', '192.168.5.5' ], null);
check('решения для соединений: geoip — только Категории с Действием',
	same(map(iv ?? [], v => v.geoip), [ [ 'ru' ], [] ]) && iv[0].action == 'direct' && iv[0].reason == 'geoip' &&
	same(K.check('192.168.5.5').ips[0].geoip, [ 'private' ]), sprintf('%J', iv));
// Категории geoip адресов: у ru на NC-1812 35 тысяч подсетей, а «Куда ходит сейчас» спрашивает до 20 адресов
// раз в 5 с — подсеть разбирается, только если в её первом октете есть адрес (было 3,7 с на Роутере).
// Сеть шире /8 захватывает и другие первые октеты.
let bigv4 = [];
for (let i = 0; i < 35000; i++)
	push(bigv4, sprintf('%d.%d.%d.0/24', 1 + (i % 220), (i / 220) & 255, (i / 56320) & 255));
push(bigv4, '224.0.0.0/4');
mkdir(C.DATA_DIR + '/geoip');
writefile(C.DATA_DIR + '/geoip/zbig.v4', join('\n', bigv4) + '\n');
let ipn = (s) => { let a = iptoarr(s); return (a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3]; };
// 7.0.0.9 — в 7.0.0.0/24; 231.1.2.3 — только в 224.0.0.0/4; 7.200.0.1 — октет есть, подсети нет; 240…249 — мимо.
let gaddrs = [ '7.0.0.9', '231.1.2.3', '7.200.0.1' ];
for (let k = 0; k < 17; k++)
	push(gaddrs, sprintf('%d.1.1.1', 240 + (k % 10)));
let gt0 = clock(true);
let gh = K.geoip_hits?.([ { set: 'geoip', tag: 'zbig' } ], map(gaddrs, ipn));
let gt1 = clock(true), gms = (gt1[0] - gt0[0]) * 1000 + (gt1[1] - gt0[1]) / 1e6;
check('Категории geoip: 20 адресов × 35 тысяч подсетей — верно и быстрее 150 мс',
	gh != null && same(gh[0], [ 'zbig' ]) && same(gh[1], [ 'zbig' ]) && same(gh[2], []) &&
	length(filter(slice(gh, 3), (h) => length(h))) == 0 && gms < 150, sprintf('%d мс, %J', gms, slice(gh ?? [], 0, 4)));

// ---- История скорости (truba stats) без процесса и файлов ----

// Счётчики nft под своими именами: байты трафика и соединения (пакеты c_tunnel и др.).
function raw(b, c) {
	return {
		c_tunnel_down: { packets: 1, bytes: b[0] }, c_tunnel_up: { packets: 1, bytes: b[1] },
		c_direct_down: { packets: 1, bytes: b[2] }, c_direct_up: { packets: 1, bytes: b[3] },
		c_inbound_down: { packets: 1, bytes: b[4] }, c_inbound_up: { packets: 1, bytes: b[5] },
		c_tunnel: { packets: c[0], bytes: 0 }, c_direct: { packets: c[1], bytes: 0 },
		c_inbound: { packets: c[2], bytes: 0 }, c_block: { packets: 7, bytes: 0 },
	};
}

let s0 = S.snapshot(raw([ 0, 0, 0, 0, 0, 0 ], [ 0, 0, 0 ]), 100, 10000, 1000);
check('снимок: байты по Действиям, затем соединения; время, монотонное время, отсчёт',
	same(s0.v, [ 0, 0, 0, 0, 0, 0, 0, 0, 0 ]) && s0.t == 1000 && s0.m == 10000 && s0.since == 100);
check('снимок: таблицы нет — значений нет', S.snapshot({}, 100, 10000, 1000).v == null);
let partial = raw([ 1, 2, 3, 4, 5, 6 ], [ 1, 2, 3 ]);
delete partial.c_tunnel;   // Маршрутизация выключена: счётчика соединений Туннеля нет
check('снимок: нет счётчика — null на его месте', same(S.snapshot(partial, 1, 0, 0).v, [ 1, 2, 3, 4, 5, 6, null, 2, 3 ]));

let s1 = S.snapshot(raw([ 5000, 500, 10000, 1000, 50, 5 ], [ 2, 3, 1 ]), 100, 15000, 1005);
check('точка: байт/с и новых соединений в минуту', same(S.point(s0, s1), [ 1005, 1000, 100, 2000, 200, 10, 1, 24, 36, 12 ]),
	sprintf('%J', S.point(s0, s1)));
check('точка: разрыв — нет первого снимка, новый отсчёт, нет таблицы, перерыв дольше минуты, меньше секунды',
	same(S.point(null, s1), [ 1005 ]) && same(S.point(s0, { ...s1, since: 200 }), [ 1005 ]) &&
	same(S.point(s0, { ...s1, v: null }), [ 1005 ]) && same(S.point(s0, { ...s1, m: 75001 }), [ 1005 ]) &&
	same(S.point(s0, { ...s1, m: 10500 }), [ 1005 ]));
let dec = S.snapshot(raw([ 5000, 500, 10000, 1000, 50, 5 ], [ 2, 3, 1 ]), 100, 10000, 1000);
let s2 = S.snapshot(raw([ 4000, 1000, 10000, 1000, 50, 5 ], [ 2, 3, 1 ]), 100, 15000, 1005);
check('точка: счётчик уменьшился — null только у него', same(S.point(dec, s2), [ 1005, null, 100, 0, 0, 0, 0, 0, 0, 0 ]),
	sprintf('%J', S.point(dec, s2)));
check('точка: округление до целых (3,5 → 4)', S.point({ m: 0, since: 1, v: [ 0, 0, 0, 0, 0, 0, 0, 0, 0 ] },
	{ m: 2000, t: 2, since: 1, v: [ 7, 0, 0, 0, 0, 0, 0, 0, 0 ] })[1] == 4);

let pts = [ [ 60, 1, 1, 1, 1 ], [ 65, 10, 20, null, 40, 9, 9 ], [ 70, 20, 40, 30, null ], [ 75 ], [ 120, 99, 99, 99, 99 ], [ 125, 50, 50, 50, 50 ] ];
check('минута (60, 120]: среднее по точкам, где значение есть', same(S.minute(pts, 120), [ 120, 43, 53, 65, 70 ]),
	sprintf('%J', S.minute(pts, 120)));
check('минута без значений — разрыв', same(S.minute([ [ 65 ], [ 70 ] ], 120), [ 120 ]));

let hist = { last: null, points: [], minutes: [] };
let counters = (k) => raw([ k * 1000, k * 100, k * 2000, k * 200, 0, 0 ], [ k, 0, 0 ]);
let closed = [];
// 25 замеров по 5 с: с 1000 до 1120, минуты кончаются в 1020, 1080, 1140.
for (let k = 0; k <= 24; k++)
	push(closed, S.add(hist, S.snapshot(counters(k), 1, k * 5000, 1000 + k * 5)));
check('накопление: первая точка — разрыв, вторая — скорость',
	same(hist.points[0], [ 1000 ]) && same(hist.points[1], [ 1005, 200, 20, 400, 40, 0, 0, 12, 0, 0 ]), sprintf('%J', hist.points[1]));
check('накопление: закрыты минуты 1020 и 1080, каждая — первой точкой следующей',
	same(map(hist.minutes, (x) => x[0]), [ 1020, 1080 ]) && closed[5] == true && closed[4] == false && length(filter(closed, (x) => x)) == 2,
	sprintf('%J', hist.minutes));
check('накопление: среднее минуты — только 4 значения графика', same(hist.minutes[1], [ 1080, 200, 20, 400, 40 ]));
check('накопление: последний снимок сохранён', hist.last.t == 1120 && hist.last.m == 120000);

let again = { ...hist, minutes: [ ...hist.minutes, [ 1140, 1, 1, 1, 1 ] ] };
S.add(again, S.snapshot(counters(25), 1, 125000, 1145));
check('перезапуск: закрытая минута не дублируется', length(filter(again.minutes, (x) => x[0] == 1140)) == 1);

let old = { last: null, points: [ [ 100, 1, 1, 1, 1 ], [ 3700, 1, 1, 1, 1 ] ], minutes: [ [ 60, 1, 1, 1, 1 ], [ 3660, 1, 1, 1, 1 ] ] };
S.add(old, S.snapshot(counters(1), 1, 0, 3701));
check('срок: точки старше часа убраны', same(map(old.points, (x) => x[0]), [ 3700, 3701 ]), sprintf('%J', old.points));
S.add(old, S.snapshot(counters(1), 1, 0, 86500));
check('срок: минуты старше суток убраны, после перерыва — только новая точка',
	same(map(old.minutes, (x) => x[0]), [ 3660, 3720 ]) && same(old.points, [ [ 86500 ] ]), sprintf('%J', old.minutes));

let back = { last: null, points: [ [ 2000 ], [ 2005, 1, 1, 1, 1 ], [ 2010, 1, 1, 1, 1 ] ], minutes: [ [ 1980, 1, 1, 1, 1 ], [ 2040, 1, 1, 1, 1 ] ] };
S.add(back, S.snapshot(counters(1), 1, 0, 2006));
check('часы назад: точки по возрастанию, минуты «из будущего» убраны',
	same(map(back.points, (x) => x[0]), [ 2000, 2005, 2006 ]) && same(map(back.minutes, (x) => x[0]), [ 1980 ]),
	sprintf('%J %J', back.points, back.minutes));

// ---- История по устройствам (truba.devstats) без процесса и файлов ----

const A = '192.168.1.50', B = '192.168.1.60', z6 = [ 0, 0, 0, 0, 0, 0 ];
let h = { last: null, devices: {} };
DV.add(h, DV.snapshot({ [A]: z6 }, 7, 0, 7195));
check('устройства: первый замер — скорости нет', h.devices[A]?.rate == null && h.devices[A]?.seen == 7195);
DV.add(h, DV.snapshot({ [A]: [ 5000, 500, 1000, 100, 0, 0 ], [B]: [ 2500, 0, 0, 0, 0, 0 ] }, 7, 5000, 7200));
check('устройства: скорость по разнице, байт/с', same(h.devices[A].rate, [ 1000, 100, 200, 20, 0, 0 ]), sprintf('%J', h.devices[A].rate));
check('устройства: новый элемент — весь его счётчик за шаг', same(h.devices[B]?.rate, [ 500, 0, 0, 0, 0, 0 ]));
check('устройства: часовая сумма и время трафика',
	same(h.devices[A].hours, [ [ 7200, 5000, 500, 1000, 100, 0, 0 ] ]) && h.devices[A].last == 7200, sprintf('%J', h.devices[A].hours));
DV.add(h, DV.snapshot({ [A]: [ 5000, 500, 1000, 100, 0, 0 ] }, 7, 10000, 7205));
check('устройства: минута (7140, 7200] закрыта средним за покрытые секунды',
	same(h.devices[A].minutes, [ [ 7200, 1000, 100, 200, 20 ] ]), sprintf('%J', h.devices[A].minutes));
check('устройства: без трафика — скорость 0, время трафика прежнее', same(h.devices[A].rate, z6) && h.devices[A].last == 7200);
check('устройства: B — минута с трафиком записана', same(h.devices[B].minutes, [ [ 7200, 500, 0, 0, 0 ] ]), sprintf('%J', h.devices[B].minutes));
check('устройства: нет в наборах — скорости нет, устройство осталось', h.devices[B] != null && h.devices[B].rate == null);
DV.add(h, DV.snapshot({ [A]: [ 10, 0, 0, 0, 0, 0 ] }, 8, 15000, 7210));
check('устройства: новое поколение таблицы — пропуск шага, суммы не уменьшились',
	h.devices[A].rate == null && same(h.devices[A].hours, [ [ 7200, 5000, 500, 1000, 100, 0, 0 ] ]), sprintf('%J', h.devices[A]));
// Минута без трафика не пишется: у сотен адресов без трафика нет 60 точек нулей в файле и в ответе ubus.
DV.add(h, DV.snapshot({ [A]: [ 10, 0, 0, 0, 0, 0 ] }, 8, 20000, 7265));
check('устройства: минута без трафика не пишется', same(map(h.devices[A].minutes, x => x[0]), [ 7200 ]), sprintf('%J', h.devices[A].minutes));

let dv2 = { last: null, devices: {} };
DV.add(dv2, DV.snapshot({ [A]: [ 100, 100, 0, 0, 0, 0 ] }, 1, 0, 1000));
DV.add(dv2, DV.snapshot({ [A]: [ 50, 200, 0, 0, 0, 0 ] }, 1, 5000, 1005));
check('устройства: счётчик уменьшился — null только у него', same(dv2.devices[A].rate, [ null, 20, 0, 0, 0, 0 ]), sprintf('%J', dv2.devices[A].rate));
DV.add(dv2, DV.snapshot({ [A]: [ 60, 300, 0, 0, 0, 0 ] }, 1, 80000, 1080));
check('устройства: перерыв дольше минуты — скорости нет', dv2.devices[A].rate == null);

let dv3 = { last: null, devices: {
	[A]: { seen: 0, last: 1000, rate: null, acc: null,
	       minutes: [ [ 96000, 1, 1, 1, 1 ], [ 99960, 2, 2, 2, 2 ] ], hours: [ [ 10800, 1, 1, 1, 1, 1, 1 ], [ 97200, 2, 2, 2, 2, 2, 2 ] ] },
	[B]: { seen: 0, last: 1000, rate: null, acc: null, minutes: [], hours: [] },
	'192.168.1.70': { seen: 50000, last: null, rate: null, acc: null, minutes: [], hours: [] },
} };
DV.add(dv3, DV.snapshot({ [A]: z6 }, 1, 0, 100000));
check('устройства: минуты старше часа и часы старше суток отброшены',
	same(dv3.devices[A].minutes, [ [ 99960, 2, 2, 2, 2 ] ]) && same(dv3.devices[A].hours, [ [ 97200, 2, 2, 2, 2, 2, 2 ] ]), sprintf('%J', dv3.devices[A]));
check('устройства: без трафика дольше суток и не в наборах — удалено; в наборах или появилось недавно — осталось',
	dv3.devices[B] == null && dv3.devices[A] != null && dv3.devices['192.168.1.70'] != null);
check('устройства: day — сумма часовых', same(DV.day({ hours: [ [ 0, 1, 2, 3, 4, 5, 6 ], [ 3600, 10, 20, 30, 40, 50, 60 ] ] }), [ 11, 22, 33, 44, 55, 66 ]));

let dvback = { last: { t: 5000, m: 0, gen: 1, v: { [A]: z6 } }, devices: {
	[A]: { seen: 0, last: 4990, rate: null, acc: null, minutes: [ [ 4800, 1, 1, 1, 1 ], [ 4980, 1, 1, 1, 1 ] ], hours: [ [ 3600, 1, 1, 1, 1, 1, 1 ] ] },
} };
DV.add(dvback, DV.snapshot({ [A]: z6 }, 1, 5000, 4900));
check('устройства: часы ушли назад — точки не раньше нового времени убраны', same(map(dvback.devices[A].minutes, x => x[0]), [ 4800 ]),
	sprintf("%J", dvback.devices[A].minutes));

// ---- Список устройств (truba.devices) без ubus и ядра ----

config(`
config device
	option name 'off'
	option mac 'AA:BB:CC:DD:EE:01'
	option policy 'tunnel'
	option enabled '0'

config device
	option mac 'aa:bb:cc:dd:ee:02'

config device
	option mac 'zz'
	option policy 'direct'

config device
	option mac 'aa:bb:cc:dd:ee:03'
	option policy 'weird'
`);
let dbad = [];
let dsecs = F.device_sections(dbad);
check('секции устройств: выключенная — «по правилам», без Политики — умолчание схемы, незнакомая — «по правилам», MAC в нижнем регистре',
	same(dsecs, [ { name: 'off', mac: 'aa:bb:cc:dd:ee:01', policy: 'rules' }, { name: '', mac: 'aa:bb:cc:dd:ee:02', policy: 'tunnel' },
	              { name: '', mac: 'aa:bb:cc:dd:ee:03', policy: 'rules' } ]), sprintf('%J', dsecs));
check('секции устройств: неверный MAC с Политикой — пропущен и перечислен', same(map(dbad, x => x.key), [ 'device.mac' ]));
check('настройки: в наборы Политик — только включённые «туннель» и «напрямую»',
	same(F.load().devices, [ { name: '', mac: 'aa:bb:cc:dd:ee:02', policy: 'tunnel' } ]), sprintf('%J', F.load().devices));
// Две секции с одним MAC (MAC в настройках бывает заглавными, повторы не запрещены): действует первая —
// и в наборах ядра, и в списке, и на вкладке. Иначе «напрямую» второй побеждала бы в classify.
config("config device\n\toption mac 'AA:BB:CC:DD:EE:05'\n\toption policy 'direct'\n\nconfig device\n\toption mac 'aa:bb:cc:dd:ee:05'\n\toption policy 'tunnel'\n");
check('секции устройств: две с одним MAC — действует первая', same(F.device_sections(), [ { name: '', mac: 'aa:bb:cc:dd:ee:05', policy: 'direct' } ]),
	sprintf('%J', F.device_sections()));
// enabled — флаг схемы, как у интерфейса: «off», «no», «false» выключают, а не только «0».
config("config device\n\toption mac 'aa:bb:cc:dd:ee:06'\n\toption policy 'direct'\n\toption enabled 'off'\n\nconfig device\n\toption mac 'aa:bb:cc:dd:ee:07'\n\toption policy 'direct'\n\toption enabled 'yes'\n");
check('секции устройств: enabled — флаг схемы', same(map(F.device_sections(), d => d.policy), [ 'rules', 'direct' ]), sprintf('%J', F.device_sections()));

let leases = DVC.parse_leases('1700000000 3C:7C:3F:00:00:9A 192.168.1.20 pc-living *\n1700000000 02:00:00:00:00:21 192.168.1.21 * 01:02\nмусор\n');
check('аренды: MAC в нижнем регистре, «*» — без имени',
	same(leases, [ { ip: '192.168.1.20', mac: '3c:7c:3f:00:00:9a', name: 'pc-living' }, { ip: '192.168.1.21', mac: '02:00:00:00:00:21', name: null } ]),
	sprintf('%J', leases));
let dhist = { devices: {
	'192.168.1.20': { seen: 1, last: 900, rate: [ 1, 2, 3, 4, 5, 6 ], minutes: [ [ 960, 1, 1, 1, 1 ] ], hours: [ [ 0, 10, 0, 0, 0, 0, 0 ] ] },
	'192.168.1.21': { seen: 1, last: 900, rate: null, minutes: [], hours: [] },
	'100.64.0.9':   { seen: 1, last: 900, rate: null, minutes: [], hours: [] },
} };
let dneigh = [ { ip: '192.168.1.30', mac: 'aa:bb:cc:dd:ee:30', dev: 'br-lan' }, { ip: '192.168.1.20', mac: '3c:7c:3f:00:00:9a', dev: 'br-lan' } ];
let dsec = [ { name: 'TV', mac: '02:00:00:00:00:21', policy: 'rules' }, { name: 'console', mac: 'aa:bb:cc:dd:ee:30', policy: 'tunnel' },
             { name: 'away', mac: 'aa:bb:cc:dd:ee:99', policy: 'direct' }, { name: 'old', mac: 'aa:bb:cc:dd:ee:98', policy: 'rules' } ];
let zone_of = (ip, dev) => (dev == 'br-lan' || match(ip, /^192\.168\.1\./)) ? 'lan' : (match(ip, /^100\.64\./) ? 'mesh' : null);
let dlist = DVC.merge(dhist, leases, dneigh, dsec, zone_of);
let dby = (k, v) => filter(dlist, d => d[k] == v)[0];
check('устройства: каждое один раз — из истории, с Политикой по соседу, с Политикой без адреса', length(dlist) == 5,
	join(' ', map(dlist, d => d.ip ?? d.mac)));
let d20 = dby('ip', '192.168.1.20');
check('устройство из истории с арендой: MAC и имя аренды, зона, трафик, сутки — сумма часов',
	d20?.mac == '3c:7c:3f:00:00:9a' && d20.name == 'pc-living' && d20.source == 'dhcp' && d20.zone == 'lan' && d20.policy == 'rules' &&
	same(d20.rate, [ 1, 2, 3, 4, 5, 6 ]) && same(d20.minutes, [ [ 960, 1, 1, 1, 1 ] ]) && d20.last == 900 && same(d20.day, [ 10, 0, 0, 0, 0, 0 ]),
	sprintf('%J', d20));
check('имя секции устройства важнее имени аренды', dby('ip', '192.168.1.21')?.name == 'TV');
let d30 = dby('ip', '192.168.1.30');
check('устройство с Политикой у соседа, без трафика: адрес соседа, источник neigh, трафика нет',
	d30?.source == 'neigh' && d30.policy == 'tunnel' && d30.name == 'console' && d30.zone == 'lan' && d30.rate == null && d30.day == null &&
	same(d30.minutes, []), sprintf('%J', d30));
let daway = dby('mac', 'aa:bb:cc:dd:ee:99');
check('устройство с Политикой не в сети: без адреса, источник config', daway?.ip == null && daway.source == 'config' && daway.policy == 'direct',
	sprintf('%J', daway));
let dmesh = dby('ip', '100.64.0.9');
check('узел mesh-VPN только по трафику: без MAC и источника, «по правилам», зона по адресу',
	dmesh?.mac == null && dmesh.source == null && dmesh.policy == 'rules' && dmesh.zone == 'mesh', sprintf('%J', dmesh));
check('секция «по правилам» без адреса и трафика — не в списке (без трафика — только с Политикой)',
	dby('mac', 'aa:bb:cc:dd:ee:98') == null);

// Аренда устарела (адрес уже у другого устройства): MAC — у соседа, имя чужой аренды не берётся.
let stale = DVC.merge({ devices: { '192.168.1.40': { seen: 1, last: 900, rate: null, minutes: [], hours: [] } } },
	[ { ip: '192.168.1.40', mac: 'aa:bb:cc:dd:ee:40', name: 'old-phone' } ], [ { ip: '192.168.1.40', mac: 'aa:bb:cc:dd:ee:41', dev: 'br-lan' } ],
	[], () => 'lan')[0];
check('устройство: сосед важнее устаревшей аренды — MAC соседа, без чужого имени, источник neigh',
	stale?.mac == 'aa:bb:cc:dd:ee:41' && stale.name == null && stale.source == 'neigh', sprintf('%J', stale));
// Процесс stats не пишет (служба остановлена): скорость в файле — старая, её не показывают как текущую.
let shist = { last: { t: 1000 }, devices: { '192.168.1.40': { seen: 1, last: 990, rate: [ 1, 2, 3, 4, 5, 6 ], minutes: [], hours: [] } } };
check('устройство: скорость старше трёх шагов — не текущая',
	DVC.merge(shist, [], [], [], () => null, 2000)[0].rate == null && same(DVC.merge(shist, [], [], [], () => null, 1010)[0].rate, [ 1, 2, 3, 4, 5, 6 ]));

// Список ограничен: в наборах до 1024 адресов, а ответ ubus и вкладка — нет. Остаются самые недавние
// и все с Политикой.
let many = { devices: {} };
for (let i = 0; i < 300; i++)
	many.devices[sprintf('10.200.%d.%d', i / 256, i % 256)] = { seen: 1, last: 1000 + i, rate: null, minutes: [], hours: [] };
let capped = DVC.merge(many, [], [ { ip: '10.200.0.0', mac: 'aa:bb:cc:dd:ee:77', dev: 'br-lan' } ],
	[ { name: 'nas', mac: 'aa:bb:cc:dd:ee:77', policy: 'direct' } ], () => null);
check('список: не больше DEV_LIST_MAX самых недавних, устройство с Политикой — всегда',
	length(capped) == C.DEV_LIST_MAX + 1 && filter(capped, d => d.ip == '10.200.1.43')[0] != null &&
	filter(capped, d => d.ip == '10.200.0.0')[0]?.policy == 'direct' && filter(capped, d => d.ip == '10.200.0.1')[0] == null,
	sprintf('%d', length(capped)));

// Интерфейс адреса без соседа — по таблицам маршрутов одним вызовом: самый длинный префикс, без default.
let routes = [ { dst: 'default', gateway: '192.0.2.1', dev: 'eth0' }, { dst: '192.168.1.0/24', dev: 'br-lan' },
               { dst: '100.64.0.0/10', dev: 'tailscale0', table: '52' }, { dst: '100.64.0.9', dev: 'mesh1' }, { type: 'unreachable', dst: '10.0.0.0/8' } ];
let rt = DVC.route_table(routes);
check('маршрут: самый длинный префикс, default и маршруты без интерфейса не в счёт',
	DVC.route_dev(rt, '100.64.0.9') == 'mesh1' && DVC.route_dev(rt, '100.64.1.1') == 'tailscale0' &&
	DVC.route_dev(rt, '192.168.1.5') == 'br-lan' && DVC.route_dev(rt, '8.8.8.8') == null && DVC.route_dev(rt, '10.1.1.1') == null);

// ---- Соединения устройства (connections) из образца conntrack ----

let ct_text = join('\n', [
	'ipv4     2 tcp      6 431999 ESTABLISHED src=192.168.1.50 dst=1.2.3.4 sport=51000 dport=443 packets=10 bytes=1000 src=1.2.3.4 dst=203.0.113.5 sport=443 dport=51000 packets=12 bytes=9000 [ASSURED] mark=16777216 zone=0 use=2',
	'ipv4     2 udp      17 29 src=192.168.1.50 dst=1.2.3.4 sport=5000 dport=3478 packets=1 bytes=100 [UNREPLIED] src=1.2.3.4 dst=203.0.113.5 sport=3478 dport=5000 packets=0 bytes=0 mark=16777216 zone=0 use=2',
	'ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.50 dst=5.6.7.8 sport=51001 dport=80 packets=3 bytes=300 src=5.6.7.8 dst=192.168.1.50 sport=80 dport=51001 packets=3 bytes=400 [ASSURED] mark=33554432 zone=0 use=2',
	'ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.60 dst=1.2.3.4 sport=1 dport=443 packets=1 bytes=1 src=1.2.3.4 dst=192.168.1.60 sport=443 dport=1 packets=1 bytes=1 mark=0 zone=0 use=2',
	'ipv6     10 tcp     6 100 ESTABLISHED src=fd00::50 dst=2001:db8::1 sport=1 dport=443 packets=1 bytes=1 src=2001:db8::1 dst=fd00::50 sport=443 dport=1 packets=1 bytes=1 mark=0 zone=0 use=2',
	'',
]);
let cts = DVC.parse_conntrack(ct_text, '192.168.1.50');
check('conntrack: только соединения устройства по IPv4, поля первого', length(cts) == 3 &&
	same(cts[0], { proto: 'tcp', dst: '1.2.3.4', dport: 443, up: 1000, down: 9000, mark: 16777216 }), sprintf('%J', cts));
// Из файла — построчно (функция-источник строк): большую таблицу не держать в памяти дважды.
let ct_lines = split(ct_text, '\n'), ct_i = 0;
check('conntrack: построчный источник — то же, что текст', same(DVC.parse_conntrack(() => ct_lines[ct_i++], '192.168.1.50'), cts));
// Сроки истории по устройствам — у службы, интерфейс берёт их из схемы (ADR 0015).
check('схема: шаг и срок поминутной истории устройств', same(F.schema().consts.devices, { step: 60, span: 3600 }), sprintf('%J', F.schema().consts.devices));
let cg = DVC.group(cts);
check('conntrack: по адресам, крупнейший первым; протокол и порт — самого крупного соединения',
	cg.total == 3 && cg.acct && length(cg.addrs) == 2 &&
	same(cg.addrs[0], { addr: '1.2.3.4', proto: 'tcp', port: 443, conns: 2, up: 1100, down: 9000, mark: 16777216 }), sprintf('%J', cg));
let noacct = DVC.group(DVC.parse_conntrack(replace(ct_text, / packets=[0-9]+ bytes=[0-9]+/g, ''), '192.168.1.50'));
check('conntrack: без nf_conntrack_acct — байтов нет, порядок по числу соединений',
	!noacct.acct && noacct.addrs[0].addr == '1.2.3.4' && noacct.addrs[0].up == null && noacct.addrs[1].down == null, sprintf('%J', noacct));
let big = [];
for (let i = 0; i < 5000; i++)
	push(big, sprintf('ipv4     2 tcp      6 100 ESTABLISHED src=192.168.1.50 dst=198.51.100.%d sport=%d dport=443 packets=1 bytes=%d src=198.51.100.%d dst=192.168.1.50 sport=443 dport=%d packets=1 bytes=1 mark=0 zone=0 use=2',
		i % 25, 10000 + i, i % 25, i % 25, 10000 + i));
let bg = DVC.group(DVC.parse_conntrack(join('\n', big), '192.168.1.50'));
check('conntrack: 5000 соединений к 25 адресам — 20 адресов, всего 5000', length(bg.addrs) == 20 && bg.total == 5000 && bg.addrs[0].addr == '198.51.100.24');

// ---- ubus-API: методы, которые читают файлы, без rpcd ----

let api = loadfile(PLUGIN)()?.truba;
check('API: плагин регистрирует объект truba', api?.status != null);
check('API: плагин без своих путей и своей shq', !match(readfile(PLUGIN), /'\/(var|usr|tmp|etc)\/|function shq/));
let now = time();
system([ 'mkdir', '-p', C.RUN_DIR ]);
writefile(C.RATES_FILE, sprintf('%J', { step: 5, points: [ [ now - 700, 1, 1, 1, 1 ], [ now - 300, 2, 2, 2, 2 ], [ now - 10 ], [ now - 5, 3, 3, 3, 3 ] ] }));
writefile(C.RATES_MIN_FILE, sprintf('%J', { step: 60, points: [ [ now - 90000, 1, 1, 1, 1 ], [ now - 120, 2, 2, 2, 2 ] ] }));
let rates = (args) => api.rates.call({ args });
let rr = rates({ span: 600 });
check('API rates: только точки за срок, разрыв тоже точка', rr.step == 5 && same(map(rr.points, p => p[0]), [ now - 300, now - 10, now - 5 ]),
	sprintf('%J', rr.points));
check('API rates: since — только новые точки', same(map(rates({ span: 600, since: now - 10 }).points, p => p[0]), [ now - 5 ]));
check('API rates: since старше срока не расширяет его', length(rates({ span: 600, since: now - 5000 }).points) == 3);
rr = rates({ span: 86400 });
check('API rates: дольше часа — поминутные средние за сутки', rr.step == 60 && same(map(rr.points, p => p[0]), [ now - 120 ]));
check('API rates: время Роутера', rr.now >= now);
check('API check: цель с пробелом или «;» не уходит в командную строку',
	api.check.call({ args: { target: 'a b' } }).error == 'invalid target' && api.check.call({ args: { target: 'x;reboot' } }).error == 'invalid target');
check('API nat_result: итога ещё нет — пустой ответ', same(api.nat_result.call(), {}));
check('API connections: не IPv4 не уходит в командную строку',
	api.connections?.call({ args: { ip: '1.2.3.4; reboot' } })?.error == 'invalid ip' && api.connections.call({ args: {} }).error == 'invalid ip');

T.finish();
