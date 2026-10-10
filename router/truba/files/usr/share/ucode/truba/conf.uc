// Чтение настроек Трубы из UCI и сведений о системе (зоны, адреса, Туннель).
'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';
import * as U from 'truba.util';
import * as C from 'truba.const';

const DEFAULT_TUNNEL_DNS = [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ];
// Два сервера: mosdns спрашивает оба разом и берёт первый ответ, поэтому обрыв одного
// соединения не оставляет запросы без ответа (на живом роутере DoH 77.88.8.8 изредка рвался).
// pipelining: запросы, пришедшие разом, идут по одному соединению, а не открывают по TLS на каждый.
const DEFAULT_DIRECT_DNS = [ 'tls+pipeline://common.dot.dns.yandex.net@77.88.8.8', 'tls+pipeline://common.dot.dns.yandex.net@77.88.8.1' ];

const MAC_RE = /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/;

// Схемы адресов, которые понимает mosdns 5; без схемы — udp. Адрес с опечаткой в схеме
// останавливает mosdns целиком, а с ним DNS всей сети, поэтому в его конфиг он не попадает.
const UPSTREAM_SCHEMES = [ 'udp', 'tcp', 'tcp+pipeline', 'tls', 'tls+pipeline', 'https', 'h3', 'quic', 'doq' ];

// «[схема://]хост[:порт][/путь][@IP]»; путь — только со схемой. Та же проверка — в dns.js.
// Регулярные выражения ucode — POSIX: внутри [...] нет \s, только [:space:].
const UPSTREAM_RE = regexp('^(([a-z0-9+]+)://)?(\\[[0-9a-fA-F:.]+\\]|[^][[:space:]/@:]+)(:[0-9]+)?(/[^[:space:]@]*)?(@[0-9.]+)?$');

export function upstream_ok(u) {
	let m = (type(u) == 'string') ? match(u, UPSTREAM_RE) : null;
	if (!m)
		return false;
	return (m[2] == null) ? (m[5] == null) : (m[2] in UPSTREAM_SCHEMES);
};

function bool(v, dflt) {
	if (v == null)
		return dflt;
	return (v == '1' || v == 'true' || v == 'on' || v == 'yes');
}

// Одно неверное значение в UCI (опечатка в консоли, старый конфиг) не должно ломать
// применение целиком: оно пропускается, вместо него — значение по умолчанию, а «Обзор»
// показывает, что пропущено (bad → applied.invalid).

// Целое в пределах [lo, hi] — те же пределы, что у полей LuCI.
function num(bad, key, v, dflt, lo, hi) {
	if (v == null || v == '')
		return dflt;
	let n = (type(v) == 'string' && match(v, /^[0-9]+$/)) ? int(v) : null;
	if (n == null || n < lo || n > hi) {
		push(bad, { key, value: '' + v });
		return dflt;
	}
	return n;
}

// Список DNS-серверов без неверных адресов; если не осталось ни одного — по умолчанию.
function upstreams(bad, key, v, dflt) {
	let all = U.to_list(v);
	let good = filter(all, upstream_ok);
	for (let u in all)
		if (!upstream_ok(u))
			push(bad, { key, value: '' + u });
	return length(good) ? good : dflt;
}

function pattern(bad, key, v, dflt, re) {
	if (v == null || v == '')
		return dflt;
	if (type(v) == 'string' && match(v, re))
		return v;
	push(bad, { key, value: '' + v });
	return dflt;
}

export function load() {
	let c = cursor();
	c.load('truba');

	let m = c.get_all('truba', 'main') ?? {};
	let d = c.get_all('truba', 'dns') ?? {};
	let l = c.get_all('truba', 'lists') ?? {};
	let w = c.get_all('truba', 'watchdog') ?? {};
	let bad = [];

	// Неверный адрес для ping — Туннель «не отвечает» навсегда, и при Аварийной блокировке
	// весь трафик «Туннеля» отбрасывается.
	let probe = w.probe ?? '';
	if (probe != '' && !U.is_ipv4(probe)) {
		push(bad, { key: 'watchdog.probe', value: '' + probe });
		probe = '';
	}

	let cfg = {
		routing: bool(m.routing, true),
		mode: (m.mode == 'selective') ? 'selective' : 'all',
		killswitch: bool(m.killswitch, true),
		// Имя интерфейса попадает в правила nftables и в имена объектов ubus.
		iface: pattern(bad, 'main.iface', m.iface, 'awg0', /^[A-Za-z0-9_]{1,15}$/),
		zones: length(U.to_list(m.zone)) ? U.to_list(m.zone) : [ 'lan' ],
		dns_hijack: bool(m.dns_hijack, true),
		upnp: bool(m.upnp, false),
		// STUN-серверы «Проверки NAT» («host:port»); пусто — стандартные из truba.nattest.
		stun: U.to_list(m.stun),
		rules: [],
		devices: [],
		dns: {
			tunnel: upstreams(bad, 'dns.tunnel_upstream', d.tunnel_upstream, DEFAULT_TUNNEL_DNS),
			direct: upstreams(bad, 'dns.direct_upstream', d.direct_upstream, DEFAULT_DIRECT_DNS),
			port: num(bad, 'dns.port', d.port, 5335, 1, 65535),
			ttl_max: num(bad, 'dns.ttl_max', d.ttl_max, 300, 30, 86400),
			cache_size: num(bad, 'dns.cache_size', d.cache_size, 65536, 1024, 1048576),
			lazy_cache_ttl: num(bad, 'dns.lazy_cache_ttl', d.lazy_cache_ttl, 86400, 0, 604800),
			// Срок IP из DNS в наборах gs_* (ADR 0007): 0 — без срока, иначе от 10 минут до недели.
			set_timeout: num(bad, 'dns.set_timeout', d.set_timeout, 86400, 0, 604800),
		},
		lists: {
			geoip_url: l.geoip_url ?? 'https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat',
			geoip_mirror: l.geoip_mirror ?? 'https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat',
			geosite_url: l.geosite_url ?? 'https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat',
			geosite_mirror: l.geosite_mirror ?? 'https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat',
			update_utc: pattern(bad, 'lists.update_utc', l.update_utc, '12:00', /^([01]?[0-9]|2[0-3]):[0-5][0-9]$/),
			via_tunnel: bool(l.via_tunnel, true),
			auto_update: bool(l.auto_update, true),
		},
		watchdog: {
			enabled: bool(w.enabled, true),
			// Интервал 0 — цикл без пауз, 0 неудач — деление на ноль в счёте перезапусков.
			interval: num(bad, 'watchdog.interval', w.interval, 30, 10, 600),
			handshake_max: num(bad, 'watchdog.handshake_max', w.handshake_max, 180, 60, 3600),
			fails: num(bad, 'watchdog.fails', w.fails, 3, 1, 20),
			probe,
		},
		invalid: bad,
	};
	// Срок короче 10 минут — короче TTL ответов: адреса пропадали бы из наборов, пока устройства
	// ещё пользуются ответом, и новые соединения шли бы мимо своей Категории.
	if (cfg.dns.set_timeout > 0 && cfg.dns.set_timeout < 600) {
		push(bad, { key: 'dns.set_timeout', value: '' + d.set_timeout });
		cfg.dns.set_timeout = 86400;
	}
	// HTTP API mosdns (счётчики кэша для «Обзора») — на соседнем с DNS порту, только 127.0.0.1.
	let p = cfg.dns.port;
	cfg.dns.api = sprintf('127.0.0.1:%d', (p < 65535) ? p + 1 : p - 1);

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

	c.foreach('truba', 'device', (s) => {
		// LuCI не сохраняет значение по умолчанию: нет policy — значит «Всё в туннель».
		let policy = s.policy ?? 'tunnel';
		if (!s.mac || !(policy in [ 'tunnel', 'direct' ]))
			return;
		if (s.enabled == '0')
			return;
		// MAC попадает в набор nftables: с опечаткой не загрузилась бы вся таблица.
		let mac = (type(s.mac) == 'string') ? lc(s.mac) : '';
		if (!match(mac, MAC_RE)) {
			push(bad, { key: 'device.mac', value: '' + s.mac });
			return;
		}
		push(cfg.devices, { name: s.name ?? '', mac, policy });
	});

	return cfg;
};

// Сведения о Туннеле из конфигурации network: адрес, адрес Трубы внутри, endpoint.
export function tunnel_info(iface, ub) {
	let c = cursor();
	c.load('network');
	let ifc = c.get_all('network', iface);
	let res = { exists: (ifc != null), disabled: false, address: null, prefix: null, peer: null,
	            subnet: null, endpoint: null, endpoint_port: null };
	if (!ifc)
		return res;

	res.disabled = (ifc.disabled == '1');
	let addr = null;

	// Предпочтительно — фактический адрес поднятого интерфейса.
	let st = U.ubus_call(ub, 'network.interface.' + iface, 'status');
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
