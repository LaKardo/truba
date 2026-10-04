// «Проверить домен/IP»: какая Категория и какое Действие сработают и почему.
'use strict';

import * as C from 'truba.const';
import * as U from 'truba.util';
import * as D from 'truba.dat';
import * as F from 'truba.conf';
import * as P from 'truba.plan';

// Совпадение записи geosite с доменом по правилам v2ray.
function entry_match(entry, d) {
	let i = index(entry, ':');
	let t = substr(entry, 0, i), v = substr(entry, i + 1);
	if (t == 'domain') {
		if (d == v)
			return true;
		let n = length(d) - length(v);
		return (n > 0 && substr(d, n - 1) == '.' + v);
	}
	if (t == 'full')
		return d == v;
	if (t == 'keyword')
		return index(d, v) >= 0;
	if (t == 'regexp') {
		try {
			return match(d, regexp(v)) != null;
		}
		catch (e) {
			return false;
		}
	}
	return false;
}

function in_nft_set(set, ip) {
	return system('nft get element inet ' + C.NFT_TABLE + ' ' + set + ' { ' + ip + ' } >/dev/null 2>&1') == 0;
}

function resolve(domain) {
	let r = U.run('nslookup ' + U.shq(domain) + ' 127.0.0.1');
	let ips = [], seen_server = false;
	for (let line in split(r.out, '\n')) {
		if (match(line, /^Name:/))
			seen_server = true;
		let m = match(line, /^Address( [0-9]+)?:\s*([0-9.]+)\s*$/);
		if (m && seen_server)
			push(ips, m[2]);
	}
	return uniq(ips);
}

function ip_verdict(cfg, plan, cats, ip, mac) {
	let steps = [];
	let geoip_hits = [];
	for (let c in cats) {
		if (c.set != 'geoip')
			continue;
		for (let cidr in D.geoip_cidrs(c.tag)) {
			if (U.cidr_contains(cidr, ip)) {
				push(geoip_hits, c.tag);
				break;
			}
		}
	}

	let action = null, reason = null;
	let sets = {
		bypass: in_nft_set('bypass4', ip),
		gi_block: in_nft_set('gi_block4', ip),
		gs_tunnel: in_nft_set('gs_tunnel4', ip),
		gs_direct: in_nft_set('gs_direct4', ip),
		gi_tunnel: in_nft_set('gi_tunnel4', ip),
		gi_direct: in_nft_set('gi_direct4', ip),
	};
	let dev = mac ? filter(cfg.devices, d => d.mac == lc(mac))[0] : null;

	if (sets.bypass) { action = 'direct'; reason = 'local'; }
	else if (sets.gi_block) { action = 'block'; reason = 'geoip_block'; }
	else if (dev?.policy == 'direct') { action = 'direct'; reason = 'device'; }
	else if (dev?.policy == 'tunnel') { action = 'tunnel'; reason = 'device'; }
	else if (sets.gs_tunnel) { action = 'tunnel'; reason = 'geosite_ip'; }
	else if (sets.gs_direct) { action = 'direct'; reason = 'geosite_ip'; }
	else if (sets.gi_tunnel) { action = 'tunnel'; reason = 'geoip'; }
	else if (sets.gi_direct) { action = 'direct'; reason = 'geoip'; }
	else { action = plan.mode_default; reason = 'mode'; }

	return { ip, geoip: geoip_hits, sets, device: dev?.name, action, reason };
}

export function check(target, mac) {
	let cfg = F.load();
	let dat = U.read_json(C.CATS_FILE, null) ?? D.ensure();
	let cats = dat?.cats ?? [];
	let plan = P.compute(cfg, cats);
	let actions = {};
	for (let g in plan.geosite)
		actions[g.tag] = g.action;

	target = lc(trim(target ?? ''));
	let res = { target, mode: cfg.mode, mode_default: plan.mode_default };

	if (U.is_ipv4(target)) {
		res.kind = 'ip';
		res.ips = [ ip_verdict(cfg, plan, cats, target, mac) ];
		res.action = res.ips[0].action;
		res.reason = res.ips[0].reason;
		return res;
	}

	res.kind = 'domain';
	let d = replace(target, /\.$/, '');

	// Все Категории geosite, где домен совпадает, и сработавшая (первая по Приоритету с явным Действием).
	let hits = [];
	for (let c in cats) {
		if (c.set != 'geosite')
			continue;
		for (let e in D.geosite_entries(c.tag)) {
			if (entry_match(e, d)) {
				push(hits, { tag: c.tag, entry: e, count: c.count, action: actions[c.tag] ?? 'mode' });
				break;
			}
		}
	}
	res.geosite = hits;

	let decisive = null;
	for (let g in plan.geosite) {
		let h = filter(hits, x => x.tag == g.tag)[0];
		if (h) {
			decisive = h;
			break;
		}
	}
	res.decisive = decisive;

	if (decisive?.action == 'block') {
		res.action = 'block';
		res.reason = 'geosite_block';
		res.ips = [];
		return res;
	}

	// Резолв через Роутер: mosdns заодно кладёт IP в набор своей Категории,
	// поэтому итог по IP совпадает с тем, что увидит nftables для нового соединения.
	res.ips = map(resolve(d), ip => ip_verdict(cfg, plan, cats, ip, mac));
	if (length(res.ips)) {
		res.action = res.ips[0].action;
		res.reason = res.ips[0].reason;
		if (decisive && res.reason == 'geosite_ip' && res.action != decisive.action)
			res.reason = 'shared_ip';   // общий CDN-адрес: Туннель побеждает Напрямую
	}
	else {
		res.action = decisive?.action ?? plan.mode_default;
		res.reason = decisive ? 'geosite' : 'mode';
	}
	return res;
};
