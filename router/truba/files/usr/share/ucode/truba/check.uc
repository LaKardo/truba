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

// «a.b.c.d[/n]» → [ сеть, маска ] числами. Без регулярного выражения: на 35 тысячах
// диапазонов geoip это в десять раз быстрее U.cidr_contains.
function net_mask(cidr) {
	let i = index(cidr, '/');
	let a = iptoarr(i < 0 ? cidr : substr(cidr, 0, i));
	if (length(a) != 4)
		return null;
	let len = (i < 0) ? 32 : int(substr(cidr, i + 1));
	let mask = len ? ((0xffffffff << (32 - len)) & 0xffffffff) : 0;
	return [ ((a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3]) & mask, mask ];
}

// Категории geoip каждого адреса: один проход по Категории сразу для всех адресов.
function geoip_hits(cats, nums) {
	let hits = map(nums, () => []);
	for (let c in cats) {
		if (c.set != 'geoip')
			continue;
		let left = length(nums), found = map(nums, () => false);
		for (let cidr in D.geoip_cidrs(c.tag)) {
			let nm = net_mask(cidr);
			if (!nm)
				continue;
			for (let k = 0; k < length(nums); k++) {
				if (!found[k] && (nums[k] & nm[1]) == nm[0]) {
					found[k] = true;
					push(hits[k], c.tag);
					left--;
				}
			}
			if (!left)
				break;
		}
	}
	return hits;
}

// Набор из ядра как список диапазонов [ от, до ]. Целиком один раз на проверку:
// «nft get element» на каждый адрес загружает всю таблицу (≈0,2 с на NC-1812).
function kernel_set(name) {
	let r = U.run('nft -j list set inet ' + C.NFT_TABLE + ' ' + name);
	let out = [];
	if (r.code != 0)
		return out;
	try {
		for (let o in json(r.out)?.nftables ?? []) {
			for (let e in o?.set?.elem ?? []) {
				let v = (type(e) == 'object' && e.elem) ? e.elem.val : e;
				if (type(v) == 'string') {
					let n = U.ip2int(v);
					if (n != null)
						push(out, [ n, n ]);
				}
				else if (v?.prefix) {
					let nm = net_mask(v.prefix.addr + '/' + v.prefix.len);
					if (nm)
						push(out, [ nm[0], nm[0] | (~nm[1] & 0xffffffff) ]);
				}
				else if (v?.range) {
					let a = U.ip2int(v.range[0]), b = U.ip2int(v.range[1]);
					if (a != null && b != null)
						push(out, [ a, b ]);
				}
			}
		}
	}
	catch (e) { }
	return out;
}

function in_ranges(rs, n) {
	for (let r in rs)
		if (n >= r[0] && n <= r[1])
			return true;
	return false;
}

function any_of(tags, wanted) {
	for (let t in tags)
		if (index(wanted, t) >= 0)
			return true;
	return false;
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

// kern — наборы из ядра (bypass4, gs_tunnel4, gs_direct4: их наполняют интерфейсы и mosdns).
// Наборы geoip выводятся из Категорий адреса и плана: в ядре каждый из них — объединение
// CIDR Категорий с этим Действием; при выключенной Маршрутизации их нет.
function ip_verdict(cfg, plan, ip, n, geoip, kern, mac) {
	let gi = (a) => cfg.routing && any_of(geoip, plan.geoip[a] ?? []);
	let action = null, reason = null;
	let sets = {
		bypass: in_ranges(kern.bypass4, n),
		gi_block: gi('block'),
		gs_tunnel: in_ranges(kern.gs_tunnel4, n),
		gs_direct: in_ranges(kern.gs_direct4, n),
		gi_tunnel: gi('tunnel'),
		gi_direct: gi('direct'),
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

	return { ip, geoip, sets, device: dev?.name, action, reason };
}

function verdicts(cfg, plan, cats, ips, mac) {
	if (!length(ips))
		return [];
	let nums = map(ips, U.ip2int);
	let hits = geoip_hits(cats, nums);
	let kern = { bypass4: kernel_set('bypass4'), gs_tunnel4: kernel_set('gs_tunnel4'), gs_direct4: kernel_set('gs_direct4') };
	let out = [];
	for (let k = 0; k < length(ips); k++)
		push(out, ip_verdict(cfg, plan, ips[k], nums[k], hits[k], kern, mac));
	return out;
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
		res.ips = verdicts(cfg, plan, cats, [ target ], mac);
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
	res.ips = verdicts(cfg, plan, cats, resolve(d), mac);
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
