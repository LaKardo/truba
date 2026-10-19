// Закреплённые библиотеки интерфейса (ADR 0017): скачать файлы из lib/VERSIONS и записать их sha256.
// Строка VERSIONS: «файл пакет@версия путь-в-пакете sha256»; сумму можно оставить пустой — её впишет скрипт.
// Чтобы обновить библиотеку: поменять версию в VERSIONS, стереть сумму в этой строке, запустить скрипт, прогнать
// tests/run.sh luci ui. Та же строка с другой суммой — ошибка: файл той же версии на CDN изменился.
//   node tests/luci/vendor.mjs
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Строка VERSIONS для скачанного файла с суммой sum: сумма записывается, если её не было, та же остаётся;
// другая при той же строке (пакет@версия) — ошибка, а не новая сумма молча.
export function record(line, sum) {
	const [ file, pkg, path, old ] = line.trim().split(/\s+/);
	if (old && old !== sum)
		throw new Error(`${file}: sha256 ${sum} не равна записанной для ${pkg} (${old}) — чтобы принять файл, сотрите сумму в VERSIONS`);
	return [ file, pkg, path, sum ].join(' ');
}

const lib = fileURLToPath(new URL('../../router/luci-app-truba/htdocs/luci-static/resources/truba/lib/', import.meta.url));
const versions = join(lib, 'VERSIONS');

// Официальная minified IIFE uPlot оборачивается экспортом в ES-модуль. Сумма
// VERSIONS относится к готовому модулю; отдельный минификатор не нужен.
export function moduleBody(file, path, body) {
	if (file === 'uplot.js' && path.endsWith('/uPlot.iife.min.js'))
		return Buffer.concat([ body, Buffer.from('\nexport default uPlot;\n') ]);
	return body;
}

async function main() {
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
		const body = moduleBody(file, path, Buffer.from(await res.arrayBuffer()));
		const rec = record(line, createHash('sha256').update(body).digest('hex'));
		writeFileSync(join(lib, file), body);
		out.push(rec);
		console.log(`${file} ← ${url} (${body.length} байт)`);
	}
	writeFileSync(versions, out.join('\n'));
}

// Скачивание — только когда файл запущен как скрипт: tests/luci/static.mjs берёт отсюда record.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
	await main();
