// Интерфейс LuCI без стенда: синтаксис JS, полнота русского перевода, каждый вызов truba.* есть в ubus-API
// пакета truba и в ACL, в представлениях нет копий значений службы, зависимость от truba, цвет рукопожатия.
//   node tests/luci/static.mjs           — проверить
//   node tests/luci/static.mjs --pot     — напечатать шаблон .pot (po/templates/truba.pot)
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../router/luci-app-truba/', import.meta.url));
// Закреплённые копии библиотек (ES-модули): не модули LuCI и не наш код — их сверяет блок «lib» ниже.
const libDir = join(root, 'htdocs/luci-static/resources/truba/lib');
const files = [];
const rel = (f) => relative(root, f).split(sep).join('/');
(function walk(d) {
	for (const f of readdirSync(d)) {
		const p = join(d, f);
		if (p === libDir) continue;
		if (statSync(p).isDirectory()) walk(p);
		else if (p.endsWith('.js')) files.push(p);
	}
})(join(root, 'htdocs'));

let fails = 0;
const strings = new Map();

for (const f of files) {
	const src = readFileSync(f, 'utf8');
	try {
		// Представления LuCI возвращают значение с верхнего уровня — компилируем как тело функции.
		new Function(src);
	} catch (e) {
		console.log(`FAIL  синтаксис ${rel(f)}: ${e.message}`);
		fails++;
		continue;
	}
	const re = /_\((['"])((?:\\.|(?!\1).)*)\1\)/g;
	let m;
	while ((m = re.exec(src))) {
		const s = m[2].replace(/\\'/g, "'").replace(/\\"/g, '"');
		if (!strings.has(s)) strings.set(s, rel(f));
	}
}

// Заголовки меню тоже переводятся.
const menu = JSON.parse(readFileSync(join(root, 'root/usr/share/luci/menu.d/luci-app-truba.json'), 'utf8'));
for (const k in menu) if (menu[k].title) strings.set(menu[k].title, 'menu.d');

const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');

if (process.argv.includes('--pot')) {
	console.log('msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8"\n');
	for (const [s, f] of strings) console.log(`#: ${f}\nmsgid "${esc(s)}"\nmsgstr ""\n`);
	process.exit(0);
}

// Закреплённые библиотеки (ADR 0017): каждый файл lib/ записан в VERSIONS, совпадает с sha256 оттуда и
// разбирается как ES-модуль; лицензии лежат рядом. Пакет ставит их как есть (LUCI_MINIFY_JS:=0).
const LICENSES = [ 'htm.txt', 'preact.txt', 'uplot.txt', 'lucide.txt' ];
const versionsFile = join(libDir, 'VERSIONS');
if (!existsSync(versionsFile)) {
	console.log('FAIL  lib/VERSIONS: нет файла');
	fails++;
} else {
	const listed = new Set();
	for (const line of readFileSync(versionsFile, 'utf8').split('\n')) {
		if (!line.trim() || line.startsWith('#'))
			continue;
		const [ file, pkg, path, sum ] = line.trim().split(/\s+/);
		listed.add(file);
		const p = join(libDir, file);
		if (!existsSync(p)) { console.log(`FAIL  lib/${file}: нет файла (${pkg} ${path})`); fails++; continue; }
		const got = createHash('sha256').update(readFileSync(p)).digest('hex');
		if (got !== sum) { console.log(`FAIL  lib/${file}: sha256 ${got}, в VERSIONS ${sum || '—'}`); fails++; }
		if (file.endsWith('.js')) {
			// node --check разбирает ES-модуль только по расширению .mjs.
			const tmp = mkdtempSync(join(tmpdir(), 'truba-'));
			writeFileSync(join(tmp, 'm.mjs'), readFileSync(p));
			const r = spawnSync(process.execPath, [ '--check', join(tmp, 'm.mjs') ], { encoding: 'utf8' });
			rmSync(tmp, { recursive: true, force: true });
			if (r.status !== 0) { console.log(`FAIL  lib/${file}: не разбирается как ES-модуль: ${r.stderr.split('\n').find((x) => x.trim()) || r.status}`); fails++; }
		}
	}
	for (const f of readdirSync(libDir))
		if (f !== 'VERSIONS' && f !== 'LICENSES' && !listed.has(f)) { console.log(`FAIL  lib/${f}: нет в VERSIONS`); fails++; }
	for (const l of LICENSES)
		if (!existsSync(join(libDir, 'LICENSES', l))) { console.log(`FAIL  lib/LICENSES/${l}: нет файла`); fails++; }
}

// Вызовы ubus из интерфейса: каждый метод truba есть в rpcd-плагине и в ACL. Иначе LuCI
// получает «Access denied» или «Method not found» — и только на живом Роутере.
const acl = JSON.parse(readFileSync(join(root, 'root/usr/share/rpcd/acl.d/luci-app-truba.json'), 'utf8'))['luci-app-truba'];
const allowed = new Set([ ...(acl.read?.ubus?.truba || []), ...(acl.write?.ubus?.truba || []) ]);
// ubus-API — в пакете truba (ADR 0008), ACL — в luci-app-truba.
const plugin = readFileSync(join(root, '../truba/files/usr/share/rpcd/ucode/truba-api.uc'), 'utf8');
const provided = new Set([ ...plugin.matchAll(/^\t(\w+): \{$/gm) ].map((m) => m[1]));
// rpcd-плагин — тонкий (ADR 0008): проверяет аргументы и зовёт команду truba, логика — в ней.
const pluginImports = [ ...plugin.matchAll(/^import .* from '([^']+)';$/gm) ].map((m) => m[1]);
if (!pluginImports.length || !pluginImports.every((m) => [ 'fs', 'truba.const', 'truba.util' ].includes(m))) {
	console.log(`FAIL  truba-api.uc: импорты только fs, truba.const и truba.util, а не ${pluginImports.join(', ')}`);
	fails++;
}
for (const f of files) {
	for (const m of readFileSync(f, 'utf8').matchAll(/object: 'truba', method: '(\w+)'/g)) {
		if (!provided.has(m[1])) { console.log(`FAIL  метода truba.${m[1]} нет в rpcd-плагине (${rel(f)})`); fails++; }
		if (!allowed.has(m[1])) { console.log(`FAIL  метода truba.${m[1]} нет в ACL (${rel(f)})`); fails++; }
	}
}

// Умолчания, пределы, имена и схемы адресов DNS интерфейс берёт у службы (truba.schema, ADR 0015):
// своих копий в представлениях нет — разошлись бы с conf.uc, как прежде порог рукопожатия.
const COPIES = [
	[ /placeholder = '\d/, 'числовая подсказка' ],
	[ /datatype = '(range|or\(range)\(/, 'пределы range(…)' ],
	[ /\|\| '(awg0|lan)'/, 'умолчание awg0/lan' ],
	[ /default = 'lan'/, 'умолчание lan' ],
	[ /== 'truba'/, 'имя зоны truba' ],
	[ /UPSTREAM_SCHEMES = \[/, 'схемы адресов DNS' ],
];
// Строки с пометкой «// опция network» — поля интерфейса AmneziaWG: это не настройки Трубы.
for (const f of files.filter((f) => rel(f).includes('/view/truba/'))) {
	readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
		if (line.includes('// опция network'))
			return;
		for (const [ re, what ] of COPIES)
			if (re.test(line)) { console.log(`FAIL  ${rel(f)}:${i + 1}: копия значения службы — ${what}`); fails++; }
	});
}

// Шаг и срок поминутной истории устройств — из схемы (consts.devices), а не числами в представлении.
const devView = join(root, 'htdocs/luci-static/resources/view/truba/devices.js');
if (existsSync(devView) && /\b3600\b|, 60\)/.test(readFileSync(devView, 'utf8'))) {
	console.log('FAIL  view/truba/devices.js: копия сроков истории устройств (3600, 60) — они в truba.schema consts.devices');
	fails++;
}

// Интерфейс вызывает truba.schema, которой нет в службе до 1.1.0-r7: с более старой truba страницы не строятся.
// Нижняя граница зависимости — не ниже неё и не выше версии truba из этого же репозитория.
const SCHEMA_SINCE = '1.1.0-r7';
const ver = (v) => v.split(/[.-]r?/).map(Number);
const cmpVer = (a, b) => { const x = ver(a), y = ver(b); for (let i = 0; i < 4; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; };
const luciMk = readFileSync(join(root, 'Makefile'), 'utf8');
const trubaMk = readFileSync(join(root, '../truba/Makefile'), 'utf8');
const floor = luciMk.match(/LUCI_EXTRA_DEPENDS:=.*truba \(>=([0-9.]+-r\d+)\)/)?.[1];
const trubaVer = `${trubaMk.match(/PKG_VERSION:=(\S+)/)[1]}-r${trubaMk.match(/PKG_RELEASE:=(\S+)/)[1]}`;
if (!floor || cmpVer(floor, SCHEMA_SINCE) < 0 || cmpVer(floor, trubaVer) > 0) {
	console.log(`FAIL  luci-app-truba зависит от truba (>=${floor || '?'}), нужно от ${SCHEMA_SINCE} до ${trubaVer}`);
	fails++;
}

// Цвет возраста рукопожатия на «Туннеле» — по handshake_max и вердикту watchdog, а не по своим порогам.
// common.js выполняется с заглушками LuCI: нужна только чистая функция.
const commonSrc = readFileSync(join(root, 'htdocs/luci-static/resources/truba/common.js'), 'utf8');
const stub = new Proxy(() => stub, { get: (t, k) => (k === 'extend' ? (x) => x : stub) });
let common = {};
try {
	common = new Function('baseclass', 'rpc', 'uci', '_', 'L', 'E', 'document', commonSrc)(
		stub, stub, stub, (s) => s, stub, stub, { querySelector: () => true });
} catch (e) {
	console.log(`FAIL  common.js не выполнился с заглушками: ${e.message}`);
	fails++;
}
// handshakeLevel(возраст, вердикт watchdog или нет его, handshake_max, запас = fails × interval).
for (const [ args, want ] of [
	[ [ null, 'healthy', 180, 90 ], 'err' ],
	[ [ 100, 'healthy', 600, 90 ], 'ok' ],
	[ [ 600, 'down', 600, 90 ], 'ok' ],
	[ [ 700, 'healthy', 600, 90 ], 'warn' ],
	[ [ 700, 'down', 600, 90 ], 'err' ],
	// watchdog выключен (вердикта нет): «внимание» за порогом, ошибка — когда он объявил бы Туннель упавшим
	[ [ 200, undefined, 180, 90 ], 'warn' ],
	[ [ 270, undefined, 180, 90 ], 'warn' ],
	[ [ 271, undefined, 180, 90 ], 'err' ],
	[ [ 7200, undefined, 180, 90 ], 'err' ],
]) {
	const got = common.handshakeLevel?.(...args);
	if (got !== want) { console.log(`FAIL  handshakeLevel(${JSON.stringify(args)}) = ${got}, ждали ${want}`); fails++; }
}

// ---- Модули интерфейса (truba/ui, ADR 0017): чистые функции — в Node с заглушками LuCI ----

const check = (ok, name) => { if (!ok) { console.log(`FAIL  ${name}`); fails++; } };
// Модуль LuCI: строки 'require x as y' — просто выражения, зависимости приходят параметрами функции.
function loadModule(path, deps) {
	try {
		const src = readFileSync(join(root, 'htdocs/luci-static/resources', path), 'utf8');
		return new Function(...Object.keys(deps), src)(...Object.values(deps));
	} catch (e) {
		console.log(`FAIL  ${path} не выполнился с заглушками: ${e.message}`);
		fails++;
		return null;
	}
}
const baseclass = { extend: (x) => x };

// app: тема по яркости фона, хранилище, опрос, счёт изменений UCI.
let pollFn = null;
const uciStub = { state: {}, set() {}, unset() {} };
const app = loadModule('truba/ui/app.js', {
	baseclass, uci: uciStub, poll: { add(fn) { pollFn = fn; } }, L: { resource: (p) => p, env: {} }, _: (s) => s
});
if (app) {
	const near = (a, b) => Math.abs(a - b) < 1e-3;
	check(near(app.luminance('rgb(255, 255, 255)'), 1), 'app.luminance: белый = 1');
	check(app.luminance('rgba(0, 0, 0, 0)') === null && app.luminance('transparent') === null, 'app.luminance: прозрачный — null');
	check(app.schemeFrom([ 'rgba(0, 0, 0, 0)', 'rgb(255, 255, 255)' ], true) === 'light', 'app.schemeFrom: прозрачный предок пропускается');
	check(app.schemeFrom([ 'rgb(169, 169, 169)' ], false) === 'dark', 'app.schemeFrom: порог 0,4 — 169 тёмный');
	check(app.schemeFrom([ 'rgb(170, 170, 170)' ], true) === 'light', 'app.schemeFrom: порог 0,4 — 170 светлый');
	check(app.schemeFrom([ 'rgba(0, 0, 0, 0)' ], true) === 'dark' && app.schemeFrom([], false) === 'light',
		'app.schemeFrom: без фона — по prefers-color-scheme');
	const s = app.store({ a: 1 });
	let seen = null;
	const off = s.on((st) => seen = st.b);
	s.set({ b: 2 });
	check(s.get().a === 1 && seen === 2, 'app.store: set сливает и оповещает');
	off();
	s.set({ b: 3 });
	check(seen === 2, 'app.store: отписка');
	app.poll(s, () => Promise.resolve({ c: 4 }), 5);
	await pollFn?.();
	check(s.get().c === 4 && s.get().offline === false, 'app.poll: успех — данные и offline=false');
	app.poll(s, () => Promise.reject(new Error('rpc')), 5);
	await pollFn?.();
	check(s.get().offline === true && s.get().c === 4, 'app.poll: ошибка — данные остаются, offline=true');
	// Пустой ответ опроса (на «Правилах» lists — раз в 30 с) — без оповещения: страница не перерисовывается зря.
	const quiet = app.store({});
	let quietCalls = 0;
	quiet.on(() => quietCalls++);
	app.poll(quiet, () => Promise.resolve({}), 5);
	await pollFn?.();
	await pollFn?.();
	check(quietCalls === 1 && quiet.get().offline === false, `app.poll: пустой ответ — без оповещения, кроме первого (${quietCalls})`);
	uciStub.state = { creates: {}, changes: { truba: { main: { routing: '0' } }, network: { awg0: { disabled: '1' } } }, deletes: {}, reorder: {} };
	check(app.changeCount() === 2, 'app.changeCount: две изменённые опции');
	uciStub.state = { creates: { truba: { cfg01: {} } }, changes: {}, deletes: { firewall: { r1: true } }, reorder: { truba: true } };
	check(app.changeCount() === 3, 'app.changeCount: новая секция, удалённая секция, порядок');
	// Несохранённое у секции — точка «изменено» у строки устройства.
	uciStub.state = { creates: { truba: { cfg01: {} } }, changes: { truba: { cfg02: { policy: 'direct' } } }, deletes: { truba: { cfg03: true } } };
	check(app.pending?.('truba', 'cfg01') && app.pending('truba', 'cfg02') && app.pending('truba', 'cfg03') &&
		!app.pending('truba', 'cfg04') && !app.pending('truba', null), 'app.pending: новая, изменённая, удалённая секция');
	uciStub.add = (c, t) => { uciStub.state.creates[c].cfg05 = { '.type': t }; return 'cfg05'; };
	check(app.add?.('truba', 'device') === 'cfg05' && app.changes.get().n === app.changeCount(), 'app.add: секция и пересчёт изменений');
	// Возврат к сохранённому значению — не изменение (A → B → A — ноль); секция, удалённая в браузере, — снова на месте.
	uciStub.state = { values: { truba: { main: { '.type': 'main', mode: 'all', zone: [ 'lan' ] }, r1: { '.type': 'rule', action: 'direct' } } },
		creates: {}, changes: { truba: { main: { mode: 'selective' } } }, deletes: { truba: { r1: true } }, reorder: {} };
	const realSet = uciStub.set;
	uciStub.set = (c, sid, o, v) => { ((uciStub.state.changes[c] ??= {})[sid] ??= {})[o] = v; };
	app.set('truba', 'main', 'mode', 'all');
	app.set('truba', 'main', 'zone', [ 'lan' ]);
	check(!uciStub.state.changes.truba?.main && app.changes.get().n === 1, `app.set: прежнее значение — не изменение (${JSON.stringify(uciStub.state.changes)})`);
	app.restore?.('truba', 'r1');
	check(!uciStub.state.deletes.truba?.r1 && app.changes.get().n === 0, 'app.restore: удалённая в браузере секция снова на месте');
	app.set('truba', 'main', 'mode', 'selective');
	check(uciStub.state.changes.truba?.main?.mode === 'selective' && app.changes.get().n === 1, 'app.set: другое значение — изменение');
	uciStub.set = realSet;
	// Неверные поля (spec §3.6): «Применить» недоступна, пока они есть; одно поле считается один раз.
	app.invalid?.('truba.lists.update_utc', true);
	app.invalid?.('truba.lists.update_utc', true);
	const bad1 = app.changes.get().bad;
	app.invalid?.('truba.lists.update_utc', false);
	check(bad1 === 1 && app.changes.get().bad === 0, `app.invalid: неверное поле — bad 1, снова верное — 0 (${bad1}, ${app.changes.get().bad})`);
	app.toast?.('Done');
	const t1 = app.toasts?.get();
	app.toast?.('Done');
	check(t1?.text === 'Done' && app.toasts.get().id > t1.id, 'app.toast: последнее сообщение, повтор того же текста — новое');
	// Опрос внутри компонента: следующий вызов — после ответа на прошлый (медленный connections не копится
	// в rpcd), ошибка не останавливает, stop — останавливает.
	let active = 0, most = 0, calls = 0;
	const stop = app.every?.(() => {
		calls++;
		active++;
		most = Math.max(most, active);
		return new Promise((ok, fail) => setTimeout(() => { active--; (calls % 2 ? ok : fail)(new Error('rpc')); }, 30));
	}, 5);
	await new Promise((r) => setTimeout(r, 150));
	stop?.();
	const after = calls;
	await new Promise((r) => setTimeout(r, 80));
	check(stop && most === 1 && calls >= 3 && calls === after, `app.every: вызовы не накладываются, ошибка не останавливает, stop — останавливает (${calls}, ${most})`);
}

// kit: стрелки в группе сегментов — по кругу.
const kit = app && loadModule('truba/ui/kit.js', { baseclass, common: {}, app, icons: {} });
if (kit) {
	const it = [ [ 'rules', 'R' ], [ 'tunnel', 'T' ], [ 'direct', 'D' ] ];
	check(kit.step?.(it, 'direct', 'ArrowRight') === 'rules' && kit.step(it, 'rules', 'ArrowLeft') === 'direct' &&
		kit.step(it, 'rules', 'ArrowRight') === 'tunnel' && kit.step(it, 'tunnel', 'Enter') === 'tunnel', 'kit.step: → и ← по кругу, другие клавиши — без смены');
}

// Стиль A (spec §4.1): цвета Действий и состояний читаются на карточке (контраст не ниже 3:1), текст —
// не ниже 4,5:1, в светлом и тёмном наборе. Токены — в блоках «.tr {» и «.tr[data-scheme="dark"] {».
const stylePath = join(root, 'htdocs/luci-static/resources/truba/ui/style.css');
if (!existsSync(stylePath)) {
	console.log('FAIL  truba/ui/style.css: нет файла');
	fails++;
} else if (app) {
	const css = readFileSync(stylePath, 'utf8');
	const hex = (h) => `rgb(${parseInt(h.slice(1, 3), 16)}, ${parseInt(h.slice(3, 5), 16)}, ${parseInt(h.slice(5, 7), 16)})`;
	for (const [ name, sel ] of [ [ 'светлый', '.tr {' ], [ 'тёмный', '.tr[data-scheme="dark"] {' ] ]) {
		const at = css.indexOf(sel);
		const block = at < 0 ? '' : css.slice(at, css.indexOf('}', at));
		const tok = Object.fromEntries([ ...block.matchAll(/(--[\w-]+):\s*(#[0-9a-fA-F]{6})\b/g) ].map((m) => [ m[1], m[2] ]));
		const ratio = (a, b) => {
			const [ x, y ] = [ app.luminance(hex(a)), app.luminance(hex(b)) ].sort((p, q) => q - p);
			return (x + 0.05) / (y + 0.05);
		};
		// Нажатое Действие (ActionPicker): подложка — цвет Действия, смешанный с --card, текст — --tx, не ниже 4,5:1.
		const pick = css.match(/color-mix\(in srgb, var\(--a\) (\d+)%, var\(--card\)\); color: var\(--tx\)/);
		if (!pick) { console.log(`FAIL  style.css (${name}): нажатое Действие — не «color-mix(in srgb, var(--a) N%, var(--card)); color: var(--tx)»`); fails++; }
		else for (const t of [ '--tun', '--dir', '--blk' ]) {
			const p = +pick[1] / 100, ch = (h, i) => parseInt(h.slice(1 + 2 * i, 3 + 2 * i), 16);
			const mix = '#' + [ 0, 1, 2 ].map((i) => Math.round(ch(tok[t], i) * p + ch(tok['--card'], i) * (1 - p)).toString(16).padStart(2, '0')).join('');
			const r = ratio(tok['--tx'], mix);
			check(r >= 4.5, `style.css (${name}): нажатое Действие ${t} — текст --tx на ${mix} = ${r.toFixed(2)}, нужно ≥ 4,5`);
		}
		for (const [ list, min ] of [ [ [ '--tun', '--dir', '--blk', '--inb', '--warn' ], 3 ], [ [ '--tx', '--mu' ], 4.5 ] ])
			for (const t of list) {
				if (!tok[t] || !tok['--card']) { console.log(`FAIL  style.css (${name}): нет ${t} или --card`); fails++; continue; }
				const r = ratio(tok[t], tok['--card']);
				check(r >= min, `style.css (${name}): контраст ${t} ${tok[t]} к --card ${tok['--card']} = ${r.toFixed(2)}, нужно ≥ ${min}`);
			}
	}
}

// Иконки Lucide: у каждой, что берут компоненты, есть разметка.
const icons = loadModule('truba/ui/icons.js', { baseclass });
if (icons)
	for (const n of [ 'circle-check', 'triangle-alert', 'circle-x', 'arrow-right', 'wifi-off', 'pencil', 'file-up', 'download', 'x', 'plus' ])
		check(typeof icons[n] === 'string' && /<(path|circle|line|polyline|rect)/.test(icons[n]), `icons.js: иконка ${n}`);

// Верх шкалы графика скорости и толщина веток схемы потоков.
const chart = loadModule('truba/ui/chart.js', { baseclass, app, common });
if (chart) {
	check(chart.scaleTop(0) === 125000, 'chart.scaleTop: не меньше 1 Мбит/с');
	check(chart.scaleTop(130000) === 250000, 'chart.scaleTop: 1,04 Мбит/с → 2');
	check(chart.scaleTop(600000) === 625000, 'chart.scaleTop: 4,8 Мбит/с → 5');
	check(chart.scaleTop(1.3e6) === 2.5e6, 'chart.scaleTop: 10,4 Мбит/с → 20');
	// Перерыв в записи (служба стояла) — разрыв линии, а не прямая через него: в поминутных средних
	// отметки разрыва нет, есть только пропуск по времени.
	const g = chart.gaps?.([ [ 0, 1 ], [ 5, 2 ], [ 100, 3 ] ], 5);
	check(JSON.stringify(g) === '[[0,1],[5,2],[10],[100,3]]', 'chart.gaps: пропуск дольше трёх шагов — строка-разрыв', JSON.stringify(g));
	check(JSON.stringify(chart.gaps?.([ [ 0, 1 ], [ 5, 2 ], [ 15, 3 ] ], 5)) === '[[0,1],[5,2],[15,3]]', 'chart.gaps: три шага — без разрыва');
	check(JSON.stringify(chart.gaps?.([], 5)) === '[]', 'chart.gaps: пустая история');
}
const flow = loadModule('truba/ui/flow.js', { baseclass, app, common });
if (flow) {
	check(flow.width(null, 1) === 0 && flow.width(0, 1) === 0, 'flow.width: нет трафика — 0');
	check(flow.width(100, 100) === 14 && flow.width(400, 100) === 14, 'flow.width: потолок 14');
	check(flow.width(25, 100) === 8, 'flow.width: корень доли');
}

// Устройства (common): Политика — как её поймёт служба, по настройкам браузера; MAC без учёта регистра
// (прежняя таблица «Маршрутизации» сохраняла заглавными); первая из секций с одним MAC.
const devSecs = [
	{ '.name': 'd1', '.type': 'device', mac: 'AA:BB:CC:DD:EE:01', policy: 'direct' },
	{ '.name': 'd2', '.type': 'device', mac: 'aa:bb:cc:dd:ee:02', policy: 'tunnel', enabled: '0' },
	{ '.name': 'd3', '.type': 'device', mac: 'aa:bb:cc:dd:ee:03' },
	{ '.name': 'd4', '.type': 'device', mac: 'aa:bb:cc:dd:ee:04', policy: 'weird' },
	{ '.name': 'd5', '.type': 'device', mac: 'aa:bb:cc:dd:ee:01', policy: 'tunnel' },
	// Правила Категорий — как их читает служба (conf.uc): без mode и с незнакомым — «all», неизвестное Действие
	// пропускается, из нескольких секций одного ключа действует последняя.
	{ '.name': 'r1', '.type': 'rule', set: 'geosite', tag: 'youtube', action: 'tunnel' },
	{ '.name': 'r2', '.type': 'rule', mode: 'all', set: 'geosite', tag: 'YouTube', action: 'direct' },
	{ '.name': 'r3', '.type': 'rule', mode: 'all', set: 'geosite', tag: 'youtube', action: 'weird' },
	{ '.name': 'r4', '.type': 'rule', mode: 'selective', set: 'geoip', tag: 'ru', action: 'weird' },
	{ '.name': 'r5', '.type': 'rule', mode: 'selective', set: 'geosite', tag: 'openai', action: 'tunnel' },
	{ '.name': 'r6', '.type': 'rule', mode: 'odd', set: 'geoip', tag: 'private', action: 'block' },
	{ '.name': 'r7', '.type': 'rule', tag: 'x', action: 'tunnel' },
	{ '.name': 'r8', '.type': 'rule', set: 'geoip', action: 'block' },
	// Пробросы «Входящих»: секции firewall и network (поле '.conf'; без него — truba). fw2 — из другой зоны,
	// fw3 — выключен и без протокола (умолчание fw4 — tcp udp).
	{ '.name': 'fw1', '.type': 'redirect', '.conf': 'firewall', src: 'truba', name: 'web', proto: 'tcp', src_dport: '8000-8100', dest_ip: '192.168.1.10', dest_port: '80' },
	{ '.name': 'fw2', '.type': 'redirect', '.conf': 'firewall', src: 'wan', src_dport: '22' },
	{ '.name': 'fw3', '.type': 'redirect', '.conf': 'firewall', src: 'truba', src_dport: '9000', dest_ip: '192.168.1.11', enabled: '0' },
	{ '.name': 'z1', '.type': 'zone', '.conf': 'firewall', name: 'lan', network: [ 'lan' ] },
	{ '.name': 'lan', '.type': 'interface', '.conf': 'network', proto: 'static', ipaddr: '192.168.1.1', netmask: '255.255.255.0' },
];
const devSchema = { sections: {
	device: { enabled: { type: 'bool', def: true }, policy: { type: 'enum', values: [ 'tunnel', 'direct', 'rules' ], def: 'tunnel' } },
	lists: { update_utc: { type: 'pattern', re: '^([01]?[0-9]|2[0-3]):[0-5][0-9]$', def: '12:00' }, geoip_url: { type: 'string', def: 'https://x' } },
	dns: { set_timeout: { type: 'int', def: 86400, lo: 0, hi: 604800, min: 600 } },
	watchdog: { probe: { type: 'ipv4', def: '' } }
}, upstream_schemes: [ 'udp', 'tcp', 'tcp+pipeline', 'tls', 'tls+pipeline', 'https', 'h3', 'quic', 'doq' ], consts: { fw_zone: 'truba' } };
// String.prototype.format задаёт luci.js; в Node — замена для текстов ошибок полей и времени строк журнала (%02d).
String.prototype.format ??= function(...a) {
	let i = 0;
	return this.replace(/%(0\d+)?([sd%])/g, (m, w, t) => (t == '%') ? '%' : w ? String(a[i++]).padStart(+w, '0') : String(a[i++]));
};
let cdev = null;
try {
	cdev = new Function('baseclass', 'rpc', 'uci', '_', 'L', 'E', 'document', commonSrc)(
		baseclass, { declare: (o) => () => Promise.resolve(o.method == 'schema' ? devSchema : {}) },
		{ sections: (c, t) => devSecs.filter((s) => (s['.conf'] || 'truba') == c && s['.type'] == t),
			get: (c, sid, o) => devSecs.find((s) => (s['.conf'] || 'truba') == c && s['.name'] == sid)?.[o] },
		(s) => s, new Proxy(stub, { get: (t, k) => (k === 'toArray') ? (x) => (x == null) ? [] : Array.isArray(x) ? x : String(x).split(/\s+/) : stub }),
		stub, { querySelector: () => true });
	await cdev.loadSchema();
} catch (e) {
	console.log(`FAIL  common.js с заглушкой uci: ${e.message}`);
	fails++;
}
if (cdev) {
	const P = (m) => cdev.devicePolicy?.(m);
	check(P('aa:bb:cc:dd:ee:01') === 'direct' && cdev.deviceSection('AA:BB:CC:DD:EE:01') === 'd1',
		'common.devicePolicy: MAC заглавными в секции, первая из двух с одним MAC');
	check(P('aa:bb:cc:dd:ee:02') === 'rules' && P('aa:bb:cc:dd:ee:03') === 'tunnel' && P('aa:bb:cc:dd:ee:04') === 'rules',
		'common.devicePolicy: выключенная — «по правилам», без Политики — умолчание схемы, незнакомая — «по правилам»');
	check(P('aa:bb:cc:dd:ee:99') === 'rules' && P(null) === 'rules' && cdev.deviceSection(null) === null, 'common.devicePolicy: нет секции или MAC — «по правилам»');
	check(cdev.normMac?.('AA-BB-CC-DD-EE-FF') === 'aa:bb:cc:dd:ee:ff' && cdev.normMac('zz') === null && cdev.normMac('') === null,
		'common.normMac: дефисы и регистр, не MAC — null');
	check(JSON.stringify(cdev.devRate?.({ rate: [ 1, 2, 3, 4, 5, 6 ] })) === '[9,12]' && cdev.devRate({ rate: null }) === null,
		'common.devRate: к устройству и от него по всем Действиям');
	check(JSON.stringify(cdev.devShare?.({ minutes: [ [ 60, 9, 9, 9, 9 ], [ 120, 1, 2, 3, 4 ] ], rate: [ 50, 50, 0, 0, 0, 0 ] }, 150)) === '[3,7]' &&
		JSON.stringify(cdev.devShare({ minutes: [], rate: [ 1, 2, 3, 4, 5, 6 ] }, 150)) === '[3,7]' && JSON.stringify(cdev.devShare({}, 150)) === '[0,0]',
		'common.devShare: Туннель и Напрямую за последнюю минуту, без неё — сейчас');
	// Минуты без трафика служба не пишет: последняя точка может быть старой — тогда по скорости сейчас.
	check(JSON.stringify(cdev.devShare({ minutes: [ [ 120, 1, 2, 3, 4 ] ], rate: [ 50, 50, 0, 0, 0, 0 ] }, 1000)) === '[100,0]',
		'common.devShare: старая минута — не последняя, доля по скорости сейчас');
	check(JSON.stringify(cdev.deviceSections?.('aa:bb:cc:dd:ee:01')) === '["d1","d5"]', 'common.deviceSections: все секции MAC, первая — первой');
	// «Куда ходит сейчас»: причина «решено до смены настроек» и Политика устройства важнее тега geoip —
	// иначе «geoip ru · Туннель» противоречил бы Действию Категории ru.
	const CL = (a) => cdev.connLabel?.(a);
	check(CL({ reason: 'changed', geoip: [ 'ru' ] }) === cdev.REASON_LABELS.changed && CL({ reason: 'device', geoip: [ 'ru' ] }) === cdev.REASON_LABELS.device &&
		CL({ reason: 'geoip', geoip: [ 'ru', 'private' ] }) === 'geoip ru, private' && CL({ reason: 'mode', geoip: [] }) === cdev.REASON_LABELS.mode &&
		CL({ reason: null, geoip: [], proto: 'tcp', port: 443 }) === 'tcp/443' && CL({ reason: null, geoip: [], proto: 'icmp', port: null }) === 'icmp',
		'common.connLabel: changed и device — раньше geoip, без причины — протокол и порт');
	check(cdev.devActive?.({ last: 700 }, 1000) === true && cdev.devActive({ last: 699 }, 1000) === false && cdev.devActive({ last: null }, 1000) === false,
		'common.devActive: трафик за 5 минут');

	// «DNS»: адрес сервера — та же проверка, что upstream_ok службы (случаи — из tests/unit/units.uc).
	const UE = (u) => cdev.upstreamError?.(u);
	check([ 'https://1.1.1.1/dns-query', 'tls://dns.example@1.2.3.4', 'tls+pipeline://dns.example@1.2.3.4', '1.1.1.1',
		'udp://[2001:db8::1]:53', '' ].every((u) => UE(u) === null), 'common.upstreamError: верные адреса — как upstream_ok');
	check([ 'htps://1.1.1.1/dns-query', '1.1.1.1/dns-query', 'udp://a b', 'https://x/y@' ].every((u) => /Expected https:/.test(UE(u) || '')),
		'common.upstreamError: опечатка в схеме, путь без схемы, пробел — ошибка');
	// Плитки состояния mosdns: без данных — «—», а не NaN% или 0%.
	const DS = (st) => cdev.dnsStats?.(st) || { tiles: [] }, vals = (s) => s.tiles.map((t) => t[1]).join(' ');
	check(DS({ routing: false }).level === '' && vals(DS({ routing: false })) === '— — — —', 'common.dnsStats: маршрутизация выкл — «—»');
	check(DS({ routing: true, mosdns: false }).level === 'err' && vals(DS({ routing: true, mosdns: false })) === '— — — —', 'common.dnsStats: mosdns остановлен');
	check(DS({ routing: true, mosdns: true, dns_cache: null }).note === 'mosdns does not report statistics', 'common.dnsStats: нет статистики');
	const dz = DS({ routing: true, mosdns: true, dns_cache: { query: 0, hit: 0, lazy_hit: 0, size: 0, max: 65536 } });
	check(vals(dz) === '— — 0% 0' && dz.note === 'no queries yet', `common.dnsStats: запросов ещё нет (${vals(dz)})`);
	const dn = DS({ routing: true, mosdns: true, dns_cache: { query: 200, hit: 150, lazy_hit: 10, size: 70000, max: 65536 } });
	check(dn.level === 'ok' && vals(dn) === '75% 5% 100% 200' && dn.note === null, `common.dnsStats: доли, заполнение не больше 100 % (${vals(dn)})`);

	// «Входящие»: итог «Проверки NAT» — без проверки и при ошибке «—», а не undefined:NaN.
	const NS = (n, w) => cdev.natSummary?.(n, w) || { rows: [], servers: [] };
	const nsVals = (s) => s.rows.map((r) => r[1]).join('|');
	check(NS(null, true).text === 'not run yet' && nsVals(NS(null, true)) === '—|—|—|—' && NS(null, true).when === 'runs by itself after the tunnel comes up' &&
		NS(null, false).when === 'never', 'common.natSummary: ещё не запускалась — «—»');
	const nd = NS({ time: 1, error: 'tunnel_down', servers: [] }, true);
	check(nd.level === 'warn' && nd.text === 'not checked: ' + cdev.NAT_ERRORS.tunnel_down && nsVals(nd) === '—|—|—|—', 'common.natSummary: Туннель лежит — warn');
	check(NS({ time: 1, error: 'weird' }, true).level === 'err' && /weird/.test(NS({ time: 1, error: 'weird' }, true).text), 'common.natSummary: незнакомая ошибка — как есть');
	const nok = NS({ time: 1, ok: true, external_ip: '203.0.113.5', external_port: 40000, ip_is_vps: true, port_preserved: true, consistent: null,
		servers: [ { server: 's1:3478', mapped: { address: '203.0.113.5', port: 40000 }, rtt: 12 }, { server: 's2:3478', error: 'timeout' } ] }, true);
	check(nok.level === 'ok' && nsVals(nok) === '203.0.113.5:40000|yes|yes|nothing to compare: one server answered' && nok.servers.length === 2 &&
		/s2:3478 — no answer/.test(nok.servers[1]), `common.natSummary: успех, один сервер (${nsVals(nok)})`);
	// UPnP: не установлен, не работает, выключен; отображения — с именем устройства.
	const US = (u) => cdev.upnpState?.(u) || {};
	check(US({ enabled: true, installed: false }).installed === false && US({ enabled: true, installed: false }).note === cdev.UPNP_MISSING &&
		/not running/.test(US({ enabled: true, installed: true, running: false }).note) && US({ enabled: false, installed: true }).note === null,
		'common.upnpState: не установлен, не работает, выключен');
	const ur = cdev.upnpRows?.([ { proto: 'UDP', ext_port: 27036, ip: '192.168.1.50', port: 27036, expires: 0, descr: 'Steam' },
		{ proto: 'TCP', ext_port: 51413, ip: '192.168.1.9', port: 51413, expires: 0, descr: '' } ], [ { ip: '192.168.1.50', name: 'pc' } ]) || [];
	check(ur.length === 2 && ur[0].who === 'pc' && ur[1].who === '192.168.1.9' && ur[1].descr === '—' && ur[0].expires === 'no expiry',
		'common.upnpRows: имя устройства по IP, без описания — «—»');
	// Пробросы из Туннеля: только зона Туннеля; проверка формы; зона назначения; значения секции.
	const FR = cdev.forwardRows?.([ { ip: '192.168.1.10', name: 'nas' } ]) || [];
	check(FR.length === 2 && FR[0].who === 'nas' && FR[0].proto === 'tcp' && FR[1].proto === 'tcp udp' && FR[1].on === false && FR[1].port === '9000',
		'common.forwardRows: только из зоны Туннеля, имя устройства, протокол по умолчанию, выключенный');
	const PE = (v, o) => cdev.portError?.(v, o);
	check([ '1', '65535', '8000-8100' ].every((v) => PE(v) === null) && PE('', true) === null &&
		[ '', '0', '65536', '100-50', 'a', '1-2-3' ].every((v) => /1–65535/.test(PE(v) || '')), 'common.portError: порт и диапазон 1–65535');
	const FE2 = (f) => cdev.forwardErrors?.({ sid: null, name: '', proto: 'tcp', ext: '', ip: '', port: '', ...f }) || {};
	check(/already forwarded/.test(FE2({ ext: '8050', ip: '192.168.1.20' }).ext || '') && !FE2({ ext: '8050', proto: 'udp', ip: '192.168.1.20' }).ext &&
		!FE2({ ext: '9000', ip: '192.168.1.20' }).ext && !FE2({ sid: 'fw1', ext: '8050', ip: '192.168.1.10' }).ext,
		'common.forwardErrors: пересечение портов при общем протоколе; выключенный и свой — не в счёт');
	check(/IPv4/.test(FE2({ ext: '1', ip: '1.2.3' }).ip || '') && /1–65535/.test(FE2({ ext: '1', ip: '192.168.1.5', port: '0' }).port || ''),
		'common.forwardErrors: IP и внутренний порт');
	const ZO = (ip, d) => cdev.zoneOfIp?.(ip, d || []);
	check(ZO('192.168.1.77') === 'lan' && ZO('10.9.9.9') === null && ZO('100.64.0.9', [ { ip: '100.64.0.9', zone: 'mesh' } ]) === 'mesh',
		'common.zoneOfIp: устройство, сеть со статическим адресом, неизвестно — null');
	const FV = cdev.forwardValues?.({ name: '', proto: 'tcp udp', ext: '25565', ip: '10.9.9.9', port: '' }) || {};
	check(FV.name === null && FV.proto === 'tcp udp' && FV.src_dport === '25565' && FV.dest_port === null && FV.dest === null && FV.dest_ip === '10.9.9.9',
		'common.forwardValues: пустое — null, без зоны — без dest');

	// «Правила»: Действие Категории — как его поймёт служба, по настройкам браузера.
	const RA = (...a) => cdev.ruleAction?.(...a);
	check(RA('all', 'geosite', 'youtube') === 'direct', `common.ruleAction: тег без учёта регистра, последняя верная из секций одного ключа (${RA('all', 'geosite', 'youtube')})`);
	check(RA('selective', 'geoip', 'ru') === 'mode' && RA('all', 'geoip', 'ru') === 'mode', 'common.ruleAction: неизвестное Действие и нет секции — «По режиму»');
	check(RA('selective', 'geosite', 'openai') === 'tunnel' && RA('all', 'geosite', 'openai') === 'mode', 'common.ruleAction: правило — только своего Режима');
	check(RA('all', 'geoip', 'private') === 'block', 'common.ruleAction: незнакомый mode — «all», как у службы');
	check(JSON.stringify(cdev.ruleSections?.('selective').map((s) => s['.name'])) === '["r4","r5"]' &&
		JSON.stringify(cdev.ruleSections('all').map((s) => s['.name'])) === '["r1","r2","r3","r6"]', 'common.ruleSections: секции Режима, без mode — «all», без set или tag — пропущены');
	check(cdev.ruleKey?.({ set: 'geoip', tag: 'RU' }) === 'geoip:ru' && cdev.ruleKey({ set: 'odd', tag: 'A' }) === 'geosite:a',
		'common.ruleKey: «набор:тег» как у службы');
	const RAS = cdev.ruleActions?.('all');
	check(RAS instanceof Map && RAS.size === 2 && RAS.get('geosite:youtube') === 'direct' && RAS.get('geoip:private') === 'block',
		'common.ruleActions: Действия Режима одним проходом — как ruleAction', RAS && JSON.stringify([ ...RAS ]));

	// Поле по схеме: текст ошибки или null — та же проверка, что у службы (conf.uc, check_value).
	const FE = (...a) => cdev.fieldError?.(...a);
	const isText = (x) => typeof x === 'string' && x.length > 0;
	check(isText(FE('lists', 'update_utc', '25:00')) && FE('lists', 'update_utc', '05:30') === null && FE('lists', 'update_utc', '') === null,
		'common.fieldError: pattern — 25:00 неверно, 05:30 и пусто — верно');
	check(isText(FE('dns', 'set_timeout', '300')) && isText(FE('dns', 'set_timeout', '604801')) && isText(FE('dns', 'set_timeout', '1e3')) &&
		FE('dns', 'set_timeout', '0') === null && FE('dns', 'set_timeout', '600') === null, 'common.fieldError: int — пределы и min, 0 — верно');
	check(isText(FE('watchdog', 'probe', '1.2.3')) && isText(FE('watchdog', 'probe', '1.2.3.256')) && FE('watchdog', 'probe', '10.0.0.1') === null,
		'common.fieldError: ipv4');
	check(isText(FE('device', 'policy', 'weird')) && FE('device', 'policy', 'direct') === null && FE('lists', 'geoip_url', 'anything') === null &&
		FE('lists', 'nope', 'x') === null, 'common.fieldError: enum; string и опция не из схемы — без проверки');

	// Опрос Наборов правил: раз в 30 с, а пока идёт обновление или применение и 15 с после «Обновить сейчас» — каждый раз.
	const LD = (...a) => cdev.listsDue?.(...a);
	check(LD(30000, 0, -Infinity, {}) === true && LD(29999, 0, -Infinity, {}) === false, 'common.listsDue: граница 30 с');
	check(LD(1000, 0, -Infinity, { updating: true }) === true && LD(1000, 0, -Infinity, { applying: true }) === true && LD(1000, 0, -Infinity, null) === false,
		'common.listsDue: обновление или применение — сразу');
	check(LD(20000, 15000, 10000, {}) === true && LD(30000, 15000, 10000, {}) === false, 'common.listsDue: 15 с после запуска обновления — сразу');

	// Вкладки: «Правила» вместо «Маршрутизации», «DNS» без списков (spec §3.1).
	const IT = (k) => cdev.invalidTab([ { key: k } ]);
	check(IT('main.zone') === 'rules' && IT('main.mode') === 'rules' && IT('main.routing') === 'rules' && IT('lists.update_utc') === 'rules' &&
		IT('rule.x') === 'rules' && IT('main.iface') === 'tunnel' && IT('dns.port') === 'dns' && IT('device.mac') === 'devices' && cdev.invalidTab([]) === 'rules',
		'common.invalidTab: Режим, Зоны, Маршрутизация, Наборы правил и правила — «Правила»');
	check(cdev.TABS.rules && !('routing' in cdev.TABS) && cdev.TABS.dns === 'DNS' &&
		[ 'lists_missing', 'zones_without_devices', 'lists_rolled_back' ].every((w) => cdev.WARNINGS[w].tab === 'rules') && cdev.WARNINGS.tunnel_not_configured.tab === 'tunnel',
		'common.TABS и WARNINGS: «Правила» вместо «Маршрутизации» и Наборов правил на «DNS»');
	check(isText(cdev.CHECK_ERRORS?.busy), 'common.CHECK_ERRORS.busy');
	// Категории перечитываются с опросом lists: распаковка или нет списка, обновление или применение на прошлом
	// опросе, сменились файлы Наборов (обновление по расписанию, откат).
	const L1 = { geoip: { sha256: 'a' }, geosite: { sha256: 'b' } }, CD = (...a) => cdev.catsDue?.(...a);
	check(CD({ cats: [ 1 ] }, L1, L1) === false && CD({ cats: [ 1 ], busy: true }, L1, L1) === true && CD({ cats: [] }, L1, L1) === true &&
		CD({ cats: [ 1 ] }, { ...L1, applying: true }, L1) === true && CD({ cats: [ 1 ] }, { ...L1, updating: true }, L1) === true &&
		CD({ cats: [ 1 ] }, L1, { ...L1, geoip: { sha256: 'c' } }) === true, 'common.catsDue: когда перечитывать Категории');
	const CE = (r) => cdev.checkErrorText?.(r);
	check(isText(CE({ error: 'busy' })) && CE({ error: 'busy' }).includes(cdev.CHECK_ERRORS.busy) && /Access denied/.test(CE({ error: 'rpc', message: 'Access denied' }) || '') &&
		CE({}) === 'The check failed.', 'common.checkErrorText: занято, ошибка RPC с текстом, без ответа');

	// Строки Категорий: около 1 700 — сразу не больше 100 (Решение 3); поиск, чип, «Показать все».
	const many = Array.from({ length: 1700 }, (_, i) => ({ set: 'geosite', tag: 'c' + i }));
	const actOf = (c) => (+c.tag.slice(1) % 17 == 0) ? 'tunnel' : 'mode';
	const CR = (...a) => cdev.catRows?.(many, actOf, ...a);
	const r1 = CR('', 'all', false), r2 = CR('', 'all', true), r3 = CR('', 'explicit', false), r4 = CR('C17', 'all', false), r5 = CR('', 'direct', false);
	check(r1?.rows.length === 100 && r1.total === 1700 && r2?.rows.length === 1700 && r3?.total === 100 && r3.rows.every((c) => actOf(c) == 'tunnel') &&
		r4?.total === 11 && r5?.total === 0, 'common.catRows: не больше 100 строк, «Показать все», чип и поиск без учёта регистра',
		JSON.stringify([ r1?.rows.length, r1?.total, r2?.rows.length, r3?.total, r4?.total, r5?.total ]));

	// «Журнал» (spec §5.7): строки logread — время, источник по тегу (Решение 1), уровень из самой строки.
	const PL = (s) => cdev.parseLog?.(s)?.[0] || {};
	const D = 'Wed Oct  7 22:47:05 2026 ';
	const l1 = PL(D + 'daemon.notice truba: x');
	check(l1.time === '07.10 22:47:05' && l1.src === 'truba' && l1.source === 'truba' && l1.level === 'info' && l1.text === 'x' &&
		l1.raw === D + 'daemon.notice truba: x', `common.parseLog: строка Трубы (${JSON.stringify(l1)})`);
	const l2 = PL(D + 'daemon.warn truba-watchdog: x');
	check(l2.source === 'watchdog' && l2.level === 'warn', `common.parseLog: watchdog — свой источник (${JSON.stringify(l2)})`);
	const l3 = PL(D + 'daemon.err mosdns[812]: 2026-10-07T17:59:32.409Z\tWARN\tupstream error\t{}');
	check(l3.source === 'mosdns' && l3.level === 'warn' && l3.text === 'upstream error {}', `common.parseLog: mosdns — уровень из строки (${JSON.stringify(l3)})`);
	check(PL(D + 'daemon.err mosdns[812]: 2026-10-07T17:59:32.409Z\tERROR\tfailed to load cache dump: open x: no such file').level === 'info',
		'common.parseLog: нет дампа кэша mosdns — не ошибка');
	const l5 = PL(D + 'cron.err crond[900]: USER root pid 1 cmd truba update-lists');
	check(l5.source === 'truba' && l5.level === 'info', 'common.parseLog: запуск задачи cron — не ошибка');
	check(PL(D + "daemon.notice netifd: Interface 'awg0' is now up").source === 'awg', 'common.parseLog: netifd — источник awg');
	const l7 = PL('garbage');
	check(l7.time === '' && l7.source === 'truba' && l7.level === 'info' && l7.text === 'garbage' && l7.raw === 'garbage',
		`common.parseLog: неразобранная строка — как есть (${JSON.stringify(l7)})`);
	const LS = [ { level: 'info', source: 'truba' }, { level: 'warn', source: 'mosdns' }, { level: 'err', source: 'truba' } ];
	const LSN = (lv, src) => cdev.logShown?.(LS, lv, src)?.length;
	check(LSN('all', [ 'truba', 'mosdns' ]) === 3 && LSN('warn', [ 'truba', 'mosdns' ]) === 2 && LSN('err', [ 'truba', 'mosdns' ]) === 1 &&
		LSN('all', [ 'mosdns' ]) === 1, 'common.logShown: уровень — порог, источники — несколько');
	check(cdev.TABS.log === 'Log' && !('diagnostics' in cdev.TABS), 'common.TABS: «Журнал» вместо «Диагностики»');
}

// Туннель AmneziaWG (spec §5.4, Решения 4 и 7): router.conf, перенос его в network и проверки опций интерфейса.
// Заглушка uci держит секции в net (имя → опции) и запоминает вызовы.
const net = {}, uciCalls = [];
const awgUci = {
	get: (c, sid, o) => (sid == null) ? null : (o == null) ? (net[sid] ?? null) : (net[sid]?.[o] ?? null),
	sections: (c, t) => Object.entries(net).filter(([ , s ]) => s['.type'] == t).map(([ n, s ]) => ({ '.name': n, ...s })),
	add: (c, t, name) => { const n = name || 'cfg' + (100 + uciCalls.length); uciCalls.push([ 'add', c, t, n ]); net[n] = { '.type': t }; return n; },
	set: (c, sid, o, v) => { uciCalls.push([ 'set', c, sid, o, v ]); (net[sid] ??= {})[o] = v; },
	unset: (c, sid, o) => { uciCalls.push([ 'unset', c, sid, o ]); if (net[sid]) delete net[sid][o]; },
	remove: (c, sid) => { uciCalls.push([ 'remove', c, sid ]); delete net[sid]; }
};
const awg = loadModule('truba/awg.js', { baseclass, uci: awgUci, _: (s) => s,
	L: { toArray: (x) => (x == null) ? [] : Array.isArray(x) ? x : String(x).split(/\s+/) } });
if (awg) {
	const txt = (x) => typeof x === 'string' && x.length > 0;
	let conf = null;
	try {
		conf = awg.parseConf('[Interface]\r\nPrivateKey = k\r\n# c\r\nAddress = 10.0.0.2/30, fd00::2/64\r\nJC = 4\r\n\r\n[Peer]\r\npublickey = p\r\nEndpoint = [2001:db8::1]:51820\r\n');
	} catch (e) { }
	check(conf?.iface.privatekey === 'k' && conf.iface.jc === '4' && conf.peers[0]?.publickey === 'p',
		`awg.parseConf: CRLF, комментарии, ключи без учёта регистра (${JSON.stringify(conf)})`);
	const throws = (t) => { try { awg.parseConf(t); return false; } catch (e) { return /PrivateKey|Peer/.test(e.message); } };
	check(throws('[Peer]\nPublicKey = x') && throws('[Interface]\nPrivateKey = k\n'), 'awg.parseConf: без PrivateKey и без [Peer] с PublicKey — ошибка');
	Object.assign(net, { old: { '.type': 'amneziawg_awg0', public_key: 'q' }, z1: { '.type': 'zone', name: 'tun', network: [ 'x' ] } });
	if (conf)
		awg.applyConf('awg0', conf, 'tun');
	const unset = (k) => uciCalls.some((c) => c[0] == 'unset' && c[2] == 'awg0' && c[3] == k);
	check(uciCalls.some((c) => c[0] == 'add' && c[2] == 'interface' && c[3] == 'awg0') && net.awg0?.proto === 'amneziawg' && net.awg0.awg_jc === '4' &&
		[ ...Object.values(awg.IFACE_KEYS), ...Object.values(awg.IFACE_BOOL) ].every(unset) && JSON.stringify(net.awg0.addresses) === '["10.0.0.2/30","fd00::2/64"]',
		`awg.applyConf: секция интерфейса заведена, прежние опции AWG сняты, новые заданы (${JSON.stringify(net.awg0)})`);
	const peers = awgUci.sections('network', 'amneziawg_awg0');
	check(!net.old && peers.length === 1 && peers[0].endpoint_host === '2001:db8::1' && peers[0].endpoint_port === '51820' &&
		JSON.stringify(peers[0].allowed_ips) === '["0.0.0.0/0"]' && peers[0].route_allowed_ips === '0' && JSON.stringify(net.z1.network) === '["x","awg0"]',
		`awg.applyConf: прежний пир удалён, новый — с адресом IPv6, интерфейс — в зоне Туннеля (${JSON.stringify(peers)})`);
	check(awg.configured('awg0') === true && awg.configured('nope') === false && awg.peerSection('awg0') === peers[0]['.name'] && awg.peerSection('nope') === null,
		'awg.configured и awg.peerSection');
	check([ '575', '1501', 'abc' ].every((v) => txt(awg.mtuError(v))) && [ '', '576', '1500' ].every((v) => awg.mtuError(v) === null), 'awg.mtuError: 576–1500');
	check(awg.rangeError('15-25', 65535) === null && awg.rangeError('4294967295', 4294967295) === null && txt(awg.rangeError('25-15', 65535)) &&
		txt(awg.rangeError('65536', 65535)), 'awg.rangeError: число или «от-до» в пределах');
	// Проверки параметров зависят от ключа защиты заголовков и RandomTrailers в настройках интерфейса.
	net.t1 = { '.type': 'interface' };
	const PE = (k, v) => awg.paramError('t1', k, v);
	const s1Plain = PE('s1', '5');
	net.t1.awg_header_protection_key = 'h';
	check(s1Plain === null && /at least 12/.test(PE('s1', '5') || '') && PE('s1', '12') === null, 'awg.paramError: S1–S4 не меньше 12 — только с защитой заголовков');
	const padPlain = PE('content_padding_addition', '10-20');
	net.t1.awg_random_trailers = '1';
	check(padPlain === null && txt(PE('content_padding_addition', '10-20')), 'awg.paramError: добавка к пакетам — пусто при RandomTrailers');
	check(txt(PE('jc', 'x')) && PE('h1', '100-200') === null && PE('i1', '<r 2>') === null && PE('jc', '') === null,
		'awg.paramError: Jc — целое, H — число или диапазон, I — без проверки, пусто — верно');
	// Версия протокола — как её определяет install-vps.sh (awg_proto_supported).
	const V = (opts, ka) => {
		net.v = { '.type': 'interface', ...opts };
		delete net.vp;
		if (ka)
			net.vp = { '.type': 'amneziawg_v', persistent_keepalive: ka };
		return awg.version('v');
	};
	check(V({}) === null && V({ awg_jc: '4' }) === '1.0' && V({ awg_s3: '20' }) === '2.0' && V({ awg_h1: '1-2' }) === '2.0' && V({ awg_i1: '<r 2>' }) === '2.0' &&
		V({ awg_header_protection_key: 'h' }) === '3.1' && V({ awg_jc: '4' }, '15-25') === '3.1' && V({ awg_jc: '4' }, '25') === '1.0',
		'awg.version: 3.1, 2.0, 1.0 — как install-vps.sh; без параметров — нет');
}

const po = readFileSync(join(root, 'po/ru/truba.po'), 'utf8');
const translated = new Map();
const blocks = po.split(/\n\s*\n/);
for (const b of blocks) {
	const id = b.match(/^msgid "((?:\\.|[^"])*)"/m);
	const str = b.match(/^msgstr "((?:\\.|[^"])*)"/m);
	if (id && str && id[1]) translated.set(id[1].replace(/\\"/g, '"').replace(/\\\\/g, '\\'), str[1]);
}
for (const [s, f] of strings) {
	if (!translated.has(s) || !translated.get(s)) {
		console.log(`FAIL  нет перевода (${f}): ${s}`);
		fails++;
	}
}
for (const s of translated.keys())
	if (!strings.has(s)) console.log(`warn  лишняя строка в po: ${s}`);

console.log(`${files.length} файлов, ${strings.size} строк`);
console.log(fails ? `${fails} FAILED` : 'ALL OK');
process.exit(fails ? 1 : 0);
