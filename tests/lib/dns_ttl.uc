// Запрос A к DNS-серверу (по умолчанию 127.0.0.1): печатает «IP TTL» на каждую A-запись ответа (tests/router).
// TYPE — другой тип запроса (номер): записи не-A печатаются как «rr ТИП».
// Нет ответа за 3 с — код 1.
//   ucode dns_ttl.uc PORT NAME [SERVER] [TYPE]
'use strict';

import * as socket from 'socket';

const port = +ARGV[0], name = ARGV[1], server = ARGV[2] ?? '127.0.0.1', qtype = +(ARGV[3] ?? 1);
let q = chr(0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0);
for (let l in split(name, '.'))
	q += chr(length(l)) + l;
q += chr(0, qtype >> 8, qtype & 255, 0, 1);

const s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
s.connect({ address: server, port });
s.send(q);
// Порт закрыт — ядро получает ICMP «порт недоступен»: poll отдаёт POLLERR без POLLIN, recv — null.
const pr = socket.poll(3000, [ s, socket.POLLIN ]);
const r = (length(pr ?? []) && (pr[0][1] & socket.POLLIN)) ? s.recv(1500) : null;
if (r == null)
	exit(1);

function u16(o) { return (ord(r, o) << 8) | ord(r, o + 1); }
function u32(o) { return (u16(o) << 16) | u16(o + 2); }
// Имя: метки или ссылка (2 байта) — пропустить. За концом ответа ord() даёт null, и цикл
// не кончился бы: обрезанный или чужой ответ — тоже код 1.
function skip(o) {
	while (true) {
		let l = ord(r, o);
		if (l == null)
			exit(1);
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
	else
		printf('rr %d\n', type);
	o += 10 + len;
}
