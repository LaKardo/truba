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
