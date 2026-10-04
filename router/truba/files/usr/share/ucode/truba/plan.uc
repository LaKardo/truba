// Действия Категорий для текущего Режима и порядок их проверки (Приоритет).
'use strict';

import * as C from 'truba.const';

const RANK = { block: 0, tunnel: 1, direct: 2 };

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
