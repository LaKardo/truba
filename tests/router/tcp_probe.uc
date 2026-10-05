// TCP-проба для проверки входящих через Туннель (integration.sh).
//   server PORT        — отвечать «truba-ok» каждому клиенту;
//   client SRC HOST PORT — подключиться с адреса SRC и прочитать ответ (код 0 — ответ пришёл).
//   SRC нужен, чтобы клиент выглядел пришедшим из интернета, а не из подсети Туннеля.
'use strict';

import * as socket from 'socket';

const STREAM = { socktype: socket.SOCK_STREAM };

if (ARGV[0] == 'server') {
	const srv = socket.listen('0.0.0.0', ARGV[1], STREAM, 8, true);
	if (!srv)
		die('listen: ' + socket.error());
	while (true) {
		const c = srv.accept();
		if (c) {
			c.send('truba-ok\n');
			c.close();
		}
	}
}
else if (ARGV[0] == 'client') {
	// Тайм-аут соединения задаёт net.ipv4.tcp_syn_retries в netns клиента.
	const s = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	if (!s || !s.bind({ address: ARGV[1], port: 0 }) || !s.connect({ address: ARGV[2], port: +ARGV[3] })) {
		print('нет соединения: ', socket.error(), '\n');
		exit(1);
	}
	const pr = socket.poll(4000, [ s, socket.POLLIN ]);
	const line = (length(pr ?? []) && (pr[0][1] & socket.POLLIN)) ? s.recv(64) : null;
	s.close();
	print(line ?? 'нет ответа\n');
	exit(line == 'truba-ok\n' ? 0 : 1);
}
else {
	die('usage: tcp_probe.uc server PORT | client SRC HOST PORT');
}
