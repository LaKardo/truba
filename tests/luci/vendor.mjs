// Закреплённые библиотеки интерфейса (ADR 0017): скачать файлы из lib/VERSIONS и записать их sha256.
// Строка VERSIONS: «файл пакет@версия путь-в-пакете sha256»; сумму можно оставить пустой — её впишет скрипт.
// Чтобы обновить библиотеку: поменять версию в VERSIONS, запустить скрипт, прогнать tests/run.sh luci ui.
//   node tests/luci/vendor.mjs
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const lib = fileURLToPath(new URL('../../router/luci-app-truba/htdocs/luci-static/resources/truba/lib/', import.meta.url));
const versions = join(lib, 'VERSIONS');

const out = [];
for (const line of readFileSync(versions, 'utf8').split('\n')) {
	if (!line.trim() || line.startsWith('#')) {
		out.push(line);
		continue;
	}
	const [ file, pkg, path ] = line.trim().split(/\s+/);
	const url = `https://unpkg.com/${pkg}/${path}`;
	const res = await fetch(url);
	if (!res.ok)
		throw new Error(`${url}: HTTP ${res.status}`);
	const body = Buffer.from(await res.arrayBuffer());
	writeFileSync(join(lib, file), body);
	const sum = createHash('sha256').update(body).digest('hex');
	out.push([ file, pkg, path, sum ].join(' '));
	console.log(`${file} ← ${url} (${body.length} байт)`);
}
writeFileSync(versions, out.join('\n'));
