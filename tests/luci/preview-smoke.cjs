// Проверка локального предпросмотра. Запуск из окружения с Puppeteer:
// node preview-smoke.cjs http://127.0.0.1:8080 /каталог/снимков
const puppeteer = require('puppeteer');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
	const base = process.argv[2] || 'http://127.0.0.1:8080';
	const out = process.argv[3];
	if (out) fs.mkdirSync(out, { recursive: true });
	const browser = await puppeteer.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
	let fails = 0;
	try {
		const page = await browser.newPage();
		let errors = [];
		page.on('pageerror', (e) => errors.push(e.message));
		for (const theme of ['light', 'dark']) for (const size of ['desktop', 'phone']) for (const lang of ['ru', 'en']) {
			await page.setViewport({ width: size == 'phone' ? 390 : 1280, height: 900 });
			for (const tab of ['overview', 'devices', 'rules', 'tunnel', 'dns', 'inbound', 'log']) {
				errors = [];
				await page.goto(`${base}/?${new URLSearchParams({ theme, size, lang, tab })}`);
				await page.waitForFunction(() => !!document.body.dataset.ready);
				if (tab == 'overview') {
					const blocked = await page.evaluate(() => [...document.querySelector('.truba-root').shadowRoot.querySelectorAll('.flow')]
						.every((svg) => /(?:block|блок): 30/i.test(svg.textContent)));
					if (!blocked) { fails++; console.log('FAIL combined DNS and packet block count'); }
				}
				if (tab == 'devices') {
					await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('button.dev')?.click());
					await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.conn button'));
					const names = await page.evaluate(() => {
						const r = document.querySelector('.truba-root').shadowRoot;
						const a = r.querySelector('[data-addr="198.51.100.7"]');
						return a?.textContent == 'www.example.org' && a.closest('.conn').textContent.includes('198.51.100.7') &&
							r.querySelector('[data-addr="192.0.2.8"]')?.textContent == '192.0.2.8';
					});
					if (!names) { fails++; console.log('FAIL DNS names and IP fallback'); }
					await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('[data-addr="198.51.100.7"]').click());
					await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('input[name="target"]')?.value == 'www.example.org');
				}
				await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
				const state = await page.evaluate(() => {
					const tr = document.querySelector('.truba-root')?.shadowRoot?.querySelector('.tr');
					return { error: document.querySelector('#error').textContent, scheme: tr?.dataset.scheme,
						overflow: tr ? tr.scrollWidth - tr.clientWidth : -1 };
				});
				const ok = !errors.length && !state.error && state.scheme == theme && state.overflow == 0;
				if (!ok) fails++;
				console.log(`${ok ? 'ok' : 'FAIL'} ${tab} ${theme} ${size} ${lang}`, ok ? '' : JSON.stringify({ state, errors }));
				if (out) await page.screenshot({ path: path.join(out, `${tab}-${theme}-${size}-${lang}.png`), fullPage: true });
			}
		}
	} finally { await browser.close(); }
	process.exitCode = fails ? 1 : 0;
})().catch((e) => { console.error(e); process.exitCode = 1; });
