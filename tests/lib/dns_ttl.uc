// Запрос A к DNS-серверу на 127.0.0.1: печатает «IP TTL» на каждую A-запись ответа (tests/router).
//   ucode dns_ttl.uc PORT NAME
'use strict';

import * as socket from 'socket';

const port = +ARGV[0], name = ARGV[1];
let q = chr(0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0);
for (let l in split(name, '.'))
	q += chr(length(l)) + l;
q += chr(0, 0, 1, 0, 1);

const s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
s.connect({ address: '127.0.0.1', port });
s.send(q);
const pr = socket.poll(3000, [ s, socket.POLLIN ]);
if (!length(pr) || !pr[0][1])
	exit(1);
const r = s.recv(1500);

function u16(o) { return (ord(r, o) << 8) | ord(r, o + 1); }
function u32(o) { return (u16(o) << 16) | u16(o + 2); }
// Имя: метки или ссылка (2 байта) — пропустить.
function skip(o) {
	while (true) {
		let l = ord(r, o);
		if (l == 0)
			return o + 1;
		if ((l & 0xc0) == 0xc0)
			return o + 2;
		o += l + 1;
	}
}

let o = skip(12) + 4;
for (let i = 0; i < u16(6); i++) {
	o = skip(o);
	let type = u16(o), ttl = u32(o + 4), len = u16(o + 8);
	if (type == 1)
		printf('%d.%d.%d.%d %d\n', ord(r, o + 10), ord(r, o + 11), ord(r, o + 12), ord(r, o + 13), ttl);
	o += 10 + len;
}
