// Быстрые проверки модулей без procd, сети и списков: план (порядок Категорий), генерация
// правил nftables и конфига mosdns (сверка с эталонами в tests/router/golden), чтение
// настроек, Приоритет «Проверить домен/IP». Секунды вместо минут интеграционного теста.
//   ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' tests/router/test_units.uc <каталог эталонов>
// UPDATE_GOLDEN=1 — записать эталоны заново (tests/run.sh units монтирует репозиторий на запись).
'use strict';

import { readfile, writefile, mkdir, popen } from 'fs';
import * as C from 'truba.const';
import * as P from 'truba.plan';
import * as R from 'truba.render';
import * as F from 'truba.conf';
import * as K from 'truba.check';

const GOLDEN = ARGV[0] ?? '/repo/tests/router/golden';
const UPDATE = !!getenv('UPDATE_GOLDEN');
let fails = 0;

function check(name, cond, detail) {
	if (cond) {
		print('ok    ', name, '\n');
	}
	else {
		print('FAIL  ', name, detail ? (' — ' + detail) : '', '\n');
		fails++;
	}
}

function same(a, b) {
	return sprintf('%J', a) == sprintf('%J', b);
}

// Сверка с эталоном: при расхождении — первая отличающаяся строка.
function golden(name, text) {
	let path = GOLDEN + '/' + name;
	if (UPDATE) {
		writefile(path, text);
		print('upd   эталон ', name, '\n');
		return;
	}
	let want = readfile(path);
	if (want == text) {
		check('эталон ' + name, true);
		return;
	}
	let a = split(want ?? '', '\n'), b = split(text, '\n'), i = 0;
	while (i < length(a) && i < length(b) && a[i] == b[i])
		i++;
	check('эталон ' + name, false, want == null ? 'нет файла (UPDATE_GOLDEN=1 tests/run.sh units)'
		: sprintf('строка %d: ждали «%s», получили «%s»', i + 1, a[i] ?? '<конец>', b[i] ?? '<конец>'));
}

// Таблицу принимает ядро: nft -c проверяет её, ничего не загружая (нужен CAP_NET_ADMIN).
// Без правила socket mark: ему нужен модуль nft_socket, которого в ядре хоста может не быть
// (WSL); его проверяет интеграционный тест на настоящем procd.
function nft_ok(name, text) {
	writefile('/tmp/unit.nft', join('\n', filter(split(text, '\n'), l => index(l, 'socket mark') < 0)));
	let p = popen('nft -c -f /tmp/unit.nft 2>&1', 'r');
	let out = p.read('all');
	let rc = p.close();
	check('nft -c принимает ' + name, rc == 0, trim(out ?? ''));
}

// ---- План: Действия Категорий текущего Режима и порядок проверки ----

let cats = [
	{ set: 'geosite', tag: 'wide',   count: 500 },
	{ set: 'geosite', tag: 'zdirect', count: 10 },
	{ set: 'geosite', tag: 'tunnel', count: 10 },
	{ set: 'geosite', tag: 'ads',    count: 10 },
	{ set: 'geosite', tag: 'adirect', count: 10 },
	{ set: 'geosite', tag: 'unused', count: 1 },
	{ set: 'geoip',   tag: 'ru',     count: 3 },
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
		dns: { tunnel: [ 'https://1.1.1.1/dns-query' ], direct: [ 'tls://common.dot.dns.yandex.net@77.88.8.8' ],
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

let notimeout = R.nft_full(mk({ set_timeout: 0 }), plan, ctx_of());
check('без срока: в наборах IP из DNS нет timeout и expires',
	!match(notimeout, /timeout|expires/) && index(notimeout, '198.51.100.1') >= 0);
nft_ok('таблицу без срока', notimeout);

let minimal = R.nft_minimal(mk(), ctx_of());
golden('truba-minimal.nft', minimal);
nft_ok('минимальную таблицу', minimal);

golden('mosdns.json', sprintf('%.J\n', R.mosdns(mk(), plan, [ 'ntp.example' ])));
let noapi = R.mosdns(mk({ api: null }), sel, []);
check('mosdns: без адреса API — без API, без своих хостов — без c_router',
	noapi.api == null && !length(filter(noapi.plugins, p => p.tag == 'c_router')));

// ---- Чтение настроек: неверные значения пропускаются ----

check('адрес DNS: схемы mosdns и «@IP»', F.upstream_ok('https://1.1.1.1/dns-query') && F.upstream_ok('tls://dns.example@1.2.3.4') &&
	F.upstream_ok('1.1.1.1') && F.upstream_ok('udp://[2001:db8::1]:53'));
check('адрес DNS: опечатка в схеме и путь без схемы — нет', !F.upstream_ok('htps://1.1.1.1/dns-query') && !F.upstream_ok('1.1.1.1/dns-query'));

mkdir('/etc/config');
writefile('/etc/config/truba', `
config main 'main'
	option mode 'selective'

config dns 'dns'
	option set_timeout '100'
	option port '70000'

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
	same(sort(map(cfg.invalid, x => x.key)), [ 'device.mac', 'dns.port', 'dns.set_timeout', 'watchdog.probe' ]),
	join(' ', sort(map(cfg.invalid, x => x.key))));
check('настройки: верный MAC — в нижнем регистре', same(cfg.devices, [ { name: '', mac: 'aa:bb:cc:dd:ee:ff', policy: 'direct' } ]));
check('настройки: API mosdns — на соседнем порту', cfg.dns.port == 5335 && cfg.dns.api == '127.0.0.1:5336');
writefile('/etc/config/truba', "config dns 'dns'\n\toption set_timeout '0'\n");
check('настройки: срок 0 — без срока', F.load().dns.set_timeout == 0);

// Адрес Трубы внутри Туннеля — из адреса Роутера (ubus нет — из настроек).
function peer_of(addr) {
	writefile('/etc/config/network', sprintf("config interface 'awg0'\n\toption proto 'amneziawg'\n\tlist addresses '%s'\n\n" +
		"config amneziawg_awg0\n\toption endpoint_host '203.0.113.10'\n", addr));
	let t = F.tunnel_info('awg0');
	return [ t.peer, t.subnet, t.endpoint ];
}
check('Туннель /30: Роутер .2 — Труба .1', same(peer_of('10.77.77.2/30'), [ '10.77.77.1', '10.77.77.0/30', '203.0.113.10' ]));
check('Туннель /31: второй адрес', same(peer_of('10.0.0.0/31')[0], '10.0.0.1'));
check('Туннель /24: Роутер .1 — Труба .2, а не он сам', same(peer_of('10.0.0.1/24')[0], '10.0.0.2'));

// ---- «Проверить домен/IP»: Приоритет ----

let ip = '198.51.100.7', n = 0xc6336407;
let kern = (sets) => ({ bypass4: [], gs_tunnel4: [], gs_direct4: [], ...sets });
let here = [ [ n, n ] ];
let rcfg = { routing: true, devices: [ { name: 'tv', mac: 'aa:bb:cc:dd:ee:ff', policy: 'tunnel' } ] };
let v = (geoip, sets, mac, c) => K.ip_verdict(c ?? rcfg, plan, ip, n, geoip, kern(sets), mac);
let r = v([ 'ru' ], { gs_tunnel4: here });
check('check: IP из DNS «Туннель» раньше geoip «Напрямую»', r.action == 'tunnel' && r.reason == 'geosite_ip' && r.sets.gi_direct);
r = v([], { gs_tunnel4: here, gs_direct4: here });
check('check: общий IP из DNS — Туннель побеждает Напрямую', r.action == 'tunnel');
r = v([ 'ru' ], { gs_direct4: here }, 'AA:BB:CC:DD:EE:FF');
check('check: Политика устройства раньше IP из DNS', r.action == 'tunnel' && r.reason == 'device' && r.device == 'tv');
r = v([], { bypass4: here, gs_tunnel4: here });
check('check: адрес домашней сети — мимо Приоритета', r.action == 'direct' && r.reason == 'local');
r = v([ 'ru' ], {}, null, { routing: false, devices: [] });
check('check: Маршрутизация выкл — наборов geoip нет, по Режиму', r.action == 'tunnel' && r.reason == 'mode' && !r.sets.gi_direct);
let bplan = { ...plan, geoip: { block: [ 'ru' ], tunnel: [], direct: [] } };
r = K.ip_verdict(rcfg, bplan, ip, n, [ 'ru' ], kern({ gs_tunnel4: here }), 'aa:bb:cc:dd:ee:ff');
check('check: Блок geoip раньше всего', r.action == 'block' && r.reason == 'geoip_block');

print('\n', fails ? sprintf('%d FAILED', fails) : 'ALL OK', '\n');
exit(fails ? 1 : 0);
