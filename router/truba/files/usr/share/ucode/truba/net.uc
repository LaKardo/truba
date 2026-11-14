// Правила маршрутизации, таблица Туннеля, межсетевой экран зон, пробросы из Туннеля, cron, UPnP. DNS — в truba.dns.
'use strict';

import { cursor } from 'uci';
import { readfile, stat, unlink, popen } from 'fs';
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

// Все вызовы ip — командой U.ip_cmd(): «ip rule … oif» и «ip route get … mark» BusyBox не умеет.
function del_rule_prio(prio) {
	let ip = U.ip_cmd();
	for (let i = 0; i < RULE_DUPS_MAX; i++)
		if (system(sprintf('%s -4 rule del priority %d 2>/dev/null', ip, prio)) != 0)
			break;
}

// Строки «ip rule show» с приоритетом prio, пробелы сведены к одному.
function rules_at(lines, prio) {
	let found = [];
	for (let line in lines) {
		let normalized = replace(trim(line), /[[:space:]]+/g, ' ');
		if (index(normalized, prio + ':') == 0)
			push(found, normalized);
	}
	return found;
}

// Правило с приоритетом prio — ровно одно и ровно такое. text — условие и таблица, как их принимает
// «ip rule add»; «ip rule show» печатает перед ними источник — «from all», если он не задан.
export function rule_present(lines, prio, text) {
	let found = rules_at(lines, prio);
	return length(found) == 1 && found[0] == prio + ': ' + ((index(text, 'from ') == 0) ? '' : 'from all ') + text;
};

// Правила Трубы по порядку: [ { prio, text } ]; text null — правила быть не должно.
// addr — адрес Роутера в Туннеле. Правило 1002 — свои пакеты Роутера с этого адреса: ответы на входящие
// из Туннеля к самому Роутеру и отказы межсетевого экрана (вход зоны truba — REJECT). Метки у них нет
// (persist стоит в postrouting, а входящий к Роутеру пакет его не проходит), сокет к awg0 не привязан — без
// правила они уходили бы по main провайдеру с адресом Туннеля в источнике. Транзитных пакетов правило не
// касается: их источник до NAT — адрес устройства. Без адреса (интерфейс не настроен) правила нет.
export function rules_wanted(dev, addr) {
	return [
		{ prio: C.PRIO_RULE_MARK, text: 'fwmark ' + sprintf('0x%x/0x%x', C.MARK_TUNNEL, C.MARK_MASK) + ' lookup ' + T },
		{ prio: C.PRIO_RULE_OIF, text: 'oif ' + dev + ' lookup ' + T },
		{ prio: C.PRIO_RULE_SRC, text: U.is_ipv4(addr) ? 'from ' + addr + ' lookup ' + T : null },
	];
};

export function ensure_rules(dev, addr) {
	let ip = U.ip_cmd();
	let r = U.run(ip + ' -4 rule show');
	let lines = r.code == 0 ? split(r.out, '\n') : [];
	for (let w in rules_wanted(dev, addr)) {
		if (w.text == null) {
			if (length(rules_at(lines, w.prio)))
				del_rule_prio(w.prio);
			continue;
		}
		if (rule_present(lines, w.prio, w.text))
			continue;
		del_rule_prio(w.prio);
		system([ ip, '-4', 'rule', 'add', ...split(w.text, ' '), 'priority', '' + w.prio ]);
	}
};

export function remove_rules() {
	for (let prio in [ C.PRIO_RULE_MARK, C.PRIO_RULE_OIF, C.PRIO_RULE_SRC ])
		del_rule_prio(prio);
	system([ U.ip_cmd(), '-4', 'route', 'flush', 'table', T ]);
};

// state: 'healthy' | 'down'. Таблица 77:
//   healthy                 → default dev <туннель>
//   down + Аварийная блок.  → blackhole default
//   down без неё            → без default: трафик проваливается в main (Напрямую)
// Подсеть Туннеля держится в таблице всегда, пока интерфейс поднят: по ней ходит проверка Туннеля.
function set_table(state, tinfo, killswitch) {
	let dev = tinfo.device, ip = U.ip_cmd();

	if (tinfo.up && tinfo.subnet)
		system([ ip, '-4', 'route', 'replace', tinfo.subnet, 'dev', dev, 'table', T ]);

	if (tinfo.up && state == 'healthy') {
		system([ ip, '-4', 'route', 'replace', 'default', 'dev', dev, 'table', T ]);
		return 'healthy';
	}
	if (killswitch) {
		system([ ip, '-4', 'route', 'replace', 'blackhole', 'default', 'table', T ]);
		return 'blocked';
	}
	system(ip + ' -4 route del default table ' + T + ' 2>/dev/null');
	return 'fallback';
}

// IPv4 серверов DNS «Туннеля», к которым mosdns подключается: «@IP» или сам адрес в URL.
export function tunnel_dns_ips(list) {
	let out = [];
	for (let u in list ?? []) {
		let m = match(u, regexp(F.UPSTREAM_RE));
		let ip = m ? (m[6] ? substr(m[6], 1) : m[3]) : null;
		if (U.is_ipv4(ip))
			push(out, ip);
	}
	return uniq(out);
};

// Какие серверы DNS «Туннеля» отклонять (набор dns_down4), пока Туннель не работает: те, что в подсети
// Туннеля (DNS на Трубе). Остальным хватает таблицы 77: при Аварийной блокировке blackhole отвечает ошибкой
// сразу, без неё запросы с меткой «Туннель» уходят напрямую, и запасной DoH отвечает.
export function dns_down_ips(state, cfg, tinfo) {
	if (state != 'down' || !tinfo.subnet)
		return [];
	return filter(tunnel_dns_ips(cfg.dns.tunnel), ip => U.cidr_contains(tinfo.subnet, ip));
};

// Набор dns_down4: таблицы нет (Маршрутизация выкл, служба остановлена) — ничего.
function dns_down_set(ips) {
	let s = 'flush set inet ' + C.NFT_TABLE + ' dns_down4\n';
	if (length(ips))
		s += 'add element inet ' + C.NFT_TABLE + ' dns_down4 { ' + join(', ', ips) + ' }\n';
	let p = popen('nft -f - >/dev/null 2>&1', 'w');
	if (p) {
		p.write(s);
		p.close();
	}
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
	if (cfg.routing)
		dns_down_set(dns_down_ips(state, cfg, tinfo));
	// Аварийная блокировка имеет смысл только при включённой Маршрутизации.
	return set_table(state, tinfo, cfg.routing && cfg.killswitch);
};

// ---- Канал до Трубы (WAN) ----

// Через что уходят внешние пакеты Туннеля: устройство, его IPv4, шлюз по умолчанию на нём и шлюз маршрута
// до Трубы, который netifd держит для Туннеля (host dependency). null — до Трубы маршрута нет.
// «route get … mark» есть только у полноценного ip: с BusyBox канал не определяется (null).
export function uplink(vps) {
	let ip = U.ip_cmd();
	let r = U.run(ip + ' -4 route get ' + U.shq(vps) + ' mark ' + sprintf('0x%x', C.MARK_DIRECT));
	let dev = (r.code == 0) ? match(r.out, /\sdev ([^ \n]+)/)?.[1] : null;
	if (!dev)
		return null;
	let host = match(U.run(ip + ' -4 route show exact ' + U.shq(vps + '/32')).out, /via ([0-9.]+) dev ([^ \n]+)/);
	return {
		dev,
		addr: match(U.run(ip + ' -4 -o addr show dev ' + U.shq(dev)).out, /inet ([0-9.]+)/)?.[1],
		gw: match(U.run(ip + ' -4 route show default dev ' + U.shq(dev)).out, /via ([0-9.]+)/)?.[1],
		host_via: (host && host[2] == dev) ? host[1] : null,
	};
};

// Что делать по событию канала до Трубы. prev — прежнее состояние (WAN_FILE), cur — uplink() и iface события.
//   save — записать cur: сменились устройство, адрес или шлюз;
//   act  — обновить Туннель: смена или повторный подъём того же интерфейса (кабель переткнули к тому же
//          провайдеру). Первое событие после загрузки (prev нет) только запоминается; продление DHCP
//          без смены и подъём соседнего интерфейса на том же устройстве (wan6) — ничего;
//   stale_route — маршрут до Трубы ведёт через шлюз, которого на канале больше нет.
export function wan_change(prev, cur, ifup) {
	let same = prev != null && prev.dev == cur.dev && prev.addr == cur.addr && prev.gw == cur.gw;
	let act = !!cur.addr && prev != null && (!same || (ifup && prev.iface == cur.iface));
	return { save: !same, act, stale_route: act && !!cur.gw && !!cur.host_via && cur.host_via != cur.gw };
};

export function set_rp_filter(dev) {
	system([ 'sysctl', '-qw', 'net.ipv4.conf.' + replace(dev, '.', '/') + '.rp_filter=0' ]);
};

// Всё, что зависит от интерфейса Туннеля: правила ip (oif — по его устройству, источник — по его адресу),
// rp_filter 0 на поднятом устройстве (обратный маршрут к источнику входящих — не через Туннель) и таблица 77.
// Итог — как у routes.
export function sync(cfg, tinfo) {
	cfg ??= F.load();
	tinfo ??= F.tunnel_info(cfg.iface);
	ensure_rules(tinfo.device, tinfo.address);
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

// ---- Пробросы портов из Туннеля ----

// Порт или диапазон из настроек межсетевого экрана («8080», «8000-8100», «8000:8100») — как его пишет
// nftables; null — пусто или неверно.
function port_spec(v) {
	v = replace('' + (v ?? ''), ':', '-');
	if (!match(v, /^[0-9]{1,5}(-[0-9]{1,5})?$/))
		return null;
	let p = map(split(v, '-'), (x) => int(x));
	if (p[0] < 1 || p[0] > 65535 || (length(p) > 1 && (p[1] < p[0] || p[1] > 65535)))
		return null;
	return v;
}

// Пробросы портов из зоны Туннеля для цепочки hairpin (render.uc): [ { proto, port, to } ] — протокол
// (tcp или udp), внешний порт или диапазон и куда: «адрес» или «адрес:порт». sections — секции redirect
// межсетевого экрана. Берутся только те, что fw4 сам отражал бы в домашнюю сеть: включённый DNAT IPv4 из
// зоны truba с внешним портом и адресом устройства, без «reflection 0». Проброс без внешнего порта (всё на
// одно устройство) не берётся: он увёл бы к устройству и SSH до самой Трубы. Проброс с src_dip — тоже: он
// задан для другого адреса назначения. Из двух пробросов одного порта и протокола действует первый, как в fw4.
// Порты, которые Труба оставляет себе (её SSH и Туннель), исключает сама цепочка (render.uc:hairpin_chains):
// проброс диапазона с таким портом берётся целиком.
export function forwards_of(sections) {
	let out = [], seen = {};
	for (let s in sections ?? []) {
		if (s.src != C.FW_ZONE || (s.target ?? 'DNAT') != 'DNAT' || s.enabled == '0' || s.reflection == '0')
			continue;
		if (s.family == 'ipv6' || s.src_dip != null || !U.is_ipv4(s.dest_ip))
			continue;
		let port = port_spec(s.src_dport), dport = (s.dest_port != null) ? port_spec(s.dest_port) : port;
		if (port == null || dport == null)
			continue;
		let protos = [];
		for (let p in U.to_list(s.proto ?? 'tcp udp'))
			for (let w in split(lc(trim(p)), /[[:space:]]+/))
				push(protos, ...((w == 'tcpudp') ? [ 'tcp', 'udp' ] : [ w ]));
		for (let proto in uniq(protos)) {
			if (!(proto in [ 'tcp', 'udp' ]) || seen[proto + ':' + port])
				continue;
			seen[proto + ':' + port] = true;
			push(out, { proto, port, to: s.dest_ip + ((dport != port) ? ':' + dport : '') });
		}
	}
	return out;
};

export function tunnel_forwards() {
	let c = cursor(), list = [];
	c.load('firewall');
	c.foreach('firewall', 'redirect', (s) => { push(list, s); });
	return forwards_of(list);
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
