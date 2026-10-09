// Действия Категорий для текущего Режима и порядок их проверки (Приоритет).
'use strict';

import * as C from 'truba.const';

const RANK = { block: 0, tunnel: 1, direct: 2 };

// Приоритет для нового соединения устройства — после адресов домашней сети (bypass4), до
// Режима. Один источник и для цепочки classify (truba.render), и для «Проверить домен/IP»
// (truba.check): порядок в правилах nftables и в объяснении не разойдётся.
// match — что сравнивается с набором: адрес назначения (ip) или MAC устройства (mac);
// key — имя признака в ответе check (sets), reason — причина решения там же.
export const PRIORITY = [
	{ set: 'gi_block4',  match: 'ip',  action: 'block',  reason: 'geoip_block', key: 'gi_block' },
	{ set: 'dev_direct', match: 'mac', action: 'direct', reason: 'device' },
	{ set: 'dev_tunnel', match: 'mac', action: 'tunnel', reason: 'device' },
	{ set: 'gs_tunnel4', match: 'ip',  action: 'tunnel', reason: 'geosite_ip',  key: 'gs_tunnel' },
	{ set: 'gs_direct4', match: 'ip',  action: 'direct', reason: 'geosite_ip',  key: 'gs_direct' },
	{ set: 'gi_tunnel4', match: 'ip',  action: 'tunnel', reason: 'geoip',       key: 'gi_tunnel' },
	{ set: 'gi_direct4', match: 'ip',  action: 'direct', reason: 'geoip',       key: 'gi_direct' },
];

// Стартовые настройки: Действия Категорий при установке и по кнопке сброса.
export const STARTING = [
	{ mode: 'all',       set: 'geoip',   tag: 'ru',                 action: 'direct' },
	{ mode: 'all',       set: 'geoip',   tag: 'private',            action: 'direct' },
	{ mode: 'all',       set: 'geosite', tag: 'category-ru',        action: 'direct' },
	{ mode: 'all',       set: 'geosite', tag: 'category-cdn-ru',    action: 'direct' },
	{ mode: 'all',       set: 'geosite', tag: 'private',            action: 'direct' },
	{ mode: 'all',       set: 'geosite', tag: 'category-ads',       action: 'block'  },
	{ mode: 'selective', set: 'geosite', tag: 'category-streaming', action: 'tunnel' },
	{ mode: 'selective', set: 'geosite', tag: 'category-ads',       action: 'block'  },
];

export function compute(cfg, cats) {
	let actions = {};
	for (let r in cfg.rules)
		if (r.mode == cfg.mode)
			actions[r.set + ':' + r.tag] = r.action;

	let present = {};
	for (let c in cats)
		present[c.set + ':' + c.tag] = c;

	let missing = filter(keys(actions), k => !present[k]);

	let geosite = [];
	let geoip = { block: [], tunnel: [], direct: [] };

	for (let c in cats) {
		let a = actions[c.set + ':' + c.tag];
		if (!a)
			continue;
		if (c.set == 'geosite')
			push(geosite, { tag: c.tag, count: c.count, action: a });
		else
			push(geoip[a], c.tag);
	}

	// Узкая Категория раньше широкой: вложенная всегда меньше объемлющей,
	// поэтому сортировка по числу записей соблюдает вложенность.
	// При равенстве — Блок → Туннель → Напрямую, затем по имени (детерминированно).
	geosite = sort(geosite, (x, y) =>
		(x.count - y.count) || (RANK[x.action] - RANK[y.action]) || ((x.tag < y.tag) ? -1 : ((x.tag > y.tag) ? 1 : 0)));

	return {
		mode: cfg.mode,
		mode_default: (cfg.mode == 'all') ? 'tunnel' : 'direct',
		geosite,
		geoip,
		missing,
	};
};

// Отпечаток всего, что влияет на содержимое доменных наборов gs_*.
export function geosite_key(plan, cats_hash) {
	return sprintf('%s|%s|%J', cats_hash ?? '-', plan.mode, map(plan.geosite, g => g.tag + '=' + g.action));
};
