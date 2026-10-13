'use strict';
'require baseclass';
'require uci';
'require poll';

// Основа интерфейса Трубы (ADR 0017): библиотеки, страница в Shadow DOM, светлый или тёмный режим,
// хранилище с опросом службы и изменения UCI. Свой код — модули LuCI: загрузчик LuCI сам ставит
// ?v= и компилирует их. ES-модули — только закреплённые библиотеки в lib/, они без своих import.
// На верхнем уровне модуля нет DOM и сети: static.mjs выполняет его в Node с заглушками.

// Адрес файла пакета с версией ресурсов LuCI: после обновления пакета браузер не возьмёт старый из кэша.
function url(path) {
	return L.resource(path) + (L.env.resource_version ? '?v=' + L.env.resource_version : '');
}

function text(path) {
	return fetch(url(path)).then((r) => {
		if (!r.ok)
			throw new Error('%s: HTTP %d'.format(path, r.status));
		return r.text();
	});
}

// Заполняется в load(): компоненты берут отсюда html и хуки при отрисовке, а не при загрузке модуля.
const lib = {};
let styles = [];
let loading = null;

function load() {
	if (!loading)
		loading = Promise.all([
			import(url('truba/lib/preact-htm.js')),
			import(url('truba/lib/uplot.js')),
			text('truba/lib/uplot.css'),
			text('truba/ui/style.css')
		]).then(([ p, u, uplotCss, css ]) => {
			Object.assign(lib, {
				h: p.h, html: p.html, render: p.render,
				useState: p.useState, useEffect: p.useEffect, useLayoutEffect: p.useLayoutEffect,
				useRef: p.useRef, useMemo: p.useMemo, useCallback: p.useCallback,
				uPlot: u.default
			});
			styles = [ uplotCss, css ];
		});
	return loading;
}

// ---- Светлый или тёмный режим ----
// От темы LuCI берётся только яркость фона под страницей: так работает в любой теме, без знания
// её атрибутов. Почти прозрачный фон (альфа меньше 0,5) не в счёт — он показывает то, что под ним.

const NUM = '([\\d.]+%?)';
const RGB = new RegExp('^rgba?\\(\\s*' + NUM + '[\\s,]+' + NUM + '[\\s,]+' + NUM + '(?:\\s*[,/]\\s*' + NUM + ')?\\s*\\)$');
const SRGB = new RegExp('^color\\(srgb\\s+' + NUM + '\\s+' + NUM + '\\s+' + NUM + '(?:\\s*/\\s*' + NUM + ')?\\s*\\)$');

// Доля 0…1 из «12», «0.4» или «40%»; scale — максимум числа без процента (255 у rgb(), 1 у color()).
function part(s, scale) {
	return s.endsWith('%') ? parseFloat(s) / 100 : parseFloat(s) / scale;
}

// Относительная яркость WCAG для rgb()/rgba() и color(srgb …); null — прозрачный или не разобрать.
function luminance(css) {
	const s = String(css).trim();
	let m = RGB.exec(s), scale = 255;
	if (!m) {
		m = SRGB.exec(s);
		scale = 1;
	}
	if (!m || (m[4] != null && part(m[4], 1) < 0.5))
		return null;
	const lin = (c) => (c <= 0.04045) ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
	const [ r, g, b ] = [ m[1], m[2], m[3] ].map((x) => lin(Math.min(Math.max(part(x, scale), 0), 1)));
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// Режим по фонам предков снизу вверх: первый непрозрачный решает (тёмный — ярче 0,4 нет).
// Ни одного — системная настройка.
function schemeFrom(backgrounds, prefersDark) {
	for (let c of backgrounds) {
		const y = luminance(c);
		if (y != null)
			return (y < 0.4) ? 'dark' : 'light';
	}
	return prefersDark ? 'dark' : 'light';
}

const DARK = '(prefers-color-scheme: dark)';

function detect(host) {
	const bg = [];
	for (let el = host.parentElement; el; el = el.parentElement)
		bg.push(getComputedStyle(el).backgroundColor);
	return schemeFrom(bg, window.matchMedia(DARK).matches);
}

// ---- Хранилище ----

function store(initial) {
	let state = Object.assign({}, initial);
	const subs = new Set();
	return {
		get: () => state,
		set(patch) {
			state = Object.assign({}, state, patch);
			subs.forEach((fn) => fn(state));
		},
		on(fn) {
			subs.add(fn);
			return () => { subs.delete(fn); };
		}
	};
}

// Хук: компонент перерисовывается при каждом set() хранилища.
function use(s) {
	const [ st, setSt ] = lib.useState(s.get());
	lib.useEffect(() => {
		const off = s.on(setSt);
		setSt(s.get());   // set() между отрисовкой и подпиской не теряется
		return off;
	}, [ s ]);
	return st;
}

// Текущий режим страницы — его слушают графики: цвета uPlot рисуются на холсте, CSS их не перекрасит.
const scheme = store({ scheme: 'light' });

// Опрос службы: ошибка не стирает данные — страница показывает последние и значок «нет связи».
// Пустой ответ (на «Правилах» lists и status приходят не на каждом шаге) ничего не меняет — без
// оповещения: иначе страница перерисовывалась бы на каждом шаге опроса.
function pollStore(s, fetchFn, interval) {
	poll.add(() => fetchFn().then(
		(patch) => {
			if (Object.keys(patch || {}).length || s.get().offline !== false)
				s.set(Object.assign({}, patch, { offline: false }));
		},
		() => s.set({ offline: true })), interval);
}

// ---- Изменения UCI ----
// Элементы управления пишут конфигурацию в браузере, как прежние переключатели «Обзора»; сохраняет и
// применяет её «Сохранить и применить» LuCI (с откатом). changes — сколько изменений ещё не сохранено.

function changeCount() {
	const st = uci.state || {};
	let n = 0;
	for (let c in st.creates || {})
		n += Object.keys(st.creates[c]).length;
	for (let c in st.changes || {})
		for (let s in st.changes[c])
			n += Object.keys(st.changes[c][s]).length;
	for (let c in st.deletes || {})
		for (let s in st.deletes[c])
			n += (st.deletes[c][s] === true) ? 1 : Object.keys(st.deletes[c][s]).length;
	return n + Object.keys(st.reorder || {}).length;
}

// bad — сколько полей страницы сейчас с неверным значением (spec §3.6): в UCI оно не пишется, а
// «Применить» недоступна, пока такие поля есть, — иначе применилось бы прежнее значение незаметно.
const changes = store({ n: 0, bad: 0 });
const badFields = new Set();

// Поле key («конфиг.секция.опция») неверно или снова верно.
function invalid(key, isBad) {
	if (isBad)
		badFields.add(key);
	else
		badFields.delete(key);
	if (changes.get().bad !== badFields.size)
		changes.set({ bad: badFields.size });
}

// Набранное, но ещё не добавленное (адрес в kit.UpstreamList), сохраняется вместе с остальным: handleSave
// страницы вызывает flush() до uci.save(). При уходе из поля оно не добавляется: новая строка сдвинула бы
// страницу под нажатой кнопкой, и клик по «Сохранить и применить» потерялся бы.
const flushers = new Set();

function onFlush(fn) {
	flushers.add(fn);
	return () => flushers.delete(fn);
}

function flush() {
	flushers.forEach((fn) => fn());
}

// Всплывающее сообщение (kit.Toast): id растёт и при том же тексте — второе «Обновление запущено» видно.
const toasts = store({ text: null, id: 0 });

function toast(text) {
	toasts.set({ text, id: toasts.get().id + 1 });
}

// Значение как в сохранённых настройках — не изменение: прежняя правка опции снимается, и A → B → A даёт
// ноль изменений. uci.set записал бы изменение и с тем же значением — панель показала бы его, а точки нет.
const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

function setOpt(config, section, option, value) {
	const st = uci.state || {};
	const saved = st.values?.[config]?.[section];
	if (saved && !st.creates?.[config]?.[section] && st.deletes?.[config]?.[section] !== true && same(saved[option], value)) {
		for (let pend of [ st.changes?.[config], st.deletes?.[config] ]) {
			if (!pend?.[section])
				continue;
			delete pend[section][option];
			if (!Object.keys(pend[section]).length)
				delete pend[section];
		}
	}
	else if (value == null)
		uci.unset(config, section, option);
	else
		uci.set(config, section, option, value);
	changes.set({ n: changeCount() });
}

// Новая секция (устройство с Политикой) — тоже несохранённое изменение.
function addSection(config, type) {
	const sid = uci.add(config, type);
	changes.set({ n: changeCount() });
	return sid;
}

// Удалить секцию (устройство «по правилам», секция с неверным MAC) — тоже несохранённое изменение.
function removeSection(config, sid) {
	uci.remove(config, sid);
	changes.set({ n: changeCount() });
}

// Сохранённая секция, удалённая в браузере, — снова на месте со своими значениями (uci.remove сбросил и её
// правки). Своего вызова у uci нет: снимается пометка удаления.
function restoreSection(config, sid) {
	const d = uci.state?.deletes?.[config];
	if (d?.[sid] === true)
		delete d[sid];
	changes.set({ n: changeCount() });
}

// У секции есть несохранённые изменения: она новая, изменена или удалена (точка «изменено» у строки).
function pending(config, sid) {
	const st = uci.state || {};
	return !!(sid && (st.creates?.[config]?.[sid] || st.changes?.[config]?.[sid] || st.deletes?.[config]?.[sid]));
}

// Повторять fn раз в ms, но следующий вызов — только после ответа на прошлый, как poll LuCI: медленный
// ответ службы не копит вызовы в rpcd, который обслуживает их по одному. Ошибка не останавливает.
// Возвращает stop.
function every(fn, ms) {
	let alive = true, timer = null;
	const run = () => {
		if (!alive)
			return;
		Promise.resolve().then(fn).catch(() => {}).then(() => {
			if (alive)
				timer = setTimeout(run, ms);
		});
	};
	run();
	return () => {
		alive = false;
		clearTimeout(timer);
	};
}

// Опрос внутри компонента (панель устройства): сразу и раз в ms, пока компонент на странице; смена deps
// начинает заново. Ошибка оставляет прежние данные и ставит offline.
function usePoll(fetchFn, ms, deps) {
	const [ st, setSt ] = lib.useState({ data: null, offline: false });
	lib.useEffect(() => {
		let alive = true;
		setSt({ data: null, offline: false });
		const stop = every(() => fetchFn().then((data) => { if (alive) setSt({ data, offline: false }); },
			() => { if (alive) setSt((s) => ({ data: s.data, offline: true })); }), ms);
		return () => {
			alive = false;
			stop();
		};
	}, deps);
	return st;
}

// ---- Страница ----

// Корень страницы — свой Shadow DOM: стили темы LuCI не попадают внутрь, наши — наружу.
function mount(view, Page, props) {
	const host = E('div', { 'class': 'truba-root' });
	const root = host.attachShadow({ mode: 'open' });
	for (let css of styles)
		root.appendChild(E('style', {}, css));
	const wrap = root.appendChild(E('div', { 'class': 'tr', 'data-scheme': schemeFrom([], window.matchMedia(DARK).matches) }));

	const apply = () => {
		if (!host.isConnected)
			return;
		const sch = detect(host);
		wrap.setAttribute('data-scheme', sch);
		if (scheme.get().scheme !== sch)
			scheme.set({ scheme: sch });
	};
	// Фон предков известен, только когда LuCI вставит страницу в документ.
	const first = () => host.isConnected ? apply() : requestAnimationFrame(first);
	requestAnimationFrame(first);
	// Тема или её режим сменились (Bootstrap «авто» меняет data-darkmode по системной настройке).
	const later = () => requestAnimationFrame(apply);
	const mo = new MutationObserver(later);
	for (let el of [ document.documentElement, document.body ])
		mo.observe(el, { attributes: true, attributeFilter: [ 'class', 'style', 'data-darkmode', 'data-theme' ] });
	window.matchMedia(DARK).addEventListener('change', later);

	changes.set({ n: changeCount() });
	lib.render(lib.html`<${Page} ...${props} view=${view} />`, wrap);
	return host;
}

return baseclass.extend({
	load, lib, luminance, schemeFrom, mount, store, use, scheme, changes, changeCount, pending, every, usePoll,
	invalid, toast, toasts, onFlush, flush,
	poll: pollStore,
	set: setOpt,
	add: addSection,
	remove: removeSection,
	restore: restoreSection
});
