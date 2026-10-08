// rpcd: ubus-объект `truba` для интерфейса LuCI. Логика — в /usr/sbin/truba.
'use strict';

import { popen } from 'fs';

function shq(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function truba(args) {
	let p = popen('/usr/sbin/truba ' + args + ' 2>/dev/null', 'r');
	if (!p)
		return { error: 'exec' };
	let out = p.read('all');
	p.close();
	try {
		return json(out);
	}
	catch (e) {
		return { error: 'parse', output: out };
	}
}

const methods = {
	status: {
		call: function() {
			return truba('status');
		}
	},

	lists: {
		call: function() {
			return truba('lists');
		}
	},

	categories: {
		call: function() {
			return truba('categories');
		}
	},

	sets: {
		call: function() {
			return truba('sets');
		}
	},

	check: {
		args: { target: 'target', mac: 'mac' },
		call: function(req) {
			let t = req.args?.target;
			if (type(t) != 'string' || !match(t, /^[A-Za-z0-9._-]{1,253}$/))
				return { error: 'invalid target' };
			let mac = req.args?.mac;
			let a = shq(t);
			if (type(mac) == 'string' && match(mac, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/))
				a += ' ' + shq(mac);
			return truba('check ' + a);
		}
	},

	nat_test: {
		call: function() {
			return truba('nat-test');
		}
	},

	tunnel_test: {
		call: function() {
			return truba('tunnel-test');
		}
	},

	update_lists: {
		args: { force: false },
		call: function(req) {
			system('( /usr/sbin/truba update-lists' + (req.args?.force ? ' -f' : '') + ' >/dev/null 2>&1 & )');
			return { started: true };
		}
	},

	rollback_lists: {
		call: function() {
			return truba('rollback-lists');
		}
	},

	log: {
		args: { lines: 200 },
		call: function(req) {
			let n = int(req.args?.lines ?? 200);
			if (n < 10 || n > 2000)
				n = 200;
			// Труба и mosdns (ошибки DNS-серверов). «invalid msg» — повреждённые запросы
			// устройств, которые dnsmasq пересылает как есть: это шум, а не ошибка Трубы.
			let p = popen(sprintf("logread -e 'truba\\|mosdns' | grep -v 'invalid msg' | tail -n %d", n), 'r');
			let out = p ? p.read('all') : '';
			p?.close();
			return { log: out };
		}
	},
};

return { truba: methods };
