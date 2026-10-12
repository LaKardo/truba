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
