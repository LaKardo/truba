// Локальный предпросмотр настоящих модулей LuCI. Только loopback, без доступа к роутеру.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, sep, extname } from 'node:path';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const resources = resolve(repo, 'router/luci-app-truba/htdocs/luci-static/resources');
// Схема берётся из службы, а не из отдельной копии умолчаний в макете.
const conf = await readFile(resolve(repo, 'router/truba/files/usr/share/ucode/truba/conf.uc'), 'utf8');
const constants = await readFile(resolve(repo, 'router/truba/files/usr/share/ucode/truba/const.uc'), 'utf8');
const literal = (source, name) => {
	const m = source.replace(/^\s*\/\/.*$/gm, '').match(new RegExp(`export const ${name}\\s*=\\s*([\\s\\S]*?);`));
	if (!m) throw new Error(`Не найдена константа ${name}`);
	return Function('return (' + m[1] + ')')();
};
// Только доверенные файлы этого checkout; при изменении синтаксиса ucode сервер завершится явно.
const schema = { sections: literal(conf, 'SCHEMA'), upstream_schemes: literal(conf, 'UPSTREAM_SCHEMES'),
	upstream_re: literal(conf, 'UPSTREAM_RE'), consts: Object.fromEntries(
		[['fw_zone', 'FW_ZONE'], ['probe_window', 'PROBE_WINDOW'], ['history', 'HISTORY'], ['mosdns_addr', 'MOSDNS_ADDR'], ['devices', 'DEV_HISTORY']]
			.map(([key, name]) => [key, literal(constants, name)])) };
const po = await readFile(resolve(repo, 'router/luci-app-truba/po/ru/truba.po'), 'utf8');
const translations = {};
for (const block of po.split(/\n\s*\n/)) {
	const fields = {}; let key;
	for (const line of block.split('\n')) {
		const m = line.match(/^(msgctxt|msgid|msgstr) (".*")$/);
		if (m) { key = m[1]; fields[key] = JSON.parse(m[2]); }
		else if (/^"/.test(line) && key) fields[key] += JSON.parse(line);
	}
	if (fields.msgid && fields.msgstr) translations[(fields.msgctxt || '') + '\u0001' + fields.msgid] = fields.msgstr;
}
const server = http.createServer(async (req, res) => {
	try {
		const pathname = new URL(req.url, 'http://localhost').pathname;
		res.setHeader('Cache-Control', 'no-store');
		res.setHeader('X-Content-Type-Options', 'nosniff');
		if (pathname == '/fixtures.json') {
			res.setHeader('Content-Type', 'application/json');
			return res.end(JSON.stringify({ schema, translations }));
		}
		const file = pathname == '/' ? resolve(repo, 'tests/luci/preview.html')
			: pathname == '/preview-client.js' ? resolve(repo, 'tests/luci/preview-client.js')
				: resolve(resources, '.' + decodeURIComponent(pathname));
		if (pathname != '/' && pathname != '/preview-client.js' && !file.startsWith(resources + sep)) {
			res.writeHead(403); return res.end();
		}
		const data = await readFile(file);
		res.setHeader('Content-Type', ({ '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html' })[extname(file)] || 'application/octet-stream');
		res.end(data);
	} catch { res.writeHead(404); res.end('Not found'); }
});
server.listen(Number(process.argv[2] || 8080), '127.0.0.1', () => console.log(`Предпросмотр: http://127.0.0.1:${server.address().port} (мок-данные, без применения настроек)`));
