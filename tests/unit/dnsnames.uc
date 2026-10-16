// Синтетический mosdns_cache_v2: protobuf, DNS со сжатием и CNAME.
'use strict';
import * as DN from 'truba.dnsnames';
import * as T from 'tlib';

function bytes(a) { return join('', map(a, n => sprintf('%c', n))); }
function vi(n) {
	let a = [];
	while (n >= 128) {
		push(a, (n % 128) + 128);
		n = int(n / 128);
	}
	push(a, n);
	return bytes(a);
}
function field(f, s) { return vi(f * 8 + 2) + vi(length(s)) + s; }
function label(s) { return join('', map(split(s, '.'), l => bytes([ length(l) ]) + l)) + bytes([ 0 ]); }
function entry(domain, until, cname) {
	let q = label(domain), target = label('cdn.example.org');
	let msg = bytes([ 0, 0, 129, 128, 0, 1, 0, cname ? 2 : 1, 0, 0, 0, 0 ]) + q + bytes([ 0, 1, 0, 1 ]);
	if (cname)
		msg += bytes([ 192, 12, 0, 5, 0, 1, 0, 0, 1, 44, 0, length(target) ]) + target;
	msg += (cname ? target : bytes([ 192, 12 ])) + bytes([ 0, 1, 0, 1, 0, 0, 1, 44, 0, 4, 198, 51, 100, 7 ]);
	return field(1, field(2, msg) + vi(32) + vi(until));
}
function block(s) {
	let n = length(s);
	return bytes([ 0, 0, 0, 0, 0, 0, int(n / 256), n % 256 ]) + s;
}
let dump = block(entry('www.example.com', 2000, true));
T.check('DNS-имена: CNAME и A с указателем → исходный домен', DN.parse(dump, 1000)['198.51.100.7'] == 'www.example.com');
T.check('DNS-имена: истёкший ответ не берётся из lazy-кэша', !length(keys(DN.parse(dump, 2000))));
T.check('DNS-имена: только нужные IP', !length(keys(DN.parse(dump, 1000, { '192.0.2.1': true }))));
let shared = entry('z.example.com', 3000, false) + entry('a.example.com', 3000, false);
T.check('DNS-имена: общий IP — стабильный выбор независимо от порядка',
	DN.parse(block(shared), 1000)['198.51.100.7'] == 'a.example.com' &&
	DN.parse(block(entry('a.example.com', 3000, false) + entry('z.example.com', 3000, false)), 1000)['198.51.100.7'] == 'a.example.com');
T.check('DNS-имена: несколько блоков, более свежий ответ важнее',
	DN.parse(dump + block(entry('new.example.com', 3000, false)), 1000)['198.51.100.7'] == 'new.example.com');
T.check('DNS-имена: обрыв, мусор и превышение лимита безопасны',
	!length(keys(DN.parse(substr(dump, 0, length(dump) - 1), 1000))) &&
	!length(keys(DN.parse('invalid', 1000))) && !length(keys(DN.parse(bytes([ 255, 255, 255, 255, 255, 255, 255, 255 ]), 1000))));
let loop = bytes([ 0, 0, 129, 128, 0, 1, 0, 0, 0, 0, 0, 0, 192, 12, 0, 1, 0, 1 ]);
T.check('DNS-имена: цикл указателей DNS не зависает',
	!length(keys(DN.parse(block(field(1, field(2, loop) + vi(32) + vi(3000))), 1000))));
T.check('DNS-имена: обрыв varint не зависает', !length(keys(DN.parse(block(bytes([ 128 ])), 1000))));
T.finish();
