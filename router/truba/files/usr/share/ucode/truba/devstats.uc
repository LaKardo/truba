// История трафика по устройствам (ADR 0018) для вкладки «Устройства». Её ведёт процесс `truba stats`
// вместе с общей историей скорости: раз в 5 с — снимок счётчиков наборов dv_* (S.dev_counters),
// по разнице — скорость каждого устройства, поминутные средние за час (мини-график) и почасовые
// суммы байт за сутки. Файл — в оперативной памяти, перезапуск процесса продолжает историю.
'use strict';

import * as C from 'truba.const';
import * as U from 'truba.util';

const STEP = C.HISTORY.fine.step;
const MINUTE = 60;        // с: перерыв дольше минуты — пропуск, а не скачок
const HOUR = 3600;
const MIN_SPAN = HOUR;    // поминутные средние — за последний час
const MIN_VALUES = 4;     // в поминутных — Туннель и Напрямую, к устройству и от него: их рисует график
const VALUES = length(C.DEV_SETS);

// Снимок: v — { ip: [ байты по C.DEV_SETS ] } или null (наборов нет); gen — поколение таблицы
// (applied.time): после применения настроек элементы наборов начинаются с нуля, и снимки разных
// поколений не сравниваются. m — монотонное время, мс: оно не прыгает, когда NTP поправляет часы.
export function snapshot(raw, gen, m, t) {
	return { t, m, gen, v: raw ?? null };
};

// Конец минуты, в которую попадает t: точка описывает шаг до t, минута — 60 с до конца.
function minute_end(t) {
	return int((t + MINUTE - 1) / MINUTE) * MINUTE;
}

// Байты за шаг по устройствам: { dt, d: { ip: [ байты ] } }; null — снимки не сравнить. Адреса не было
// в прошлом снимке того же поколения — элемент новый, и весь его счётчик набран за этот шаг.
// Счётчик, который уменьшился, даёт null только на своём месте.
function deltas(prev, cur) {
	let dt = prev ? (cur.m - prev.m) / 1000.0 : 0;
	if (!prev || prev.v == null || cur.v == null || prev.gen != cur.gen || dt < 1 || dt > MINUTE)
		return null;
	let d = {};
	for (let ip, a in cur.v) {
		let b = prev.v[ip];
		d[ip] = map(a, (x, i) => (b == null) ? x : ((x != null && b[i] != null && x >= b[i]) ? x - b[i] : null));
	}
	return { dt, d };
}

// Минута закрывается первым замером следующей: среднее — байты минуты на секунды, покрытые замерами.
// Минута без трафика не пишется: адреса живут в наборах сутки, и у сотен устройств без трафика
// были бы сотни точек нулей в файле и в ответе devices. На графике её место — пропуск.
function close_minute(dev) {
	let a = dev.acc;
	if (a.s > 0 && length(filter(a.b, (x) => x > 0)))
		push(dev.minutes, [ a.end, ...map(a.b, (x) => int(x / a.s + 0.5)) ]);
	dev.acc = null;
}

// Добавить снимок cur к истории hist { last — прошлый снимок, devices: { ip: устройство } }.
// Устройство: seen — когда появилось, last — время последнего трафика, rate — байт/с по C.DEV_SETS
// (null — сравнивать не с чем), acc — копилка текущей минуты, minutes — [ t, 4 средних ] за час,
// hours — [ начало часа, 6 сумм байт ] за сутки.
export function add(hist, cur) {
	let t = cur.t, devs = hist.devices, now = cur.v ?? {};
	// Часы ушли назад (их поправил NTP): точки «из будущего» убираются, иначе порядок сломан.
	if (hist.last && t < hist.last.t) {
		for (let ip, dev in devs) {
			dev.minutes = filter(dev.minutes, (x) => x[0] < t);
			dev.hours = filter(dev.hours, (x) => x[0] < t);
			dev.acc = null;
		}
	}
	let dd = deltas(hist.last, cur);
	let end = minute_end(t), hour = int(t / HOUR) * HOUR;
	for (let ip in now)
		devs[ip] ??= { seen: t, last: null, rate: null, acc: null, minutes: [], hours: [] };

	let gone = [];
	for (let ip, dev in devs) {
		if (dev.acc && dev.acc.end != end)
			close_minute(dev);
		let d = dd?.d[ip];
		if (d) {
			dev.rate = map(d, (x) => (x == null) ? null : int(x / dd.dt + 0.5));
			dev.acc ??= { end, b: [ 0, 0, 0, 0 ], s: 0 };
			for (let i = 0; i < MIN_VALUES; i++)
				dev.acc.b[i] += d[i] ?? 0;
			dev.acc.s += dd.dt;
			let hb = dev.hours[length(dev.hours) - 1];
			if (hb?.[0] != hour)
				push(dev.hours, hb = [ hour, 0, 0, 0, 0, 0, 0 ]);
			for (let i = 0; i < VALUES; i++)
				hb[i + 1] += d[i] ?? 0;
			if (length(filter(d, (x) => x > 0)))
				dev.last = t;
		}
		else
			dev.rate = null;
		dev.minutes = filter(dev.minutes, (x) => x[0] > t - MIN_SPAN);
		dev.hours = filter(dev.hours, (x) => x[0] > t - C.DEV_SPAN);
		// Элемент набора живёт сутки после последнего пакета: устройство, которого в наборах нет
		// и которое не появлялось и не передавало дольше суток, больше не показывается.
		let seen = ((dev.last ?? 0) > dev.seen) ? dev.last : dev.seen;
		if (!(ip in now) && seen < t - C.DEV_SPAN)
			push(gone, ip);
	}
	for (let ip in gone)
		delete devs[ip];
	hist.last = cur;
};

// Байты за сутки по C.DEV_SETS — сумма почасовых.
export function day(dev) {
	let s = [ 0, 0, 0, 0, 0, 0 ];
	for (let h in dev?.hours ?? [])
		for (let i = 0; i < VALUES; i++)
			s[i] += h[i + 1] ?? 0;
	return s;
};

function list(x) {
	return filter((type(x) == 'array') ? x : [], (p) => type(p) == 'array' && type(p[0]) == 'int');
}

// История из файла: продолжить после перезапуска процесса (смена кода, reload).
export function load() {
	let f = U.read_json(C.DEVICES_FILE, null), devs = {};
	for (let ip, d in (type(f?.devices) == 'object') ? f.devices : {}) {
		if (!U.is_ipv4(ip) || type(d) != 'object')
			continue;
		devs[ip] = { seen: d.seen ?? time(), last: d.last, rate: null, acc: (type(d.acc) == 'object') ? d.acc : null,
		             minutes: list(d.minutes), hours: list(d.hours) };
	}
	return { last: (type(f?.last) == 'object') ? f.last : null, devices: devs };
};

// Каждый замер: скорость устройств нужна вкладке свежей. Файл — в /var/run (оперативная память).
export function save(hist) {
	U.mkdirp(C.RUN_DIR);
	U.write_json(C.DEVICES_FILE, { step: STEP, last: hist.last, devices: hist.devices });
};
