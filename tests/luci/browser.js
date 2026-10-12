// Один проход headless Chromium по интерфейсу на живом стенде (tests/luci/stand.sh):
// все вкладки «Службы → Труба» без ошибок JS и HTTP, «Проверить домен/IP», затем
// «Сохранить и применить» по шагам — служба сама перестраивает правила (ucitrack → reload).
// Итог шага берётся у службы через ubus (запрос к /ubus с сессией LuCI), а не по таймеру.
//   node browser.js http://<адрес стенда> /out
const puppeteer = require('puppeteer');
const fs = require('fs');

const base = process.argv[2];
const out = process.argv[3] || '/out';
const url = (p) => `${base}/cgi-bin/luci/admin/services/truba/${p}`;
const tabs = [ 'overview', 'tunnel', 'routing', 'dns', 'inbound', 'diagnostics' ];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let fails = 0;
const result = (ok, name, detail) => {
	if (!ok) fails++;
	console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`);
};

// Страница построена: данные пришли, индикаторов загрузки нет. Вкладки на новом интерфейсе (ADR 0017)
// рисуются в Shadow DOM корня .truba-root — там свой .tr и свои индикаторы.
async function settled(page) {
	await page.waitForFunction(() => {
		const main = document.querySelector('#maincontent');
		if (!main || main.querySelector('.spinning'))
			return false;
		const root = document.querySelector('.truba-root')?.shadowRoot;
		return !document.querySelector('.truba-root') || (root?.querySelector('.tr') && !root.querySelector('.spinning'));
	}, { timeout: 10000 }).catch(() => {});
}

// Текст вкладки вместе с Shadow DOM: innerText хозяина его не включает.
function pageText(page) {
	return page.evaluate(() => [
		(document.querySelector('#view') || document.querySelector('#maincontent'))?.innerText || '',
		...[ ...document.querySelectorAll('.truba-root') ].map((r) => r.shadowRoot?.querySelector('.tr')?.innerText || '')
	].join('\n'));
}

// Элемент внутри Shadow DOM страницы.
function shadowSel(page, sel) {
	return page.evaluateHandle((sel) => document.querySelector('.truba-root')?.shadowRoot?.querySelector(sel), sel);
}
const shadowHas = (page, sel) => page.evaluate((sel) => !!document.querySelector('.truba-root')?.shadowRoot?.querySelector(sel), sel);

// Вызов ubus от имени сессии LuCI — прямо через /ubus, мимо страницы: она перезагружается
// после применения, а вторая вкладка в фоне у Chromium не работает.
let session = null;
async function ubus(object, method, params = {}) {
	const r = await fetch(base + session.path, { method: 'POST', headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call', params: [ session.sid, object, method, params ] }) });
	const res = (await r.json()).result;
	if (!res || res[0] != 0)
		throw new Error(`ubus ${object}.${method}: ${JSON.stringify(res)}`);
	return res[1];
}

// Ждать до 45 с, пока служба не применит настройки заново и cond(status) не выполнится.
async function applied(prevTime, cond) {
	for (let i = 0; i < 90; i++) {
		const st = await ubus('truba', 'status').catch(() => null);
		if (st?.applied?.time > prevTime && !st.applied.error && await cond(st))
			return true;
		await sleep(500);
	}
	return false;
}

// «Save & Apply» — составная кнопка LuCI (ComboButton): кликаем по её видимому пункту и ждём,
// пока LuCI доведёт применение до конца. Оно идёт с откатом: окно состояния висит, пока LuCI не
// подтвердит изменения. Уйти раньше — значит получить откат, а на следующей странице окно
// ожидания поверх своих окон.
async function saveApply(page) {
	await page.evaluate(() => [ ...document.querySelectorAll('.cbi-page-actions *') ]
		.find((x) => x.childElementCount == 0 && x.textContent.trim() == 'Save & Apply').click());
	await waitApply(page);
}

// Применение уже запущено (кнопкой LuCI или «Применить» панели изменений) — дождаться его конца.
async function waitApply(page) {
	const overlay = () => page.evaluate(() => document.body.classList.contains('modal-overlay-active')).catch(() => true);
	for (let i = 0; i < 10 && !await overlay(); i++)
		await sleep(200);
	for (let i = 0, quiet = 0; i < 180 && quiet < 3; i++) {
		quiet = await overlay() ? 0 : quiet + 1;
		await sleep(500);
	}
}

(async () => {
	const browser = await puppeteer.launch({ args: [ '--no-sandbox', '--disable-dev-shm-usage' ] });
	const page = await browser.newPage();
	await page.setViewport({ width: 1280, height: 900 });
	const errors = [];
	// Ошибки страниц Трубы; стартовая панель LuCI стенда к проверке не относится.
	const ours = () => page.url().includes('/admin/services/truba/');
	// Исключение — ошибка самого LuCI (form.js): закрытое окно GridSection после «Save» ещё раз
	// проверяет зависимости полей, которых уже нет. Сохранение и применение при этом проходят.
	const luciCore = (e) => /checkDepends/.test(e.stack || '') && /reading '_class'/.test(e.message);
	page.on('pageerror', (e) => {
		if (ours() && !luciCore(e))
			errors.push(`[${page.url()}] pageerror: ${e.message} ${(e.stack || '').split('\n').slice(1, 6).join(' ← ')}`);
	});
	// «Failed to load resource» в консоли — без адреса; тот же запрос с адресом ловит response.
	page.on('console', (m) => {
		if (ours() && m.type() === 'error' && !/^Failed to load resource/.test(m.text())) errors.push(`[${page.url()}] console: ${m.text()}`);
	});
	// LuCI подгружает protocol/<proto>.js для каждого обработчика netifd: на стенде wireguard-tools
	// стоит без luci-proto-wireguard — это 404 стенда, а не интерфейса Трубы.
	page.on('response', (r) => {
		if (ours() && r.status() >= 400 && !/\/luci-static\/resources\/protocol\//.test(r.url()))
			errors.push(`[${page.url()}] HTTP ${r.status()}: ${r.url()}`);
	});

	// Вход: имя «root» уже в поле, пароль на чистом стенде пустой.
	await page.goto(`${base}/cgi-bin/luci/`, { waitUntil: 'networkidle2' });
	await page.$eval('input[name=luci_password]', (el) => { el.value = ''; });
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }), page.keyboard.press('Enter') ]);
	session = await page.evaluate(() => ({ sid: L.env.sessionid, path: L.env.ubuspath }));

	// «Обзор» на новом интерфейсе — сразу после старта службы, пока история скорости почти пуста:
	// пустые и единичные ряды uPlot не должны давать ошибок JS (их собирает page.on выше).
	await page.goto(url('overview'), { waitUntil: 'networkidle2' });
	await settled(page);
	result(await shadowHas(page, '.tr[data-scheme]'), '«Обзор»: страница в Shadow DOM, режим выбран');
	result(await shadowHas(page, 'svg.flow'), '«Обзор»: схема потоков');
	result(await shadowHas(page, 'canvas'), '«Обзор»: график uPlot');
	result(/Where traffic goes/.test(await pageText(page)), '«Обзор»: карточка «Куда идёт трафик»');

	for (const t of tabs) {
		await page.goto(url(t), { waitUntil: 'networkidle2' });
		await settled(page);
		// #view — сама вкладка, без общих баннеров LuCI (например, «No password set»), плюс Shadow DOM.
		const text = await pageText(page);
		result(!/Unable to load|TypeError|ReferenceError|Error: |Authorization Required/.test(text), `вкладка ${t}`,
			text.replace(/\s+/g, ' ').slice(0, 100));
		fs.writeFileSync(`${out}/${t}.txt`, text);
		await page.screenshot({ path: `${out}/${t}.png`, fullPage: true });
		// Подсказки полей — из схемы службы (truba.schema, ADR 0015), а не из представления.
		if (t == 'dns' || t == 'tunnel') {
			const id = t == 'dns' ? 'widget.cbid.truba.dns.port' : 'widget.cbid.truba.watchdog.handshake_max';
			const ph = await page.evaluate((id) => document.getElementById(id)?.placeholder, id);
			const sch = await ubus('truba', 'schema');
			const want = String(t == 'dns' ? sch.sections.dns.port.def : sch.sections.watchdog.handshake_max.def);
			result(ph === want, `вкладка ${t}: подсказка поля — умолчание схемы службы`, `${ph} / ${want}`);
		}
	}

	// «Проверить домен/IP»: IP из geoip:ru.
	await page.type('input.cbi-input-text', '77.88.8.8');
	await page.keyboard.press('Enter');
	const verdict = await page.waitForFunction(() => /77\.88\.8\.8 →[^\n]*/.exec(document.querySelector('#maincontent').innerText)?.[0],
		{ timeout: 20000 }).then((h) => h.jsonValue()).catch(() => null);
	result(verdict != null, '«Проверить домен/IP»', verdict);
	await page.screenshot({ path: `${out}/diagnostics-check.png`, fullPage: true });

	const time = async () => (await ubus('truba', 'status')).applied?.time ?? 0;

	// 1. Маршрутизация: youtube → Напрямую в Режиме «Всё в туннель».
	let t0 = await time();
	await page.goto(url('routing'), { waitUntil: 'networkidle2' });
	// Таблица Категорий строится после загрузки списков — ждём саму строку.
	await page.waitForSelector('div[data-tab="all"] tr[data-search="geosite:youtube"] select', { timeout: 20000 });
	await page.evaluate(() => {
		const row = [ ...document.querySelectorAll('div[data-tab="all"] tr') ].find((r) => r.getAttribute('data-search') == 'geosite:youtube');
		const sel = row.querySelector('select');
		sel.value = 'direct';
		sel.dispatchEvent(new Event('change', { bubbles: true }));
	});
	await saveApply(page);
	result(await applied(t0, (st) => (st.applied.geosite_order || []).includes('youtube=direct')),
		'«Сохранить и применить»: Действие Категории → служба перестроила правила');

	// 2. Политика устройства «Всё в туннель».
	t0 = await time();
	await page.goto(url('routing'), { waitUntil: 'networkidle2' });
	await settled(page);
	await page.waitForSelector('#cbi-truba-device .cbi-button-add', { timeout: 20000 });
	await page.click('#cbi-truba-device .cbi-button-add');
	await page.waitForSelector('.modal input[id$=".name"]', { visible: true });
	await page.type('.modal input[id$=".name"]', 'console');
	await page.type('.modal input[id$=".mac"]', '02:11:22:33:44:55');
	await page.evaluate(() => [ ...document.querySelectorAll('.modal button') ].find((b) => /Save/.test(b.textContent)).click());
	await page.waitForSelector('.modal', { hidden: true });
	await saveApply(page);
	result(await applied(t0, async () =>
		(await ubus('truba', 'check', { target: '8.8.8.8', mac: '02:11:22:33:44:55' })).reason == 'device'),
		'«Сохранить и применить»: Политика устройства → действует');

	// 3. Переключатель «Маршрутизация» в строке состояния «Обзора» — выкл, применение — панелью изменений.
	t0 = await time();
	await page.goto(url('overview'), { waitUntil: 'networkidle2' });
	await settled(page);
	await (await shadowSel(page, 'input[data-opt="truba.main.routing"]')).click();
	const bar = await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.changes')?.innerText,
		{ timeout: 5000 }).then((h) => h.jsonValue()).catch(() => '');
	result(/Unapplied changes: 1/.test(bar), 'панель изменений: одно несохранённое изменение', bar.replace(/\s+/g, ' '));
	await (await shadowSel(page, '.changes [data-act="apply"]')).click();
	await waitApply(page);
	result(await applied(t0, (st) => st.routing === false && st.mosdns === false),
		'«Применить» панели изменений: Маршрутизация выкл → mosdns остановлен');

	// Темы LuCI: режим страницы — по яркости фона темы; снимки на ПК и телефоне. На 375 точках нет
	// горизонтальной прокрутки ни у страницы, ни у корня Трубы.
	const theme = async (path) => {
		await ubus('uci', 'set', { config: 'luci', section: 'main', values: { mediaurlbase: path } });
		await ubus('uci', 'commit', { config: 'luci' });
	};
	const themes = [
		[ 'bootstrap-dark', null, 'dark' ],
		[ 'bootstrap-light', null, 'light' ],
		[ 'bootstrap', 'dark', 'dark' ]   // «авто»: режим по системной настройке
	];
	const installed = Object.values(await ubus('uci', 'get', { config: 'luci', section: 'themes' }).then((r) => r.values).catch(() => ({})));
	if (installed.includes('/luci-static/argon'))
		themes.push([ 'argon', null, null ]);
	for (const [ name, prefers, want ] of themes) {
		await theme('/luci-static/' + name);
		await page.emulateMediaFeatures([ { name: 'prefers-color-scheme', value: prefers || 'light' } ]);
		for (const w of [ 1280, 375 ]) {
			await page.setViewport({ width: w, height: w > 600 ? 900 : 812 });
			await page.goto(url('overview'), { waitUntil: 'networkidle2' });
			await settled(page);
			await sleep(300);   // режим выбирается после вставки страницы в документ
			const got = await page.evaluate(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.tr')?.dataset.scheme);
			if (want)
				result(got === want, `тема ${name} ${w}: режим ${want}`, got);
			if (w == 375) {
				const o = await page.evaluate(() => {
					const tr = document.querySelector('.truba-root')?.shadowRoot?.querySelector('.tr');
					return { doc: document.documentElement.scrollWidth, win: window.innerWidth, tr: tr ? tr.scrollWidth - tr.clientWidth : 0 };
				});
				result(o.doc <= o.win && o.tr <= 0, `тема ${name} 375: без горизонтальной прокрутки`, JSON.stringify(o));
			}
			await page.screenshot({ path: `${out}/overview-${name}-${w}.png`, fullPage: true });
		}
	}
	await theme('/luci-static/bootstrap');
	await page.emulateMediaFeatures([ { name: 'prefers-color-scheme', value: 'light' } ]);
	await page.setViewport({ width: 1280, height: 900 });

	// Служба остановлена: строка состояния и график говорят об этом, ошибок JS нет. Затем — запуск.
	await ubus('rc', 'init', { name: 'truba', action: 'stop' });
	await page.goto(url('overview'), { waitUntil: 'networkidle2' });
	await settled(page);
	// Последняя точка истории считается свежей ещё 15 с — «Обзор» опрашивает службу раз в 5 с.
	const stopped = await page.waitForFunction(() => {
		const t = document.querySelector('.truba-root')?.shadowRoot?.querySelector('.tr')?.innerText || '';
		return /service stopped/i.test(t) && /Speed is not being recorded/.test(t);
	}, { timeout: 40000 }).then(() => true).catch(() => false);
	result(stopped, '«Обзор»: служба остановлена — строка состояния и график');
	await page.screenshot({ path: `${out}/overview-stopped.png`, fullPage: true });
	await ubus('rc', 'init', { name: 'truba', action: 'start' });
	let up = false;
	for (let i = 0; i < 60 && !up; i++) {
		up = (await ubus('truba', 'status').catch(() => ({}))).service === true;
		if (!up)
			await sleep(500);
	}
	result(up, 'служба снова запущена');

	for (const e of errors) console.log('JSERR ' + e);
	console.log(errors.length || fails ? `${errors.length} ошибок JS/HTTP, ${fails} провалов` : 'ALL OK');
	await browser.close();
	process.exit(errors.length || fails ? 1 : 0);
})().catch((e) => { console.log('FAIL  ' + e.message); process.exit(1); });
