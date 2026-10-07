// Оркестрация: применить настройки, снять всё, состояние Туннеля, обновление списков.
'use strict';

import { readfile, writefile, stat, unlink, rename } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as socket from 'socket';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as D from 'truba.dat';
import * as F from 'truba.conf';
import * as P from 'truba.plan';
import * as R from 'truba.render';
import * as N from 'truba.net';

function ensure_dirs() {
	for (let d in [ C.RUN_DIR, C.ETC_DIR, C.DATA_DIR, C.LISTS_DIR, C.PREV_DIR, C.STATE_DIR ])
		U.mkdirp(d);
}

function bypass4(vps, tinfo) {
	let b = F.connected_subnets();
	if (vps)
		push(b, vps + '/32');
	if (tinfo.subnet)
		push(b, tinfo.subnet);
	push(b, '224.0.0.0/4', '255.255.255.255/32');
	return uniq(b);
}

// Элементы динамического набора (наполненного mosdns) для переноса в новую таблицу.
function set_elements(name) {
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
}

// Счётчики таблицы Трубы под своими именами (c_…); пусто, если таблицы нет.
// Объявлена до apply(): ucode не поднимает объявления функций.
function counters_raw() {
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
}

// Умеет ли ядро «socket mark» (kmod-nft-socket). nft -c проверяет правило в ядре,
// ничего не создавая: без модуля таблица Трубы не загрузилась бы целиком.
function socket_mark_ok() {
	return U.run("nft -c 'add table inet truba_probe; " +
	             "add chain inet truba_probe o { type filter hook output priority 0; }; " +
	             "add rule inet truba_probe o socket mark 0'").code == 0;
}

// Порт API mosdns занят другой программой? Ошибка API останавливает mosdns целиком —
// весь DNS сети, поэтому тогда mosdns запускается без API (нет только счётчиков кэша).
// Конфликтуют слушатели этого порта на 127.0.0.1 и на всех адресах.
function api_port_taken(api) {
	let port = split(api, ':')[1];
	for (let l in split(U.run('netstat -lntp').out, '\n')) {
		let f = split(trim(l), /\s+/);
		if (f[5] != 'LISTEN' || match(f[6] ?? '', /\/mosdns$/))
			continue;
		let i = rindex(f[3], ':');
		if (substr(f[3], i + 1) == port && (substr(f[3], 0, i) in [ '127.0.0.1', '0.0.0.0', '::', '' ]))
			return true;
	}
	return false;
}

function health_state() {
	return U.read_json(C.HEALTH_FILE, null);
}

// Состояние таблицы 77 по здоровью Туннеля.
export function routes(cfg, tinfo) {
	cfg ??= F.load();
	tinfo ??= F.tunnel_info(cfg.iface);
	let st = N.iface_up(cfg.iface);
	let h = health_state();
	let state;
	if (tinfo.disabled || !st.up)
		state = 'down';
	else if (cfg.watchdog.enabled && h?.state == 'down')
		state = 'down';
	else
		state = 'healthy';
	// Аварийная блокировка имеет смысл только при включённой Маршрутизации.
	return N.set_table(state, cfg.iface, tinfo, cfg.routing && cfg.killswitch);
};

export function apply() {
	let lk = U.lock('truba');
	ensure_dirs();

	let cfg = F.load();
	let tinfo = F.tunnel_info(cfg.iface);
	let vps = F.vps_ip(tinfo);
	let st = N.iface_up(cfg.iface);
	let prev = U.read_json(C.APPLIED_FILE, {});
	let warnings = [];
	// Счётчики прежней таблицы переносятся в новую: учёт идёт с запуска службы, а не с последнего применения.
	let ctx = { lan_if: F.zone_devices(cfg.zones), bypass4: bypass4(vps, tinfo), socket_mark: socket_mark_ok(), vps,
	            counters: counters_raw() };
	if (!ctx.socket_mark)
		U.warn_log('nft: нет socket mark (kmod-nft-socket) — свои сокеты Роутера с меткой Туннеля не защищены от чужих цепочек output');

	if (!length(ctx.lan_if))
		push(warnings, 'zones_without_devices');
	if (!tinfo.exists)
		push(warnings, 'tunnel_not_configured');

	let applied = { routing: cfg.routing, mode: cfg.mode, time: time(), vps, warnings, missing: [],
	                socket_mark: ctx.socket_mark,
	                counters_since: (length(ctx.counters) && prev.counters_since) ? prev.counters_since : time() };
	let text;

	if (cfg.routing) {
		let dat = D.ensure();
		if (!length(dat.cats)) {
			push(warnings, 'lists_missing');
			// 1000>&- — блокировка procd из rc.common: фоновый процесс не должен её
			// наследовать, иначе его собственный reload ждёт сам себя.
			if (!stat(C.RUN_DIR + '/update.pid'))
				system('( /usr/sbin/truba update-lists >/dev/null 2>&1 1000>&- & )');
		}
		let plan = P.compute(cfg, dat.cats);
		let gkey = P.geosite_key(plan, dat.hash);

		ctx.gs_tunnel4 = [];
		ctx.gs_direct4 = [];
		if (prev.routing && prev.gkey == gkey) {
			ctx.gs_tunnel4 = set_elements('gs_tunnel4');
			ctx.gs_direct4 = set_elements('gs_direct4');
		}
		ctx.dev_tunnel = map(filter(cfg.devices, d => d.policy == 'tunnel'), d => d.mac);
		ctx.dev_direct = map(filter(cfg.devices, d => d.policy == 'direct'), d => d.mac);

		text = R.nft_full(cfg, plan, ctx);

		if (api_port_taken(cfg.dns.api)) {
			U.warn_log(sprintf('порт %s занят другой программой: mosdns без API, счётчиков кэша на «Обзоре» не будет', cfg.dns.api));
			cfg.dns.api = null;
		}
		applied.dns_api = cfg.dns.api;
		let hosts = F.router_hosts(cfg, tinfo);
		let mconf = sprintf('%J', R.mosdns(cfg, plan, hosts));
		U.write_atomic(C.MOSDNS_CONF, mconf);
		// Метка поколения: меняется вместе с данными — procd перезапустит mosdns.
		let stamp = U.sha256_str(gkey + '\n' + mconf);
		if (readfile(C.STAMP_FILE) != stamp)
			writefile(C.STAMP_FILE, stamp);

		applied.gkey = gkey;
		applied.geoip_sizes = ctx.set_sizes;
		applied.missing = plan.missing;
		applied.geosite_order = map(plan.geosite, g => g.tag + '=' + g.action);
	}
	else {
		text = R.nft_minimal(cfg, ctx);
	}

	U.write_atomic(C.NFT_FILE, text);
	let r = U.run('nft -f ' + U.shq(C.NFT_FILE));
	if (r.code != 0) {
		U.err('nft: ' + r.out);
		applied.error = 'nft: ' + trim(r.out);
		U.write_json(C.APPLIED_FILE, applied);
		lk?.close();
		return applied;
	}

	if (cfg.routing)
		N.dnsmasq_enable(cfg.dns.port);
	else
		N.dnsmasq_restore();

	N.ensure_rules(st.device);
	if (st.up)
		N.set_rp_filter(st.device);
	applied.table = routes(cfg, tinfo);
	N.cron_set(cfg.routing && cfg.lists.auto_update, cfg.lists.update_utc);
	N.upnp_set(cfg.upnp, cfg.iface, vps);

	U.write_json(C.APPLIED_FILE, applied);
	U.info(sprintf('применено: Маршрутизация %s, Режим %s, таблица Туннеля: %s',
		cfg.routing ? 'вкл' : 'выкл', cfg.mode, applied.table));
	lk?.close();
	return applied;
};

export function teardown() {
	let lk = U.lock('truba');
	system([ 'nft', 'delete', 'table', 'inet', C.NFT_TABLE ]);
	N.remove_rules();
	N.dnsmasq_restore();
	N.cron_set(false);
	N.upnp_set(false);
	unlink(C.APPLIED_FILE);
	unlink(C.HEALTH_FILE);
	U.info('Труба остановлена: правила сняты');
	lk?.close();
};

// Обновить только набор bypass4 (смена адресов интерфейсов).
export function refresh_bypass() {
	if (system('nft list table inet ' + C.NFT_TABLE + ' >/dev/null 2>&1') != 0)
		return;
	let prev = U.read_json(C.APPLIED_FILE, {});
	if (!prev.routing)
		return;
	let cfg = F.load();
	let tinfo = F.tunnel_info(cfg.iface);
	let b = bypass4(F.vps_ip(tinfo), tinfo);
	let s = 'flush set inet ' + C.NFT_TABLE + ' bypass4\n';
	if (length(b))
		s += 'add element inet ' + C.NFT_TABLE + ' bypass4 { ' + join(', ', b) + ' }\n';
	let tmp = C.RUN_DIR + '/bypass.nft';
	writefile(tmp, s);
	system('nft -f ' + U.shq(tmp) + ' >/dev/null 2>&1');
	unlink(tmp);
};

// ---- Наборы правил ----

function curl(url, out, dev) {
	let cmd = [ 'curl', '-fsSL', '--connect-timeout', '15', '--max-time', '180', '-o', out ];
	if (dev)
		push(cmd, '--interface', dev);
	push(cmd, url);
	return system(cmd) == 0;
}

function sha_from_sumfile(path) {
	let m = match(readfile(path) ?? '', /^([0-9a-fA-F]{64})/);
	return m ? lc(m[1]) : null;
}

export function update_lists(force) {
	let lk = U.lock('truba-lists');
	if (!lk)
		return { error: 'busy' };
	ensure_dirs();
	writefile(C.RUN_DIR + '/update.pid', '' + time());

	let cfg = F.load();
	let st = N.iface_up(cfg.iface);
	let tmpdir = '/tmp/truba-dl';
	U.mkdirp(tmpdir);

	let result = { time: time(), sets: {} };
	let changed = false;

	for (let set in [ 'geoip', 'geosite' ]) {
		let file = C.DAT_FILES[set];
		let dst = C.LISTS_DIR + '/' + file;
		let tmp = tmpdir + '/' + file;
		let sources = [];
		if (cfg.lists.via_tunnel && st.up)
			push(sources, { url: cfg.lists[set + '_url'], dev: st.device, via: 'tunnel' });
		else
			push(sources, { url: cfg.lists[set + '_url'], dev: null, via: 'direct' });
		push(sources, { url: cfg.lists[set + '_mirror'], dev: null, via: 'mirror' });

		let got = null, errors = [];
		for (let src in sources) {
			unlink(tmp);
			unlink(tmp + '.sha256sum');
			if (!curl(src.url, tmp, src.dev) || !curl(src.url + '.sha256sum', tmp + '.sha256sum', src.dev)) {
				push(errors, src.via + ': download failed');
				continue;
			}
			let want = sha_from_sumfile(tmp + '.sha256sum');
			let have = U.sha256_file(tmp);
			if (!want || want != have) {
				push(errors, src.via + ': sha256 mismatch');
				continue;
			}
			got = { sha: have, via: src.via };
			break;
		}

		if (!got) {
			result.sets[set] = { ok: false, errors };
			U.err(sprintf('списки: %s не обновлён (%s)', file, join('; ', errors)));
			continue;
		}

		let cur = U.sha256_file(dst);
		if (cur == got.sha && !force) {
			result.sets[set] = { ok: true, changed: false, sha: got.sha, via: got.via };
			unlink(tmp);
			unlink(tmp + '.sha256sum');
			continue;
		}

		let prev = C.PREV_DIR + '/' + file;
		if (cur) {
			rename(dst, prev);
			if (stat(dst + '.sha256sum'))
				rename(dst + '.sha256sum', prev + '.sha256sum');
		}
		// tmp лежит в /tmp (tmpfs), dst — на флеше: простой rename здесь не работает.
		if (!U.move_file(tmp, dst) || !U.move_file(tmp + '.sha256sum', dst + '.sha256sum')) {
			unlink(dst);
			unlink(dst + '.sha256sum');
			if (cur) {
				rename(prev, dst);
				rename(prev + '.sha256sum', dst + '.sha256sum');
			}
			result.sets[set] = { ok: false, errors: [ 'не удалось записать ' + dst ] };
			U.err(sprintf('списки: %s скачан, но не записан в %s', file, C.LISTS_DIR));
			continue;
		}
		changed = true;
		result.sets[set] = { ok: true, changed: true, sha: got.sha, via: got.via };
		U.info(sprintf('списки: %s обновлён (%s, %s)', file, got.via, substr(got.sha, 0, 12)));
	}

	result.changed = changed;
	U.write_json(C.LISTS_STATE, result);
	unlink(C.RUN_DIR + '/update.pid');
	lk.close();

	if (changed)
		system('/etc/init.d/truba reload >/dev/null 2>&1');
	return result;
};

export function rollback_lists() {
	let lk = U.lock('truba-lists');
	if (!lk)
		return { error: 'busy' };
	let swapped = [];
	for (let set in [ 'geoip', 'geosite' ]) {
		let file = C.DAT_FILES[set];
		let cur = C.LISTS_DIR + '/' + file, old = C.PREV_DIR + '/' + file;
		if (!stat(old))
			continue;
		for (let ext in [ '', '.sha256sum' ]) {
			let tmp = cur + ext + '.swap';
			if (stat(cur + ext))
				rename(cur + ext, tmp);
			if (stat(old + ext))
				rename(old + ext, cur + ext);
			if (stat(tmp))
				rename(tmp, old + ext);
		}
		push(swapped, file);
	}
	lk.close();
	if (length(swapped)) {
		U.info('списки: откат ' + join(', ', swapped));
		system('/etc/init.d/truba reload >/dev/null 2>&1');
	}
	return { swapped };
};

// sums — с контрольной суммой: она нужна только вкладке «DNS и списки».
function list_info(dir, file, sums) {
	let p = dir + '/' + file;
	let st = stat(p);
	if (!st)
		return null;
	let res = { mtime: st.mtime, size: st.size };
	if (sums)
		res.sha256 = sha_from_sumfile(p + '.sha256sum') ?? U.sha256_file(p);
	return res;
}

// ---- Состояние ----

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
// «Обзор» показывает, и без лишних процессов. Версии списков — lists().
export function status() {
	let cfg = F.load();
	let tinfo = F.tunnel_info(cfg.iface);
	let st = N.iface_up(cfg.iface);
	let applied = U.read_json(C.APPLIED_FILE, null);
	let raw = counters_raw();
	let ub = connect();
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
		vps_ip: applied?.vps ?? F.vps_ip(tinfo),
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
			updating: stat(C.RUN_DIR + '/update.pid') != null,
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
		updating: stat(C.RUN_DIR + '/update.pid') != null,
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

// Сбросить Действия Категорий Режима к Стартовым настройкам (без применения).
export function reset_rules(mode) {
	mode = (mode == 'selective') ? 'selective' : 'all';
	let c = cursor();
	c.load('truba');
	let del = [];
	c.foreach('truba', 'rule', (s) => {
		if ((s.mode ?? 'all') == mode)
			push(del, s['.name']);
	});
	for (let sid in del)
		c.delete('truba', sid);
	for (let r in P.STARTING) {
		if (r.mode != mode)
			continue;
		let sid = c.add('truba', 'rule');
		c.set('truba', sid, 'mode', r.mode);
		c.set('truba', sid, 'set', r.set);
		c.set('truba', sid, 'tag', r.tag);
		c.set('truba', sid, 'action', r.action);
	}
	c.commit('truba');
	return { mode, rules: length(filter(P.STARTING, r => r.mode == mode)) };
};

export function categories() {
	let cfg = F.load();
	let dat = U.read_json(C.CATS_FILE, null) ?? D.ensure();
	return { mode: cfg.mode, cats: dat?.cats ?? [], hash: dat?.hash, rules: cfg.rules, starting: P.STARTING };
};
