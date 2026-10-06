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

// Время ответа на ping через Туннель, мс; null — ответа нет.
export function ping_rtt(dev, target) {
	let r = U.run(sprintf('ping -c 1 -W 2 -w 3 -I %s %s', U.shq(dev), U.shq(target)));
	let m = (r.code == 0) ? match(r.out, /time=([0-9.]+) ?ms/) : null;
	return m ? +m[1] : null;
};

// Окно последних проверок для «Обзора»: задержка и потери за ~10 минут при интервале 30 с.
const PROBE_WINDOW = 20;

export function run() {
	let cfg = F.load();
	if (!cfg.watchdog.enabled)
		return;

	let state = U.read_json(C.HEALTH_FILE, null)?.state ?? 'healthy';
	let since = time(), fails = 0;
	let probes = [];   // задержки последних проверок, мс; null — потеря
	let timer;

	let probed = (rtt) => {
		push(probes, rtt);
		if (length(probes) > PROBE_WINDOW)
			shift(probes);
	};

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
		let rec = { state, since, fails, last_check: time(), interval: w.interval, handshake_age: null, ping: null, rtt: null };

		if (tinfo.disabled) {
			fails = 0;
			probes = [];
			set_state('down', 'интерфейс выключен');
		}
		else if (!st.up) {
			fails++;
			probed(null);
			if (fails >= w.fails)
				set_state('down', 'интерфейс не поднят');
		}
		else {
			let probe = length(w.probe) ? w.probe : tinfo.peer;
			let ping_ok = true;
			if (probe) {
				rec.rtt = ping_rtt(st.device, probe);
				ping_ok = rec.rtt != null;
				probed(rec.rtt);
			}
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
		rec.probes = probes;
		U.mkdirp(C.RUN_DIR);
		U.write_json(C.HEALTH_FILE, rec);
		timer.set(w.interval * 1000);
	};

	uloop.init();
	timer = uloop.timer(1000, tick);
	uloop.run();
};
