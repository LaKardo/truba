// Чтение настроек Трубы из UCI и сведений о системе (зоны, адреса, Туннель).
'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';
import * as U from 'truba.util';
import * as C from 'truba.const';

const MAC_RE = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;

// Схемы адресов, которые понимает mosdns 5; без схемы — udp. Адрес с опечаткой в схеме
// останавливает mosdns целиком, а с ним DNS всей сети, поэтому в его конфиг он не попадает.
// Интерфейс получает список и само выражение вместе со схемой настроек (truba schema, ADR 0015).
export const UPSTREAM_SCHEMES = [ 'udp', 'tcp', 'tcp+pipeline', 'tls', 'tls+pipeline', 'https', 'h3', 'quic', 'doq' ];

// «[схема://]хост[:порт][/путь][@IP]»; путь — только со схемой. Группы: 2 — схема, 5 — путь, 6 — «@IP».
// Регулярные выражения ucode — POSIX: внутри [...] нет \s, только [:space:].
export const UPSTREAM_RE = '^(([a-z0-9+]+)://)?(\\[[0-9a-fA-F:.]+\\]|[^][[:space:]/@:]+)(:[0-9]+)?(/[^[:space:]@]*)?(@[0-9.]+)?$';
const UPSTREAM_RX = regexp(UPSTREAM_RE);

// Адрес DNS-сервера по частям: { addr, dial_addr } (addr — без «@IP») или null, если mosdns его не поймёт.
export function parse_upstream(u) {
	let m = (type(u) == 'string') ? match(u, UPSTREAM_RX) : null;
	if (!m || ((m[2] == null) ? (m[5] != null) : !(m[2] in UPSTREAM_SCHEMES)))
		return null;
	return m[6] ? { addr: substr(u, 0, length(u) - length(m[6])), dial_addr: substr(m[6], 1) } : { addr: u };
};

export function upstream_ok(u) {
	return parse_upstream(u) != null;
};

// Схема настроек (ADR 0015): тип каждой опции UCI, значение по умолчанию и пределы — только здесь.
// По ней load() проверяет настройки, интерфейс (truba schema) строит подсказки и проверки полей,
// а юнит-тест сверяет с ней /etc/config/truba из пакета.
// Поля: type, def; int — lo, hi и min («0 или не меньше min»); enum — values; pattern — re (POSIX).
export const SCHEMA = {
	main: {
		routing:    { type: 'bool', def: true },
		mode:       { type: 'enum', values: [ 'all', 'selective' ], def: 'all' },
		killswitch: { type: 'bool', def: true },
		// Имя интерфейса попадает в правила nftables и в имена объектов ubus.
		iface:      { type: 'pattern', re: '^[A-Za-z0-9_]{1,15}$', def: 'awg0' },
		zone:       { type: 'list', def: [ 'lan' ] },
		dns_hijack: { type: 'bool', def: true },
		upnp:       { type: 'bool', def: false },
		// STUN-серверы «Проверки NAT» («host:port»); пусто — стандартные из truba.nattest.
		stun:       { type: 'list', def: [] },
	},
	dns: {
		// DNS-сервер на Трубе (install-vps.sh, ADR 0013) и запасной DoH: каждый запрос идёт к обоим. Без сервера
		// на Трубе (VPS ставился другим способом) порт сразу отвечает «закрыт», и отвечает DoH.
		tunnel_upstream: { type: 'upstreams', def: [ 'udp://10.77.77.1', 'https://1.1.1.1/dns-query' ] },
		// Два сервера: mosdns спрашивает оба разом и берёт первый ответ, поэтому обрыв одного
		// соединения не оставляет запросы без ответа (на живом роутере DoH 77.88.8.8 изредка рвался).
		// pipelining: запросы, пришедшие разом, идут по одному соединению, а не открывают по TLS на каждый.
		direct_upstream: { type: 'upstreams', def: [ 'tls+pipeline://common.dot.dns.yandex.net@77.88.8.8',
		                                             'tls+pipeline://common.dot.dns.yandex.net@77.88.8.1' ] },
		port:            { type: 'int', def: 5335, lo: 1, hi: 65535 },
		ttl_max:         { type: 'int', def: 300, lo: 30, hi: 86400 },
		cache_size:      { type: 'int', def: 65536, lo: 1024, hi: 1048576 },
		lazy_cache_ttl:  { type: 'int', def: 86400, lo: 0, hi: 604800 },
		// Срок IP из DNS в наборах gs_* (ADR 0007): 0 — без срока, иначе от 10 минут до недели. Срок
		// короче 10 минут — короче TTL ответов: адреса пропадали бы из наборов, пока устройства ещё
		// пользуются ответом, и новые соединения шли бы мимо своей Категории.
		set_timeout:     { type: 'int', def: 86400, lo: 0, hi: 604800, min: 600 },
	},
	lists: {
		geoip_url:      { type: 'string', def: 'https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat' },
		geoip_mirror:   { type: 'string', def: 'https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat' },
		geosite_url:    { type: 'string', def: 'https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat' },
		geosite_mirror: { type: 'string', def: 'https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat' },
		via_tunnel:     { type: 'bool', def: true },
		auto_update:    { type: 'bool', def: true },
	},
	watchdog: {
		enabled:       { type: 'bool', def: true },
		// Интервал 0 — цикл без пауз, 0 неудач — деление на ноль в счёте перезапусков.
		interval:      { type: 'int', def: 30, lo: 10, hi: 600 },
		handshake_max: { type: 'int', def: 180, lo: 60, hi: 3600 },
		fails:         { type: 'int', def: 3, lo: 1, hi: 20 },
		// Неверный адрес для ping — Туннель «не отвечает» навсегда, и при Аварийной блокировке
		// весь трафик «Туннеля» отбрасывается. Пусто — адрес Трубы внутри Туннеля.
		probe:         { type: 'ipv4', def: '' },
	},
	device: {
		enabled: { type: 'bool', def: true },
		// LuCI не сохраняет значение по умолчанию: нет policy — значит «Всё в туннель».
		// rules — «По правилам»: устройство не попадает ни в один набор Политик.
		policy:  { type: 'enum', values: [ 'tunnel', 'direct', 'rules' ], def: 'tunnel' },
	},
};

// Одно неверное значение в UCI (опечатка в консоли, старый конфиг) не должно ломать
// применение целиком: оно пропускается, вместо него — значение по умолчанию, а «Обзор»
// показывает, что пропущено (bad → applied.invalid). Флаги и выбор из списка неверными
// не бывают: всё, кроме «да», — «нет», незнакомый вариант — по умолчанию.
// raw — значение из UCI (строка или список); null — опции нет.
export function check_value(sec, key, raw, bad) {
	let o = SCHEMA[sec][key];
	let invalid = (v) => {
		push(bad ?? [], { key: sec + '.' + key, value: '' + v });
		return o.def;
	};
	if (raw == null)
		return o.def;
	switch (o.type) {
	case 'bool':
		return (type(raw) == 'bool') ? raw : (raw in [ '1', 'true', 'on', 'yes' ]);
	case 'enum':
		return (raw in o.values) ? raw : o.def;
	case 'string':
		return raw;
	case 'list':
		return length(U.to_list(raw)) ? U.to_list(raw) : o.def;
	case 'int':
		if (raw === '')
			return o.def;
		let n = (type(raw) == 'int') ? raw : ((type(raw) == 'string' && match(raw, /^[0-9]+$/)) ? int(raw) : null);
		// Число больше int64 int() читает как NaN (double), а любое сравнение с NaN ложно: без
		// проверки типа порт из 80 цифр прошёл бы пределы, и dnsmasq с сервером 127.0.0.1#NaN
		// не запустился бы — сеть без DNS и DHCP.
		if (type(n) != 'int' || n < o.lo || n > o.hi || (o.min && n > 0 && n < o.min))
			return invalid(raw);
		return n;
	case 'pattern':
		if (raw === '')
			return o.def;
		return (type(raw) == 'string' && match(raw, regexp(o.re))) ? raw : invalid(raw);
	case 'ipv4':
		return (raw === '' || U.is_ipv4(raw)) ? raw : invalid(raw);
	case 'upstreams':
		// Неверные адреса пропускаются; если не осталось ни одного — по умолчанию.
		let all = U.to_list(raw), good = filter(all, upstream_ok);
		for (let u in all)
			if (!upstream_ok(u))
				invalid(u);
		return length(good) ? good : o.def;
	}
	die('схема: неизвестный тип ' + o.type);
};

// Схема и константы, которые нужны интерфейсу (вызов truba.schema).
export function schema() {
	return {
		sections: SCHEMA,
		upstream_schemes: UPSTREAM_SCHEMES,
		upstream_re: UPSTREAM_RE,
		consts: { fw_zone: C.FW_ZONE, probe_window: C.PROBE_WINDOW, history: C.HISTORY, mosdns_addr: C.MOSDNS_ADDR,
		          devices: C.DEV_HISTORY },
	};
};

// Секции устройств с Политикой так, как её понимает служба: tunnel и direct — у включённой секции
// с одной из них (нет опции — умолчание схемы), иначе rules. Незнакомая Политика — как «По правилам»,
// а не как умолчание: устройство не уходит в Туннель по опечатке. Секция без верного MAC пропускается:
// MAC попадает в набор nftables, с опечаткой не загрузилась бы вся таблица; если секция что-то
// меняла бы, она — в bad. Из нескольких секций с одним MAC действует первая: иначе в наборах ядра
// «напрямую» одной побеждала бы «туннель» другой, а вкладка и проверка показывали бы первую.
// c — курсор с загруженным truba (иначе свой).
export function device_sections(bad, c) {
	if (!c) {
		c = cursor();
		c.load('truba');
	}
	let out = [], seen = {};
	c.foreach('truba', 'device', (s) => {
		// enabled — флаг схемы, как его читает и интерфейс: «off», «no», «false» тоже выключают.
		let policy = s.policy ?? SCHEMA.device.policy.def;
		if (!(policy in [ 'tunnel', 'direct' ]) || !check_value('device', 'enabled', s.enabled))
			policy = 'rules';
		let mac = (type(s.mac) == 'string') ? lc(s.mac) : '';
		if (!match(mac, MAC_RE)) {
			if (s.mac && policy != 'rules')
				push(bad ?? [], { key: 'device.mac', value: '' + s.mac });
			return;
		}
		if (seen[mac])
			return;
		seen[mac] = true;
		push(out, { name: s.name ?? '', mac, policy });
	});
	return out;
};

export function load() {
	let c = cursor();
	c.load('truba');

	let bad = [];
	let v = (sec, key) => check_value(sec, key, c.get('truba', sec, key), bad);

	let cfg = {
		routing: v('main', 'routing'),
		mode: v('main', 'mode'),
		killswitch: v('main', 'killswitch'),
		iface: v('main', 'iface'),
		zones: v('main', 'zone'),
		dns_hijack: v('main', 'dns_hijack'),
		upnp: v('main', 'upnp'),
		stun: v('main', 'stun'),
		rules: [],
		devices: [],
		dns: {
			tunnel: v('dns', 'tunnel_upstream'),
			direct: v('dns', 'direct_upstream'),
			port: v('dns', 'port'),
			ttl_max: v('dns', 'ttl_max'),
			cache_size: v('dns', 'cache_size'),
			lazy_cache_ttl: v('dns', 'lazy_cache_ttl'),
			set_timeout: v('dns', 'set_timeout'),
		},
		lists: {
			geoip_url: v('lists', 'geoip_url'),
			geoip_mirror: v('lists', 'geoip_mirror'),
			geosite_url: v('lists', 'geosite_url'),
			geosite_mirror: v('lists', 'geosite_mirror'),
			via_tunnel: v('lists', 'via_tunnel'),
			auto_update: v('lists', 'auto_update'),
		},
		watchdog: {
			enabled: v('watchdog', 'enabled'),
			interval: v('watchdog', 'interval'),
			handshake_max: v('watchdog', 'handshake_max'),
			fails: v('watchdog', 'fails'),
			probe: v('watchdog', 'probe'),
		},
		invalid: bad,
	};
	// HTTP API mosdns (счётчики кэша для «Обзора») — на соседнем с DNS порту, на адресе mosdns.
	let p = cfg.dns.port;
	cfg.dns.api = sprintf('%s:%d', C.MOSDNS_ADDR, (p < 65535) ? p + 1 : p - 1);

	c.foreach('truba', 'rule', (s) => {
		if (!s.set || !s.tag || !(s.action in C.ACTIONS))
			return;
		push(cfg.rules, {
			mode: (s.mode == 'selective') ? 'selective' : 'all',
			set: (s.set == 'geoip') ? 'geoip' : 'geosite',
			tag: lc(s.tag),
			action: s.action,
		});
	});

	// В наборы Политик попадают только «Всё в туннель» и «Всё напрямую».
	cfg.devices = filter(device_sections(bad, c), (d) => d.policy != 'rules');

	return cfg;
};

// Значения для shell-скриптов пакета (truba env, ADR 0015): eval "$(truba env)" даёт TRUBA_* —
// пути, имена и действующие настройки после проверки, а не сырые значения UCI.
export function env_lines() {
	let cfg = load();
	let vars = {
		RUN_DIR: C.RUN_DIR, ETC_DIR: C.ETC_DIR, DATA_DIR: C.DATA_DIR, CONF_DIR: C.CONF_DIR,
		LISTS_DIR: C.LISTS_DIR, STATE_DIR: C.STATE_DIR, GOOD_DIR: C.GOOD_DIR, DL_DIR: C.DL_DIR,
		APPLIED: C.APPLIED_FILE, MOSDNS_CONF: C.MOSDNS_CONF, STAMP: C.STAMP_FILE,
		INIT: C.INIT, REINSTALL: C.REINSTALL, FW_ZONE: C.FW_ZONE, NO6_SUFFIX: C.FW_NO6_SUFFIX,
		IFACE: cfg.iface, WATCHDOG: cfg.watchdog.enabled ? '1' : '0',
	};
	let s = '';
	for (let k, v in vars)
		s += 'TRUBA_' + k + '=' + U.shq(v) + '\n';
	return s;
};

// Сведения о Туннеле из конфигурации network: адрес, адрес Трубы внутри, endpoint, а из одного вызова
// ubus — поднят ли интерфейс и его l3-устройство (up, device).
export function tunnel_info(iface, ub) {
	let c = cursor();
	c.load('network');
	let ifc = c.get_all('network', iface);
	let res = { exists: (ifc != null), disabled: false, up: false, device: iface, address: null, prefix: null,
	            peer: null, subnet: null, endpoint: null, endpoint_port: null };
	if (!ifc)
		return res;

	res.disabled = (ifc.disabled == '1');
	let addr = null;

	// Предпочтительно — фактический адрес поднятого интерфейса.
	let st = U.ubus_call(ub, 'network.interface.' + iface, 'status');
	res.up = !!st?.up;
	res.device = st?.l3_device ?? st?.device ?? iface;
	let a4 = st?.['ipv4-address']?.[0];
	if (a4?.address)
		addr = a4.address + '/' + (a4.mask ?? 32);

	// Иначе — из настроек: amneziawg хранит addresses, static — ipaddr/netmask.
	for (let a in U.to_list(ifc.addresses)) {
		if (addr == null && match(a, /^[0-9.]+(\/[0-9]+)?$/))
			addr = a;
	}
	if (addr == null && U.is_ipv4(ifc.ipaddr)) {
		let nm = U.ip2int(ifc.netmask ?? '255.255.255.255'), len = 0;
		while (len < 32 && ((nm >> (31 - len)) & 1))
			len++;
		addr = ifc.ipaddr + '/' + len;
	}
	if (addr) {
		let m = match(addr, /^([0-9.]+)(\/([0-9]+))?$/);
		res.address = m[1];
		res.prefix = (m[3] != null) ? int(m[3]) : 32;
		if (res.prefix < 32) {
			let r = U.cidr_range(res.address + '/' + res.prefix);
			res.subnet = U.int2ip(r[0]) + '/' + res.prefix;
			// Адрес Трубы: для /30 и /31 — второй хост подсети, иначе первый хост.
			let me = U.ip2int(res.address);
			if (res.prefix >= 30) {
				let first = (res.prefix == 31) ? r[0] : r[0] + 1;
				let second = (res.prefix == 31) ? r[1] : r[1] - 1;
				res.peer = U.int2ip(me == first ? second : first);
			}
			else {
				// Первый хост подсети, а если первый — сам Роутер, то второй: иначе watchdog пинговал бы себя.
				res.peer = U.int2ip((me == r[0] + 1) ? r[0] + 2 : r[0] + 1);
			}
		}
	}

	c.foreach('network', 'amneziawg_' + iface, (s) => {
		if (res.endpoint == null && s.endpoint_host && s.disabled != '1') {
			res.endpoint = s.endpoint_host;
			res.endpoint_port = s.endpoint_port;
		}
	});

	return res;
};

// IP Трубы: endpoint, при необходимости отрезолвленный.
export function vps_ip(tinfo) {
	if (!tinfo.endpoint)
		return null;
	if (U.is_ipv4(tinfo.endpoint))
		return tinfo.endpoint;
	let ips = U.nslookup(tinfo.endpoint);
	return ips[length(ips) - 1];
};

// Устройства (l3) сетей, входящих в выбранные зоны межсетевого экрана.
export function zone_devices(zones, ub) {
	let c = cursor();
	c.load('firewall');
	let nets = [], devs = [];
	c.foreach('firewall', 'zone', (z) => {
		if (!(z.name in zones))
			return;
		for (let n in U.to_list(z.network))
			push(nets, n);
		for (let d in U.to_list(z.device))
			push(devs, d);
	});

	let own = (ub == null && length(nets)) ? connect() : null;
	for (let n in nets) {
		let st = (ub ?? own)?.call('network.interface.' + n, 'status', {});
		let dev = st?.l3_device ?? st?.device;
		if (dev)
			push(devs, dev);
	}
	own?.disconnect();
	return uniq(devs);
};

// Зона межсетевого экрана каждого l3-устройства: { устройство: зона } по всем зонам — для списка
// устройств (через какой интерфейс виден адрес).
export function dev_zones(ub) {
	let c = cursor();
	c.load('firewall');
	let zones = [];
	c.foreach('firewall', 'zone', (z) => {
		if (z.name)
			push(zones, z.name);
	});
	let out = {};
	for (let z in zones)
		for (let d in zone_devices([ z ], ub))
			out[d] ??= z;
	return out;
};

// Все подключённые IPv4-подсети (scope link в main) — локальный трафик не трогаем.
export function connected_subnets() {
	let r = U.run('ip -4 -j route show table main scope link');
	let out = [];
	try {
		for (let rt in json(r.out) ?? []) {
			let dst = rt.dst;
			if (!dst || dst == 'default')
				continue;
			if (!match(dst, /\//))
				dst += '/32';
			push(out, dst);
		}
	}
	catch (e) { }
	return uniq(out);
};

// Подсети всех IPv4-адресов Роутера — их dnsmasq с --local-service считает локальными и отвечает
// только им. У адреса /32 (mesh-VPN) подсеть — он сам: узлы такой сети для dnsmasq чужие.
export function local_subnets() {
	let r = U.run('ip -4 -j addr show');
	let out = [];
	try {
		for (let l in json(r.out) ?? [])
			for (let a in l.addr_info ?? []) {
				let rg = U.cidr_range(a.local + '/' + a.prefixlen);
				if (rg)
					push(out, U.int2ip(rg[0]) + '/' + a.prefixlen);
			}
	}
	catch (e) { }
	return uniq(out);
};

// Хосты, которые сам Роутер должен резолвить напрямую: NTP, зеркала списков, endpoint.
export function router_hosts(cfg, tinfo) {
	let c = cursor();
	c.load('system');
	let hosts = [];
	c.foreach('system', 'timeserver', (s) => {
		for (let h in U.to_list(s.server))
			push(hosts, h);
	});
	for (let u in [ cfg.lists.geoip_mirror, cfg.lists.geosite_mirror ]) {
		let m = match(u ?? '', /^[a-z]+:\/\/([^\/:]+)/);
		if (m)
			push(hosts, m[1]);
	}
	if (tinfo.endpoint)
		push(hosts, tinfo.endpoint);
	return uniq(filter(hosts, h => h && !U.is_ipv4(h)));
};
