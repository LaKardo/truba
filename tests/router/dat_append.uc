// Дописать в Набор правил ещё одну Категорию. Файл остаётся правильным (в protobuf
// повторяющееся поле можно дописать в конец), но это уже другая версия: другой хеш.
//   ucode dat_append.uc geoip|geosite <файл> <тег>
'use strict';

import { readfile, writefile } from 'fs';

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

const set = ARGV[0], path = ARGV[1], tag = ARGV[2];
let cat;
if (set == 'geoip')
	// GeoIP { country_code = 1; CIDR cidr = 2 { ip = 1; prefix = 2 } }: 198.18.0.0/24
	cat = bytes(1, tag) + bytes(2, bytes(1, chr(198, 18, 0, 0)) + uint(2, 24));
else
	// GeoSite { country_code = 1; Domain domain = 2 { type = 1 (2 — domain); value = 2 } }
	cat = bytes(1, tag) + bytes(2, uint(1, 2) + bytes(2, tag + '.example'));

writefile(path, readfile(path) + bytes(1, cat));
