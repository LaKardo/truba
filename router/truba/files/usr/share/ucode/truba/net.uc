// Правила маршрутизации, таблица Туннеля, dnsmasq, cron, UPnP.
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

function del_rule_prio(prio) {
	for (let i = 0; i < 8; i++)
		if (system(sprintf('ip -4 rule del priority %d 2>/dev/null', prio)) != 0)
			break;
}

export function ensure_rules(dev) {
	del_rule_prio(C.PRIO_RULE_MARK);
	del_rule_prio(C.PRIO_RULE_OIF);
	system([ 'ip', '-4', 'rule', 'add', 'fwmark', sprintf('0x%x/0x%x', C.MARK_TUNNEL, C.MARK_MASK),
	         'lookup', T, 'priority', '' + C.PRIO_RULE_MARK ]);
	system([ 'ip', '-4', 'rule', 'add', 'oif', dev, 'lookup', T, 'priority', '' + C.PRIO_RULE_OIF ]);
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
function set_table(state, iface, tinfo, killswitch) {
	let st = iface_up(iface);
	let dev = st.device;

	if (st.up && tinfo.subnet)
		system([ 'ip', '-4', 'route', 'replace', tinfo.subnet, 'dev', dev, 'table', T ]);

	if (st.up && state == 'healthy') {
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
	let st = iface_up(cfg.iface);
	let h = U.read_json(C.HEALTH_FILE, null);
	let state;
	if (tinfo.disabled || !st.up)
		state = 'down';
	else if (cfg.watchdog.enabled && h?.state == 'down')
		state = 'down';
	else
		state = 'healthy';
	// Аварийная блокировка имеет смысл только при включённой Маршрутизации.
	return set_table(state, cfg.iface, tinfo, cfg.routing && cfg.killswitch);
};

export function set_rp_filter(dev) {
	system([ 'sysctl', '-qw', 'net.ipv4.conf.' + replace(dev, '.', '/') + '.rp_filter=0' ]);
};

// ---- dnsmasq: перенаправление в mosdns с сохранением исходных значений ----

function dnsmasq_section(c) {
	let sid = null;
	c.foreach('dhcp', 'dnsmasq', (s) => {
		if (sid == null)
			sid = s['.name'];
	});
	return sid;
}

export function dnsmasq_enable(port) {
	let c = cursor();
	c.load('dhcp');
	let sid = dnsmasq_section(c);
	if (!sid)
		return false;

	let want = C.MOSDNS_ADDR + '#' + port;
	let cur = U.to_list(c.get('dhcp', sid, 'server'));

	if (!stat(C.DNSMASQ_BACKUP)) {
		U.mkdirp(C.STATE_DIR);
		U.write_json(C.DNSMASQ_BACKUP, {
			sid,
			noresolv: c.get('dhcp', sid, 'noresolv'),
			cachesize: c.get('dhcp', sid, 'cachesize'),
			server: cur,
		});
	}

	// Серверы для отдельных доменов (/domain/ip) оставляем, общие заменяем на mosdns.
	let servers = filter(cur, s => index(s, '/') == 0);
	push(servers, want);

	let changed = (c.get('dhcp', sid, 'noresolv') != '1') || (c.get('dhcp', sid, 'cachesize') != '0') ||
	              (sprintf('%J', cur) != sprintf('%J', servers));
	if (!changed)
		return false;

	c.set('dhcp', sid, 'noresolv', '1');
	c.set('dhcp', sid, 'cachesize', '0');
	c.set('dhcp', sid, 'server', servers);
	c.commit('dhcp');
	system('/etc/init.d/dnsmasq restart >/dev/null 2>&1');
	return true;
};

export function dnsmasq_restore() {
	let b = U.read_json(C.DNSMASQ_BACKUP, null);
	if (!b)
		return false;
	let c = cursor();
	c.load('dhcp');
	let sid = b.sid;
	if (c.get('dhcp', sid) == null)
		sid = dnsmasq_section(c);
	if (sid) {
		for (let k in [ 'noresolv', 'cachesize' ]) {
			if (b[k] == null)
				c.delete('dhcp', sid, k);
			else
				c.set('dhcp', sid, k, b[k]);
		}
		if (length(b.server ?? []))
			c.set('dhcp', sid, 'server', b.server);
		else
			c.delete('dhcp', sid, 'server');
		c.commit('dhcp');
	}
	unlink(C.DNSMASQ_BACKUP);
	system('/etc/init.d/dnsmasq restart >/dev/null 2>&1');
	return true;
};

// ---- Межсетевой экран: перенаправления зон Маршрутизации в зону Туннеля ----

// Своя секция перенаправления зоны: <зона>_truba (имя секции UCI — только буквы, цифры и «_»).
function fwd_name(zone) {
	return replace(zone, /[^A-Za-z0-9_]/g, '_') + '_' + C.FW_ZONE;
}

// Без перенаправления зоны в truba fw4 отбрасывает трафик её устройств, которому Труба выбрала Туннель
// (ADR 0014). У каждой выбранной зоны оно должно быть: нет никакого — Труба заводит своё, секцию
// fwd_name(). Перенаправления владельца (любое другое имя) засчитываются и не трогаются, а свои
// секции зон, которые больше не выбраны или удалены, убираются. Межсетевой экран перезагружается,
// только если что-то изменилось.
export function forwardings_set(zones) {
	let c = cursor();
	c.load('firewall');
	let exist = {};
	c.foreach('firewall', 'zone', (z) => {
		if (z.name)
			exist[z.name] = true;
	});
	let want = {};
	if (exist[C.FW_ZONE])
		for (let z in zones)
			if (exist[z] && z != C.FW_ZONE)
				want[z] = true;

	let changed = false, drop = [], have = {};
	c.foreach('firewall', 'forwarding', (f) => {
		if (f.dest != C.FW_ZONE || !f.src)
			return;
		if (f['.name'] == fwd_name(f.src) && !want[f.src])
			push(drop, f['.name']);
		else
			have[f.src] = true;
	});
	for (let sid in drop) {
		c.delete('firewall', sid);
		changed = true;
	}
	for (let z in want) {
		if (have[z])
			continue;
		let sid = fwd_name(z);
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
	if (!changed)
		return false;
	c.commit('firewall');
	system('/etc/init.d/firewall reload >/dev/null 2>&1');
	return true;
};

// ---- cron: блок между маркерами ----

const CRONTAB_DIR = '/etc/crontabs', CRONTAB = CRONTAB_DIR + '/root';

// update_utc «ЧЧ:ММ» → локальное время Роутера.
function utc_to_local(hhmm) {
	let m = match(hhmm ?? '', /^([0-9]{1,2}):([0-9]{2})$/);
	let h = m ? int(m[1]) : 12, mi = m ? int(m[2]) : 0;
	let now = time();
	let off = int((timegm(localtime(now)) - now) / 60);   // смещение часового пояса, минуты
	let t = ((h * 60 + mi + off) % 1440 + 1440) % 1440;
	return [ int(t / 60), t % 60 ];
}

// Ближайший запуск обновления списков, unix-время; null — блока cron нет. Считается по
// самой строке cron в местном времени Роутера, как её запустит crond (и после смены
// летнего времени, когда строка уже разошлась с update_utc до следующего применения).
// Строка — первая в блоке Трубы (cron_set).
export function cron_next() {
	let lines = split(readfile(CRONTAB) ?? '', '\n');
	let i = index(lines, C.CRON_BEGIN);
	let m = (i >= 0) ? match(lines[i + 1] ?? '', /^([0-9]+) ([0-9]+) /) : null;
	if (!m)
		return null;
	let now = time();
	let tm = localtime(now);
	tm.hour = int(m[2]);
	tm.min = int(m[1]);
	tm.sec = 0;
	let t = timelocal(tm);
	if (t <= now) {
		tm.mday++;
		t = timelocal(tm);
	}
	return t;
};

export function cron_set(enabled, update_utc) {
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
		let t = utc_to_local(update_utc);
		push(out, C.CRON_BEGIN);
		push(out, sprintf('%d %d * * * %s update-lists >/dev/null 2>&1', t[1], t[0], C.CLI));
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
