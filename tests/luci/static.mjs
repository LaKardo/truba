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
	for (const n of [ 'circle-check', 'triangle-alert', 'circle-x', 'arrow-right', 'wifi-off', 'pencil' ])
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
];
const devSchema = { sections: { device: { enabled: { type: 'bool', def: true },
	policy: { type: 'enum', values: [ 'tunnel', 'direct', 'rules' ], def: 'tunnel' } } }, upstream_schemes: [], consts: {} };
let cdev = null;
try {
	cdev = new Function('baseclass', 'rpc', 'uci', '_', 'L', 'E', 'document', commonSrc)(
		baseclass, { declare: (o) => () => Promise.resolve(o.method == 'schema' ? devSchema : {}) },
		{ sections: (c, t) => devSecs.filter((s) => s['.type'] == t), get: (c, sid, o) => devSecs.find((s) => s['.name'] == sid)?.[o] },
		(s) => s, stub, stub, { querySelector: () => true });
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
	check(cdev.devActive?.({ last: 700 }, 1000) === true && cdev.devActive({ last: 699 }, 1000) === false && cdev.devActive({ last: null }, 1000) === false,
		'common.devActive: трафик за 5 минут');
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
