// Генерация таблицы nftables `inet truba`.
'use strict';

import * as C from 'truba.const';
import * as D from 'truba.dat';
import * as P from 'truba.plan';

const ACTION_MARK = { tunnel: C.MARK_TUNNEL, direct: C.MARK_DIRECT };

function hex(n) {
	return sprintf('0x%08x', n);
}

function q(s) {
	return '"' + replace(s, /"/g, '') + '"';
}

// Метки Трубы занимают только биты MARK_MASK: остальные биты meta mark и ct mark
// принадлежат другим службам Роутера (QoS, балансировка каналов, mesh-VPN и т.п.).
const KEEP = hex(~C.MARK_MASK & 0xffffffff);

// prerouting Трубы — после всех цепочек mangle (ADR 0011): чужие restore из ct mark и разметка с тем же
// приоритетом шли бы в порядке загрузки и могли перезаписать метку Трубы. Но до dstnat: классификация
// видит адрес назначения до DNAT, а перехват DNS идёт после неё.
const PREROUTING_HOOK = '\t\ttype filter hook prerouting priority mangle + 10; policy accept;\n';

// persist — в самом конце postrouting: после srcnat (100) и чужих цепочек с обычными приоритетами,
// чтобы решение Трубы попало в ct mark последним (ADR 0011).
const PERSIST_HOOK = '\t\ttype filter hook postrouting priority 300; policy accept;\n';

function set_meta(mark) {
	return 'meta mark set meta mark and ' + KEEP + ' or ' + hex(mark);
}

function ct_is(mark) {
	return 'ct mark and ' + hex(C.MARK_MASK) + ' == ' + hex(mark);
}

// Соединение с одним из решений (ответы на входящие и «Туннель» идут одним путём).
function ct_in(marks) {
	return 'ct mark and ' + hex(C.MARK_MASK) + ' { ' + join(', ', map(marks, hex)) + ' }';
}

// Решение для соединения держится в meta mark каждого пакета и в самом конце
// postrouting записывается в ct mark. Так оно переживает чужие цепочки, которые
// перезаписывают ct mark целиком раньше (например, «ct mark set ip dscp | 0x80»).
function persist_chain() {
	let s = '\n\tchain persist {\n';
	s += PERSIST_HOOK;
	s += '\t\tmeta nfproto != ipv4 return\n';
	for (let m in [ C.MARK_INBOUND, C.MARK_TUNNEL, C.MARK_DIRECT ])
		s += '\t\tmeta mark and ' + hex(C.MARK_MASK) + ' == ' + hex(m) +
			' ct mark set ct mark and ' + KEEP + ' or ' + hex(m) + ' return\n';
	s += '\t}\n';
	return s;
}

// Свои сокеты Роутера с SO_MARK «Туннель» (mosdns, nat-test). Чужая цепочка output
// (например, прозрачный прокси для самого Роутера: «meta mark set 0x162», своё
// ip rule с точной меткой) может перезаписать meta mark целиком и увести пакет в
// свою таблицу. После mangle байт Трубы возвращается из метки сокета, и route-цепочка
// перемаршрутизирует пакет: правило 1000 с маской срабатывает, а чужое правило с
// точной меткой — уже нет.
// socket mark — модуль kmod-nft-socket; без него этого правила нет (ctx.socket_mark).
//
// Пакеты к IP Трубы — это сам Туннель (внешние зашифрованные пакеты AmneziaWG), им
// только напрямую, по двум причинам:
// - они проходят output ещё раз и несут сокет исходного пакета — с его меткой
//   «Туннель»; вернуть им её значит завернуть Туннель в себя: петля, awg0
//   отбрасывает пакет;
// - чужая цепочка output, которая метит всё подряд, увела бы их в свою таблицу,
//   и Туннель пошёл бы не через провайдера.
// Метка «Напрямую» ставится в байт Трубы: правило с точной чужой меткой уже не
// сработает, а правило 1000 Трубы — только для «Туннеля». Без IP Трубы цепочки нет.
// DSCP у них — 0: модуль ставит рукопожатию AF41, как WireGuard, а мусорным пакетам —
// случайный, и по этому Туннель узнают. ECN не трогается.
function output_chain(ctx) {
	if (!ctx.vps)
		return '';
	let s = '\n\tchain output {\n';
	s += '\t\ttype route hook output priority mangle + 10; policy accept;\n';
	s += '\t\tmeta nfproto != ipv4 return\n';
	s += '\t\tip daddr ' + ctx.vps + ' ip dscp != cs0 ip dscp set cs0\n';
	s += '\t\tip daddr ' + ctx.vps + ' ' + set_meta(C.MARK_DIRECT) + ' return\n';
	if (ctx.socket_mark)
		s += '\t\tsocket mark and ' + hex(C.MARK_MASK) + ' == ' + hex(C.MARK_TUNNEL) + ' ' + set_meta(C.MARK_TUNNEL) + '\n';
	s += '\t}\n';
	return s;
}

// Пакеты из Туннеля: ответы на них — только в Туннель. Метка ставится на каждый
// пакет, а не только на первый: persist восстанавливает её после чужих перезаписей.
function inbound_rules(iface) {
	let s = '\t\tiifname ' + iface + ' ct state new counter name c_inbound\n';
	s += '\t\tiifname ' + iface + ' ' + set_meta(C.MARK_INBOUND) + ' return\n';
	return s;
}

// Счётчики. c_tunnel, c_direct — новые соединения устройств по Действиям (первый пакет
// проходит классификацию), c_block — отброшенные пакеты, c_inbound — новые входящие
// через Туннель. Остальные — байты трафика устройств по направлениям (цепочка stats).
const CONN_COUNTERS = [ 'c_tunnel', 'c_direct', 'c_block', 'c_inbound' ];
const TRAFFIC_COUNTERS = [ 'c_tunnel_down', 'c_tunnel_up', 'c_direct_down', 'c_direct_up',
                                  'c_inbound_down', 'c_inbound_up' ];

// Значения из прежней таблицы (carry) переносятся: «Сохранить и применить» не обнуляет учёт.
function counter_decls(names, carry) {
	let s = '';
	for (let n in names) {
		let v = carry?.[n];
		s += '\tcounter ' + n + ' {' + (v ? sprintf(' packets %d bytes %d', v.packets, v.bytes) : '') + ' }\n';
	}
	return s + '\n';
}

// Трафик по устройствам (ADR 0018): элемент набора — адрес устройства со своим счётчиком. Элемент
// появляется с первым пакетом и живёт сутки после последнего; при перезагрузке таблицы — с нуля.
function dev_sets() {
	let s = '';
	for (let n in C.DEV_SETS)
		s += sprintf('\tset %s {\n\t\ttype ipv4_addr;\n\t\tflags dynamic,timeout;\n\t\ttimeout %ds;\n\t\tsize %d;\n\t\tcounter;\n\t}\n',
			n, C.DEV_SPAN, C.DEV_SET_SIZE);
	return s;
}

// Учёт трафика устройств из зон Трубы. Хук forward видит только транзитные пакеты,
// уже пропущенные fw4 (приоритет после него), — свой трафик Роутера сюда не попадает.
// Направление — по интерфейсам и ct direction, а не по ct mark: ответы из Туннеля
// переписывают её на «входящее». Down — к устройствам, up — от них. Пакеты соединений,
// ускоренных flowtable (программное ускорение), идут мимо этой цепочки.
// Каждое правило — сначала счётчик Действия, затем адрес устройства в его набор (ключ — адрес
// со стороны Роутера: источник от устройства, назначение к нему). Когда набор полон, update нового
// адреса прерывает правило: return не срабатывает, и пакет идёт к следующим правилам. Поэтому
// счётчик стоит раньше update, а правила не пересекаются (ct direction, оба интерфейса): пакет из
// прерванного правила больше ни с чем не совпадёт, и счётчики Действий не врут.
function stats_chain(iface) {
	let rule = (cond, cnt, key) => sprintf('\t\t%s counter name c_%s update @dv_%s { ip %s } return\n', cond, cnt, cnt, key);
	let s = '\n\tchain stats {\n';
	s += '\t\ttype filter hook forward priority filter + 10; policy accept;\n';
	s += '\t\tmeta nfproto != ipv4 return\n';
	s += '\t\tiifname @lan_if oifname @lan_if return\n';
	s += rule('iifname @lan_if oifname ' + iface + ' ct direction original', 'tunnel_up', 'saddr');
	s += rule('iifname ' + iface + ' oifname @lan_if ct direction reply', 'tunnel_down', 'daddr');
	s += rule('iifname ' + iface + ' oifname @lan_if ct direction original', 'inbound_down', 'daddr');
	s += rule('iifname @lan_if oifname ' + iface + ' ct direction reply', 'inbound_up', 'saddr');
	s += rule('iifname @lan_if oifname != ' + iface + ' ct direction original', 'direct_up', 'saddr');
	s += rule('iifname != ' + iface + ' oifname @lan_if ct direction reply', 'direct_down', 'daddr');
	s += '\t}\n';
	return s;
}

// DNS устройств из зон Трубы с адресов вне подсетей Роутера (local4) — например, узлов mesh-VPN
// за интерфейсом с адресом /32. dnsmasq с --local-service (по умолчанию) таким не отвечает,
// и перехват оставлял бы их без DNS. Им источник подменяется на адрес Роутера, к которому пришёл
// запрос (после перехвата — адрес интерфейса): dnsmasq видит в нём свой адрес и отвечает (ADR 0014).
// Ответ ядро возвращает устройству по conntrack. Устройства из подсетей Роутера dnsmasq видит как есть.
function dns_snat_chain() {
	let s = '\n\tchain dns_snat {\n';
	s += '\t\ttype nat hook input priority srcnat; policy accept;\n';
	s += '\t\tmeta nfproto ipv4 iifname @lan_if ip saddr != @local4 meta l4proto { tcp, udp } th dport 53 snat ip to ip daddr\n';
	s += '\t}\n';
	return s;
}

// Перехват DNS устройств зон (в dnsmasq Роутера) и подмена источника для чужих подсетей.
// Приоритет dstnat - 5: после prerouting Трубы, раньше dstnat fw4 и dns_redirect dnsmasq.
function dns_chains(cfg) {
	if (!cfg.dns_hijack)
		return '';
	let s = '\n\tchain dns_hijack {\n';
	s += '\t\ttype nat hook prerouting priority dstnat - 5; policy accept;\n';
	s += '\t\tmeta nfproto ipv4 iifname @lan_if meta l4proto { tcp, udp } th dport 53 redirect to :53\n';
	s += '\t}\n';
	return s + dns_snat_chain();
}

// timeout — срок элементов по умолчанию, с (набор с flags timeout).
function set_decl(name, typ, flags, elems, timeout) {
	let s = '\tset ' + name + ' {\n\t\ttype ' + typ + ';\n';
	if (flags)
		s += '\t\tflags ' + flags + ';\n';
	if (timeout)
		s += sprintf('\t\ttimeout %ds;\n', timeout);
	if (index(flags ?? '', 'interval') >= 0)
		s += '\t\tauto-merge;\n';
	if (length(elems))
		s += '\t\telements = { ' + join(', ', elems) + ' }\n';
	s += '\t}\n';
	return s;
}

// IP из DNS, перенесённые из прежней таблицы ({ ip, expires }), — с оставшимся сроком: перенос
// не продлевает его, иначе частые применения держали бы устаревшие адреса вечно (ADR 0007).
// Срок длиннее timeout набора ядро не принимает, а в наборе без срока — срок вообще.
// Элемент без срока (прежняя таблица без него) получает срок набора целиком.
function dns_elems(list, timeout) {
	let out = [];
	for (let e in list ?? []) {
		let ip = (type(e) == 'object') ? e.ip : e;
		let left = (type(e) == 'object') ? e.expires : null;
		if (!timeout || left == null)
			push(out, ip);
		else if (left >= 1)
			push(out, sprintf('%s expires %ds', ip, (left < timeout) ? left : timeout));
	}
	return out;
}

// ctx: { lan_if[], bypass4[], local4[], gs_tunnel4[], gs_direct4[], dev_tunnel[], dev_direct[], socket_mark, counters };
// local4 — подсети адресов Роутера (F.local_subnets), нужен только с перехватом DNS.
// gs_* — IP из прежней таблицы: строки или { ip, expires } (S.set_elements).
// Заполняет ctx.set_sizes — число подсетей geoip по Действиям: из ядра огромный набор читать дорого,
// и ctx.gi — сами подсети: копия правил (ADR 0006) строится из того же ctx без нового чтения.
export function nft_full(cfg, plan, ctx) {
	let gi = ctx.gi;
	if (!gi) {
		gi = ctx.gi = { block: [], tunnel: [], direct: [] };
		for (let a in [ 'block', 'tunnel', 'direct' ])
			for (let tag in plan.geoip[a])
				for (let cidr in D.geoip_cidrs(tag))
					push(gi[a], cidr);
	}
	ctx.set_sizes = { block: length(gi.block), tunnel: length(gi.tunnel), direct: length(gi.direct) };

	let iface = q(cfg.iface);
	let dflt = (plan.mode_default == 'tunnel') ? C.MARK_TUNNEL : C.MARK_DIRECT;

	let s = 'table inet ' + C.NFT_TABLE + '\ndelete table inet ' + C.NFT_TABLE + '\n';
	s += 'table inet ' + C.NFT_TABLE + ' {\n';
	s += set_decl('lan_if', 'ifname', null, map(ctx.lan_if, q));
	s += set_decl('bypass4', 'ipv4_addr', 'interval', ctx.bypass4);
	if (cfg.dns_hijack)
		s += set_decl('local4', 'ipv4_addr', 'interval', ctx.local4);
	s += set_decl('gi_block4', 'ipv4_addr', 'interval', gi.block);
	s += set_decl('gi_tunnel4', 'ipv4_addr', 'interval', gi.tunnel);
	s += set_decl('gi_direct4', 'ipv4_addr', 'interval', gi.direct);
	// IP из ответов DNS (их кладёт mosdns) — со сроком: адрес CDN, которым домен больше не
	// пользуется, перестаёт направлять трафик не позже срока (ADR 0007). 0 — без срока.
	let gst = cfg.dns.set_timeout;
	s += set_decl('gs_tunnel4', 'ipv4_addr', gst ? 'timeout' : null, dns_elems(ctx.gs_tunnel4, gst), gst);
	s += set_decl('gs_direct4', 'ipv4_addr', gst ? 'timeout' : null, dns_elems(ctx.gs_direct4, gst), gst);
	s += set_decl('dev_tunnel', 'ether_addr', null, ctx.dev_tunnel);
	s += set_decl('dev_direct', 'ether_addr', null, ctx.dev_direct);
	s += dev_sets();
	s += counter_decls([ ...CONN_COUNTERS, ...TRAFFIC_COUNTERS ], ctx.counters);

	s += '\tchain prerouting {\n';
	s += PREROUTING_HOOK;
	s += '\t\tmeta nfproto != ipv4 return\n';
	// Новые соединения извне: из Туннеля — ответы в Туннель, с остальных внешних интерфейсов — Напрямую.
	s += inbound_rules(iface);
	s += '\t\tiifname != @lan_if ct state new ' + set_meta(C.MARK_DIRECT) + ' return\n';
	// Решение уже принято для соединения — тот же путь для всех его пакетов.
	s += '\t\tct mark and ' + hex(C.MARK_MASK) + ' != 0 goto restore\n';
	s += '\t\tiifname != @lan_if return\n';
	s += '\t\tip daddr @bypass4 return\n';
	s += '\t\tjump classify\n';
	s += '\t\tmeta mark and ' + hex(C.MARK_MASK) + ' == ' + hex(C.MARK_TUNNEL) + ' counter name c_tunnel\n';
	s += '\t\tmeta mark and ' + hex(C.MARK_MASK) + ' == ' + hex(C.MARK_DIRECT) + ' counter name c_direct\n';
	s += '\t}\n\n';

	// Ответы на входящие из Туннеля идут в Туннель так же, как соединения «Туннель».
	s += '\tchain restore {\n';
	s += '\t\t' + ct_in([ C.MARK_INBOUND, C.MARK_TUNNEL ]) + ' ' + set_meta(C.MARK_TUNNEL) + ' return\n';
	s += '\t\t' + ct_is(C.MARK_DIRECT) + ' ' + set_meta(C.MARK_DIRECT) + ' return\n';
	s += '\t}\n\n';

	// Приоритет (P.PRIORITY): Блок → Политика устройства → geosite (Туннель > Напрямую) → geoip → Режим.
	s += '\tchain classify {\n';
	for (let p in P.PRIORITY) {
		s += '\t\t' + ((p.match == 'mac') ? 'ether saddr @' : 'ip daddr @') + p.set + ' ';
		s += (p.action == 'block') ? 'counter name c_block drop\n' : set_meta(ACTION_MARK[p.action]) + ' return\n';
	}
	s += '\t\t' + set_meta(dflt) + '\n';
	s += '\t}\n';
	s += persist_chain();
	s += stats_chain(iface);
	s += output_chain(ctx);
	s += dns_chains(cfg);

	s += '}\n';
	return s;
};

// Маршрутизация выключена: остаётся только возврат ответов на входящие через Туннель.
export function nft_minimal(cfg, ctx) {
	let iface = q(cfg.iface);
	let s = 'table inet ' + C.NFT_TABLE + '\ndelete table inet ' + C.NFT_TABLE + '\n';
	s += 'table inet ' + C.NFT_TABLE + ' {\n';
	s += set_decl('lan_if', 'ifname', null, map(ctx.lan_if, q));
	s += dev_sets();
	s += counter_decls([ 'c_inbound', ...TRAFFIC_COUNTERS ], ctx.counters);
	s += '\tchain prerouting {\n';
	s += PREROUTING_HOOK;
	s += '\t\tmeta nfproto != ipv4 return\n';
	s += inbound_rules(iface);
	// persist пишет ответы как «Туннель», поэтому подходят обе метки.
	s += '\t\tiifname @lan_if ' + ct_in([ C.MARK_INBOUND, C.MARK_TUNNEL ]) + ' ' + set_meta(C.MARK_TUNNEL) + ' return\n';
	s += '\t}\n';
	s += persist_chain();
	s += stats_chain(iface);
	s += output_chain(ctx);
	s += '}\n';
	return s;
};
