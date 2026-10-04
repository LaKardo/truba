// Генерация таблицы nftables `inet truba` и конфига mosdns.
'use strict';

import * as C from 'truba.const';
import * as D from 'truba.dat';

function hex(n) {
	return sprintf('0x%08x', n);
}

function q(s) {
	return '"' + replace(s, /"/g, '') + '"';
}

function set_decl(name, typ, flags, elems) {
	let s = '\tset ' + name + ' {\n\t\ttype ' + typ + ';\n';
	if (flags)
		s += '\t\tflags ' + flags + ';\n';
	if (index(flags ?? '', 'interval') >= 0)
		s += '\t\tauto-merge;\n';
	if (length(elems))
		s += '\t\telements = { ' + join(', ', elems) + ' }\n';
	s += '\t}\n';
	return s;
}

// ctx: { lan_if[], bypass4[], gs_tunnel4[], gs_direct4[], dev_tunnel[], dev_direct[] }
export function nft_full(cfg, plan, ctx) {
	let gi = { block: [], tunnel: [], direct: [] };
	for (let a in [ 'block', 'tunnel', 'direct' ])
		for (let tag in plan.geoip[a])
			for (let cidr in D.geoip_cidrs(tag))
				push(gi[a], cidr);

	let iface = q(cfg.iface);
	let dflt = (plan.mode_default == 'tunnel') ? C.MARK_TUNNEL : C.MARK_DIRECT;

	let s = 'table inet ' + C.NFT_TABLE + '\ndelete table inet ' + C.NFT_TABLE + '\n';
	s += 'table inet ' + C.NFT_TABLE + ' {\n';
	s += set_decl('lan_if', 'ifname', null, map(ctx.lan_if, q));
	s += set_decl('bypass4', 'ipv4_addr', 'interval', ctx.bypass4);
	s += set_decl('gi_block4', 'ipv4_addr', 'interval', gi.block);
	s += set_decl('gi_tunnel4', 'ipv4_addr', 'interval', gi.tunnel);
	s += set_decl('gi_direct4', 'ipv4_addr', 'interval', gi.direct);
	s += set_decl('gs_tunnel4', 'ipv4_addr', null, ctx.gs_tunnel4);
	s += set_decl('gs_direct4', 'ipv4_addr', null, ctx.gs_direct4);
	s += set_decl('dev_tunnel', 'ether_addr', null, ctx.dev_tunnel);
	s += set_decl('dev_direct', 'ether_addr', null, ctx.dev_direct);
	s += '\tcounter c_tunnel { }\n\tcounter c_direct { }\n\tcounter c_block { }\n\tcounter c_inbound { }\n\n';

	s += '\tchain prerouting {\n';
	s += '\t\ttype filter hook prerouting priority mangle; policy accept;\n';
	s += '\t\tmeta nfproto != ipv4 return\n';
	// Новые соединения извне: из Туннеля — ответы в Туннель, с остальных внешних интерфейсов — Напрямую.
	s += '\t\tiifname ' + iface + ' ct state new ct mark set ' + hex(C.MARK_INBOUND) + ' counter name c_inbound return\n';
	s += '\t\tiifname != @lan_if ct state new ct mark set ' + hex(C.MARK_DIRECT) + ' return\n';
	s += '\t\tiifname != @lan_if return\n';
	s += '\t\tct mark ' + hex(C.MARK_INBOUND) + ' meta mark set ' + hex(C.MARK_TUNNEL) + ' return\n';
	s += '\t\tct mark and ' + hex(C.MARK_TUNNEL | C.MARK_DIRECT) + ' != 0 meta mark set ct mark return\n';
	s += '\t\tip daddr @bypass4 return\n';
	s += '\t\tjump classify\n';
	s += '\t\tct mark set meta mark\n';
	s += '\t\tmeta mark ' + hex(C.MARK_TUNNEL) + ' counter name c_tunnel\n';
	s += '\t\tmeta mark ' + hex(C.MARK_DIRECT) + ' counter name c_direct\n';
	s += '\t}\n\n';

	// Приоритет: Блок → Политика устройства → geosite (Туннель > Напрямую) → geoip → Режим.
	s += '\tchain classify {\n';
	s += '\t\tip daddr @gi_block4 counter name c_block drop\n';
	s += '\t\tether saddr @dev_direct meta mark set ' + hex(C.MARK_DIRECT) + ' return\n';
	s += '\t\tether saddr @dev_tunnel meta mark set ' + hex(C.MARK_TUNNEL) + ' return\n';
	s += '\t\tip daddr @gs_tunnel4 meta mark set ' + hex(C.MARK_TUNNEL) + ' return\n';
	s += '\t\tip daddr @gs_direct4 meta mark set ' + hex(C.MARK_DIRECT) + ' return\n';
	s += '\t\tip daddr @gi_tunnel4 meta mark set ' + hex(C.MARK_TUNNEL) + ' return\n';
	s += '\t\tip daddr @gi_direct4 meta mark set ' + hex(C.MARK_DIRECT) + ' return\n';
	s += '\t\tmeta mark set ' + hex(dflt) + '\n';
	s += '\t}\n';

	if (cfg.dns_hijack) {
		s += '\n\tchain dns_hijack {\n';
		s += '\t\ttype nat hook prerouting priority dstnat - 5; policy accept;\n';
		s += '\t\tmeta nfproto ipv4 iifname @lan_if meta l4proto { tcp, udp } th dport 53 redirect to :53\n';
		s += '\t}\n';
	}

	s += '}\n';
	return s;
};

// Маршрутизация выключена: остаётся только возврат ответов на входящие через Туннель.
export function nft_minimal(cfg, ctx) {
	let iface = q(cfg.iface);
	let s = 'table inet ' + C.NFT_TABLE + '\ndelete table inet ' + C.NFT_TABLE + '\n';
	s += 'table inet ' + C.NFT_TABLE + ' {\n';
	s += set_decl('lan_if', 'ifname', null, map(ctx.lan_if, q));
	s += '\tcounter c_inbound { }\n\n';
	s += '\tchain prerouting {\n';
	s += '\t\ttype filter hook prerouting priority mangle; policy accept;\n';
	s += '\t\tmeta nfproto != ipv4 return\n';
	s += '\t\tiifname ' + iface + ' ct state new ct mark set ' + hex(C.MARK_INBOUND) + ' counter name c_inbound return\n';
	s += '\t\tiifname @lan_if ct mark ' + hex(C.MARK_INBOUND) + ' meta mark set ' + hex(C.MARK_TUNNEL) + '\n';
	s += '\t}\n';
	s += '}\n';
	return s;
};

// «url@dial_ip» → { addr, dial_addr }.
function upstream(u, mark) {
	let m = match(u, /^(.*)@([0-9.]+)$/);
	let o = m ? { addr: m[1], dial_addr: m[2] } : { addr: u };
	if (mark)
		o.so_mark = mark;
	return o;
}

// JSON — подмножество YAML, mosdns читает его как обычный конфиг.
export function mosdns(cfg, plan, router_hosts) {
	let P = [];
	let main = [];

	main = [
		{ matches: [ 'qtype 28' ], exec: 'reject 0' },   // AAAA → пусто: Маршрутизация только IPv4 (ADR 0005)
		{ exec: '$cache' },
	];

	if (length(router_hosts)) {
		push(P, { tag: 'c_router', type: 'domain_set', args: { exps: map(router_hosts, h => 'full:' + h) } });
		push(main, { matches: [ 'qname $c_router' ], exec: 'goto flow_router' });
	}

	let i = 0;
	for (let g in plan.geosite) {
		let tag = sprintf('c_%d', i++);
		push(P, { tag, type: 'domain_set', args: { files: [ D.geosite_file(g.tag) ] } });
		let ex = (g.action == 'block') ? 'reject 3' : ((g.action == 'tunnel') ? 'goto flow_tunnel' : 'goto flow_direct');
		push(main, { matches: [ 'qname $' + tag ], exec: ex });
	}
	push(main, { exec: 'goto flow_default' });

	push(P, { tag: 'up_tunnel', type: 'forward',
	          args: { concurrent: 2, upstreams: map(cfg.dns.tunnel, u => upstream(u, C.MARK_TUNNEL)) } });
	push(P, { tag: 'up_direct', type: 'forward',
	          args: { concurrent: 2, upstreams: map(cfg.dns.direct, u => upstream(u, null)) } });
	push(P, { tag: 'cache', type: 'cache', args: { size: cfg.dns.cache_size } });

	let ttl = sprintf('ttl 0-%d', cfg.dns.ttl_max);
	// nftset в mosdns 5 — только встроенное действие: «семейство,таблица,набор,тип,маска».
	let nftset = (set) => sprintf('nftset inet,%s,%s,ipv4_addr,32', C.NFT_TABLE, set);
	// Ответ из кэша тоже проходит через nftset: после пересборки наборов IP возвращаются сами.
	push(P, { tag: 'flow_tunnel', type: 'sequence', args: [
		{ matches: [ '!has_resp' ], exec: '$up_tunnel' },
		{ exec: ttl },
		{ exec: nftset('gs_tunnel4') },
	] });
	push(P, { tag: 'flow_direct', type: 'sequence', args: [
		{ matches: [ '!has_resp' ], exec: '$up_direct' },
		{ exec: ttl },
		{ exec: nftset('gs_direct4') },
	] });
	push(P, { tag: 'flow_router', type: 'sequence', args: [
		{ matches: [ '!has_resp' ], exec: '$up_direct' },
	] });
	push(P, { tag: 'flow_default', type: 'sequence', args: [
		{ matches: [ '!has_resp' ], exec: (plan.mode_default == 'tunnel') ? '$up_tunnel' : '$up_direct' },
	] });

	push(P, { tag: 'main', type: 'sequence', args: main });

	let listen = sprintf('127.0.0.1:%d', cfg.dns.port);
	push(P, { tag: 'udp_in', type: 'udp_server', args: { entry: 'main', listen } });
	push(P, { tag: 'tcp_in', type: 'tcp_server', args: { entry: 'main', listen } });

	return { log: { level: 'warn' }, plugins: P };
};
