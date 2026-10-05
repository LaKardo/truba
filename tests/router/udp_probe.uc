// UDP-проба для проверки исходящих Роутера через Туннель (integration.sh).
//   server ADDR PORT TAG     — отвечать TAG на каждую датаграмму. Ответ уходит с ADDR:
//                              с 0.0.0.0 ядро берёт адрес по маршруту, и ответ из netns vps
//                              пришёл бы не с того адреса, что в conntrack Роутера;
//   client HOST PORT [MARK]  — отправить датаграмму (с SO_MARK, если задан)
//                              и напечатать ответ (код 0 — ответ пришёл).
//   TAG показывает, кто ответил: узел за Туннелем или перехватчик на самом Роутере.
'use strict';

import * as socket from 'socket';

if (ARGV[0] == 'server') {
	const s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (!s || !s.bind({ address: ARGV[1], port: +ARGV[2] }))
		die('bind: ' + socket.error());
	while (true) {
		const from = {};
		if (s.recv(512, 0, from) != null)
			s.send(ARGV[3], 0, from);
	}
}
else if (ARGV[0] == 'client') {
	const s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (ARGV[3])
		s.setopt(socket.SOL_SOCKET, socket.SO_MARK, +ARGV[3]);
	if (!s.send('truba', 0, { address: ARGV[1], port: +ARGV[2] })) {
		print('не отправилось: ', socket.error(), '\n');
		exit(1);
	}
	const pr = socket.poll(3000, [ s, socket.POLLIN ]);
	const r = (length(pr ?? []) && (pr[0][1] & socket.POLLIN)) ? s.recv(512) : null;
	s.close();
	print(r ?? 'нет ответа', '\n');
	exit(r != null ? 0 : 1);
}
else {
	die('usage: udp_probe.uc server ADDR PORT TAG | client HOST PORT [MARK]');
}
