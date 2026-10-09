// Состояние Трубы для интерфейса: status, lists, sets. «Обзор» опрашивает status раз в 5 с,
// поэтому этот модуль не тянет за собой распаковщик, генератор правил и watchdog —
// командная строка загружает только его.
'use strict';

import { readfile, stat } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as socket from 'socket';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as F from 'truba.conf';
import * as N from 'truba.net';

// Элементы динамического набора (наполненного mosdns): для переноса в новую таблицу и для «Обзора».
export function set_elements(name) {
	let r = U.run('nft -j list set inet ' + C.NFT_TABLE + ' ' + name);
	if (r.code != 0)
		return [];
	let out = [];
	try {
		for (let o in json(r.out)?.nftables ?? []) {
			for (let e in o?.set?.elem ?? []) {
				let v = (type(e) == 'object') ? (e.elem?.val ?? e.val) : e;
				if (type(v) == 'string' && U.is_ipv4(v))
					push(out, v);
			}
		}
	}
	catch (e) { }
	return out;
};

// Счётчики таблицы Трубы под своими именами (c_…); пусто, если таблицы нет.
export function counters_raw() {
	let r = U.run('nft -j list counters table inet ' + C.NFT_TABLE);
	let out = {};
	if (r.code != 0)
		return out;
	try {
		for (let o in json(r.out)?.nftables ?? [])
			if (o.counter)
				out[o.counter.name] = { packets: o.counter.packets, bytes: o.counter.bytes };
	}
	catch (e) { }
	return out;
};

export function health_state() {
	return U.read_json(C.HEALTH_FILE, null);
};

// sums — с контрольной суммой: она нужна только вкладке «DNS и списки».
function list_info(dir, file, sums) {
	let p = dir + '/' + file;
	let st = stat(p);
	if (!st)
		return null;
	let res = { mtime: st.mtime, size: st.size };
	if (sums)
		res.sha256 = U.sha_from_sumfile(p + '.sha256sum') ?? U.sha256_file(p);
	return res;
}

function counters(raw) {
	let out = {};
	for (let n in raw)
		out[replace(n, /^c_/, '')] = raw[n];
	return out;
}

// Трафик устройств по Действиям, байты: down — к устройствам, up — от них.
function traffic(raw) {
	let b = (n) => raw['c_' + n]?.bytes ?? 0;
	return {
		tunnel: { down: b('tunnel_down'), up: b('tunnel_up') },
		direct: { down: b('direct_down'), up: b('direct_up') },
		inbound: { down: b('inbound_down'), up: b('inbound_up') },
	};
}

// Соседи, которые искажают учёт или проверки Трубы.
function neighbours() {
	let c = cursor();
	let res = { offload: false, offload_hw: false, openclash_fakeip: false };
	if (c.load('firewall'))
		c.foreach('firewall', 'defaults', (s) => {
			res.offload ||= (s.flow_offloading == '1');
			res.offload_hw ||= (s.flow_offloading_hw == '1');
		});
	if (stat('/etc/config/openclash') && c.load('openclash'))
		res.openclash_fakeip = c.get('openclash', 'config', 'enable') == '1' &&
			match(c.get('openclash', 'config', 'en_mode') ?? '', /fake-ip/) != null;
	return res;
}

// Работает ли служба procd (или её инстанс) — по ubus, без pidof. mosdns — инстанс
// службы truba: чужой mosdns, запущенный отдельно, за Трубу не считается.
function running(ub, service, instance) {
	let r = ub?.call('service', 'list', { name: service });
	for (let name, inst in r?.[service]?.instances ?? {})
		if ((instance == null || name == instance) && inst.running)
			return true;
	return false;
}

// UPnP на Туннеле: включён ли в Трубе, стоит ли miniupnpd, работает ли, его пробросы.
function upnp_info(cfg, ub) {
	let res = { enabled: cfg.upnp, installed: stat('/etc/init.d/miniupnpd') != null,
	            running: running(ub, 'miniupnpd'), leases: [] };
	let c = cursor();
	let file = (stat('/etc/config/upnpd') && c.load('upnpd')) ? c.get('upnpd', 'config', 'upnp_lease_file') : null;
	// Строка: ПРОТОКОЛ:внешний порт:IP устройства:порт устройства:срок (unix):описание
	for (let l in split(trim(readfile(file ?? '/var/run/miniupnpd.leases') ?? ''), '\n')) {
		let f = split(l, ':', 6);
		if (length(f) >= 4)
			push(res.leases, { proto: f[0], ext_port: int(f[1]), ip: f[2], port: int(f[3]),
			                   expires: int(f[4] ?? 0), descr: f[5] ?? '' });
	}
	return res;
}

// GET по HTTP/1.0 к локальному API — прямо из ucode, без curl и оболочки: status
// вызывается раз в 5 с. Тело ответа 200 или null (нет ответа, тайм-аут, обрыв).
function http_get(addr, path, timeout) {
	let i = rindex(addr, ':');
	let s = socket.connect(substr(addr, 0, i), substr(addr, i + 1), { socktype: socket.SOCK_STREAM }, timeout);
	if (!s)
		return null;
	let out = '', done = false, end = U.now_ms() + timeout;
	if (s.send(sprintf('GET %s HTTP/1.0\r\nHost: %s\r\n\r\n', path, addr))) {
		while (true) {
			let left = end - U.now_ms();
			let pr = (left > 0) ? socket.poll(int(left), [ s, socket.POLLIN ]) : null;
			let chunk = length(pr ?? []) ? s.recv(65536) : null;
			if (chunk == null)
				break;
			if (chunk == '') {
				done = true;
				break;
			}
			out += chunk;
		}
	}
	s.close();
	let b = index(out, '\r\n\r\n');
	return (done && b >= 0 && match(out, /^HTTP\/1\.[01] 200 /)) ? substr(out, b + 4) : null;
}

// Счётчики кэша mosdns из его API: query — запросов, hit — ответов из кэша (вместе с
// истёкшими), lazy_hit — истёкших, size — записей сейчас. Отсчёт — с запуска mosdns.
function dns_cache(api, cfg) {
	let res = {};
	for (let l in split(http_get(api, '/metrics', 1000) ?? '', '\n')) {
		let m = match(l, /^mosdns_cache_(query_total|hit_total|lazy_hit_total|size_current)(\{[^}]*\})? ([0-9.e+]+)$/);
		if (m)
			res[replace(m[1], /_(total|current)$/, '')] = int(+m[3]);
	}
	if (res.query == null)
		return null;
	res.max = cfg.dns.cache_size;
	return res;
}

function awg_peer(dev) {
	let r = U.run('awg show ' + U.shq(dev) + ' dump');
	if (r.code != 0)
		return null;
	let lines = split(trim(r.out), '\n');
	if (length(lines) < 2)
		return null;
	// Строка пира: pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
	let f = split(lines[1], '\t');
	let hs = int(f[4] ?? 0);
	return {
		endpoint: f[2],
		handshake: hs,
		handshake_age: hs ? (time() - hs) : null,
		rx: int(f[5] ?? 0),
		tx: int(f[6] ?? 0),
	};
}

// Состояние для «Обзора»: его опрашивают раз в 5 с, поэтому здесь только то, что
// «Обзор» показывает, одно соединение ubus и без лишних процессов. Версии списков — lists().
export function status() {
	let ub = connect();
	let cfg = F.load();
	let tinfo = F.tunnel_info(cfg.iface, ub);
	let st = N.iface_up(cfg.iface, ub);
	let applied = U.read_json(C.APPLIED_FILE, null);
	let raw = counters_raw();
	let res = {
		routing: cfg.routing,
		mode: cfg.mode,
		killswitch: cfg.killswitch,
		service: applied != null,
		applied,
		tunnel: {
			iface: cfg.iface,
			configured: tinfo.exists,
			disabled: tinfo.disabled,
			up: st.up,
			device: st.device,
			address: tinfo.address,
			peer: tinfo.peer,
			endpoint: tinfo.endpoint,
			awg: st.up ? awg_peer(st.device) : null,
		},
		// IP Трубы знает apply; без него — только endpoint-адрес: имя здесь не резолвится,
		// иначе каждый опрос ждал бы DNS (а когда служба остановлена, DNS мог и не работать).
		vps_ip: applied?.vps ?? (U.is_ipv4(tinfo.endpoint) ? tinfo.endpoint : null),
		health: health_state(),
		table: U.run('ip -4 route show table ' + C.RT_TABLE).out,
		// counters — сырые счётчики (connections: tunnel/direct/inbound — новые соединения,
		// block — отброшенные пакеты), traffic — байты трафика устройств; отсчёт с applied.counters_since.
		counters: counters(raw),
		traffic: traffic(raw),
		neighbours: neighbours(),
		upnp: upnp_info(cfg, ub),
		mosdns: running(ub, 'truba', 'mosdns'),
		// Адрес API — тот, с которым mosdns запущена (его может не быть, если порт занят).
		dns_cache: (cfg.routing && applied?.dns_api) ? dns_cache(applied.dns_api, cfg) : null,
		// Итог последней «Проверки NAT» — кнопкой или watchdog после подъёма Туннеля.
		nat: U.read_json(C.NAT_FILE, null),
		lists: {
			geoip: list_info(C.LISTS_DIR, C.DAT_FILES.geoip),
			geosite: list_info(C.LISTS_DIR, C.DAT_FILES.geosite),
			last: U.read_json(C.LISTS_STATE, null),
			updating: U.lock_busy(C.LOCK_LISTS),
			next: N.cron_next(),
		},
	};
	ub?.disconnect();
	return res;
};

// Версии Наборов правил для вкладки «DNS и списки»: текущие и предыдущие, с контрольными суммами.
export function lists() {
	return {
		geoip: list_info(C.LISTS_DIR, C.DAT_FILES.geoip, true),
		geosite: list_info(C.LISTS_DIR, C.DAT_FILES.geosite, true),
		prev_geoip: list_info(C.PREV_DIR, C.DAT_FILES.geoip, true),
		prev_geosite: list_info(C.PREV_DIR, C.DAT_FILES.geosite, true),
		last: U.read_json(C.LISTS_STATE, null),
		updating: U.lock_busy(C.LOCK_LISTS),
		// Идёт применение настроек (после отката или обновления списков — в фоне).
		applying: U.lock_busy(C.LOCK_APPLY),
	};
};

// Размеры наборов для «Обзора»: geoip — подсетей по Действиям (посчитаны при применении),
// dns — IP, которые mosdns положил по ответам для доменов geosite. Дороже status — реже.
export function sets() {
	let applied = U.read_json(C.APPLIED_FILE, null);
	if (!applied?.routing)
		return { routing: false };
	return {
		routing: true,
		geoip: applied.geoip_sizes ?? null,
		dns: { tunnel: length(set_elements('gs_tunnel4')), direct: length(set_elements('gs_direct4')) },
	};
};
