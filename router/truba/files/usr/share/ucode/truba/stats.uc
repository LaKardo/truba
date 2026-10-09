// История скорости трафика устройств для графика «Обзора». Её ведёт процесс `truba stats`
// (инстанс procd): раз в 5 с он читает счётчики Трубы и считает скорость. Браузер историю
// только показывает, поэтому она не рвётся, когда вкладка свёрнута или закрыта.
// Хранится в оперативной памяти (/var/run): флеш не изнашивается, а после перезагрузки
// счётчики и так начинаются с нуля. Перезапуск процесса продолжает историю из файлов.
'use strict';

import * as uloop from 'uloop';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as S from 'truba.state';

export const STEP = 5;           // точки — раз в 5 с
export const FINE_SPAN = 3600;   // за последний час
export const MIN_STEP = 60;      // поминутные средние
export const MIN_SPAN = 86400;   // за сутки

// Значения точки после времени: байт/с к устройствам и от них по Действиям, затем новых
// соединений в минуту. В поминутных средних — только первые MIN_VALUES: их рисует график.
const BYTES = [ 'c_tunnel_down', 'c_tunnel_up', 'c_direct_down', 'c_direct_up', 'c_inbound_down', 'c_inbound_up' ];
const CONNS = [ 'c_tunnel', 'c_direct', 'c_inbound' ];
const MIN_VALUES = 4;

// Снимок счётчиков: t — время точки, m — монотонное время, мс (по нему считается скорость:
// оно не прыгает, когда NTP поправляет часы), since — начало отсчёта счётчиков (applied).
// v — байты и соединения по порядку BYTES, CONNS; null — таблицы Трубы нет.
export function snapshot(raw, since, m, t) {
	let v = null;
	if (length(raw)) {
		v = [];
		for (let n in BYTES)
			push(v, raw[n]?.bytes);
		for (let n in CONNS)
			push(v, raw[n]?.packets);
	}
	return { t, m, since, v };
};

// Точка по разнице снимков: [t, значения…]. [t] — разрыв: сравнивать не с чем (первый
// замер, перерыв дольше минуты, таблицы нет) или счётчики начаты заново. Счётчик,
// который уменьшился или которого нет, даёт null только на своём месте.
export function point(prev, cur) {
	let dt = prev ? (cur.m - prev.m) / 1000.0 : 0;   // 1000.0: целые ucode делит нацело
	if (!prev || prev.v == null || cur.v == null || dt < 1 || dt > 60 || prev.since != cur.since)
		return [ cur.t ];
	let p = [ cur.t ];
	for (let i = 0; i < length(cur.v); i++) {
		let a = cur.v[i], b = prev.v[i];
		let r = (a != null && b != null && a >= b) ? (a - b) / dt : null;
		push(p, (r == null) ? null : int(((i < length(BYTES)) ? r : r * 60) + 0.5));
	}
	return p;
};

// Конец минуты, в которую попадает точка t: точка описывает 5 с до t, минута — 60 с до конца.
function minute_end(t) {
	return int((t + MIN_STEP - 1) / MIN_STEP) * MIN_STEP;
}

// Поминутное среднее за минуту (end − 60, end]: у каждого значения — по точкам, где оно есть.
// [end] — разрыв: значений нет.
export function minute(points, end) {
	let sum = [], n = [], any = false;
	for (let x in points) {
		if (x[0] <= end - MIN_STEP || x[0] > end)
			continue;
		for (let i = 1; i <= MIN_VALUES; i++) {
			if (x[i] != null) {
				sum[i] = (sum[i] ?? 0) + x[i];
				n[i] = (n[i] ?? 0) + 1;
				any = true;
			}
		}
	}
	if (!any)
		return [ end ];
	let p = [ end ];
	for (let i = 1; i <= MIN_VALUES; i++)
		push(p, n[i] ? int(sum[i] * 1.0 / n[i] + 0.5) : null);
	return p;
};

function last_t(list) {
	return length(list) ? list[length(list) - 1][0] : null;
}

// Добавить замер cur к истории hist { last — прошлый снимок, points — по 5 с, minutes — поминутные }.
// true — закрылась минута: её среднее добавлено, файл поминутных пора переписать.
export function add(hist, cur) {
	// Часы ушли назад (их поправил NTP): точки «из будущего» убираются, иначе порядок сломан.
	if (last_t(hist.points) != null && cur.t <= last_t(hist.points)) {
		hist.points = filter(hist.points, (x) => x[0] < cur.t);
		hist.minutes = filter(hist.minutes, (x) => x[0] < cur.t);
	}
	// Минута закрывается первой точкой следующей. Уже закрытая (процесс перезапустили
	// между записью двух файлов) не повторяется.
	let closed = false, prev = last_t(hist.points);
	if (prev != null && minute_end(cur.t) != minute_end(prev) && (last_t(hist.minutes) ?? 0) < minute_end(prev)) {
		push(hist.minutes, minute(hist.points, minute_end(prev)));
		closed = true;
	}
	push(hist.points, point(hist.last, cur));
	hist.last = cur;
	hist.points = filter(hist.points, (x) => x[0] > cur.t - FINE_SPAN);
	hist.minutes = filter(hist.minutes, (x) => x[0] > cur.t - MIN_SPAN);
	return closed;
};

// История из файлов: продолжить после перезапуска процесса (смена кода, reload).
function load() {
	let f = U.read_json(C.RATES_FILE, null), m = U.read_json(C.RATES_MIN_FILE, null);
	let list = (x) => filter((type(x) == 'array') ? x : [], (p) => type(p) == 'array' && type(p[0]) == 'int');
	return {
		last: (type(f?.last) == 'object') ? f.last : null,
		points: list(f?.points),
		minutes: list(m?.points),
	};
}

// Точки по 5 с — каждый замер, поминутные — когда закрылась минута.
function save(hist, minutes) {
	U.mkdirp(C.RUN_DIR);
	if (minutes)
		U.write_json(C.RATES_MIN_FILE, { step: MIN_STEP, points: hist.minutes });
	U.write_json(C.RATES_FILE, { step: STEP, last: hist.last, points: hist.points });
}

export function run() {
	let hist = load();
	let timer;
	let tick = () => {
		let m = int(U.now_ms());
		let since = U.read_json(C.APPLIED_FILE, null)?.counters_since;
		save(hist, add(hist, snapshot(S.counters_raw(), since, m, time())));
		// Следующий замер — через STEP от начала этого, сколько бы ни шёл этот.
		let wait = STEP * 1000 - (int(U.now_ms()) - m);
		timer.set((wait < 1000) ? 1000 : wait);
	};
	uloop.init();
	timer = uloop.timer(1000, tick);
	uloop.run();
};
