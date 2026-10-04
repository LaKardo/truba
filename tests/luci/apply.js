// Сквозная проверка «Сохранить и применить»: меняем настройки в интерфейсе и
// ждём, что служба truba сама перестроила правила (ucitrack → /etc/init.d/truba reload).
// После прогона проверки на стороне Роутера делает tests/luci/verify-apply.sh.
const puppeteer = require('puppeteer');

const base = process.argv[2] || 'http://172.17.0.2';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function saveApply(page) {
	// «Save & Apply» — составная кнопка LuCI (ComboButton): кликаем по её видимому пункту.
	await page.evaluate(() => {
		const el = [ ...document.querySelectorAll('.cbi-page-actions *') ]
			.find((x) => x.childElementCount == 0 && x.textContent.trim() == 'Save & Apply');
		el.click();
	});
	// Ждём окончания применения (LuCI показывает индикатор, затем перезагружает данные).
	await sleep(12000);
}

(async () => {
	const browser = await puppeteer.launch({ args: [ '--no-sandbox', '--disable-dev-shm-usage' ] });
	const page = await browser.newPage();
	await page.setViewport({ width: 1280, height: 900 });
	await page.goto(`${base}/cgi-bin/luci/`, { waitUntil: 'networkidle2' });
	await page.$eval('input[name=luci_username]', (el) => { el.value = 'root'; });
	await page.$eval('input[name=luci_password]', (el) => { el.value = ''; });
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }), page.keyboard.press('Enter') ]);

	const only = process.argv[3];
	if (!only || only == 'step1') {
	// 1. Маршрутизация: youtube → Напрямую в Режиме «Всё в туннель».
	await page.goto(`${base}/cgi-bin/luci/admin/services/truba/routing`, { waitUntil: 'networkidle2' });
	await sleep(1500);
	await page.evaluate(() => {
		const row = [ ...document.querySelectorAll('div[data-tab="all"] tr') ].find((r) => r.getAttribute('data-search') == 'geosite:youtube');
		const sel = row.querySelector('select');
		sel.value = 'direct';
		sel.dispatchEvent(new Event('change', { bubbles: true }));
	});
	await saveApply(page);
	console.log('step1 done: youtube → direct');
	}

	if (!only || only == 'step2') {
	// 2. Устройства: добавить Политику «Всё в туннель».
	await page.goto(`${base}/cgi-bin/luci/admin/services/truba/devices`, { waitUntil: 'networkidle2' });
	await sleep(1500);
	await page.evaluate(() => {
		const add = [ ...document.querySelectorAll('button') ].find((b) => /Add/.test(b.textContent) && b.closest('.cbi-section'));
		add.click();
	});
	await sleep(1500);
	await page.type('.modal input[id$=".name"]', 'console');
	// Поле MAC: при наличии DHCP-клиентов — выпадающий список с вводом, иначе обычное поле.
	if (await page.$('.modal .cbi-dropdown')) {
		await page.click('.modal .cbi-dropdown');
		await page.type('.modal .cbi-dropdown input.create-item-input', '02:11:22:33:44:55');
		await page.keyboard.press('Enter');
	}
	else {
		await page.type('.modal input[id$=".mac"]', '02:11:22:33:44:55');
	}
	await sleep(500);
	await page.evaluate(() => {
		const save = [ ...document.querySelectorAll('.modal button') ].find((b) => /Save/.test(b.textContent));
		save.click();
	});
	await sleep(1500);
	await saveApply(page);
	console.log('step2 done: device policy added');
	}

	if (!only || only == 'step3') {
	// 3. Главный переключатель «Маршрутизация» — выкл.
	await page.goto(`${base}/cgi-bin/luci/admin/services/truba/overview`, { waitUntil: 'networkidle2' });
	await sleep(1500);
	await page.evaluate(() => {
		const cb = document.querySelector('input[id$=".main.routing"]') || [ ...document.querySelectorAll('input[type=checkbox]') ][1];
		cb.click();
	});
	await saveApply(page);
	console.log('step3 done: routing off');
	}

	await browser.close();
})().catch((e) => { console.log('ERROR ' + e.message); process.exit(1); });
