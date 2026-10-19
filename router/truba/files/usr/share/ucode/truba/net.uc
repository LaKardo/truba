// Правила маршрутизации, таблица Туннеля, межсетевой экран зон, cron, UPnP. DNS — в truba.dns.
'use strict';

import { cursor } from 'uci';
import { readfile, stat, unlink } from 'fs';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as F from 'truba.conf';

const T = '' + C.RT_TABLE;

// ub — уже открытое соединение ubus (необязательно).
export function iface_up(iface, ub) {
	let st = U.ubus_call(ub, 'network.interface.' + iface, 'status');
	return { up: !!st?.up, device: st?.l3_device ?? st?.device ?? iface };
};

// Сколько копий правила с одним приоритетом убирать за раз: ip rule add не проверяет повторы, и после
// сбоя между удалением и добавлением правило могло задвоиться. Предел — чтобы цикл не шёл вечно.
const RULE_DUPS_MAX = 8;

function del_rule_prio(prio) {
	for (let i = 0; i < RULE_DUPS_MAX; i++)
		if (system(sprintf('ip -4 rule del priority %d 2>/dev/null', prio)) != 0)
			break;
}

function rule_present(lines, prio, text) {
	let found = [];
	for (let line in lines) {
		let normalized = replace(trim(line), /[[:space:]]+/g, ' ');
		if (index(normalized, prio + ':') == 0)
			push(found, normalized);
	}
	return length(found) == 1 && found[0] == prio + ': from all ' + text;
}

export function ensure_rules(dev) {
	let r = U.run('ip -4 rule show');
	let lines = r.code == 0 ? split(r.out, '\n') : [];
	let mark = 'fwmark ' + sprintf('0x%x/0x%x', C.MARK_TUNNEL, C.MARK_MASK) + ' lookup ' + T;
	let oif = 'oif ' + dev + ' lookup ' + T;
	if (!rule_present(lines, C.PRIO_RULE_MARK, mark)) {
		del_rule_prio(C.PRIO_RULE_MARK);
		system([ 'ip', '-4', 'rule', 'add', ...split(mark, ' '), 'priority', '' + C.PRIO_RULE_MARK ]);
	}
	if (!rule_present(lines, C.PRIO_RULE_OIF, oif)) {
		del_rule_prio(C.PRIO_RULE_OIF);
		system([ 'ip', '-4', 'rule', 'add', ...split(oif, ' '), 'priority', '' + C.PRIO_RULE_OIF ]);
	}
};

export function remove_rules() {
	del_rule_prio(C.PRIO_RULE_MARK);
	del_rule_prio(C.PRIO_RULE_OIF);
	system([ 'ip', '-4', 'route', 'flush', 'table', T ]);
};

// state: 'healthy' | 'down'. Таблица 77:
//   healthy                 → default dev <туннель>
//   down + Аварийная блок.  → blackhole default
//   down без неё            → без default: трафик проваливается в main (Напрямую)
// Подсеть Туннеля держится в таблице всегда, пока интерфейс поднят: по ней ходит проверка Туннеля.
function set_table(state, tinfo, killswitch) {
	let dev = tinfo.device;

	if (tinfo.up && tinfo.subnet)
		system([ 'ip', '-4', 'route', 'replace', tinfo.subnet, 'dev', dev, 'table', T ]);

	if (tinfo.up && state == 'healthy') {
		system([ 'ip', '-4', 'route', 'replace', 'default', 'dev', dev, 'table', T ]);
		return 'healthy';
	}
	if (killswitch) {
		system([ 'ip', '-4', 'route', 'replace', 'blackhole', 'default', 'table', T ]);
		return 'blocked';
	}
	system('ip -4 route del default table ' + T + ' 2>/dev/null');
	return 'fallback';
}

// Таблица 77 по здоровью Туннеля: его состояние watchdog пишет в HEALTH_FILE.
export function routes(cfg, tinfo) {
	cfg ??= F.load();
	tinfo ??= F.tunnel_info(cfg.iface);
	let h = U.read_json(C.HEALTH_FILE, null);
	let state;
	if (tinfo.disabled || !tinfo.up)
		state = 'down';
	else if (cfg.watchdog.enabled && h?.state == 'down')
		state = 'down';
	else
		state = 'healthy';
	// Аварийная блокировка имеет смысл только при включённой Маршрутизации.
	return set_table(state, tinfo, cfg.routing && cfg.killswitch);
};

export function set_rp_filter(dev) {
	system([ 'sysctl', '-qw', 'net.ipv4.conf.' + replace(dev, '.', '/') + '.rp_filter=0' ]);
};

// Всё, что зависит от интерфейса Туннеля: правила ip (oif — по его устройству), rp_filter 0 на поднятом
// устройстве (обратный маршрут к источнику входящих — не через Туннель) и таблица 77. Итог — как у routes.
export function sync(cfg, tinfo) {
	cfg ??= F.load();
	tinfo ??= F.tunnel_info(cfg.iface);
	ensure_rules(tinfo.device);
	if (tinfo.up)
		set_rp_filter(tinfo.device);
	return routes(cfg, tinfo);
};

// ---- Межсетевой экран зон Маршрутизации: перенаправления в зону Туннеля, IPv6-интернет ----

// Своя секция зоны: имя зоны (имя секции UCI — только буквы, цифры и «_») и окончание из truba.const.
function own_name(zone, suffix) {
	return replace(zone, /[^A-Za-z0-9_]/g, '_') + suffix;
}

// Без перенаправления зоны в truba fw4 отбрасывает трафик её устройств, которому Труба выбрала Туннель
// (ADR 0014). У каждой выбранной зоны оно должно быть: нет никакого — Труба заводит своё, секцию
// <зона>_truba. Перенаправления владельца (любое другое имя) засчитываются и не трогаются, а свои
// секции зон, которые больше не выбраны или удалены, убираются.
function forwardings_sync(c, zones) {
	let changed = false, drop = [], have = {};
	c.foreach('firewall', 'forwarding', (f) => {
		if (f.dest != C.FW_ZONE || !f.src)
			return;
		if (f['.name'] == own_name(f.src, C.FW_FWD_SUFFIX) && !(f.src in zones))
			push(drop, f['.name']);
		else
			have[f.src] = true;
	});
	for (let sid in drop) {
		c.delete('firewall', sid);
		changed = true;
	}
	for (let z in zones) {
		if (have[z])
			continue;
		let sid = own_name(z, C.FW_FWD_SUFFIX);
		// Имя занято чужой секцией — её не трогаем.
		if (c.get('firewall', sid) != null) {
			U.err(sprintf('межсетевой экран: секция %s уже есть — перенаправление %s → %s не заведено', sid, z, C.FW_ZONE));
			continue;
		}
		c.set('firewall', sid, 'forwarding');
		c.set('firewall', sid, 'src', z);
		c.set('firewall', sid, 'dest', C.FW_ZONE);
		changed = true;
	}
	return changed;
}

// Локальные IPv6-адреса — ULA, link-local и multicast: между зонами сети IPv6 остаётся (ADR 0005).
const IPV6_LOCAL = [ 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

// Правило зоны: IPv6 в любую зону, кроме локальных адресов, — REJECT, а не DROP: Happy Eyeballs
// сразу уходит на IPv4. Интернет — по адресу, а не по зоне: имя и число зон WAN неважны (ADR 0016).
// «enabled» здесь нет: выключить правило зоны может владелец.
function no6_rule(zone) {
	return {
		name: 'Truba: no IPv6 internet from ' + zone,
		src: zone,
		dest: '*',
		family: 'ipv6',
		proto: 'all',
		dest_ip: map(IPV6_LOCAL, (p) => '!' + p),
		target: 'REJECT',
	};
}

// Маршрутизация только IPv4: IPv6-интернет выбранной зоны шёл бы мимо Туннеля. У каждой выбранной
// зоны — своё правило, секция <зона>_truba_no_ipv6: изменённое применение возвращает, удалённое
// заводит снова. Свои правила зон, которые больше не выбраны или удалены, убираются.
function no6_sync(c, zones) {
	let changed = false, drop = [];
	c.foreach('firewall', 'rule', (r) => {
		if (r.src && r['.name'] == own_name(r.src, C.FW_NO6_SUFFIX) && !(r.src in zones))
			push(drop, r['.name']);
	});
	for (let sid in drop) {
		c.delete('firewall', sid);
		changed = true;
	}
	for (let z in zones) {
		let sid = own_name(z, C.FW_NO6_SUFFIX), t = c.get('firewall', sid);
		// Имя занято чужой секцией — её не трогаем.
		if (t != null && (t != 'rule' || c.get('firewall', sid, 'src') != z)) {
			U.err(sprintf('межсетевой экран: секция %s уже есть — IPv6-интернет зоны %s не закрыт', sid, z));
			continue;
		}
		if (t == null) {
			c.set('firewall', sid, 'rule');
			changed = true;
		}
		for (let k, v in no6_rule(z))
			if (sprintf('%J', c.get('firewall', sid, k)) != sprintf('%J', v)) {
				c.set('firewall', sid, k, v);
				changed = true;
			}
	}
	return changed;
}

// Межсетевой экран выбранных зон: перенаправления в truba и правила IPv6 — при каждом применении,
// и при выключенной Маршрутизации тоже. Зоны, которой нет, и самой truba это не касается; без зоны
// truba перенаправлений нет, правила IPv6 есть. Межсетевой экран перезагружается, только если что-то изменилось.
export function zones_firewall(zones) {
	let c = cursor();
	c.load('firewall');
	let exist = {};
	c.foreach('firewall', 'zone', (z) => {
		if (z.name)
			exist[z.name] = true;
	});
	let sel = [];
	for (let z in zones)
		if (exist[z] && z != C.FW_ZONE && !(z in sel))
			push(sel, z);

	let changed = forwardings_sync(c, exist[C.FW_ZONE] ? sel : []);
	if (no6_sync(c, sel))
		changed = true;
	if (!changed)
		return false;
	c.commit('firewall');
	system('/etc/init.d/firewall reload >/dev/null 2>&1');
	return true;
};

// ---- cron: блок между маркерами ----

const CRONTAB_DIR = '/etc/crontabs', CRONTAB = CRONTAB_DIR + '/root';

// Ближайший запуск обновления списков, unix-время; null — блока cron нет. Считается по
// самой строке cron в местном времени Роутера, как её запустит crond. Строка — первая
// в блоке Трубы (cron_set).
export function cron_next() {
	let lines = split(readfile(CRONTAB) ?? '', '\n');
	let i = index(lines, C.CRON_BEGIN);
	let m = (i >= 0) ? match(lines[i + 1] ?? '', /^([0-9]+) \* \* \* \* /) : null;
	if (!m)
		return null;
	let now = time();
	let tm = localtime(now);
	tm.min = int(m[1]);
	tm.sec = 0;
	let t = timelocal(tm);
	return (t > now) ? t : t + 3600;
};

// Наборы правил выходят в разное время суток (geoip — бывает и вечером по UTC): проверка
// каждый час, в начале часа. Без изменений она скачивает только контрольные суммы.
export function cron_set(enabled) {
	let cur = readfile(CRONTAB) ?? '';
	let lines = split(cur, '\n');
	let out = [], skip = false;
	for (let l in lines) {
		if (l == C.CRON_BEGIN) { skip = true; continue; }
		if (l == C.CRON_END) { skip = false; continue; }
		if (!skip)
			push(out, l);
	}
	while (length(out) && out[length(out) - 1] == '')
		pop(out);

	if (enabled) {
		push(out, C.CRON_BEGIN);
		push(out, sprintf('0 * * * * %s update-lists >/dev/null 2>&1', C.CLI));
		push(out, C.CRON_END);
	}

	let next = length(out) ? join('\n', out) + '\n' : '';
	if (next == cur)
		return false;
	U.mkdirp(CRONTAB_DIR);
	U.write_atomic(CRONTAB, next, 0600);
	system('/etc/init.d/cron restart >/dev/null 2>&1');
	return true;
};

// ---- UPnP/NAT-PMP на Туннеле ----

export function upnp_set(enabled, iface, vps_ip) {
	if (!stat('/etc/config/upnpd'))
		return false;
	let c = cursor();
	c.load('upnpd');
	if (c.get('upnpd', 'config') == null)
		return false;

	if (enabled) {
		if (!stat(C.UPNP_BACKUP)) {
			U.mkdirp(C.STATE_DIR);
			U.write_json(C.UPNP_BACKUP, {
				enabled: c.get('upnpd', 'config', 'enabled'),
				external_iface: c.get('upnpd', 'config', 'external_iface'),
				external_ip: c.get('upnpd', 'config', 'external_ip'),
			});
		}
		let want = { enabled: '1', external_iface: iface, external_ip: vps_ip };
		let changed = false;
		for (let k in want) {
			if (want[k] != null && c.get('upnpd', 'config', k) != want[k]) {
				c.set('upnpd', 'config', k, want[k]);
				changed = true;
			}
		}
		if (changed) {
			c.commit('upnpd');
			system('/etc/init.d/miniupnpd enable >/dev/null 2>&1; /etc/init.d/miniupnpd restart >/dev/null 2>&1');
		}
		return changed;
	}

	let b = U.read_json(C.UPNP_BACKUP, null);
	if (!b)
		return false;
	for (let k in [ 'enabled', 'external_iface', 'external_ip' ]) {
		if (b[k] == null)
			c.delete('upnpd', 'config', k);
		else
			c.set('upnpd', 'config', k, b[k]);
	}
	c.commit('upnpd');
	unlink(C.UPNP_BACKUP);
	system('/etc/init.d/miniupnpd restart >/dev/null 2>&1');
	return true;
};
