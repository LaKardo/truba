// Правила маршрутизации, таблица Туннеля, dnsmasq, cron, UPnP.
'use strict';

import { cursor } from 'uci';
import { connect } from 'ubus';
import { readfile, stat, unlink } from 'fs';
import * as C from 'truba.const';
import * as U from 'truba.util';

const T = '' + C.RT_TABLE;

export function iface_up(iface) {
	let ub = connect();
	let st = ub ? ub.call('network.interface.' + iface, 'status', {}) : null;
	if (ub)
		ub.disconnect();
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
export function set_table(state, iface, tinfo, killswitch) {
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

	let want = '127.0.0.1#' + port;
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

// ---- cron: блок между маркерами ----

const CRONTAB = '/etc/crontabs/root';

// update_utc «ЧЧ:ММ» → локальное время Роутера.
function utc_to_local(hhmm) {
	let m = match(hhmm ?? '', /^([0-9]{1,2}):([0-9]{2})$/);
	let h = m ? int(m[1]) : 4, mi = m ? int(m[2]) : 0;
	let now = time();
	let off = int((timegm(localtime(now)) - now) / 60);   // смещение часового пояса, минуты
	let t = ((h * 60 + mi + off) % 1440 + 1440) % 1440;
	return [ int(t / 60), t % 60 ];
}

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
		push(out, sprintf('%d %d * * * /usr/sbin/truba update-lists >/dev/null 2>&1', t[1], t[0]));
		push(out, C.CRON_END);
	}

	let next = length(out) ? join('\n', out) + '\n' : '';
	if (next == cur)
		return false;
	U.mkdirp('/etc/crontabs');
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
