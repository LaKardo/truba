// Контроль Туннеля: handshake + ping до Трубы внутри Туннеля, перезапуск, Аварийная блокировка.
'use strict';

import * as uloop from 'uloop';
import { connect } from 'ubus';
import { readfile } from 'fs';
import { cursor } from 'uci';
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

// ping: ответа ждём 2 с (через Туннель — с запасом к обычным 30–150 мс), одиночный — не дольше 3 с всего.
const PING_WAIT = 2, PING_DEADLINE = 3;
// Размер пакета ping — это данные (-s): IP-пакет больше на заголовки IPv4 (20) и ICMP (8).
const ICMP_HDR = 28;
// Меньше минимального MTU IPv4 интерфейс не настроен (нет данных): крупные пакеты не проверяются.
const MTU_MIN_V4 = 576;

// Время ответа на ping через Туннель, мс; null — ответа нет.
export function ping_rtt(dev, target) {
	let r = U.run(sprintf('ping -c 1 -W %d -w %d -I %s %s', PING_WAIT, PING_DEADLINE, U.shq(dev), U.shq(target)));
	let m = (r.code == 0) ? match(r.out, /time=([0-9.]+) ?ms/) : null;
	return m ? +m[1] : null;
};

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
function big_probe(dev, target) {
	let mtu = iface_mtu(dev);
	if (mtu < MTU_MIN_V4)
		return null;
	let s = ping_stats(U.run(sprintf('ping -c 3 -W %d -s %d -I %s %s', PING_WAIT, mtu - ICMP_HDR, U.shq(dev), U.shq(target))).out);
	return { ok: s.received >= 2, sent: s.sent, received: s.received, size: mtu, time: time() };
}

// Крупные пакеты проверяются раз в BIG_EVERY проверок (5 мин при интервале 30 с) и сразу
// после подъёма Туннеля: ping пакетом во весь MTU дороже обычного.
const BIG_EVERY = 10;

// «Проверка Туннеля» на «Туннеле»: ping Трубы пакетами трёх размеров разом.
// Размеры — IP-пакета в байтах: обычный ping (56 байт данных), средний (1000) и во весь MTU Туннеля.
const TT_SMALL = 84, TT_MID = 1028;

function run_tunnel_test() {
	let cfg = F.load();
	let tinfo = F.tunnel_info(cfg.iface);
	if (!tinfo.exists)
		return { error: 'not_configured' };
	if (tinfo.disabled || !tinfo.up)
		return { error: 'tunnel_down' };
	let target = length(cfg.watchdog.probe) ? cfg.watchdog.probe : tinfo.peer;
	if (!target)
		return { error: 'no_target' };
	let dev = tinfo.device;
	let mtu = iface_mtu(dev);
	let sizes = [ TT_SMALL ];
	if (mtu > TT_MID)
		push(sizes, TT_MID);
	if (mtu > TT_SMALL)
		push(sizes, mtu);
	let dir = trim(U.run('mktemp -d ' + C.TT_TMP + '.XXXXXX').out);
	if (substr(dir, 0, length(C.TT_TMP) + 1) != C.TT_TMP + '.')
		return { error: 'tmp' };
	let cmd = '';
	for (let s in sizes)
		cmd += sprintf('ping -c 5 -W %d -s %d -I %s %s > %s/%d 2>&1 & ', PING_WAIT, s - ICMP_HDR, U.shq(dev), U.shq(target), dir, s);
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

// После события truba.recheck: первая проверка через RECHECK_DELAY с, после смены канала до Трубы — ещё
// FAST_SPAN с раз в FAST_INTERVAL с.
const RECHECK_DELAY = 2, FAST_INTERVAL = 5, FAST_SPAN = 60;
// Сколько последних простоев хранить в health.json.
const OUTAGES_MAX = 10;

// Квантиль q (0…1) задержек окна, мс: ближайший ранг; null — ответов нет. Потери не входят.
export function rtt_quantile(probes, q) {
	let v = sort(filter(probes, x => x != null), (a, b) => a - b);
	if (!length(v))
		return null;
	let i = int(q * length(v) + 0.999999) - 1;
	return v[i < 0 ? 0 : (i >= length(v) ? length(v) - 1 : i)];
};

// Канал до Трубы пропал (событие ifdown, отметка в WAN_FILE): неудачи проверок — не вина Туннеля.
// Не дольше WAN_DOWN_MAX: если подъём канала прошёл мимо (другое имя интерфейса), контроль не замирает.
const WAN_DOWN_MAX = 300;
function wan_down() {
	let d = U.read_json(C.WAN_FILE, null)?.down;
	return d != null && time() - d < WAN_DOWN_MAX;
}

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
	let probes = (fresh && type(prev.probes) == 'array') ? slice(prev.probes, -C.PROBE_WINDOW) : [];   // задержки, мс; null — потеря
	let big = fresh ? prev.big : null, big_n = 0;   // итог big_probe
	// Простои переживают перезапуск watchdog и перерыв: это история, а не текущее окно.
	let outages = (type(prev?.outages) == 'array') ? slice(prev.outages, -OUTAGES_MAX) : [];
	let timer;
	// Быстрые проверки после смены канала до Трубы: раз в FAST_INTERVAL с в течение FAST_SPAN с — Туннель
	// возвращается за секунды, а не к следующему циклу. last_up — интерфейс был поднят на прошлом цикле.
	let fast_until = 0, last_up = true;
	// Смена канала до Трубы, по которой ещё не записано, через сколько пришли рукопожатие и ping.
	let wan_at = null;
	// Простой идёт — отметить в нём время события (смена канала, действие).
	let mark = (k, v) => {
		if (state == 'down' && length(outages) && outages[-1].end == null) {
			if (k == 'act')
				push(outages[-1].acts ??= [], v);
			else
				outages[-1][k] = v;
		}
	};

	let probed = (rtt) => {
		push(probes, rtt);
		if (length(probes) > C.PROBE_WINDOW)
			shift(probes);
	};

	// Запись текущей проверки (rec) с состоянием цикла: в файл идёт целиком, чтобы «Обзор» и в этот момент
	// видел задержку и окно проверок.
	let save = (rec) => {
		rec.state = state;
		rec.since = since;
		rec.fails = fails;
		rec.probes = probes;
		rec.big = big;
		rec.outages = outages;
		rec.rtt_p50 = rtt_quantile(probes, 0.5);
		rec.rtt_p95 = rtt_quantile(probes, 0.95);
		U.mkdirp(C.RUN_DIR);
		U.write_json(C.HEALTH_FILE, rec);
	};

	let set_state = (next, info, rec, tinfo) => {
		if (next == state)
			return;
		let was = time() - since;
		state = next;
		since = time();
		// Журнал простоев для «Туннеля»: начало, длительность, причина. Последние OUTAGES_MAX.
		if (next == 'down')
			push(outages, { start: since, why: info });
		else if (length(outages) && outages[-1].end == null) {
			outages[-1].end = since;
			outages[-1].secs = was;
		}
		while (length(outages) > OUTAGES_MAX)
			shift(outages);
		// routes() читает состояние из файла — записать до пересчёта таблицы.
		save(rec);
		let table = N.routes(cfg, tinfo);
		U.log(next == 'healthy' ? 'notice' : 'warning',
			sprintf('Туннель %s (%s)%s; таблица Туннеля: %s',
				next == 'healthy' ? 'восстановлен' : 'не отвечает', info,
				next == 'healthy' ? sprintf(', простой %d с', was) : '', table), C.WATCHDOG_TAG);
		system([ 'ubus', 'send', 'truba.tunnel', sprintf('%J', { state: next, info, table, ...(next == 'healthy' ? { downtime: was } : {}) }) ]);
	};

	let tick = () => {
		cfg = F.load();
		let w = cfg.watchdog;
		let tinfo = F.tunnel_info(cfg.iface);
		// interval и handshake_max — для «Туннеля»: окно проверок во времени и порог возраста рукопожатия.
		let rec = { last_check: time(), interval: w.interval, handshake_max: w.handshake_max,
		            handshake_age: null, ping: null, rtt: null };

		if (tinfo.disabled) {
			fails = 0;
			probes = [];
			set_state('down', 'интерфейс выключен', rec, tinfo);
		}
		else if (!tinfo.up) {
			// В окно не идёт: «Потери» — про пакеты в Туннеле, а не про выключенный интерфейс.
			fails++;
			if (fails >= w.fails)
				set_state('down', 'интерфейс не поднят', rec, tinfo);
		}
		else if (wan_down()) {
			// Кабель вынут или канал ещё поднимается: Туннелю некуда слать пакеты. Не считать неудачи и не
			// перезапускать — по подъёму канала hotplug сам обновит Туннель и попросит проверить его.
			rec.wan_down = true;
		}
		else {
			let probe = length(w.probe) ? w.probe : tinfo.peer;
			let ping_ok = true;
			if (probe) {
				rec.rtt = ping_rtt(tinfo.device, probe);
				// В окно — первая попытка: повтор скрывал бы одиночные потери, и «Потери» были бы занижены.
				probed(rec.rtt);
				// Одна контрольная проба после потери: вердикт цикла — по ней.
				if (rec.rtt == null)
					rec.rtt = ping_rtt(tinfo.device, probe);
				ping_ok = rec.rtt != null;
			}
			let age = handshake_age(tinfo.device);
			rec.ping = ping_ok;
			rec.handshake_age = age;

			if (ping_ok && age != null && age <= w.handshake_max) {
				fails = 0;
				// Сколько Туннель возвращался после смены канала: ping и рукопожатие (его время — по awg). Новый
				// порт сессию не рвёт, и рукопожатия может не быть до планового rekey: тогда hs — null.
				if (wan_at != null) {
					let hs = time() - age;
					let n = { ping: time() - wan_at, hs: (hs >= wan_at) ? hs - wan_at : null };
					U.log('info', sprintf('после смены канала до Трубы: ping через %d с, %s', n.ping,
						(n.hs != null) ? sprintf('рукопожатие через %d с', n.hs) : 'сессия прежняя'), C.WATCHDOG_TAG);
					mark('after_wan', n);
					wan_at = null;
				}
				set_state('healthy', sprintf('handshake %d с назад', age), rec, tinfo);
				// В фоне: проверка ждёт ответов до 4,5 с, а цикл не должен.
				if (nat_due(since)) {
					nat_started = time();
					system('( ' + C.CLI + ' nat-test auto >/dev/null 2>&1 & )');
				}
				// Итога нет или он старше подъёма Туннеля — проверить сейчас, иначе раз в BIG_EVERY.
				if (probe && (big == null || big.time < since || ++big_n >= BIG_EVERY)) {
					big_n = 0;
					big = big_probe(tinfo.device, probe);
				}
			}
			else {
				fails++;
				let why = !ping_ok ? 'нет ответа на ping ' + probe : sprintf('handshake %s', age == null ? 'не было' : age + ' с назад');
				if (fails >= w.fails) {
					set_state('down', why, rec, tinfo);
					if (fails % w.fails == 0) {
						U.log('warn', 'перезапуск интерфейса ' + cfg.iface + ': ' + why, C.WATCHDOG_TAG);
						mark('act', { t: time(), what: 'restart' });
						// 0 просит ядро выбрать новый порт. Явный listen_port владельца не менять.
						// Только сокет Туннеля: общую таблицу NAT устройств не сбрасывать.
						if (!int(cursor().get('network', cfg.iface, 'listen_port') ?? 0) &&
						    system([ 'awg', 'set', tinfo.device, 'listen-port', '0' ]) != 0)
							U.log('warn', 'не удалось сменить порт Туннеля ' + cfg.iface, C.WATCHDOG_TAG);
						system([ 'ifup', cfg.iface ]);
					}
				}
			}
		}

		save(rec);
		last_up = tinfo.up;
		let iv = (time() < fast_until && FAST_INTERVAL < w.interval) ? FAST_INTERVAL : w.interval;
		timer.set(iv * 1000);
	};

	uloop.init();
	timer = uloop.timer(1000, tick);
	// truba.recheck (из hotplug): Туннель поднялся или сменился канал до Трубы — проверить через RECHECK_DELAY с.
	// Неудачи, пока интерфейса не было, к перезапуску не ведут: только что поднятый Туннель иначе мог бы
	// сразу уйти на перезапуск. Свой перезапуск watchdog (интерфейс был поднят) счёт неудач не сбрасывает —
	// иначе перезапуски шли бы чаще чем раз в fails циклов.
	let ub = connect();
	let recheck = ub?.listener(C.RECHECK_EVENT, (ev, data) => {
		if (data?.reason == 'wan') {
			fails = 0;
			fast_until = time() + FAST_SPAN;
			wan_at = time();
			mark('wan', wan_at);
			if (data.action)
				mark('act', { t: wan_at, what: data.action });
		}
		else if (!last_up)
			fails = 0;
		timer.set(RECHECK_DELAY * 1000);
	});
	uloop.run();
	recheck?.remove();
	ub?.disconnect();
};
