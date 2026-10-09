// Общие функции ucode-проверок: check, same, итог части, синтетические Наборы правил.
//   ucode -L '/repo/tests/lib/*.uc' …  →  import * as T from 'tlib';
'use strict';

let fails = 0;

export function check(name, cond, detail) {
	if (cond) {
		print('ok    ', name, '\n');
		return true;
	}
	print('FAIL  ', name, detail ? (' — ' + detail) : '', '\n');
	fails++;
	return false;
};

export function same(a, b) {
	return sprintf('%J', a) == sprintf('%J', b);
};

export function finish() {
	print('\n', fails ? sprintf('%d FAILED', fails) : 'ALL OK', '\n');
	exit(fails ? 1 : 0);
};

// ---- protobuf v2ray: GeoSiteList / GeoIPList ----

function varint(n) {
	let s = '';
	while (n >= 0x80) {
		s += chr((n & 0x7f) | 0x80);
		n >>= 7;
	}
	return s + chr(n);
}

// Поле с длиной (wiretype 2) и целое (wiretype 0).
function bytes(num, s) { return varint((num << 3) | 2) + varint(length(s)) + s; }
function uint(num, v) { return varint(num << 3) + varint(v); }

// Domain.Type: Plain=0 (keyword), Regex=1, RootDomain=2 (domain), Full=3.
const DOMAIN_TYPE = { keyword: 0, regexp: 1, domain: 2, full: 3 };

// Категория geosite одной записью GeoSiteList: entries — «domain:x», «full:x», «regexp:x», «keyword:x».
export function geosite_cat(tag, entries) {
	let body = bytes(1, uc(tag));
	for (let e in entries) {
		let i = index(e, ':');
		body += bytes(2, uint(1, DOMAIN_TYPE[substr(e, 0, i)]) + bytes(2, substr(e, i + 1)));
	}
	return bytes(1, body);
};

// Категория geoip одной записью GeoIPList: cidrs — IPv4 «a.b.c.d/n».
export function geoip_cat(tag, cidrs) {
	let body = bytes(1, uc(tag));
	for (let c in cidrs) {
		let m = match(c, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\/([0-9]+)$/);
		body += bytes(2, bytes(1, chr(+m[1], +m[2], +m[3], +m[4])) + uint(2, +m[5]));
	}
	return bytes(1, body);
};
