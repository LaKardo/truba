// Устройства домашней сети для вкладки «Устройства» и «Обзора»: трафик из истории (truba.devstats,
// ADR 0018), имена и MAC — из аренд DHCP, соседей и секций device, зона — по интерфейсу, через
// который виден адрес. Политика — как её понимает служба (F.device_sections).
'use strict';

import { readfile, open } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as F from 'truba.conf';
import * as DV from 'truba.devstats';
import * as DN from 'truba.dnsnames';

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

// Указатель списка по полю: первая запись с этим значением. Списки бывают по сотне записей, а
// поиск нужен для каждого устройства.
function index_by(list, key) {
	let out = {};
	for (let x in list)
		if (x[key] != null)
			out[x[key]] ??= x;
	return out;
}

// Список устройств: адреса из истории — не больше C.DEV_LIST_MAX самых недавних, но все с Политикой;
// затем адреса устройств с Политикой (по MAC — сосед, аренда), а секции с Политикой, чей MAC сейчас
// не в сети, — без адреса. Секция «по правилам» без трафика в список не попадает: она ничего не меняет.
// MAC адреса — у соседа (кто держит адрес сейчас), без него — из аренды; имя аренды — только если она
// того же MAC: устаревшая аренда принадлежит другому устройству. now — время Роутера: скорость, записанная
// раньше трёх шагов (процесс stats не пишет — служба остановлена), за текущую не выдаётся.
// leases — parse_leases, neigh — [ { ip, mac, dev } ], secs — F.device_sections, zone_of(ip, dev) — зона.
export function merge(hist, leases, neigh, secs, zone_of, now) {
	let devs = (type(hist?.devices) == 'object') ? hist.devices : {};
	let fresh = (now == null) || ((hist?.last?.t ?? 0) >= now - 3 * C.HISTORY.fine.step);
	let l_ip = index_by(leases, 'ip'), l_mac = index_by(leases, 'mac');
	let n_ip = index_by(neigh, 'ip'), n_mac = index_by(neigh, 'mac'), s_mac = index_by(secs, 'mac');
	let mac_at = (ip) => n_ip[ip]?.mac ?? l_ip[ip]?.mac;
	let ruled = (ip) => (s_mac[mac_at(ip)]?.policy ?? 'rules') != 'rules';
	let recent = (ip) => ((devs[ip].last ?? 0) > (devs[ip].seen ?? 0)) ? devs[ip].last : (devs[ip].seen ?? 0);

	let ips = [], listed = {}, extra = [];
	for (let ip in sort(keys(devs), (a, b) => recent(b) - recent(a))) {
		if (length(ips) < C.DEV_LIST_MAX || ruled(ip)) {
			push(ips, ip);
			listed[ip] = true;
		}
	}
	for (let s in secs) {
		if (s.policy == 'rules')
			continue;
		let ip = n_mac[s.mac]?.ip ?? l_mac[s.mac]?.ip;
		if (ip == null)
			push(extra, s);
		else if (!listed[ip]) {
			push(ips, ip);
			listed[ip] = true;
		}
	}

	let out = [];
	for (let ip in ips) {
		let n = n_ip[ip], h = devs[ip], mac = mac_at(ip);
		let l = (l_ip[ip]?.mac == mac) ? l_ip[ip] : null;
		let sec = mac ? s_mac[mac] : null;
		push(out, {
			ip, mac,
			name: length(sec?.name) ? sec.name : l?.name,
			source: l ? 'dhcp' : (n ? 'neigh' : null),
			zone: zone_of(ip, n?.dev),
			policy: sec?.policy ?? 'rules',
			rate: fresh ? h?.rate : null, day: h ? DV.day(h) : null, minutes: h?.minutes ?? [], last: h?.last,
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

// Маршруты всех таблиц (ip -4 -j route show table all) как [ сеть, маска, длина, интерфейс ]: у адресов
// без соседа (узлы mesh-VPN, их маршруты — в своих таблицах) интерфейс ищется по ним, одним вызовом
// ip на весь список, а не своим процессом на каждый адрес. default и маршруты без интерфейса не в счёт.
export function route_table(routes) {
	let out = [];
	for (let r in routes ?? []) {
		if (!r?.dev || r.dst == null || r.dst == 'default' || !((r.type ?? 'unicast') in [ 'unicast', 'local' ]))
			continue;
		let m = match(r.dst, /^([0-9.]+)(\/([0-9]+))?$/), net = m ? U.ip2int(m[1]) : null;
		if (net == null)
			continue;
		let len = (m[3] != null) ? int(m[3]) : 32;
		let mask = len ? ((0xffffffff << (32 - len)) & 0xffffffff) : 0;
		push(out, [ net & mask, mask, len, r.dev ]);
	}
	return out;
};

// Интерфейс адреса по самому длинному подходящему префиксу; null — не нашёлся.
export function route_dev(table, ip) {
	let n = U.ip2int(ip), best = null, len = -1;
	if (n == null)
		return null;
	for (let r in table)
		if (r[2] > len && (n & r[1]) == r[0]) {
			best = r[3];
			len = r[2];
		}
	return best;
};

// Для rpcd (truba.devices): { now, devices }.
export function list(lite) {
	let ub = connect();
	let zones = F.dev_zones(ub);
	ub?.disconnect();
	let table = null;
	let zone_of = (ip, dev) => {
		if (dev == null) {
			try {
				table ??= route_table(json(U.run('ip -4 -j route show table all').out));
			}
			catch (e) {
				table = [];
			}
			dev = route_dev(table, ip);
		}
		return zones[dev];
	};
	let now = time();
	let devices = merge(U.read_json(C.DEVICES_FILE, null), leases(), neighbours(), F.device_sections(), zone_of, now);
	// Обзору нужна только последняя минута для долей Действий, а не час мини-графика.
	if (lite)
		for (let d in devices)
			d.minutes = length(d.minutes) ? [ d.minutes[length(d.minutes) - 1] ] : [];
	return { now, devices };
};

// ---- Куда устройство ходит сейчас (truba.connections) ----

// Записи conntrack, где ip — источник исходного направления: { proto, dst, dport, up, down, mark }.
// up — байты от устройства, down — к нему; без nf_conntrack_acct их нет (null). src — текст или функция,
// отдающая по строке (null — конец): таблицу в десятки тысяч записей незачем держать в памяти целиком.
// Строки отбираются подстрокой до разбора.
export function parse_conntrack(src, ip) {
	let next = src;
	if (type(src) != 'function') {
		let lines = split(src ?? '', '\n'), i = 0;
		next = () => lines[i++];
	}
	let needle = ' src=' + ip + ' ', out = [];
	for (let l = next(); l != null; l = next()) {
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

// MAC адреса — для Политики устройства в решении по правилам: у соседа (кто держит адрес сейчас), без него — из аренды.
function mac_of(ip) {
	return index_by(neighbours(), 'ip')[ip]?.mac ?? index_by(leases(), 'ip')[ip]?.mac;
}

// Для rpcd (truba.connections): CONN_TOP адресов с причиной по нынешним правилам. Если правила
// решили бы иначе, чем ct mark, соединение началось до смены настроек — причина changed.
export function connections(ip) {
	let f = open(C.CONNTRACK, 'r');
	if (!f)
		return { ip, error: 'no_conntrack' };
	// По строке: в конце файла read даёт пустую строку.
	let g = group(parse_conntrack(() => {
		let l = f.read('line');
		return length(l) ? l : null;
	}, ip));
	f.close();
	let cfg = F.load(), vs = null;
	if (length(g.addrs) && cfg.routing) {
		// Разбор Наборов правил — только здесь: список устройств опрашивается чаще и без него.
		let K = loadstring("import * as K from 'truba.check'; return K;")();
		vs = K.ip_verdicts(map(g.addrs, (a) => a.addr), mac_of(ip), cfg);
	}
	let names = DN.lookup(map(g.addrs, a => a.addr));
	for (let i, a in g.addrs) {
		if (names[a.addr])
			a.domain = names[a.addr];
		a.action = mark_action(a.mark);
		let v = vs?.[i];
		a.reason = v ? ((v.action == a.action) ? v.reason : 'changed') : null;
		a.geoip = v?.geoip ?? [];
		delete a.mark;
	}
	return { ip, total: g.total, acct: g.acct, addrs: g.addrs };
};
