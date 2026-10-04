// Обход всех вкладок «Службы → Труба» headless-браузером: ошибки JS, текст страниц, скриншоты.
// Запуск: node screens.js http://<ip-стенда> /out [lang]
const puppeteer = require('puppeteer');
const fs = require('fs');

const base = process.argv[2] || 'http://172.17.0.2';
const out = process.argv[3] || '/out';
const pages = [ 'overview', 'tunnel', 'routing', 'devices', 'dns', 'lists', 'inbound', 'diagnostics' ];

(async () => {
	const browser = await puppeteer.launch({ args: [ '--no-sandbox', '--disable-dev-shm-usage' ] });
	const page = await browser.newPage();
	await page.setViewport({ width: 1280, height: 900 });
	const errors = [];
	// Ошибки страниц Трубы; стартовая панель LuCI стенда к проверке не относится.
	const ours = () => page.url().includes('/admin/services/truba/');
	page.on('pageerror', (e) => { if (ours()) errors.push(`[${page.url()}] pageerror: ${e.message}`); });
	page.on('console', (m) => { if (ours() && m.type() === 'error') errors.push(`[${page.url()}] console: ${m.text()}`); });

	await page.goto(`${base}/cgi-bin/luci/`, { waitUntil: 'networkidle2' });
	// Поле имени заполнено «root» заранее; пароль на чистом стенде пустой.
	await page.$eval('input[name=luci_username]', (el) => { el.value = 'root'; });
	await page.$eval('input[name=luci_password]', (el) => { el.value = ''; });
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }), page.keyboard.press('Enter') ]);

	let fails = 0;
	for (const p of pages) {
		await page.goto(`${base}/cgi-bin/luci/admin/services/truba/${p}`, { waitUntil: 'networkidle2' });
		await new Promise((r) => setTimeout(r, 1500));
		const text = await page.evaluate(() => document.querySelector('#maincontent')?.innerText || document.body.innerText);
		const broken = /Unable to load|TypeError|ReferenceError|Error: |Authorization Required/.test(text);
		if (broken) fails++;
		console.log(`${broken ? 'FAIL' : 'ok  '}  ${p}: ${text.replace(/\s+/g, ' ').slice(0, 160)}`);
		fs.writeFileSync(`${out}/${p}.txt`, text);
		await page.screenshot({ path: `${out}/${p}.png`, fullPage: true });
	}

	// Диагностика: проверка IP из geoip:ru.
	await page.goto(`${base}/cgi-bin/luci/admin/services/truba/diagnostics`, { waitUntil: 'networkidle2' });
	await page.type('input.cbi-input-text', '77.88.8.8');
	await page.keyboard.press('Enter');
	await page.waitForFunction(() => /77\.88\.8\.8 →/.test(document.querySelector('#maincontent').innerText), { timeout: 30000 })
		.catch(() => {});
	const diag = await page.evaluate(() => document.querySelector('#maincontent').innerText);
	const at = diag.indexOf('77.88.8.8 →');
	console.log(`${at >= 0 ? 'ok  ' : 'FAIL'}  diagnostics check: ${diag.slice(Math.max(at, 0), at + 200).replace(/\s+/g, ' ')}`);
	if (at < 0) fails++;
	await page.screenshot({ path: `${out}/diagnostics-check.png`, fullPage: true });

	for (const e of errors) console.log('JSERR ' + e);
	console.log(errors.length || fails ? `${errors.length} js errors, ${fails} broken pages` : 'ALL OK');
	await browser.close();
	process.exit(errors.length || fails ? 1 : 0);
})();
