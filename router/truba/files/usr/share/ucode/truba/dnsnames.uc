// Подсказки IPv4 → домен из кэша mosdns 5.3.3. Не участвуют в решении о маршруте:
// общий IP не доказывает, какое имя запрашивало конкретное устройство.
'use strict';

import { popen } from 'fs';
import * as U from 'truba.util';
import * as C from 'truba.const';

const MAX_DUMP = 8388608;

function uint(s, p, n) {
	if (p < 0 || p + n > length(s))
		die('короткое число');
	let v = 0;
	for (let i = 0; i < n; i++)
		v = v * 256 + ord(s, p + i);
	return v;
}

// Ограниченный protobuf: varint, строки и пропуск fixed32/fixed64.
function fields(s) {
	let p = 0, out = {};
	let varint = () => {
		let v = 0, mul = 1;
		for (let i = 0; i < 8; i++) {
			let b = uint(s, p++, 1);
			v += (b & 127) * mul;
			if (b < 128)
				return v;
			mul *= 128;
		}
		die('длинный varint');
	};
	while (p < length(s)) {
		let key = varint(), f = key >> 3, wt = key & 7, v;
		if (!f)
			die('поле protobuf');
		if (wt == 0)
			v = varint();
		else if (wt == 2) {
			let n = varint();
			if (n > length(s) - p)
				die('короткое поле');
			v = substr(s, p, n);
			p += n;
		}
		else if (wt == 1 || wt == 5) {
			p += (wt == 1) ? 8 : 4;
			if (p > length(s))
				die('короткое fixed');
		}
		else
			die('тип protobuf');
		out[f] ??= [];
		push(out[f], v);
	}
	return out;
}

// DNS-имя, включая указатели сжатия; следующий байт — после исходного имени.
function name(s, start) {
	let p = start, next = null, labels = [], seen = {};
	for (let i = 0; i < 128; i++) {
		if (seen[p])
			die('цикл DNS');
		seen[p] = true;
		let n = uint(s, p++, 1);
		if ((n & 192) == 192) {
			let target = (n & 63) * 256 + uint(s, p++, 1);
			next ??= p;
			p = target;
			continue;
		}
		if (n > 63 || p + n > length(s))
			die('имя DNS');
		if (!n) {
			let value = lc(join('.', labels));
			if (length(value) > 253 || !match(value, /^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/))
				die('домен DNS');
			return { value, next: next ?? p };
		}
		push(labels, substr(s, p, n));
		p += n;
	}
	die('длинное имя DNS');
}

function addresses(s) {
	if (length(s) < 12 || (uint(s, 2, 2) & 0x820f) != 0x8000 || uint(s, 4, 2) != 1)
		return null;
	let q = name(s, 12), p = q.next;
	if (uint(s, p, 2) != 1 || uint(s, p + 2, 2) != 1)
		return null;
	p += 4;
	let records = [], aliases = {}, count = uint(s, 6, 2);
	for (let i = 0; i < count; i++) {
		let owner = name(s, p);
		p = owner.next;
		let type = uint(s, p, 2), cls = uint(s, p + 2, 2), n = uint(s, p + 8, 2);
		p += 10;
		if (p + n > length(s))
			die('короткий ответ DNS');
		if (cls == 1 && type == 5) {
			let target = name(s, p);
			if (target.next != p + n)
				die('длина CNAME');
			aliases[owner.value] = target.value;
		}
		if (cls == 1 && type == 1 && n == 4)
			push(records, { owner: owner.value, ip: join('.', map([ 0, 1, 2, 3 ], i => uint(s, p + i, 1))) });
		p += n;
	}
	let reachable = {}, cur = q.value;
	for (let i = 0; i < 128 && cur != null && !reachable[cur]; i++) {
		reachable[cur] = true;
		cur = aliases[cur];
	}
	return { domain: q.value, ips: map(filter(records, r => reachable[r.owner]), r => r.ip) };
}

// Уже распакованный поток: блоки с восьмибайтовой big-endian длиной, CacheDumpBlock.
// Поле 4 — срок самого DNS-ответа, а не lazy-кэша: истёкшие имена не показываем.
export function parse(s, now, wanted, with_expiry) {
	let out = {}, expiry = {}, p = 0;
	if (type(s) != 'string' || length(s) > MAX_DUMP)
		return out;
	try {
		while (p < length(s)) {
			if (uint(s, p, 4) != 0)
				die('длина блока mosdns');
			let n = uint(s, p + 4, 4);
			p += 8;
			if (n > 1048576 || n > length(s) - p)
				die('длина блока mosdns');
			let block = fields(substr(s, p, n));
			p += n;
			for (let raw in block[1] ?? []) {
				let e = fields(raw), until = e[4]?.[0];
				if (type(until) != 'int' || until <= now || type(e[2]?.[0]) != 'string')
					continue;
				let a = addresses(e[2][0]);
				for (let ip in a?.ips ?? []) {
					if (wanted != null && !wanted[ip])
						continue;
					// При общем IP — самое позднее истечение, затем имя: порядок дампа случаен.
					if (expiry[ip] == null || until > expiry[ip] || (until == expiry[ip] && a.domain < out[ip])) {
						out[ip] = a.domain;
						expiry[ip] = until;
					}
				}
			}
		}
	}
	catch (e) { return {}; }
	if (with_expiry)
		for (let ip, domain in out)
			out[ip] = { domain, until: expiry[ip] };
	return out;
};

// Только активный локальный API из применённого плана. Старый файл после остановки
// mosdns не используем. Лимиты времени и распаковки защищают rpcd и память Роутера.
export function lookup(ips) {
	let applied = U.read_json(C.APPLIED_FILE, null), api = applied?.dns_api;
	if (!length(ips) || type(api) != 'string' || !match(api, /^127\.0\.0\.1:[0-9]+$/))
		return {};
	let pid = trim(U.run('pidof mosdns').out);
	if (!length(pid))
		return {};
	let wanted = {};
	for (let ip in ips)
		wanted[ip] = true;
	let cached = U.read_json(C.DNS_NAMES_FILE, null);
	let now = time(), m = int(U.now_ms()), out = {};
	let valid = cached?.pid == pid && cached?.api == api && cached?.applied == applied.time &&
		type(cached.m) == 'int' && m >= cached.m && m - cached.m < 30000;
	if (valid) {
		let covered = true;
		for (let ip in ips) {
			covered &&= !!cached.wanted?.[ip];
			let entry = cached.names?.[ip];
			if (entry?.until > now)
				out[ip] = entry.domain;
		}
		if (covered)
			return out;
	}
	let f = popen('set -o pipefail; curl -fsS --noproxy ' + U.shq('*') + ' --connect-timeout 1 --max-time 2 ' +
		U.shq('http://' + api + '/plugins/cache/dump') + ' 2>/dev/null | gzip -dc 2>/dev/null | head -c ' + (MAX_DUMP + 1), 'r');
	if (!f)
		return {};
	let data = '', chunk;
	while (length(data) <= MAX_DUMP && length(chunk = f.read(65536) ?? ''))
		data += chunk;
	let rc = f.close();
	if (rc != 0)
		return {};
	let fresh = parse(data, time(), wanted, true);
	out = {};
	for (let ip, entry in fresh)
		out[ip] = entry.domain;
	U.write_json(C.DNS_NAMES_FILE, { m, pid, api, applied: applied.time, wanted, names: fresh });
	return out;
};
