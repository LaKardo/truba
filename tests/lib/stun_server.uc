// STUN-сервер для проверки «truba nat-test» (tests/router): на Binding Request отвечает
// XOR-MAPPED-ADDRESS с адресом MAPPED и портом источника — как Труба, которая выпускает
// Роутер от своего IP, сохраняя порт.
//   stun_server.uc ADDR PORT MAPPED
'use strict';

import * as socket from 'socket';

const s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
if (!s || !s.bind({ address: ARGV[0], port: +ARGV[1] }))
	die('bind: ' + socket.error());
const ip = map(split(ARGV[2], '.'), (x) => +x);

while (true) {
	const from = {};
	const req = s.recv(512, 0, from);
	if (req == null || length(req) < 20 || ord(req, 0) != 0 || ord(req, 1) != 1)
		continue;
	const port = from.port ^ 0x2112;
	const attr = chr(0x00, 0x20, 0x00, 0x08, 0x00, 0x01, port >> 8, port & 255,
		ip[0] ^ 0x21, ip[1] ^ 0x12, ip[2] ^ 0xa4, ip[3] ^ 0x42);
	// Заголовок ответа: тип 0x0101, длина атрибутов, magic cookie и transaction ID запроса.
	s.send(chr(0x01, 0x01, 0x00, length(attr)) + substr(req, 4, 16) + attr, 0, from);
}
