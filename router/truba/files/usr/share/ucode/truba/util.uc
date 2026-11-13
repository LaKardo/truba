// Общие помощники: журнал, файлы, JSON, команды, команда ip, IPv4.
'use strict';

import { readfile, rename, mkdir, stat, popen, unlink, open } from 'fs';
import { connect } from 'ubus';
import * as C from 'truba.const';

export function shq(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
};

// Выполнить команду через shell и вернуть { code, out }.
export function run(cmd) {
	let p = popen(cmd + ' 2>&1; echo "@@rc=$?"', 'r');
	if (!p)
		return { code: -1, out: '' };
	let out = p.read('all') ?? '';
	p.close();
	let m = match(out, /@@rc=([0-9]+)\n?$/);
	let code = m ? int(m[1]) : -1;
	out = replace(out, /@@rc=[0-9]+\n?$/, '');
	return { code, out };
};

// ---- Команда ip ----

// Службе нужен полноценный ip (iproute2, пакет ip-full): вывод в JSON (-j), «ip rule … oif»,
// «ip route get … mark». BusyBox ничего из этого не умеет: на -j отвечает справкой и кодом 1.
// Команда ip на Роутере — ссылка /sbin/ip, и ставят её оба пакета: после переустановки busybox она
// ведёт на его ip, хотя ip-full установлен. Поэтому все вызовы ip идут через ip_cmd и ip_json.
const IP_BINS = [ 'ip', C.IP_FULL ];
// «Полноценного ip нет» помнится столько секунд: rpcd и truba stats живут долго и не должны
// перебирать команды на каждый опрос, но установленный позже ip-full обязаны заметить.
const IP_RETRY = 60;
let ip_bin = null, ip_checked = null;

// Понимает ли команда -j: интерфейс lo есть всегда, ответ — массив JSON.
function ip_works(bin) {
	let r = run(bin + ' -j link show dev lo');
	return r.code == 0 && substr(ltrim(r.out), 0, 1) == '[';
}

// Команда полноценного ip — «ip» или путь ip-full; null — такого нет. Ответ помнится на время процесса:
// найденная команда — пока работает (после сбоя ip_json проверяет заново), «нет» — IP_RETRY секунд.
// recheck — проверить сейчас.
export function ip_full(recheck) {
	let now = time();
	if (!recheck && (ip_bin != null || (ip_checked != null && now - ip_checked < IP_RETRY)))
		return ip_bin;
	ip_bin = null;
	ip_checked = now;
	for (let bin in IP_BINS)
		if (ip_works(bin)) {
			ip_bin = bin;
			break;
		}
	return ip_bin;
};

// Команда ip для вызовов службы: полноценная, а без неё — какая есть (простые команды BusyBox умеет).
export function ip_cmd() {
	return ip_full() ?? IP_BINS[0];
};

// «ip -j <args>» разобранным JSON; null — полноценного ip нет или команда не удалась.
export function ip_json(args) {
	let known = (ip_bin != null);
	for (let pass = 0; pass < 2; pass++) {
		let bin = ip_full(pass > 0);
		if (bin == null)
			return null;
		let r = run(bin + ' -j ' + args);
		if (r.code == 0) {
			try {
				return json(r.out);
			}
			catch (e) { }
		}
		// Команда найдена раньше, а ссылку с тех пор могли переписать: проверить заново и повторить.
		if (!known)
			return null;
		known = false;
	}
	return null;
};

// Вызов ubus по переданному соединению (ub) или по своему: status опрашивается раз в 5 с,
// и ему хватает одного соединения на все вызовы.
export function ubus_call(ub, obj, method, args) {
	let own = (ub == null) ? connect() : null;
	let res = (ub ?? own)?.call(obj, method, args ?? {});
	own?.disconnect();
	return res;
};

// Монотонное время в миллисекундах — для тайм-аутов внутри одного вызова.
export function now_ms() {
	let c = clock(true);
	return c[0] * 1000 + c[1] / 1000000;
};

export function mkdirp(path) {
	let parts = split(path, '/'), cur = '';
	for (let p in parts) {
		if (p == '')
			continue;
		cur += '/' + p;
		if (!stat(cur))
			mkdir(cur, 0755);
	}
};

export function read_json(path, dflt) {
	let s = readfile(path);
	if (s == null)
		return dflt;
	try {
		return json(s);
	}
	catch (e) {
		return dflt;
	}
};

// Атомарная запись: во временный файл и rename. Записано не всё (флеш заполнен) — прежний
// файл остаётся: обрезанная копия не должна заменять целую.
export function write_atomic(path, data, mode) {
	let tmp = path + '.tmp';
	let fd = open(tmp, 'w', mode ?? 0644);
	if (!fd)
		return false;
	let ok = (fd.write(data) == length(data));
	fd.close();
	if (!ok) {
		unlink(tmp);
		return false;
	}
	return rename(tmp, path);
};

export function write_json(path, obj) {
	return write_atomic(path, sprintf('%J', obj));
};

const WDAYS = [ 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' ];
const MONS = [ 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' ];

// Строка в виде logread: «Mon Nov  2 18:11:33 2026 daemon.warn truba: текст».
export function event_line(t, level, tag, msg) {
	return sprintf('%s %s %2d %02d:%02d:%02d %d daemon.%s %s: %s\n', WDAYS[t.wday % 7], MONS[t.mon - 1], t.mday,
		t.hour, t.min, t.sec, t.year, level, tag, replace('' + msg, /\n/g, ' '));
};

// Дописать строку; файл больше EVENTS_MAX — оставить вторую половину (по целым строкам).
function event_add(line) {
	if (!stat(C.RUN_DIR))
		mkdirp(C.RUN_DIR);
	let f = open(C.EVENTS_FILE, 'a', 0644);
	if (!f)
		return;
	f.write(line);
	f.close();
	if ((stat(C.EVENTS_FILE)?.size ?? 0) <= C.EVENTS_MAX)
		return;
	let s = readfile(C.EVENTS_FILE) ?? '';
	s = substr(s, length(s) - C.EVENTS_MAX / 2);
	write_atomic(C.EVENTS_FILE, substr(s, index(s, '\n') + 1));
}

// Журнал: syslog и копия в EVENTS_FILE. tag — для своего источника на «Журнале» (watchdog);
// без него — тег службы.
export function log(level, msg, tag) {
	tag ??= C.LOG_TAG;
	system([ 'logger', '-t', tag, '-p', 'daemon.' + level, msg ]);
	try {
		event_add(time() + '\t' + event_line(localtime(), level, tag, msg));
	}
	catch (e) { }
};

export function info(msg) { log('info', msg); };
export function warn_log(msg) { log('warn', msg); };
export function err(msg) { log('err', msg); };

// Перенос файла. Между файловыми системами (tmpfs /tmp → overlay /etc) rename
// не работает (EXDEV), тогда — копия рядом с целью и атомарный rename.
export function move_file(src, dst) {
	if (rename(src, dst))
		return true;
	let before = stat(src), input = open(src, 'r');
	if (!input)
		return false;
	let tmp = dst + '.tmp', output = open(tmp, 'w', 0644);
	if (!output) {
		input.close();
		return false;
	}
	let ok = true, chunk, copied = 0;
	while (length(chunk = input.read(65536) ?? ''))
		if (output.write(chunk) != length(chunk)) {
			ok = false;
			break;
		}
		else
			copied += length(chunk);
	ok &&= before != null && copied == before.size;
	input.close();
	ok = output.close() && ok;
	if (!ok || !rename(tmp, dst)) {
		unlink(tmp);
		return false;
	}
	unlink(src);
	return true;
};

export function sha256_file(path) {
	if (!stat(path))
		return null;
	let r = run('sha256sum ' + shq(path));
	let m = match(r.out, /^([0-9a-f]{64})/);
	return m ? m[1] : null;
};

// Контрольная сумма из файла «.sha256sum» (первое поле) или null.
export function sha_from_sumfile(path) {
	let m = match(readfile(path) ?? '', /^([0-9a-fA-F]{64})/);
	return m ? lc(m[1]) : null;
};

// Записать, только если содержимое другое: флеш не изнашивается одинаковыми записями.
export function write_if_changed(path, data) {
	if (data == null || readfile(path) == data)
		return false;
	return write_atomic(path, data);
};

// Текст исключения: ucode передаёт в catch объект { type, message, stacktrace }.
export function errmsg(e) {
	return (type(e) == 'object') ? (e.message ?? sprintf('%J', e)) : ('' + e);
};

// IPv4 «a.b.c.d» → целое число или null.
export function ip2int(ip) {
	let a = iptoarr(ip);
	if (type(a) != 'array' || length(a) != 4)
		return null;
	return (a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3];
};

export function int2ip(n) {
	return arrtoip([ (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255 ]);
};

// «a.b.c.d/n» → [ first, last ] (включительно) или null.
export function cidr_range(cidr) {
	let m = match(cidr, /^([0-9.]+)(\/([0-9]+))?$/);
	if (!m)
		return null;
	let base = ip2int(m[1]);
	if (base == null)
		return null;
	let len = (m[3] != null) ? int(m[3]) : 32;
	if (len < 0 || len > 32)
		return null;
	let size = 1 << (32 - len);
	let first = base & ~(size - 1) & 0xffffffff;
	return [ first, first + size - 1 ];
};

export function cidr_contains(cidr, ip) {
	let r = cidr_range(cidr), n = ip2int(ip);
	return (r != null && n != null && n >= r[0] && n <= r[1]);
};

// IPv4-адреса имени через nslookup (busybox); server — DNS-сервер, по умолчанию системный.
// Только запрос A: без -type busybox шлёт ещё и AAAA, а ответ на него не нужен.
// Адреса ответа идут после строки «Name:», до неё — адрес самого DNS-сервера.
export function nslookup(host, server) {
	let r = run('nslookup -type=A ' + shq(host) + (server ? ' ' + shq(server) : ''));
	let ips = [], answer = false;
	for (let line in split(r.out, '\n')) {
		if (match(line, /^Name:/))
			answer = true;
		let m = answer ? match(line, /^Address( [0-9]+)?:\s*([0-9.]+)\s*$/) : null;
		if (m)
			push(ips, m[2]);
	}
	return uniq(ips);
};

// FNV-1a 32 бита для структурного ключа (отпечатка) данных.
export function fnv1a(s) {
	let h = 0x811c9dc5;
	for (let i = 0; i < length(s); i++)
		h = ((h ^ ord(s, i)) * 0x01000193) & 0xffffffff;
	return h;
};

export function is_ipv4(s) {
	return (type(s) == 'string' && match(s, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) && ip2int(s) != null);
};

export function to_list(v) {
	if (v == null)
		return [];
	return (type(v) == 'array') ? v : [ v ];
};

// Простая блокировка на файле: держится, пока открыт дескриптор.
// 'e' (O_CLOEXEC): иначе дескриптор наследуют дочерние процессы (фоновый
// update-lists), блокировка переживает apply, и следующий apply ждёт её вечно.
// nowait — не ждать: null, если блокировку держит другой процесс.
export function lock(name, nowait) {
	mkdirp('/var/lock');
	let fd = open('/var/lock/' + name + '.lock', 'we');
	if (!fd)
		return null;
	if (!fd.lock(nowait ? 'xn' : 'x')) {
		fd.close();
		return null;
	}
	return fd;
};

// Держит ли блокировку другой процесс. В отличие от файла-флага, она снимается сама,
// даже если процесс убит: «идёт обновление» не залипает навсегда.
export function lock_busy(name) {
	// Чтение состояния из rpcd не создаёт файл с маской самого rpcd.
	let path = '/var/lock/' + name + '.lock';
	let fd = open(path, 're');
	if (!fd)
		return stat(path) != null;
	let busy = !fd.lock('xn');
	fd.close();
	return busy;
};
