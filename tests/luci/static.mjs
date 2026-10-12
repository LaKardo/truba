// Интерфейс LuCI без стенда: синтаксис JS, полнота русского перевода, каждый вызов truba.* есть в ubus-API
// пакета truba и в ACL, в представлениях нет копий значений службы, зависимость от truba, цвет рукопожатия.
//   node tests/luci/static.mjs           — проверить
//   node tests/luci/static.mjs --pot     — напечатать шаблон .pot (po/templates/truba.pot)
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../router/luci-app-truba/', import.meta.url));
const files = [];
const rel = (f) => relative(root, f).split(sep).join('/');
(function walk(d) {
	for (const f of readdirSync(d)) {
		const p = join(d, f);
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
