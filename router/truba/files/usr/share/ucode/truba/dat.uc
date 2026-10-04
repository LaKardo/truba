// Распаковщик Наборов правил (geoip.dat / geosite.dat, protobuf v2ray).
// Меняет только формат: каждая запись попадает в текстовый файл ровно такой,
// какая она в файле. Атрибуты (@cn, @ads) не используются.
'use strict';

import { readfile, writefile, stat, lsdir, unlink } from 'fs';
import * as C from 'truba.const';
import * as U from 'truba.util';

// Domain.Type в v2ray: Plain=0 (keyword), Regex=1, RootDomain=2 (domain), Full=3.
const DOMAIN_TYPES = [ 'keyword', 'regexp', 'domain', 'full' ];

// Обход полей сообщения protobuf в s[start, end).
// cb(field, wiretype, a, b): для wiretype 0 a = значение; для 2 a = начало, b = длина.
function fields(s, start, end, cb) {
	let p = start, c, shift;
	while (p < end) {
		let key = 0;
		shift = 0;
		while (true) {
			c = ord(s, p++);
			key |= (c & 0x7f) << shift;
			shift += 7;
			if (c < 0x80)
				break;
		}

		let f = key >> 3, wt = key & 7;

		if (wt == 0) {
			let v = 0;
			shift = 0;
			while (true) {
				c = ord(s, p++);
				v |= (c & 0x7f) << shift;
				shift += 7;
				if (c < 0x80)
					break;
			}
			cb(f, 0, v);
		}
		else if (wt == 2) {
			let n = 0;
			shift = 0;
			while (true) {
				c = ord(s, p++);
				n |= (c & 0x7f) << shift;
				shift += 7;
				if (c < 0x80)
					break;
			}
			cb(f, 2, p, n);
			p += n;
		}
		else if (wt == 1) {
			p += 8;
		}
		else if (wt == 5) {
			p += 4;
		}
		else {
			die(sprintf('protobuf: неизвестный wiretype %d на смещении %d', wt, p));
		}
	}
	if (p != end)
		die('protobuf: сообщение обрезано');
}

export function parse_geosite(path) {
	let s = readfile(path);
	if (s == null)
		die('не удалось прочитать ' + path);

	let cats = [];
	fields(s, 0, length(s), (f, wt, a, b) => {
		if (f != 1 || wt != 2)
			return;

		let cat = { set: 'geosite', tag: null, entries: [],
		            types: { domain: 0, full: 0, regexp: 0, keyword: 0 } };

		fields(s, a, a + b, (f2, wt2, a2, b2) => {
			if (f2 == 1 && wt2 == 2) {
				cat.tag = lc(substr(s, a2, b2));
			}
			else if (f2 == 2 && wt2 == 2) {
				let dtype = 0, value = null;
				fields(s, a2, a2 + b2, (f3, wt3, a3, b3) => {
					if (f3 == 1 && wt3 == 0)
						dtype = a3;
					else if (f3 == 2 && wt3 == 2)
						value = substr(s, a3, b3);
				});
				let t = DOMAIN_TYPES[dtype];
				if (t == null || value == null)
					die(sprintf('geosite: неизвестная запись (тип %d) в категории %s', dtype, cat.tag));
				push(cat.entries, t + ':' + value);
				cat.types[t]++;
			}
		});

		if (cat.tag == null)
			die('geosite: категория без тега');
		cat.count = length(cat.entries);
		push(cats, cat);
	});
	return cats;
};

export function parse_geoip(path) {
	let s = readfile(path);
	if (s == null)
		die('не удалось прочитать ' + path);

	let cats = [];
	fields(s, 0, length(s), (f, wt, a, b) => {
		if (f != 1 || wt != 2)
			return;

		let cat = { set: 'geoip', tag: null, v4: [], count6: 0, reverse: false };

		fields(s, a, a + b, (f2, wt2, a2, b2) => {
			if (f2 == 1 && wt2 == 2) {
				cat.tag = lc(substr(s, a2, b2));
			}
			else if (f2 == 2 && wt2 == 2) {
				let ip = null, prefix = null;
				fields(s, a2, a2 + b2, (f3, wt3, a3, b3) => {
					if (f3 == 1 && wt3 == 2)
						ip = substr(s, a3, b3);
					else if (f3 == 2 && wt3 == 0)
						prefix = a3;
				});
				if (ip == null || prefix == null)
					die('geoip: повреждённая запись CIDR');
				if (length(ip) == 4) {
					push(cat.v4, sprintf('%d.%d.%d.%d/%d',
						ord(ip, 0), ord(ip, 1), ord(ip, 2), ord(ip, 3), prefix));
				}
				else {
					// IPv6-записи пропускаются: Маршрутизация только IPv4 (ADR 0005).
					cat.count6++;
				}
			}
			else if (f2 == 3 && wt2 == 0) {
				cat.reverse = (a2 != 0);
			}
		});

		if (cat.tag == null)
			die('geoip: категория без тега');
		cat.count4 = length(cat.v4);
		cat.count = cat.count4 + cat.count6;
		push(cats, cat);
	});
	return cats;
};

// Имя файла из тега: только безопасные символы.
export function fname(tag) {
	return replace(tag, /[^a-z0-9._!@-]/g, '_');
};

// Вложенность Категорий geosite: A ⊂ B, если каждая запись A есть в B.
function compute_subsets(cats) {
	let lookup = {};
	let setof = (c) => {
		if (!lookup[c.tag]) {
			let o = {};
			for (let e in c.entries)
				o[e] = true;
			lookup[c.tag] = o;
		}
		return lookup[c.tag];
	};

	for (let a in cats) {
		a.subset_of = [];
		if (a.count == 0)
			continue;
		for (let b in cats) {
			if (a === b || b.count < a.count)
				continue;
			let sb = setof(b);
			if (!sb[a.entries[0]])
				continue;
			let all = true;
			for (let e in a.entries) {
				if (!sb[e]) {
					all = false;
					break;
				}
			}
			if (all)
				push(a.subset_of, b.tag);
		}
	}
}

function clear_dir(dir) {
	U.mkdirp(dir);
	for (let f in (lsdir(dir) ?? []))
		unlink(dir + '/' + f);
}

// Распаковать оба файла в DATA_DIR. Возвращает перечень Категорий.
export function unpack(geoip_path, geosite_path) {
	let out = [];

	if (geosite_path && stat(geosite_path)) {
		let gs = parse_geosite(geosite_path);
		compute_subsets(gs);
		clear_dir(C.DATA_DIR + '/geosite');
		for (let c in gs) {
			writefile(C.DATA_DIR + '/geosite/' + fname(c.tag) + '.txt', join('\n', c.entries) + '\n');
			push(out, { set: 'geosite', tag: c.tag, count: c.count, types: c.types, subset_of: c.subset_of });
		}
	}

	if (geoip_path && stat(geoip_path)) {
		let gi = parse_geoip(geoip_path);
		clear_dir(C.DATA_DIR + '/geoip');
		for (let c in gi) {
			writefile(C.DATA_DIR + '/geoip/' + fname(c.tag) + '.v4', join('\n', c.v4) + '\n');
			push(out, { set: 'geoip', tag: c.tag, count: c.count, count4: c.count4, count6: c.count6,
			            reverse: c.reverse, subset_of: [] });
		}
	}

	return out;
};

export function geoip_cidrs(tag) {
	let s = readfile(C.DATA_DIR + '/geoip/' + fname(tag) + '.v4');
	if (s == null)
		return [];
	return filter(split(s, '\n'), l => l != '');
};

export function geosite_file(tag) {
	return C.DATA_DIR + '/geosite/' + fname(tag) + '.txt';
};

export function geosite_entries(tag) {
	let s = readfile(geosite_file(tag));
	if (s == null)
		return [];
	return filter(split(s, '\n'), l => l != '');
};

// Распаковать, только если изменились хеши исходных файлов.
export function ensure() {
	let gi = C.LISTS_DIR + '/' + C.DAT_FILES.geoip;
	let gs = C.LISTS_DIR + '/' + C.DAT_FILES.geosite;
	if (!stat(gi) && !stat(gs))
		return { cats: [], hash: null };

	let hash = (U.sha256_file(gi) ?? '-') + ':' + (U.sha256_file(gs) ?? '-');
	let prev = U.read_json(C.CATS_FILE, null);
	if (prev && prev.hash == hash && stat(C.DATA_DIR + '/geosite') && stat(C.DATA_DIR + '/geoip'))
		return prev;

	let cats = unpack(gi, gs);
	let res = { hash, cats, unpacked: time() };
	U.mkdirp(C.DATA_DIR);
	U.write_json(C.CATS_FILE, res);
	return res;
};
