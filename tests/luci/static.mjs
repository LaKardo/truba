// Интерфейс LuCI без стенда: синтаксис JS, полнота русского перевода, схемы DNS как у службы, каждый вызов truba.*
// есть в ubus-API пакета truba и в ACL.
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

// Схемы адресов DNS-серверов: поле в интерфейсе (dns.js) и служба (conf.uc) проверяют одно и то же.
// Разойдутся — интерфейс пропустит адрес, который служба отбросит, или наоборот.
const schemes = (src) => (src.match(/UPSTREAM_SCHEMES = \[([^\]]*)\]/)?.[1].match(/'[^']+'/g) ?? []).sort().join(' ');
const uiSchemes = schemes(readFileSync(join(root, 'htdocs/luci-static/resources/view/truba/dns.js'), 'utf8'));
const svcSchemes = schemes(readFileSync(join(root, '../truba/files/usr/share/ucode/truba/conf.uc'), 'utf8'));
if (!uiSchemes || uiSchemes !== svcSchemes) {
	console.log(`FAIL  схемы DNS в dns.js (${uiSchemes || '—'}) и conf.uc (${svcSchemes || '—'}) разошлись`);
	fails++;
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
