// Общие помощники: журнал, файлы, JSON, команды, IPv4.
'use strict';

import { readfile, writefile, rename, mkdir, stat, popen, unlink, open } from 'fs';

export function log(level, msg) {
	system([ 'logger', '-t', 'truba', '-p', 'daemon.' + level, msg ]);
};

export function info(msg) { log('info', msg); };
export function warn_log(msg) { log('warn', msg); };
export function err(msg) { log('err', msg); };

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

// Атомарная запись: во временный файл и rename.
export function write_atomic(path, data, mode) {
	let tmp = path + '.tmp';
	let fd = open(tmp, 'w', mode ?? 0644);
	if (!fd)
		return false;
	fd.write(data);
	fd.close();
	return rename(tmp, path);
};

export function write_json(path, obj) {
	return write_atomic(path, sprintf('%J', obj));
};

// Перенос файла. Между файловыми системами (tmpfs /tmp → overlay /etc) rename
// не работает (EXDEV), тогда — копия рядом с целью и атомарный rename.
export function move_file(src, dst) {
	if (rename(src, dst))
		return true;
	let data = readfile(src);
	if (data == null || !write_atomic(dst, data))
		return false;
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

export function sha256_str(s) {
	let tmp = '/tmp/truba-hash.' + time();
	writefile(tmp, s);
	let h = sha256_file(tmp);
	unlink(tmp);
	return h;
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
export function lock(name) {
	mkdirp('/var/lock');
	let fd = open('/var/lock/' + name + '.lock', 'we');
	if (!fd)
		return null;
	if (!fd.lock('x')) {
		fd.close();
		return null;
	}
	return fd;
};

export function file_mtime(path) {
	let st = stat(path);
	return st ? st.mtime : null;
};
