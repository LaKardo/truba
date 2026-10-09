// Проверка истории скорости (truba.stats) без процесса и файлов: снимки счётчиков,
// точки по 5 с, поминутные средние, обрезка по сроку, разрывы.
// Запуск внутри контейнера после копирования файлов пакета: ucode tests/router/test_stats.uc
'use strict';

import * as T from 'truba.stats';

let fails = 0;

function check(name, cond, detail) {
	if (cond) {
		print('ok   ', name, '\n');
	}
	else {
		print('FAIL ', name, detail ? (' — ' + detail) : '', '\n');
		fails++;
	}
}

function same(a, b) {
	return sprintf('%J', a) == sprintf('%J', b);
}

// Счётчики nft под своими именами: байты трафика и соединения (пакеты c_tunnel и др.).
function raw(b, c) {
	return {
		c_tunnel_down: { packets: 1, bytes: b[0] }, c_tunnel_up: { packets: 1, bytes: b[1] },
		c_direct_down: { packets: 1, bytes: b[2] }, c_direct_up: { packets: 1, bytes: b[3] },
		c_inbound_down: { packets: 1, bytes: b[4] }, c_inbound_up: { packets: 1, bytes: b[5] },
		c_tunnel: { packets: c[0], bytes: 0 }, c_direct: { packets: c[1], bytes: 0 },
		c_inbound: { packets: c[2], bytes: 0 }, c_block: { packets: 7, bytes: 0 },
	};
}

// ---- снимок счётчиков ----
let s0 = T.snapshot(raw([ 0, 0, 0, 0, 0, 0 ], [ 0, 0, 0 ]), 100, 10000, 1000);
check('снимок: байты по Действиям, затем соединения', same(s0.v, [ 0, 0, 0, 0, 0, 0, 0, 0, 0 ]));
check('снимок: время, монотонное время и отсчёт', s0.t == 1000 && s0.m == 10000 && s0.since == 100);
check('снимок: таблицы нет — значений нет', T.snapshot({}, 100, 10000, 1000).v == null);
let partial = raw([ 1, 2, 3, 4, 5, 6 ], [ 1, 2, 3 ]);
delete partial.c_tunnel;   // Маршрутизация выключена: счётчика соединений Туннеля нет
check('снимок: нет счётчика — null на его месте', same(T.snapshot(partial, 1, 0, 0).v, [ 1, 2, 3, 4, 5, 6, null, 2, 3 ]));

// ---- точка по разнице снимков ----
let s1 = T.snapshot(raw([ 5000, 500, 10000, 1000, 50, 5 ], [ 2, 3, 1 ]), 100, 15000, 1005);
check('точка: байт/с и новых соединений в минуту', same(T.point(s0, s1), [ 1005, 1000, 100, 2000, 200, 10, 1, 24, 36, 12 ]),
	sprintf('%J', T.point(s0, s1)));
check('точка: первого снимка нет — разрыв', same(T.point(null, s1), [ 1005 ]));
check('точка: отсчёт начат заново — разрыв', same(T.point(s0, { ...s1, since: 200 }), [ 1005 ]));
check('точка: таблицы нет — разрыв', same(T.point(s0, { ...s1, v: null }), [ 1005 ]));
check('точка: перерыв дольше минуты — разрыв', same(T.point(s0, { ...s1, m: 75001 }), [ 1005 ]));
check('точка: меньше секунды — разрыв', same(T.point(s0, { ...s1, m: 10500 }), [ 1005 ]));
let dec = T.snapshot(raw([ 5000, 500, 10000, 1000, 50, 5 ], [ 2, 3, 1 ]), 100, 10000, 1000);
let s2 = T.snapshot(raw([ 4000, 1000, 10000, 1000, 50, 5 ], [ 2, 3, 1 ]), 100, 15000, 1005);
check('точка: счётчик уменьшился — null только у него', same(T.point(dec, s2), [ 1005, null, 100, 0, 0, 0, 0, 0, 0, 0 ]),
	sprintf('%J', T.point(dec, s2)));
// Округление: 7 байт за 2 с — 3,5 → 4.
check('точка: округление до целых', T.point({ m: 0, since: 1, v: [ 0, 0, 0, 0, 0, 0, 0, 0, 0 ] },
	{ m: 2000, t: 2, since: 1, v: [ 7, 0, 0, 0, 0, 0, 0, 0, 0 ] })[1] == 4);

// ---- поминутное среднее ----
let pts = [ [ 60, 1, 1, 1, 1 ], [ 65, 10, 20, null, 40, 9, 9 ], [ 70, 20, 40, 30, null ], [ 75 ], [ 120, 99, 99, 99, 99 ], [ 125, 50, 50, 50, 50 ] ];
check('минута (60, 120]: среднее по точкам, где значение есть', same(T.minute(pts, 120), [ 120, 43, 53, 65, 70 ]),
	sprintf('%J', T.minute(pts, 120)));
check('минута без значений — разрыв', same(T.minute([ [ 65 ], [ 70 ] ], 120), [ 120 ]));

// ---- накопление: точки, минуты, обрезка ----
let hist = { last: null, points: [], minutes: [] };
let counters = (k) => raw([ k * 1000, k * 100, k * 2000, k * 200, 0, 0 ], [ k, 0, 0 ]);
let closed = [];
// 25 замеров по 5 с: с 1000 до 1120, минуты кончаются в 1020, 1080, 1140.
for (let k = 0; k <= 24; k++)
	push(closed, T.add(hist, T.snapshot(counters(k), 1, k * 5000, 1000 + k * 5)));
check('накопление: первая точка — разрыв', same(hist.points[0], [ 1000 ]));
check('накопление: вторая точка — скорость', same(hist.points[1], [ 1005, 200, 20, 400, 40, 0, 0, 12, 0, 0 ]),
	sprintf('%J', hist.points[1]));
check('накопление: закрыты минуты, кончившиеся в 1020 и 1080', same(map(hist.minutes, (x) => x[0]), [ 1020, 1080 ]),
	sprintf('%J', hist.minutes));
check('накопление: минута закрывается первой точкой следующей', closed[5] == true && closed[4] == false && length(filter(closed, (x) => x)) == 2);
check('накопление: среднее минуты — только 4 значения графика', same(hist.minutes[1], [ 1080, 200, 20, 400, 40 ]));
check('накопление: последний снимок сохранён', hist.last.t == 1120 && hist.last.m == 120000);

// После перезапуска процесса история та же, а минута, уже закрытая, не повторяется.
let again = { ...hist, minutes: [ ...hist.minutes, [ 1140, 1, 1, 1, 1 ] ] };
T.add(again, T.snapshot(counters(25), 1, 125000, 1145));
check('накопление: закрытая минута не дублируется', length(filter(again.minutes, (x) => x[0] == 1140)) == 1);

// Срок: точки по 5 с — час, минуты — сутки.
let old = { last: null, points: [ [ 100, 1, 1, 1, 1 ], [ 3700, 1, 1, 1, 1 ] ], minutes: [ [ 60, 1, 1, 1, 1 ], [ 3660, 1, 1, 1, 1 ] ] };
T.add(old, T.snapshot(counters(1), 1, 0, 3701));
check('обрезка: точки старше часа убраны', same(map(old.points, (x) => x[0]), [ 3700, 3701 ]), sprintf('%J', old.points));
// Через сутки: минута 3720 закрывается, минута 60 старше суток.
T.add(old, T.snapshot(counters(1), 1, 0, 86500));
check('обрезка: минуты старше суток убраны', same(map(old.minutes, (x) => x[0]), [ 3660, 3720 ]), sprintf('%J', old.minutes));
check('обрезка: после перерыва осталась только новая точка', same(old.points, [ [ 86500 ] ]), sprintf('%J', old.points));

// Часы Роутера ушли назад (поправил NTP): точки «из будущего» убираются, порядок не ломается.
let back = { last: null, points: [ [ 2000 ], [ 2005, 1, 1, 1, 1 ], [ 2010, 1, 1, 1, 1 ] ], minutes: [ [ 1980, 1, 1, 1, 1 ], [ 2040, 1, 1, 1, 1 ] ] };
T.add(back, T.snapshot(counters(1), 1, 0, 2006));
check('часы назад: точки по возрастанию времени', same(map(back.points, (x) => x[0]), [ 2000, 2005, 2006 ]), sprintf('%J', back.points));
check('часы назад: минуты «из будущего» убраны', same(map(back.minutes, (x) => x[0]), [ 1980 ]), sprintf('%J', back.minutes));

print(fails ? sprintf('\n%d FAILED\n', fails) : '\nALL OK\n');
exit(fails ? 1 : 0);
