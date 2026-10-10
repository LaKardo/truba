// Модули Трубы без procd и сети — секунды. Всё, что можно проверить без ядра и служб:
// план, Приоритет, правила nftables и конфиг mosdns (эталоны в tests/golden + nft -c),
// чтение настроек, «Проверить домен/IP» на синтетических Наборах правил, история скорости,
// методы ubus-API, которые читают файлы.
//   ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' -L '/repo/tests/lib/*.uc' units.uc [каталог эталонов]
// UPDATE_GOLDEN=1 — записать эталоны заново (tests/run.sh монтирует репозиторий на запись).
'use strict';

import { readfile, writefile, mkdir, popen } from 'fs';
import * as T from 'tlib';
import * as C from 'truba.const';
import * as P from 'truba.plan';
import * as R from 'truba.render';
import * as F from 'truba.conf';
import * as K from 'truba.check';
import * as S from 'truba.stats';

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

let notimeout = R.nft_full(mk({ set_timeout: 0 }), plan, ctx_of());
check('без срока: в наборах IP из DNS нет timeout и expires',
	!match(notimeout, /timeout|expires/) && index(notimeout, '198.51.100.1') >= 0);
nft_ok('таблицу без срока', notimeout);

let minimal = R.nft_minimal(mk(), ctx_of());
golden('truba-minimal.nft', minimal);
nft_ok('минимальную таблицу', minimal);

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
check('mosdns: у каждого сервера idle_timeout, один сервер — просто forward',
	length(filter(three.plugins, p => p.type == 'forward' && p.args.upstreams[0].idle_timeout != 180)) == 0 &&
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
	same(cfg.dns.tunnel, [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ]), sprintf('%J', cfg.dns.tunnel));
check('настройки: верный MAC — в нижнем регистре', same(cfg.devices, [ { name: '', mac: 'aa:bb:cc:dd:ee:ff', policy: 'direct' } ]));
check('настройки: API mosdns — на соседнем порту', cfg.dns.port == 5335 && cfg.dns.api == '127.0.0.1:5336');
config("config dns 'dns'\n\toption set_timeout '0'\n");
check('настройки: срок 0 — без срока', F.load().dns.set_timeout == 0);

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

// ---- ubus-API: методы, которые читают файлы, без rpcd ----

let api = loadfile(PLUGIN)()?.truba;
check('API: плагин регистрирует объект truba', api?.status != null);
let now = time();
system([ 'mkdir', '-p', '/var/run/truba' ]);
writefile('/var/run/truba/rates.json', sprintf('%J', { step: 5, points: [ [ now - 700, 1, 1, 1, 1 ], [ now - 300, 2, 2, 2, 2 ], [ now - 10 ], [ now - 5, 3, 3, 3, 3 ] ] }));
writefile('/var/run/truba/rates-min.json', sprintf('%J', { step: 60, points: [ [ now - 90000, 1, 1, 1, 1 ], [ now - 120, 2, 2, 2, 2 ] ] }));
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

T.finish();
