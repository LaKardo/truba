// Контроль Туннеля: handshake + ping до Трубы внутри Туннеля, перезапуск, Аварийная блокировка.
'use strict';

import * as uloop from 'uloop';
import { readfile } from 'fs';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as F from 'truba.conf';
import * as N from 'truba.net';

function handshake_age(dev) {
	let r = U.run('awg show ' + U.shq(dev) + ' latest-handshakes');
	if (r.code != 0)
		return null;
	let latest = 0;
	for (let line in split(trim(r.out), '\n')) {
		let f = split(line, '\t');
		let ts = int(f[1] ?? 0);
		if (ts > latest)
			latest = ts;
	}
	return latest ? (time() - latest) : null;
}

// Время ответа на ping через Туннель, мс; null — ответа нет.
export function ping_rtt(dev, target) {
	let r = U.run(sprintf('ping -c 1 -W 2 -w 3 -I %s %s', U.shq(dev), U.shq(target)));
	let m = (r.code == 0) ? match(r.out, /time=([0-9.]+) ?ms/) : null;
	return m ? +m[1] : null;
};

// Окно последних проверок для «Обзора»: задержка и потери за ~10 минут при интервале 30 с.
const PROBE_WINDOW = 20;

function iface_mtu(dev) {
	return int(trim(readfile('/sys/class/net/' + dev + '/mtu') ?? '0'));
}

// Итог ping: сколько отправлено и получено, средняя задержка (мс) или null.
function ping_stats(out) {
	let m = match(out, /([0-9]+) packets transmitted, ([0-9]+) packets received/);
	let a = match(out, /= [0-9.]+\/([0-9.]+)\//);
	return { sent: m ? int(m[1]) : 0, received: m ? int(m[2]) : 0, avg: a ? +a[1] : null };
}

// Крупные пакеты: ping Трубы пакетом во весь MTU Туннеля. Обычный ping мелкий и не видит
// пути, который теряет полноразмерные пакеты (MTU, фрагменты): при нём сайты открываются
// с задержкой, а загрузки замирают на секунды. size — размер пакета в байтах (= MTU).
export function big_probe(dev, target) {
	let mtu = iface_mtu(dev);
	if (mtu < 576)
		return null;
	let s = ping_stats(U.run(sprintf('ping -c 3 -W 2 -s %d -I %s %s', mtu - 28, U.shq(dev), U.shq(target))).out);
	return { ok: s.received >= 2, sent: s.sent, received: s.received, size: mtu, time: time() };
};

// Крупные пакеты проверяются раз в BIG_EVERY проверок (5 мин при интервале 30 с) и сразу
// после подъёма Туннеля: ping пакетом во весь MTU дороже обычного.
const BIG_EVERY = 10;

// «Проверка Туннеля» на «Диагностике»: ping Трубы пакетами трёх размеров разом.
// Размеры — IP-пакета в байтах: обычный ping, средний и во весь MTU Туннеля.
function run_tunnel_test() {
	let cfg = F.load();
	let tinfo = F.tunnel_info(cfg.iface);
	if (!tinfo.exists)
		return { error: 'not_configured' };
	let st = N.iface_up(cfg.iface);
	if (tinfo.disabled || !st.up)
		return { error: 'tunnel_down' };
	let target = length(cfg.watchdog.probe) ? cfg.watchdog.probe : tinfo.peer;
	if (!target)
		return { error: 'no_target' };
	let mtu = iface_mtu(st.device);
	let sizes = [ 84 ];
	if (mtu > 1028)
		push(sizes, 1028);
	if (mtu > 84)
		push(sizes, mtu);
	let dir = trim(U.run('mktemp -d /tmp/truba-tt.XXXXXX').out);
	if (!match(dir, /^\/tmp\/truba-tt\./))
		return { error: 'tmp' };
	let cmd = '';
	for (let s in sizes)
		cmd += sprintf('ping -c 5 -W 2 -s %d -I %s %s > %s/%d 2>&1 & ', s - 28, U.shq(st.device), U.shq(target), dir, s);
	U.run(cmd + 'wait');
	let results = map(sizes, (s) => {
		let r = ping_stats(readfile(dir + '/' + s) ?? '');
		r.size = s;
		// Один потерянный из пяти — ещё не потери крупных пакетов.
		r.ok = r.received >= r.sent - 1 && r.sent > 0;
		return r;
	});
	system([ 'rm', '-rf', dir ]);
	return { target, mtu, time: time(), results, ok: length(filter(results, (r) => !r.ok)) == 0 };
}

// Итог сохраняется в TT_FILE: rpcd запускает проверку в фоне (она идёт секунды, а rpcd
// обслуживает вызовы по одному), и интерфейс забирает итог оттуда.
export function tunnel_test() {
	let res = run_tunnel_test();
	res.time ??= time();
	U.mkdirp(C.RUN_DIR);
	U.write_json(C.TT_FILE, res);
	return res;
};

// «Проверка NAT» сама: после подъёма Туннеля (итог старше «в порядке с») и после
// перезагрузки (итога нет). Если ни один сервер не ответил — повтор не чаще раза в
// NAT_RETRY с: при загрузке DNS может ещё не работать. Запущенную проверку (до ~5 с)
// ждём NAT_WAIT с, а не запускаем вторую.
const NAT_RETRY = 600, NAT_WAIT = 60;
let nat_started = 0;

function nat_due(since) {
	if (time() - nat_started < NAT_WAIT)
		return false;
	let n = U.read_json(C.NAT_FILE, null);
	return !n || n.time < since || (n.error && time() - n.time >= NAT_RETRY);
}

export function run() {
	let cfg = F.load();
	if (!cfg.watchdog.enabled)
		return;

	// Перезапуск watchdog (смена настроек, обновление пакета) продолжает с прежнего места:
	// «в порядке с» и окно проверок не обнуляются — если запись свежая. После перерыва
	// (watchdog был выключен) они бы описывали давнее прошлое. Состояние берётся всегда:
	// по нему построена таблица 77. После перезагрузки файла нет.
	let prev = U.read_json(C.HEALTH_FILE, null);
	let fresh = prev && time() - (prev.last_check ?? 0) <= 3 * cfg.watchdog.interval && prev.interval == cfg.watchdog.interval;
	let state = prev?.state ?? 'healthy';
	let since = (fresh && prev.since) ? prev.since : time(), fails = 0;
	let probes = (fresh && type(prev.probes) == 'array') ? slice(prev.probes, -PROBE_WINDOW) : [];   // задержки, мс; null — потеря
	let big = fresh ? prev.big : null, big_n = 0;   // итог big_probe
	let timer;

	let probed = (rtt) => {
		push(probes, rtt);
		if (length(probes) > PROBE_WINDOW)
			shift(probes);
	};

	// rec — запись текущей проверки: в файл идёт целиком, чтобы «Обзор» и в этот момент
	// видел задержку и окно проверок.
	let set_state = (next, info, rec) => {
		if (next == state)
			return;
		state = next;
		since = time();
		// routes() читает состояние из файла — записать до пересчёта таблицы.
		U.mkdirp(C.RUN_DIR);
		U.write_json(C.HEALTH_FILE, { ...rec, state, since, fails, probes });
		let c = F.load();
		let table = N.routes(c, F.tunnel_info(c.iface));
		U.log(next == 'healthy' ? 'notice' : 'warning',
			sprintf('Туннель %s (%s); таблица Туннеля: %s',
				next == 'healthy' ? 'восстановлен' : 'не отвечает', info, table));
		system([ 'ubus', 'send', 'truba.tunnel', sprintf('%J', { state: next, info, table }) ]);
	};

	let tick = () => {
		cfg = F.load();
		let w = cfg.watchdog;
		let tinfo = F.tunnel_info(cfg.iface);
		let st = N.iface_up(cfg.iface);
		let rec = { state, since, fails, last_check: time(), interval: w.interval, handshake_age: null, ping: null, rtt: null, big };

		if (tinfo.disabled) {
			fails = 0;
			probes = [];
			set_state('down', 'интерфейс выключен', rec);
		}
		else if (!st.up) {
			fails++;
			probed(null);
			if (fails >= w.fails)
				set_state('down', 'интерфейс не поднят', rec);
		}
		else {
			let probe = length(w.probe) ? w.probe : tinfo.peer;
			let ping_ok = true;
			if (probe) {
				rec.rtt = ping_rtt(st.device, probe);
				ping_ok = rec.rtt != null;
				probed(rec.rtt);
			}
			let age = handshake_age(st.device);
			rec.ping = ping_ok;
			rec.handshake_age = age;

			if (ping_ok && age != null && age <= w.handshake_max) {
				fails = 0;
				set_state('healthy', sprintf('handshake %d с назад', age), rec);
				// В фоне: проверка ждёт ответов до 4,5 с, а цикл не должен.
				if (nat_due(since)) {
					nat_started = time();
					system('( /usr/sbin/truba nat-test auto >/dev/null 2>&1 & )');
				}
				// Итога нет или он старше подъёма Туннеля — проверить сейчас, иначе раз в BIG_EVERY.
				if (probe && (big == null || big.time < since || ++big_n >= BIG_EVERY)) {
					big_n = 0;
					big = big_probe(st.device, probe);
				}
			}
			else {
				fails++;
				let why = !ping_ok ? 'нет ответа на ping ' + probe : sprintf('handshake %s', age == null ? 'не было' : age + ' с назад');
				if (fails >= w.fails) {
					set_state('down', why, rec);
					if (fails % w.fails == 0) {
						U.warn_log('перезапуск интерфейса ' + cfg.iface + ': ' + why);
						system([ 'ifup', cfg.iface ]);
					}
				}
			}
		}

		rec.state = state;
		rec.since = since;
		rec.fails = fails;
		rec.probes = probes;
		rec.big = big;
		U.mkdirp(C.RUN_DIR);
		U.write_json(C.HEALTH_FILE, rec);
		timer.set(w.interval * 1000);
	};

	uloop.init();
	timer = uloop.timer(1000, tick);
	uloop.run();
};
