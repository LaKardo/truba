// Чтение настроек Трубы из UCI и сведений о системе (зоны, адреса, Туннель).
'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';
import * as U from 'truba.util';
import * as C from 'truba.const';

const DEFAULT_TUNNEL_DNS = [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ];
const DEFAULT_DIRECT_DNS = [ 'tls://common.dot.dns.yandex.net@77.88.8.8' ];

function bool(v, dflt) {
	if (v == null)
		return dflt;
	return (v == '1' || v == 'true' || v == 'on' || v == 'yes');
}

export function load() {
	let c = cursor();
	c.load('truba');

	let m = c.get_all('truba', 'main') ?? {};
	let d = c.get_all('truba', 'dns') ?? {};
	let l = c.get_all('truba', 'lists') ?? {};
	let w = c.get_all('truba', 'watchdog') ?? {};

	let cfg = {
		routing: bool(m.routing, true),
		mode: (m.mode == 'selective') ? 'selective' : 'all',
		killswitch: bool(m.killswitch, true),
		iface: m.iface ?? 'awg0',
		zones: length(U.to_list(m.zone)) ? U.to_list(m.zone) : [ 'lan' ],
		dns_hijack: bool(m.dns_hijack, true),
		upnp: bool(m.upnp, false),
		rules: [],
		devices: [],
		dns: {
			tunnel: length(U.to_list(d.tunnel_upstream)) ? U.to_list(d.tunnel_upstream) : DEFAULT_TUNNEL_DNS,
			direct: length(U.to_list(d.direct_upstream)) ? U.to_list(d.direct_upstream) : DEFAULT_DIRECT_DNS,
			port: int(d.port ?? 5335),
			ttl_max: int(d.ttl_max ?? 300),
			cache_size: int(d.cache_size ?? 65536),
			lazy_cache_ttl: int(d.lazy_cache_ttl ?? 86400),
		},
		lists: {
			geoip_url: l.geoip_url ?? 'https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat',
			geoip_mirror: l.geoip_mirror ?? 'https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat',
			geosite_url: l.geosite_url ?? 'https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat',
			geosite_mirror: l.geosite_mirror ?? 'https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat',
			update_utc: l.update_utc ?? '12:00',
			via_tunnel: bool(l.via_tunnel, true),
			auto_update: bool(l.auto_update, true),
		},
		watchdog: {
			enabled: bool(w.enabled, true),
			interval: int(w.interval ?? 30),
			handshake_max: int(w.handshake_max ?? 180),
			fails: int(w.fails ?? 3),
			probe: w.probe ?? '',
		},
	};
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
		push(cfg.devices, { name: s.name ?? '', mac: lc(s.mac), policy });
	});

	return cfg;
};

// Сведения о Туннеле из конфигурации network: адрес, адрес Трубы внутри, endpoint.
export function tunnel_info(iface) {
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
	let ub = connect();
	let st = ub ? ub.call('network.interface.' + iface, 'status', {}) : null;
	if (ub)
		ub.disconnect();
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
				res.peer = U.int2ip(r[0] + 1);
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
	let r = U.run('nslookup ' + U.shq(tinfo.endpoint));
	let ips = [];
	for (let line in split(r.out, '\n')) {
		let m = match(line, /^Address( [0-9]+)?:\s*([0-9.]+)\s*$/);
		if (m && m[2] != '127.0.0.1')
			push(ips, m[2]);
	}
	return ips[length(ips) - 1];
};

// Устройства (l3) сетей, входящих в выбранные зоны межсетевого экрана.
export function zone_devices(zones) {
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

	let ub = connect();
	for (let n in nets) {
		let st = ub ? ub.call('network.interface.' + n, 'status', {}) : null;
		let dev = st?.l3_device ?? st?.device;
		if (dev)
			push(devs, dev);
	}
	if (ub)
		ub.disconnect();
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
