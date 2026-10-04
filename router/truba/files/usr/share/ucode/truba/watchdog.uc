// Контроль Туннеля: handshake + ping до Трубы внутри Туннеля, перезапуск, Аварийная блокировка.
'use strict';

import * as uloop from 'uloop';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as F from 'truba.conf';
import * as N from 'truba.net';
import * as K from 'truba.core';

function handshake_age(dev) {
	let r = U.run('awg show ' + U.shq(dev) + ' latest-handshakes');
	if (r.code != 0)
		return null;
	let latest = 0;
	for (let line in split(trim(r.out), '\n')) {
		let f = split(line, '\t');
		let ts = int(f[1] ?? 0);
		if (ts > latest)
			latest = ts;
	}
	return latest ? (time() - latest) : null;
}

export function run() {
	let cfg = F.load();
	if (!cfg.watchdog.enabled)
		return;

	let state = U.read_json(C.HEALTH_FILE, null)?.state ?? 'healthy';
	let since = time(), fails = 0;
	let timer;

	let set_state = (next, info) => {
		if (next == state)
			return;
		state = next;
		since = time();
		// routes() читает состояние из файла — записать до пересчёта таблицы.
		U.mkdirp(C.RUN_DIR);
		U.write_json(C.HEALTH_FILE, { state, since, fails, last_check: time() });
		let c = F.load();
		let table = K.routes(c, F.tunnel_info(c.iface));
		U.log(next == 'healthy' ? 'notice' : 'warning',
			sprintf('Туннель %s (%s); таблица Туннеля: %s',
				next == 'healthy' ? 'восстановлен' : 'не отвечает', info, table));
		system([ 'ubus', 'send', 'truba.tunnel', sprintf('%J', { state: next, info, table }) ]);
	};

	let tick = () => {
		cfg = F.load();
		let w = cfg.watchdog;
		let tinfo = F.tunnel_info(cfg.iface);
		let st = N.iface_up(cfg.iface);
		let rec = { state, since, fails, last_check: time(), handshake_age: null, ping: null };

		if (tinfo.disabled) {
			fails = 0;
			set_state('down', 'интерфейс выключен');
		}
		else if (!st.up) {
			fails++;
			if (fails >= w.fails)
				set_state('down', 'интерфейс не поднят');
		}
		else {
			let probe = length(w.probe) ? w.probe : tinfo.peer;
			let ping_ok = probe
				? system([ 'ping', '-c', '1', '-W', '2', '-I', st.device, probe ], 5000) == 0
				: true;
			let age = handshake_age(st.device);
			rec.ping = ping_ok;
			rec.handshake_age = age;

			if (ping_ok && age != null && age <= w.handshake_max) {
				fails = 0;
				set_state('healthy', sprintf('handshake %d с назад', age));
			}
			else {
				fails++;
				let why = !ping_ok ? 'нет ответа на ping ' + probe : sprintf('handshake %s', age == null ? 'не было' : age + ' с назад');
				if (fails >= w.fails) {
					set_state('down', why);
					if (fails % w.fails == 0) {
						U.warn_log('перезапуск интерфейса ' + cfg.iface + ': ' + why);
						system([ 'ifup', cfg.iface ]);
					}
				}
			}
		}

		rec.state = state;
		rec.since = since;
		rec.fails = fails;
		U.mkdirp(C.RUN_DIR);
		U.write_json(C.HEALTH_FILE, rec);
		timer.set(w.interval * 1000);
	};

	uloop.init();
	timer = uloop.timer(1000, tick);
	uloop.run();
};
