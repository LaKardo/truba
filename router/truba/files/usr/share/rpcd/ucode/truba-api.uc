// rpcd: ubus-объект `truba` — API службы для LuCI и скриптов (ubus call truba status).
// Логика — в /usr/sbin/truba; плагин — в пакете truba, чтобы API менялся вместе с ней (ADR 0008).
// Быстрые синхронные методы чтения (status, lists, sets, categories, schema, devices, log)
// вызывают ucode-модули напрямую без fork/exec CLI, экономя 2 процесса на каждый опрос.
'use strict';

import { popen, readfile } from 'fs';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as S from 'truba.state';
import * as F from 'truba.conf';
import * as DV from 'truba.devices';

// rpcd работает с umask 077: без своей маски файлы, которые пишут запущенные им команды (Наборы
// правил, состояние, распакованные списки), получали бы права 600, а из cron и консоли — 644.
const CLI = 'umask 022; ' + C.CLI;

function truba(args) {
	let p = popen(CLI + ' ' + args + ' 2>/dev/null', 'r');
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

// Проверки NAT и Туннеля и обновление Наборов правил идут секунды, а rpcd обслуживает вызовы
// по одному: пока он ждёт, стоит весь LuCI. Поэтому они запускаются в фоне, а итог интерфейс
// забирает отдельным вызовом, когда в нём появится время не раньше started.
function background(args) {
	system('( ' + CLI + ' ' + args + ' >/dev/null 2>&1 & )');
	return { started: time() };
}

// Итог из файла — без запуска процессов; {} — итога ещё нет.
function result(path) {
	try {
		return json(readfile(path) ?? '{}') ?? {};
	}
	catch (e) {
		return {};
	}
}

const methods = {
	status: {
		args: { cached: false, part: '' },
		call: function(req) {
			return S.status(req?.args?.cached == true, req?.args?.part);
		}
	},

	lists: {
		call: function() {
			return S.lists();
		}
	},

	categories: {
		call: function() {
			// Холодный кэш распаковывает CLI со своей маской, а не процесс rpcd.
			return truba('categories');
		}
	},

	// Схема настроек и константы службы (ADR 0015): умолчания, пределы и имена интерфейс берёт отсюда.
	schema: {
		call: function() {
			return F.schema();
		}
	},

	sets: {
		call: function() {
			return S.sets();
		}
	},

	// Устройства: трафик из истории (её пишет процесс truba stats), имена, зоны и Политики.
	devices: {
		args: { lite: false },
		call: function(req) {
			return DV.list(req?.args?.lite == true);
		}
	},

	// Куда устройство ходит сейчас: адреса из conntrack с Действием и причиной.
	connections: {
		args: { ip: 'ip' },
		call: function(req) {
			let ip = req.args?.ip;
			if (!U.is_ipv4(ip))
				return { error: 'invalid ip' };
			return truba('connections ' + U.shq(ip));
		}
	},

	check: {
		args: { target: 'target', mac: 'mac' },
		call: function(req) {
			let t = req.args?.target;
			if (type(t) != 'string' || !match(t, /^[A-Za-z0-9._-]{1,253}$/))
				return { error: 'invalid target' };
			let mac = req.args?.mac;
			let a = U.shq(t);
			if (type(mac) == 'string' && match(mac, /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/))
				a += ' ' + U.shq(mac);
			return truba('check ' + a);
		}
	},

	nat_test: {
		call: function() {
			return background('nat-test');
		}
	},

	nat_result: {
		call: function() {
			return result(C.NAT_FILE);
		}
	},

	tunnel_test: {
		call: function() {
			return background('tunnel-test');
		}
	},

	tunnel_result: {
		call: function() {
			return result(C.TT_FILE);
		}
	},

	// История скорости для графика «Обзора» (её пишет процесс truba stats): точки новее
	// since за последние span секунд; срок больше часа — поминутные средние. now — время
	// Роутера: по нему интерфейс строит ось, часы компьютера могут расходиться с ним.
	rates: {
		args: { span: 600, since: 0 },
		call: function(req) {
			let span = int(req.args?.span ?? 600), since = int(req.args?.since ?? 0);
			let f = result((span > C.HISTORY.fine.span) ? C.RATES_MIN_FILE : C.RATES_FILE);
			let now = time(), from = (since > now - span) ? since : now - span;
			let points = filter((type(f.points) == 'array') ? f.points : [], (p) => type(p) == 'array' && p[0] > from);
			return { now, step: f.step ?? null, points };
		}
	},

	// Итог — lists.last со временем не раньше started.
	update_lists: {
		args: { force: false },
		call: function(req) {
			return background('update-lists' + (req.args?.force ? ' -f' : ''));
		}
	},

	// Файлы переставляются сразу, а применяются в фоне: пока rpcd ждал бы применения
	// (распаковка, загрузка подсетей geoip), стоял бы весь LuCI. Ход — в lists (applying).
	rollback_lists: {
		call: function() {
			return truba('rollback-lists --bg');
		}
	},

	log: {
		args: { lines: 200 },
		call: function(req) {
			let n = int(req.args?.lines ?? 200);
			if (n < 10 || n > 2000)
				n = 200;
			return S.log(n);
		}
	},
};

// Объект truba регистрирует только этот плагин: второй плагин того же объекта роняет rpcd (ADR 0008).
return { truba: methods };
