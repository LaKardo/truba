// Журнал mosdns без шума. Каждый неудачный запрос mosdns пишет 2–4 строками WARN (сервер, ветка
// fallback, вход), и при мёртвом домене, который устройство спрашивает раз в секунду, они вытесняют из
// кольцевого буфера logd строки Трубы. Уровень error убрал бы и полезные предупреждения, файл журнала
// mosdns в /tmp рос бы без ротации. Поэтому mosdns запускает `truba mosdns-log <команда>`: stderr
// mosdns идёт сюда, такие строки складываются в одну сводку раз в минуту, остальные уходят в журнал
// как есть (под тегом mosdns и в формате mosdns — «Журнал» разбирает их по-прежнему).
'use strict';

import * as uloop from 'uloop';
import * as socket from 'socket';
import { readfile, lsdir } from 'fs';
import * as U from 'truba.util';

// Строки о неудачном запросе: их сводка — раз в минуту.
const NOISE = {
	'upstream error': true, 'primary error': true, 'secondary error': true,
	'exchange failed': true, 'entry err': true, 'invalid msg': true,
};
const SUMMARY_EVERY = 60000;
// Прочих строк — не больше стольких за минуту: остальные только считаются.
const PASS_MAX = 20;
const TOP = 5;

// Строка mosdns (zap, консольный вид): «время<TAB>УРОВЕНЬ<TAB>[источник<TAB>]сообщение[<TAB>{поля}]».
export function parse(line) {
	let p = split(line, '\t');
	if (length(p) < 3 || !match(p[0], /^[0-9]{4}-[0-9][0-9]-[0-9][0-9]T/))
		return null;
	let fields = null;
	if (length(p) > 3 && substr(p[length(p) - 1], 0, 1) == '{') {
		try {
			fields = json(p[length(p) - 1]);
		}
		catch (e) { }
		p = slice(p, 0, length(p) - 1);
	}
	let msg = p[length(p) - 1];
	return { level: p[1], logger: (length(p) > 3) ? p[2] : null, msg, fields: fields ?? {} };
};

export function summary_new() {
	return { failed: 0, names: {}, upstreams: {}, invalid: 0, other: 0, passed: 0, skipped: 0 };
};

function bump(o, k) {
	o[k] = (o[k] ?? 0) + 1;
}

// Учесть строку. true — строку пропустить в журнал как есть.
export function summary_add(s, e) {
	if (!e || e.level != 'WARN' || !NOISE[e.msg]) {
		if (s.passed >= PASS_MAX) {
			s.skipped++;
			return false;
		}
		s.passed++;
		return true;
	}
	let f = e.fields;
	if (e.msg == 'invalid msg')
		s.invalid++;
	else if (e.msg == 'entry err') {
		s.failed++;
		let q = f.query?.qname;
		if (type(q) == 'string')
			bump(s.names, rtrim(q, '.'));
	}
	else if (e.msg == 'upstream error' && type(f.upstream) == 'string') {
		let k = f.upstream + ((type(f.error) == 'string') ? ' (' + f.error + ')' : '');
		bump(s.upstreams, k);
	}
	else
		s.other++;
	return false;
};

function top(o) {
	let ks = sort(keys(o), (a, b) => (o[b] - o[a]) || ((a < b) ? -1 : (a > b) ? 1 : 0));
	let out = map(slice(ks, 0, TOP), k => k + ' ×' + o[k]);
	if (length(ks) > TOP)
		push(out, 'ещё ' + (length(ks) - TOP));
	return join(', ', out);
}

// Текст сводки за период или null, если сообщать не о чем. Повреждённые запросы устройств
// (invalid msg) — шум, а не ошибка: только они — сводки нет.
export function summary_text(s, secs) {
	let parts = [];
	if (s.failed)
		push(parts, sprintf('без ответа %d запросов: %s', s.failed, top(s.names)));
	if (length(s.upstreams))
		push(parts, 'ошибки серверов: ' + top(s.upstreams));
	if (!length(parts))
		return s.skipped ? sprintf('за %d с пропущено строк журнала mosdns: %d', secs, s.skipped) : null;
	if (s.invalid)
		push(parts, sprintf('повреждённых запросов: %d', s.invalid));
	if (s.skipped)
		push(parts, sprintf('пропущено строк: %d', s.skipped));
	return sprintf('за %d с %s', secs, join('; ', parts));
};

function iso_now() {
	let t = gmtime();
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
}

function emit(level, line) {
	let prio = { ERROR: 'err', FATAL: 'crit', PANIC: 'crit', DPANIC: 'crit', WARN: 'warn', DEBUG: 'debug' }[level] ?? 'info';
	system([ 'logger', '-t', 'mosdns', '-p', 'daemon.' + prio, line ]);
}

// mosdns этого фильтра, оставшийся без родителя: прежний процесс фильтра убит SIGKILL раньше, чем
// дождался mosdns. Он держит порт, и новый mosdns не запустился бы. Свой — по метке в окружении:
// mosdns, запущенный procd напрямую (прежняя версия), тоже без родителя, но его не трогать.
const ORPHAN_MARK = 'TRUBA_MOSDNS_LOG=1';

function kill_orphans(argv) {
	let want = join('\x00', argv) + '\x00';
	for (let pid in lsdir('/proc') ?? []) {
		if (!match(pid, /^[0-9]+$/) || readfile('/proc/' + pid + '/cmdline') != want)
			continue;
		let st = split(readfile('/proc/' + pid + '/stat') ?? '', ') ')[1];
		let env = split(readfile('/proc/' + pid + '/environ') ?? '', '\x00');
		if (split(st ?? '', ' ')[1] == '1' && ORPHAN_MARK in env) {
			U.warn_log('mosdns ' + pid + ' остался от прежнего запуска — остановлен');
			system([ 'kill', '-KILL', pid ]);
		}
	}
}

// Запустить команду (mosdns) и фильтровать её stderr и stdout. Код выхода — её.
// SIGHUP — перезапустить команду сразу, без паузы respawn procd (5 с): после смены адреса WAN соединения
// mosdns с серверами DNS «Напрямую» остались на прежнем адресе, и запросы по ним ждали бы тайм-аута.
export function run(argv) {
	if (!length(argv))
		die('нет команды');
	kill_orphans(argv);
	let code = 1, child = null, s = summary_new(), since = U.now_ms(), restart = false;

	let flush = () => {
		let txt = summary_text(s, int((U.now_ms() - since) / 1000 + 0.5));
		if (txt)
			emit('WARN', iso_now() + '\tWARN\tсводка ' + txt);
		s = summary_new();
		since = U.now_ms();
	};
	let line = (l) => {
		l = rtrim(l, '\r');
		if (l == '')
			return;
		let e = parse(l);
		if (summary_add(s, e))
			emit(e?.level, l);
	};

	let readers = 0, stopping = false, ended = false;
	let finish = () => {
		if (!ended && !child && !readers) {
			ended = true;
			uloop.end();
		}
	};

	// Вывод одного запуска команды: свой сокет и свой хвост строки.
	let reader = (r) => {
		let buf = '', h = null;
		readers++;
		h = uloop.handle(r, () => {
			let d = r.recv(4096);
			if (d == null || d == '') {
				if (length(buf))
					line(buf);
				buf = '';
				h.delete();
				r.close();
				readers--;
				finish();
				return;
			}
			buf += d;
			let parts = split(buf, '\n');
			buf = pop(parts);
			for (let l in parts)
				line(l);
			// Строка без перевода длиннее 8 КиБ — отдать как есть.
			if (length(buf) > 8192) {
				line(buf);
				buf = '';
			}
		}, uloop.ULOOP_READ);
	};

	let start;
	start = () => {
		let pair = socket.pair();
		if (!pair)
			die('socket.pair: ' + socket.error());
		let r = pair[0], w = pair[1];
		// Дочернему процессу — только 0, 1 и 2: остальные дескрипторы (uloop, сокеты) ему не нужны.
		child = uloop.process('/bin/sh', [ '-c', sprintf('export %s; exec 2>&%d 1>&2; ' +
			'for f in /proc/$$/fd/*; do n=${f##*/}; [ "$n" -gt 2 ] 2>/dev/null && eval "exec $n>&-"; done; exec "$@"',
			ORPHAN_MARK, w.fileno()),
			'mosdns-log', ...argv ], {}, (c) => {
			code = c;
			child = null;
			if (restart && !stopping) {
				restart = false;
				start();
				return;
			}
			// stderr может держать и потомок команды: ждать его не дольше секунды.
			if (readers)
				uloop.timer(1000, () => { readers = 0; finish(); });
			finish();
		});
		w.close();
		if (!child)
			die('не запущен ' + argv[0]);
		reader(r);
	};

	uloop.init();
	start();

	// procd останавливает инстанс SIGTERM этому процессу: передать его mosdns и дождаться его выхода.
	let stop = () => {
		stopping = true;
		if (child)
			system([ 'kill', '-TERM', '' + child.pid() ]);
	};
	uloop.signal('SIGTERM', stop);
	uloop.signal('SIGINT', stop);
	uloop.signal('SIGHUP', () => {
		if (!child || stopping || restart)
			return;
		restart = true;
		U.info('mosdns перезапускается: сменился канал до Трубы');
		system([ 'kill', '-TERM', '' + child.pid() ]);
	});

	let t = null;
	t = uloop.timer(SUMMARY_EVERY, () => {
		flush();
		t.set(SUMMARY_EVERY);
	});

	uloop.run();
	flush();
	return code;
};
