// Устройства домашней сети для вкладки «Устройства» и «Обзора»: трафик из истории (truba.devstats,
// ADR 0018), имена и MAC — из аренд DHCP, соседей и секций device, зона — по интерфейсу, через
// который виден адрес. Политика — как её понимает служба (F.device_sections).
'use strict';

import { readfile } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as F from 'truba.conf';
import * as DV from 'truba.devstats';

const DHCP_LEASES = '/tmp/dhcp.leases';   // умолчание dnsmasq, если в секции нет leasefile

// Строки файла аренд dnsmasq: «срок MAC IP имя client-id»; имя «*» — устройство его не сообщило.
export function parse_leases(text) {
	let out = [];
	for (let l in split(text ?? '', '\n')) {
		let f = split(trim(l), /[ \t]+/);
		if (length(f) < 4 || !U.is_ipv4(f[2]) || !match(f[1], /^[0-9A-Fa-f:]{17}$/))
			continue;
		push(out, { ip: f[2], mac: lc(f[1]), name: (f[3] == '*') ? null : f[3] });
	}
	return out;
};

function first(list, key, value) {
	for (let x in list)
		if (x[key] == value)
			return x;
	return null;
}

// Список устройств: адреса из истории, затем адреса устройств с Политикой (по MAC — аренда, сосед),
// а секции, чей MAC сейчас не в сети, — без адреса. leases — parse_leases, neigh — [ { ip, mac, dev } ],
// secs — F.device_sections, zone_of(ip, dev) — зона fw4 или null.
export function merge(hist, leases, neigh, secs, zone_of) {
	let devs = (type(hist?.devices) == 'object') ? hist.devices : {};
	let ips = keys(devs), extra = [];
	for (let s in secs) {
		let ip = first(leases, 'mac', s.mac)?.ip ?? first(neigh, 'mac', s.mac)?.ip;
		if (ip == null)
			push(extra, s);
		else if (!(ip in ips))
			push(ips, ip);
	}

	let out = [];
	for (let ip in ips) {
		let l = first(leases, 'ip', ip), n = first(neigh, 'ip', ip), h = devs[ip];
		let mac = l?.mac ?? n?.mac;
		let sec = mac ? first(secs, 'mac', mac) : null;
		push(out, {
			ip, mac,
			name: length(sec?.name) ? sec.name : l?.name,
			source: l ? 'dhcp' : (n ? 'neigh' : null),
			zone: zone_of(ip, n?.dev),
			policy: sec?.policy ?? 'rules',
			rate: h?.rate, day: h ? DV.day(h) : null, minutes: h?.minutes ?? [], last: h?.last,
		});
	}
	for (let s in extra)
		push(out, { ip: null, mac: s.mac, name: length(s.name) ? s.name : null, source: 'config', zone: null,
		            policy: s.policy, rate: null, day: null, minutes: [], last: null });
	return out;
};

// Аренды из файлов всех экземпляров dnsmasq (только dnsmasq: служба не зависит от LuCI).
function leases() {
	let c = cursor(), files = [];
	if (c.load('dhcp'))
		c.foreach('dhcp', 'dnsmasq', (s) => push(files, s.leasefile ?? DHCP_LEASES));
	let out = [];
	for (let f in uniq(length(files) ? files : [ DHCP_LEASES ]))
		push(out, ...parse_leases(readfile(f)));
	return out;
}

// Соседи IPv4 с известным MAC.
function neighbours() {
	let out = [];
	try {
		for (let n in json(U.run('ip -4 -j neigh show').out) ?? []) {
			let st = join(',', n.state ?? []);
			if (!U.is_ipv4(n.dst) || !n.lladdr || index(st, 'FAILED') >= 0 || index(st, 'INCOMPLETE') >= 0)
				continue;
			push(out, { ip: n.dst, mac: lc(n.lladdr), dev: n.dev });
		}
	}
	catch (e) { }
	return out;
}

// Интерфейс, через который Роутер видит адрес (узлы mesh-VPN соседями не бывают).
function route_dev(ip) {
	try {
		return json(U.run('ip -4 -j route get ' + U.shq(ip)).out)?.[0]?.dev;
	}
	catch (e) {
		return null;
	}
}

// Для rpcd (truba.devices): { now, devices }.
export function list() {
	let ub = connect();
	let zones = F.dev_zones(ub);
	ub?.disconnect();
	let zone_of = (ip, dev) => zones[dev ?? route_dev(ip)];
	return { now: time(), devices: merge(U.read_json(C.DEVICES_FILE, null), leases(), neighbours(), F.device_sections(), zone_of) };
};

// ---- Куда устройство ходит сейчас (truba.connections) ----

// Записи conntrack, где ip — источник исходного направления: { proto, dst, dport, up, down, mark }.
// up — байты от устройства, down — к нему; без nf_conntrack_acct их нет (null). Строки отбираются
// подстрокой до разбора: в таблице бывают десятки тысяч записей.
export function parse_conntrack(text, ip) {
	let needle = ' src=' + ip + ' ', out = [];
	for (let l in split(text ?? '', '\n')) {
		if (substr(l, 0, 4) != 'ipv4' || index(l, needle) < 0 || match(l, / src=([0-9.]+) /)?.[1] != ip)
			continue;
		let dport = match(l, / dport=([0-9]+) /), mark = match(l, / mark=([0-9]+) /);
		let bytes = match(l, / bytes=([0-9]+)/g) ?? [];
		push(out, {
			proto: split(trim(l), /[ \t]+/)[2],
			dst: match(l, / dst=([0-9.]+) /)?.[1],
			dport: dport ? int(dport[1]) : null,
			up: length(bytes) ? int(bytes[0][1]) : null,
			down: (length(bytes) > 1) ? int(bytes[1][1]) : null,
			mark: mark ? int(mark[1]) : 0,
		});
	}
	return out;
};

// По адресам назначения: протокол, порт и метка — самого крупного соединения, число соединений,
// байты в обе стороны. Сортировка по объёму, а без nf_conntrack_acct — по числу соединений.
export function group(conns) {
	let by = {}, list = [], acct = false, top = {};
	for (let c in conns) {
		acct ||= (c.up != null);
		let a = by[c.dst];
		if (!a)
			push(list, a = by[c.dst] = { addr: c.dst, proto: c.proto, port: c.dport, conns: 0, up: null, down: null, mark: c.mark });
		a.conns++;
		if (c.up != null) {
			a.up = (a.up ?? 0) + c.up;
			a.down = (a.down ?? 0) + (c.down ?? 0);
		}
		let size = (c.up ?? 0) + (c.down ?? 0);
		if (top[c.dst] == null || size > top[c.dst]) {
			top[c.dst] = size;
			a.proto = c.proto;
			a.port = c.dport;
			a.mark = c.mark;
		}
	}
	let vol = (a) => acct ? (a.up ?? 0) + (a.down ?? 0) : a.conns;
	list = sort(list, (x, y) => (vol(y) - vol(x)) || ((x.addr < y.addr) ? -1 : ((x.addr > y.addr) ? 1 : 0)));
	return { total: length(conns), acct, addrs: slice(list, 0, C.CONN_TOP) };
};

// Действие соединения — по ct mark (его ставит persist): ответы на входящие уходят в Туннель,
// без метки соединение идёт по основной таблице, то есть напрямую.
function mark_action(mark) {
	let m = mark & C.MARK_MASK;
	return (m == C.MARK_TUNNEL || m == C.MARK_INBOUND) ? 'tunnel' : 'direct';
}

// MAC адреса — для Политики устройства в решении по правилам.
function mac_of(ip) {
	return first(leases(), 'ip', ip)?.mac ?? first(neighbours(), 'ip', ip)?.mac;
}

// Для rpcd (truba.connections): CONN_TOP адресов с причиной по нынешним правилам. Если правила
// решили бы иначе, чем ct mark, соединение началось до смены настроек — причина changed.
export function connections(ip) {
	let text = readfile(C.CONNTRACK);
	if (text == null)
		return { ip, error: 'no_conntrack' };
	let g = group(parse_conntrack(text, ip));
	let vs = null;
	if (length(g.addrs) && F.load().routing) {
		// Разбор Наборов правил — только здесь: список устройств опрашивается чаще и без него.
		let K = loadstring("import * as K from 'truba.check'; return K;")();
		vs = K.ip_verdicts(map(g.addrs, (a) => a.addr), mac_of(ip));
	}
	for (let i, a in g.addrs) {
		a.action = mark_action(a.mark);
		let v = vs?.[i];
		a.reason = v ? ((v.action == a.action) ? v.reason : 'changed') : null;
		a.geoip = v?.geoip ?? [];
		delete a.mark;
	}
	return { ip, total: g.total, acct: g.acct, addrs: g.addrs };
};
