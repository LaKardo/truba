// Оркестрация: применить настройки, снять всё, таблица Туннеля, обновление списков.
// Состояние для интерфейса — truba.state.
'use strict';

import { readfile, writefile, stat, unlink, rename, lsdir } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as D from 'truba.dat';
import * as F from 'truba.conf';
import * as P from 'truba.plan';
import * as R from 'truba.render';
import * as N from 'truba.net';
import * as S from 'truba.state';

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

// Есть ли в ядре таблица Трубы. Короткая цепочка вместо «nft list table»: та вывела бы
// и все подсети geoip.
function table_loaded() {
	return system('nft list chain inet ' + C.NFT_TABLE + ' prerouting >/dev/null 2>&1') == 0;
}

// Состояние таблицы 77 по здоровью Туннеля.
export function routes(cfg, tinfo) {
	cfg ??= F.load();
	tinfo ??= F.tunnel_info(cfg.iface);
	let st = N.iface_up(cfg.iface);
	let h = S.health_state();
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

// ---- Наборы правил на флеше: текущие и предыдущие ----

// Поменять местами текущие и предыдущие Наборы правил. Вызывать под блокировкой LOCK_LISTS.
function swap_lists() {
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
	return swapped;
}

// Распаковать Наборы правил. Если текущие не читаются (остались от версий, которые не
// проверяли скачанное, или повреждены на флеше), вернуть предыдущие и распаковать их.
// Блокировку списков не ждём: её держит update-lists, а он сам применит новые, когда закончит.
function unpack_lists(warnings) {
	try {
		return D.ensure();
	}
	catch (e) {
		let why = U.errmsg(e);
		let lk = U.lock(C.LOCK_LISTS, true);
		let swapped = lk ? swap_lists() : [];
		lk?.close();
		if (!length(swapped))
			die('списки не распаковались: ' + why);
		U.err(sprintf('списки не распаковались (%s): возвращены предыдущие — %s', why, join(', ', swapped)));
		push(warnings, 'lists_rolled_back');
		return D.ensure();
	}
}

// ---- Применение настроек ----

// Последняя удачная копия (ADR 0006): правила nftables без счётчиков и без IP из DNS (их
// снова наберёт mosdns), конфиг mosdns без API (его порт к следующей загрузке может быть
// занят) и списки доменов, на которые он ссылается. На флеш пишется только то, что изменилось.
function save_good(cfg, plan, ctx, hosts, res) {
	U.mkdirp(C.GOOD_GEOSITE);
	let meta = U.read_json(C.GOOD_META, {});
	let gctx = { ...ctx, counters: null, gs_tunnel4: [], gs_direct4: [] };
	let changed = U.write_if_changed(C.GOOD_NFT, plan ? R.nft_full(cfg, plan, gctx) : R.nft_minimal(cfg, gctx));
	let keep = {};

	if (plan) {
		let have = true;
		for (let g in plan.geosite) {
			let f = D.geosite_file(g.tag, C.GOOD_GEOSITE);
			keep[f] = true;
			have &&= (stat(f) != null);
		}
		// Списки доменов зависят только от файлов Наборов правил и Категорий плана — от того же,
		// что и gkey: пока он прежний, они не перечитываются.
		if (meta.gkey != res.gkey || !have)
			for (let g in plan.geosite)
				changed = U.write_if_changed(D.geosite_file(g.tag, C.GOOD_GEOSITE), readfile(D.geosite_file(g.tag))) || changed;
		let m = R.mosdns({ ...cfg, dns: { ...cfg.dns, api: null } }, plan, hosts, C.GOOD_GEOSITE);
		changed = U.write_if_changed(C.GOOD_MOSDNS, sprintf('%J', m)) || changed;
	}
	else if (stat(C.GOOD_MOSDNS)) {
		unlink(C.GOOD_MOSDNS);
		changed = true;
	}

	// Списки, на которые копия больше не ссылается, — после записи её конфига mosdns.
	for (let f in lsdir(C.GOOD_GEOSITE) ?? []) {
		let p = C.GOOD_GEOSITE + '/' + f;
		if (!keep[p]) {
			unlink(p);
			changed = true;
		}
	}

	if (changed || meta.time == null)
		U.write_json(C.GOOD_META, { time: time(), routing: res.routing, mode: res.mode, port: cfg.dns.port,
		                            vps: res.vps, gkey: res.gkey, geoip_sizes: res.geoip_sizes,
		                            missing: res.missing, geosite_order: res.geosite_order });
}

// Загрузить последнюю удачную копию: метаданные копии или null (копии нет, nft её не принял).
function load_good() {
	let meta = U.read_json(C.GOOD_META, null);
	if (!meta || !stat(C.GOOD_NFT))
		return null;
	let r = U.run('nft -f ' + U.shq(C.GOOD_NFT));
	if (r.code != 0) {
		U.err('последняя удачная копия правил не загрузилась: ' + trim(r.out));
		return null;
	}
	let m = meta.routing ? readfile(C.GOOD_MOSDNS) : null;
	meta.mosdns = (m != null) && !!U.write_atomic(C.MOSDNS_CONF, m);
	return meta;
}

// Применить настройки; итог — в res. Ошибка nft — res.error, остальное — исключением.
// res.loaded — новая таблица уже в ядре.
function apply_config(res, prev) {
	let cfg = F.load();
	let ub = connect();
	let tinfo = F.tunnel_info(cfg.iface, ub);
	let st = N.iface_up(cfg.iface, ub);
	let lan_if = F.zone_devices(cfg.zones, ub);
	ub?.disconnect();
	let vps = F.vps_ip(tinfo);
	// Счётчики прежней таблицы переносятся в новую: учёт идёт с запуска службы, а не с последнего применения.
	let ctx = { lan_if, bypass4: bypass4(vps, tinfo), socket_mark: socket_mark_ok(), vps, counters: S.counters_raw() };
	if (!ctx.socket_mark)
		U.warn_log('nft: нет socket mark (kmod-nft-socket) — свои сокеты Роутера с меткой Туннеля не защищены от чужих цепочек output');
	if (length(cfg.invalid))
		U.warn_log('пропущены неверные настройки: ' + join(', ', map(cfg.invalid, (x) => x.key + '=' + x.value)));

	if (!length(ctx.lan_if))
		push(res.warnings, 'zones_without_devices');
	if (!tinfo.exists)
		push(res.warnings, 'tunnel_not_configured');

	res.routing = cfg.routing;
	res.mode = cfg.mode;
	res.vps = vps;
	res.missing = [];
	res.invalid = cfg.invalid;
	res.socket_mark = ctx.socket_mark;
	res.counters_since = (length(ctx.counters) && prev.counters_since) ? prev.counters_since : time();
	res.mosdns = false;
	let text, mconf, plan, hosts;

	if (cfg.routing) {
		let dat = unpack_lists(res.warnings);
		if (!length(dat.cats)) {
			push(res.warnings, 'lists_missing');
			// 1000>&- — блокировка procd из rc.common: фоновый процесс не должен её
			// наследовать, иначе его собственный reload ждёт сам себя.
			if (!U.lock_busy(C.LOCK_LISTS))
				system('( /usr/sbin/truba update-lists >/dev/null 2>&1 1000>&- & )');
		}
		plan = P.compute(cfg, dat.cats);
		let gkey = P.geosite_key(plan, dat.hash);

		ctx.gs_tunnel4 = [];
		ctx.gs_direct4 = [];
		if (prev.routing && prev.gkey == gkey) {
			ctx.gs_tunnel4 = S.set_elements('gs_tunnel4');
			ctx.gs_direct4 = S.set_elements('gs_direct4');
		}
		ctx.dev_tunnel = map(filter(cfg.devices, d => d.policy == 'tunnel'), d => d.mac);
		ctx.dev_direct = map(filter(cfg.devices, d => d.policy == 'direct'), d => d.mac);

		text = R.nft_full(cfg, plan, ctx);

		if (api_port_taken(cfg.dns.api)) {
			U.warn_log(sprintf('порт %s занят другой программой: mosdns без API, счётчиков кэша на «Обзоре» не будет', cfg.dns.api));
			cfg.dns.api = null;
		}
		res.dns_api = cfg.dns.api;
		hosts = F.router_hosts(cfg, tinfo);
		mconf = sprintf('%J', R.mosdns(cfg, plan, hosts));

		res.gkey = gkey;
		res.geoip_sizes = ctx.set_sizes;
		res.missing = plan.missing;
		res.geosite_order = map(plan.geosite, g => g.tag + '=' + g.action);
	}
	else {
		text = R.nft_minimal(cfg, ctx);
	}

	U.write_atomic(C.NFT_FILE, text);
	let r = U.run('nft -f ' + U.shq(C.NFT_FILE));
	if (r.code != 0) {
		res.error = 'nft: ' + trim(r.out);
		return;
	}
	res.loaded = true;

	// Конфиг mosdns — только после загрузки таблицы: если nft её не принял, действующий
	// конфиг mosdns должен по-прежнему соответствовать действующей (прежней) таблице.
	if (cfg.routing) {
		U.write_atomic(C.MOSDNS_CONF, mconf);
		// Метка поколения меняется вместе с данными (списки, Режим, Действия Категорий):
		// procd сравнивает содержимое файла и перезапускает mosdns; mosdns.json он отслеживает сам.
		if (readfile(C.STAMP_FILE) != res.gkey)
			writefile(C.STAMP_FILE, res.gkey);
		N.dnsmasq_enable(cfg.dns.port);
	}
	else
		N.dnsmasq_restore();
	res.mosdns = cfg.routing;

	N.ensure_rules(st.device);
	if (st.up)
		N.set_rp_filter(st.device);
	res.table = routes(cfg, tinfo);
	N.cron_set(cfg.routing && cfg.lists.auto_update, cfg.lists.update_utc);
	N.upnp_set(cfg.upnp, cfg.iface, vps);

	// Сбой записи копии не отменяет того, что применено.
	try {
		save_good(cfg, plan, ctx, hosts, res);
	}
	catch (e) {
		U.err('последняя удачная копия правил не сохранена: ' + U.errmsg(e));
	}
}

// Применить не удалось (ADR 0006). Служба не останавливается, DNS сети не пропадает:
// - таблица Трубы в ядре есть — действует она (nft -f атомарен: если новая не загрузилась,
//   осталась прежняя), и mosdns работает с конфигом, который ей соответствует;
// - таблицы нет (загрузка Роутера) — загружается последняя удачная копия с флеша;
// - нет и копии — правил Трубы нет, трафик идёт напрямую, и DNS тоже: dnsmasq без mosdns.
function keep_running(res, prev) {
	let out = { time: res.time, error: res.error, warnings: res.warnings ?? [], invalid: res.invalid ?? [] };
	if (table_loaded()) {
		// Поля описывают действующую таблицу: новую, если она успела загрузиться, иначе прежнюю.
		out = { ...(res.loaded ? res : prev), ...out, fallback: 'kept' };
		out.mosdns = stat(C.DNSMASQ_BACKUP) != null && stat(C.MOSDNS_CONF) != null;
	}
	else {
		let good = load_good();
		if (good) {
			out = { ...out, fallback: 'last_good', good_time: good.time, routing: good.routing, mode: good.mode,
			        vps: good.vps, gkey: good.gkey, geoip_sizes: good.geoip_sizes, missing: good.missing ?? [],
			        geosite_order: good.geosite_order, counters_since: time(), mosdns: good.mosdns };
			if (good.mosdns) {
				writefile(C.STAMP_FILE, good.gkey ?? '');
				N.dnsmasq_enable(good.port);
			}
			else
				N.dnsmasq_restore();
		}
		else {
			N.dnsmasq_restore();
			out = { ...out, fallback: 'none', routing: false, mosdns: false };
		}
	}

	// Правила ip и таблица Туннеля не зависят от того, что не применилось.
	try {
		let cfg = F.load();
		let tinfo = F.tunnel_info(cfg.iface);
		let st = N.iface_up(cfg.iface);
		N.ensure_rules(st.device);
		if (st.up)
			N.set_rp_filter(st.device);
		out.table = routes(cfg, tinfo);
	}
	catch (e) {
		U.err('таблица Туннеля не пересчитана: ' + U.errmsg(e));
	}
	return out;
}

const FALLBACK_LOG = {
	kept: 'действуют правила, загруженные до ошибки',
	last_good: 'загружена последняя удачная копия правил',
	none: 'правил Трубы нет: трафик и DNS идут напрямую',
};

// Применить настройки. Итог — в applied.json: его показывает «Обзор», а init-скрипт по
// полю mosdns решает, запускать ли mosdns, — и при ошибке тоже (ADR 0006).
export function apply() {
	let lk = U.lock(C.LOCK_APPLY);
	ensure_dirs();
	let prev = U.read_json(C.APPLIED_FILE, {});
	let res = { time: time(), warnings: [] };
	try {
		apply_config(res, prev);
	}
	catch (e) {
		res.error = U.errmsg(e);
	}

	if (res.error) {
		U.err('настройки не применены: ' + res.error);
		try {
			res = keep_running(res, prev);
		}
		catch (e) {
			U.err('после ошибки: ' + U.errmsg(e));
			res.fallback = 'kept';
			res.mosdns = stat(C.DNSMASQ_BACKUP) != null && stat(C.MOSDNS_CONF) != null;
		}
		U.warn_log(FALLBACK_LOG[res.fallback] ?? res.fallback);
	}
	else {
		U.info(sprintf('применено: Маршрутизация %s, Режим %s, таблица Туннеля: %s',
			res.routing ? 'вкл' : 'выкл', res.mode, res.table));
	}
	delete res.loaded;

	U.write_json(C.APPLIED_FILE, res);
	lk?.close();
	return res;
};

export function teardown() {
	let lk = U.lock(C.LOCK_APPLY);
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
	let prev = U.read_json(C.APPLIED_FILE, {});
	if (!prev.routing)
		return;
	// Только этот набор: «nft list table» вывел бы и все подсети geoip.
	if (system('nft list set inet ' + C.NFT_TABLE + ' bypass4 >/dev/null 2>&1') != 0)
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

export function update_lists(force) {
	let lk = U.lock(C.LOCK_LISTS);
	if (!lk)
		return { error: 'busy' };
	ensure_dirs();

	let cfg = F.load();
	let st = N.iface_up(cfg.iface);
	let tmpdir = '/tmp/truba-dl';
	U.mkdirp(tmpdir);

	let result = { time: time(), sets: {} };
	let changed = false, reapply = false;

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
			let want = U.sha_from_sumfile(tmp + '.sha256sum');
			let have = U.sha256_file(tmp);
			if (!want || want != have) {
				push(errors, src.via + ': sha256 mismatch');
				continue;
			}
			// Контрольная сумма подтверждает только, что файл скачан целиком. Файл, который
			// распаковщик не разбирает, ломал бы каждое применение настроек: он не заменяет текущий.
			let bad = D.validate(set, tmp);
			if (bad) {
				push(errors, src.via + ': parse failed');
				U.err(sprintf('списки: %s (%s) не разбирается — %s', file, src.via, bad));
				continue;
			}
			got = { sha: have, via: src.via };
			break;
		}

		if (!got) {
			unlink(tmp);
			unlink(tmp + '.sha256sum');
			result.sets[set] = { ok: false, errors };
			U.err(sprintf('списки: %s не обновлён (%s)', file, join('; ', errors)));
			continue;
		}

		let cur = U.sha256_file(dst);
		if (cur == got.sha) {
			result.sets[set] = { ok: true, changed: false, sha: got.sha, via: got.via };
			unlink(tmp);
			unlink(tmp + '.sha256sum');
			// -f — применить ещё раз, не трогая файлы: предыдущая версия остаётся версией для отката.
			reapply ||= !!force;
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
	lk.close();

	if (changed || reapply)
		system('/etc/init.d/truba reload >/dev/null 2>&1');
	return result;
};

// bg — применить в фоне и не ждать занятую блокировку списков: так вызывает rpcd. Он обслуживает
// вызовы по одному, и, пока ждал бы применения (распаковка, загрузка подсетей geoip) или
// идущего обновления списков, стоял бы весь LuCI. Перестановка файлов — сразу, она быстрая.
export function rollback_lists(bg) {
	let lk = U.lock(C.LOCK_LISTS, !!bg);
	if (!lk)
		return { error: 'busy' };
	let swapped = swap_lists();
	lk.close();
	if (length(swapped)) {
		U.info('списки: откат ' + join(', ', swapped));
		system(bg ? '( /etc/init.d/truba reload >/dev/null 2>&1 & )' : '/etc/init.d/truba reload >/dev/null 2>&1');
	}
	return { swapped, applying: !!bg && length(swapped) > 0 };
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

// Категории и Действия для вкладки «Маршрутизация». busy — списки распаковывает apply.
export function categories() {
	let cfg = F.load();
	let dat = D.cached();
	return { mode: cfg.mode, cats: dat?.cats ?? [], hash: dat?.hash, busy: (dat == null), error: dat?.error,
	         rules: cfg.rules, starting: P.STARTING };
};
