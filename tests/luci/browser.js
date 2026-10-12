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
const tabs = [ 'overview', 'devices', 'tunnel', 'routing', 'dns', 'inbound', 'diagnostics' ];
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
	// Устройства стенда (stand.sh): оба с трафиком за 5 минут — на схеме «2 active», в карточке — список.
	const flowText = await page.evaluate(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('svg.flow')?.textContent || '');
	result(/2 active/.test(flowText), '«Обзор»: схема потоков — число активных устройств', flowText.replace(/\s+/g, ' ').slice(0, 80));
	const devCard = await page.evaluate(() => {
		const c = document.querySelector('.truba-root')?.shadowRoot?.querySelector('.card.devs');
		return { text: c?.innerText || '', link: c?.querySelector('a.go')?.getAttribute('href') || '' };
	});
	result(/192\.168\.1\.50/.test(devCard.text) && /\/admin\/services\/truba\/devices$/.test(devCard.link),
		'«Обзор»: карточка «Устройства» — устройство и ссылка на вкладку', devCard.text.replace(/\s+/g, ' ').slice(0, 80));

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

	// «Устройства» (ADR 0018): на стенде сосед с MAC и узел mesh-VPN без него (stand.sh).
	const rowSel = (ip) => `button.dev[data-ip="${ip}"]`;
	const el = async (sel) => (await shadowSel(page, sel)).asElement();
	const tap = async (sel) => { const e = await el(sel); if (e) await e.click(); return !!e; };
	const panelText = () => page.evaluate(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.panel')?.innerText || '');
	const clickIn = (sel, re) => page.evaluate((sel, re) => [ ...document.querySelector('.truba-root').shadowRoot.querySelectorAll(sel) ]
		.find((b) => new RegExp(re).test(b.textContent))?.click(), sel, re);
	await page.goto(url('devices'), { waitUntil: 'networkidle2' });
	await settled(page);
	result(await shadowHas(page, rowSel('192.168.1.50')) && await shadowHas(page, rowSel('100.64.0.9')), '«Устройства»: в списке сосед и узел mesh-VPN');
	// Разметка строки: в кнопке — только фразовые элементы; у карточки списка нет пустого заголовка.
	const markup = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		return { divs: r.querySelectorAll('button.dev div').length, h3: r.querySelectorAll('.card.list .card-h h3').length };
	});
	result(markup.divs == 0 && markup.h3 == 0, '«Устройства»: в строке-кнопке нет div, у списка нет пустого заголовка', JSON.stringify(markup));
	const chips = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.chips')?.innerText || '');
	result(/Active\s*2/.test(chips), '«Устройства»: у обоих трафик за 5 минут — активны', chips.replace(/\s+/g, ' '));
	await tap(rowSel('192.168.1.50'));
	await page.waitForFunction(() => /02:11:22:33:44:55/.test(document.querySelector('.truba-root')?.shadowRoot?.querySelector('.panel')?.innerText || ''),
		{ timeout: 5000 }).catch(() => {});
	const p50 = await panelText();
	result(/02:11:22:33:44:55/.test(p50) && /Where it goes now/.test(p50) && await shadowHas(page, '.panel .policy .seg'),
		'«Устройства»: панель — MAC, Политика, «Куда ходит сейчас»', p50.replace(/\s+/g, ' ').slice(0, 120));
	await tap(rowSel('100.64.0.9'));
	await sleep(300);
	const off = await page.evaluate(() => [ ...document.querySelector('.truba-root').shadowRoot.querySelectorAll('.panel .policy button') ]
		.every((b) => b.disabled));
	result(/tied to the MAC address/.test(await panelText()) && off, '«Устройства»: без MAC — Политика недоступна, с пояснением');
	// «Проверить для этого устройства» без MAC — проверка для всех устройств: mac не передаётся вовсе
	// (rpcd отклоняет null вместо строки).
	await (await el('.panel form.check input[name="target"]'))?.type('77.88.8.8');
	await tap('.panel form.check button[type="submit"]');
	const noMac = await page.waitForFunction(() => {
		const t = document.querySelector('.truba-root')?.shadowRoot?.querySelector('.panel .check-res')?.innerText || '';
		return /→|failed/.test(t) && t;
	}, { timeout: 20000 }).then((h) => h.jsonValue()).catch(() => '');
	result(/77\.88\.8\.8 →/.test(noMac), '«Устройства»: проверка у устройства без MAC', noMac);
	await page.screenshot({ path: `${out}/devices-1280.png`, fullPage: true });

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

	// 2. Политика устройства «Всё в туннель» — в панели устройства, применение — панелью изменений.
	t0 = await time();
	await page.goto(url('devices'), { waitUntil: 'networkidle2' });
	await settled(page);
	await tap(rowSel('192.168.1.50'));
	await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.panel .policy .seg'), { timeout: 5000 }).catch(() => {});
	await clickIn('.panel .policy button', '^All via tunnel$');
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(await applied(t0, async () =>
		(await ubus('truba', 'check', { target: '8.8.8.8', mac: '02:11:22:33:44:55' })).reason == 'device'),
		'«Применить»: Политика устройства → действует');
	// Имя из IP не пишется: адрес устройства меняется, а имя в настройках осталось бы прежним адресом.
	const devSecs = async (mac) => Object.values((await ubus('uci', 'get', { config: 'truba', type: 'device' })).values || {})
		.filter((s) => String(s.mac).toLowerCase() == mac);
	const s50 = await devSecs('02:11:22:33:44:55');
	result(s50.length == 1 && !s50[0].name, '«Политика устройства»: без имени у аренды в имя не пишется IP', JSON.stringify(s50));

	// «Добавить по MAC»: Политика заранее — устройству, которого нет в сети.
	t0 = await time();
	await page.goto(url('devices'), { waitUntil: 'networkidle2' });
	await settled(page);
	await tap('[data-act="add-mac"]');
	const macIn = await el('.addmac input[name="mac"]');
	await macIn?.type('zz');
	const badMac = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		return !!r.querySelector('.addmac .err-text') && r.querySelector('.addmac [data-act="add"]')?.disabled && !r.querySelector('.changes');
	});
	result(badMac, '«Добавить по MAC»: неверный MAC — ошибка у поля, изменений нет');
	await macIn?.click({ clickCount: 3 });
	await macIn?.type('02:AA:BB:CC:DD:01');
	await (await el('.addmac input[name="name"]'))?.type('console');
	await clickIn('.addmac .seg button', '^All direct$');
	await tap('.addmac [data-act="add"]');
	const newRow = 'button.dev[data-mac="02:aa:bb:cc:dd:01"]';
	const rowText = await page.waitForFunction((s) => document.querySelector('.truba-root')?.shadowRoot?.querySelector(s)?.innerText, { timeout: 5000 }, newRow)
		.then((h) => h.jsonValue()).catch(() => '');
	result(/console/.test(rowText) && /offline/.test(rowText) && await shadowHas(page, newRow + ' .dot.warn[aria-label]'),
		'«Добавить по MAC»: строка «offline» с точкой изменения', rowText.replace(/\s+/g, ' '));
	// Тот же MAC ещё раз — новой секции нет, выбрана его строка.
	await tap('[data-act="add-mac"]');
	await (await el('.addmac input[name="mac"]'))?.type('02:aa:bb:cc:dd:01');
	await clickIn('.addmac .seg button', '^All direct$');   // Политика из формы — его секции
	await tap('.addmac [data-act="add"]');
	const same = await page.evaluate(async () => (await L.require('uci')).sections('truba', 'device')
		.filter((s) => String(s.mac).toLowerCase() == '02:aa:bb:cc:dd:01').length);
	result(same == 1 && await shadowHas(page, newRow + '.sel'), '«Добавить по MAC»: тот же MAC — без второй секции, строка выбрана', String(same));
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(await applied(t0, async () => {
		const d = (await ubus('truba', 'devices')).devices.find((x) => x.mac == '02:aa:bb:cc:dd:01');
		return d?.policy == 'direct' && d.source == 'config' && d.ip == null;
	}), '«Добавить по MAC» → служба знает устройство: «напрямую», из настроек');

	// «Добавить по MAC» с MAC устройства в сети, у которого секция уже есть: Политика из формы — его
	// секции, выбрана его строка. Затем «Сбросить» — изменение не нужно.
	await page.goto(url('devices'), { waitUntil: 'networkidle2' });
	await settled(page);
	await tap('[data-act="add-mac"]');
	await (await el('.addmac input[name="mac"]'))?.type('02:11:22:33:44:55');
	await clickIn('.addmac .seg button', '^All direct$');
	await tap('.addmac [data-act="add"]');
	await sleep(300);
	const online = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		return { sel: !!r.querySelector('button.dev.sel[data-ip="192.168.1.50"]'),
			pol: [ ...r.querySelectorAll('.panel .policy button') ].find((b) => b.getAttribute('aria-pressed') == 'true')?.textContent };
	});
	result(online.sel && online.pol == 'All direct', '«Добавить по MAC»: устройство в сети — его строка выбрана, Политика из формы', JSON.stringify(online));
	// Имя устройства с секцией меняется в панели.
	const nameIn = await el('.panel input[name="devname"]');
	await nameIn?.click({ clickCount: 3 });
	await nameIn?.type('tv-box');
	await page.keyboard.press('Tab');
	await sleep(300);
	const renamed = await page.evaluate(async () => ({
		row: document.querySelector('.truba-root').shadowRoot.querySelector('button.dev[data-ip="192.168.1.50"]')?.innerText || '',
		uci: (await L.require('uci')).sections('truba', 'device').find((s) => String(s.mac).toLowerCase() == '02:11:22:33:44:55')?.name
	}));
	result(!!nameIn && renamed.uci == 'tv-box' && /tv-box/.test(renamed.row), '«Устройства»: имя меняется в панели', JSON.stringify(renamed));
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);
	await settled(page);

	// «По правилам» убирает секцию: устройство без Политики и без трафика уходит из списка.
	t0 = await time();
	await tap(newRow);
	await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.panel .policy .seg'), { timeout: 5000 }).catch(() => {});
	await clickIn('.panel .policy button', '^By rules$');
	const gone = await page.waitForFunction((s) => !document.querySelector('.truba-root').shadowRoot.querySelector(s), { timeout: 5000 }, newRow)
		.then(() => true).catch(() => false);
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(gone && await applied(t0, async () => !(await ubus('truba', 'devices')).devices.some((x) => x.mac == '02:aa:bb:cc:dd:01')) &&
		!(await devSecs('02:aa:bb:cc:dd:01')).length, '«По правилам»: секция убрана, устройство ушло из списка');

	// Секция с неверным MAC: служба её пропускает и предупреждает, ссылка ведёт сюда — здесь её видно и можно убрать.
	await ubus('uci', 'add', { config: 'truba', type: 'device', values: { mac: 'zz:zz', policy: 'direct' } });
	await ubus('uci', 'commit', { config: 'truba' });
	await page.goto(url('devices'), { waitUntil: 'networkidle2' });
	await settled(page);
	const badText = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.badmac')?.innerText || '');
	await tap('.badmac [data-act="remove-bad"]');
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(/zz:zz/.test(badText) && !(await devSecs('zz:zz')).length, '«Устройства»: секция с неверным MAC видна и убирается',
		badText.replace(/\s+/g, ' '));

	// 3. Переключатель «Маршрутизация» в строке состояния «Обзора» — выкл, применение — панелью изменений.
	t0 = await time();
	await page.goto(url('overview'), { waitUntil: 'networkidle2' });
	await settled(page);
	await (await shadowSel(page, 'input[data-opt="truba.main.routing"]')).click();
	const bar = await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.changes')?.innerText,
		{ timeout: 5000 }).then((h) => h.jsonValue()).catch(() => '');
	result(/Unapplied changes: 1/.test(bar), 'панель изменений: одно несохранённое изменение', bar.replace(/\s+/g, ' '));
	// Переключатель — в строке состояния наверху: панель должна быть видна сразу, без прокрутки.
	const inView = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot.querySelector('.changes').getBoundingClientRect();
		return r.top >= 0 && r.bottom <= window.innerHeight;
	});
	result(inView, 'панель изменений на 1280×900 — в пределах экрана');
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

	// «Устройства» на телефоне — здесь, а не сразу после входа: к этому времени закрылась минута трафика
	// стенда, и в панели есть график — она выше и не должна уходить за край экрана.
	await page.setViewport({ width: 375, height: 812 });
	await page.goto(url('devices'), { waitUntil: 'networkidle2' });
	await settled(page);
	await tap(rowSel('192.168.1.50'));
	// Панель растёт, пока рисуется график: мерить, когда в ней уже есть холст uPlot (трафик на стенде есть).
	const measure = () => {
		const p = document.querySelector('.truba-root').shadowRoot.querySelector('.panel');
		const r = p?.getBoundingClientRect();
		return { ready: !!p?.querySelector('canvas'), ok: !!r && r.top >= 0 && r.bottom <= window.innerHeight + 1 && r.left >= 0 && r.right <= window.innerWidth + 1,
			doc: document.documentElement.scrollWidth, win: window.innerWidth, top: r && Math.round(r.top), bottom: r && Math.round(r.bottom), vh: window.innerHeight };
	};
	await page.waitForFunction(`(${measure})().ready`, { timeout: 30000 }).catch(() => {});
	await sleep(300);
	const sheet = await page.evaluate(measure);
	result(sheet.ok && sheet.doc <= sheet.win, '«Устройства» 375: панель в пределах экрана, без горизонтальной прокрутки', JSON.stringify(sheet));
	// Несохранённое изменение: панель изменений не закрывает низ панели устройства.
	await clickIn('.panel .policy button', '^All direct$');
	await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.changes'), { timeout: 5000 }).catch(() => {});
	await sleep(300);
	const overlap = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		const p = r.querySelector('.panel')?.getBoundingClientRect(), b = r.querySelector('.changes')?.getBoundingClientRect();
		return { panel: p && Math.round(p.bottom), bar: b && Math.round(b.top) };
	});
	result(overlap.bar != null && overlap.panel <= overlap.bar + 1, '«Устройства» 375: панель изменений не закрывает панель устройства', JSON.stringify(overlap));
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);
	await page.screenshot({ path: `${out}/devices-375.png`, fullPage: true });
	await page.setViewport({ width: 1280, height: 900 });

	// Длинное неверное значение настройки попадает в предупреждение как есть — и на телефоне не должно
	// растягивать страницу вбок. Порт DNS из 79 цифр и буквы служба пропускает как неверный (ADR 0015).
	t0 = await time();
	const prevPort = await ubus('uci', 'get', { config: 'truba', section: 'dns', option: 'port' }).then((r) => r.value).catch(() => null);
	const setPort = async (v) => {
		if (v == null)
			await ubus('uci', 'delete', { config: 'truba', section: 'dns', option: 'port' });
		else
			await ubus('uci', 'set', { config: 'truba', section: 'dns', values: { port: v } });
		await ubus('uci', 'commit', { config: 'truba' });
	};
	await setPort('9'.repeat(79) + 'x');
	result(await applied(t0, (st) => (st.applied.invalid || []).some((x) => x.key == 'dns.port')), 'неверный порт DNS — в предупреждениях');
	await page.setViewport({ width: 375, height: 812 });
	await page.goto(url('overview'), { waitUntil: 'networkidle2' });
	await settled(page);
	const wide = await page.evaluate(() => {
		const tr = document.querySelector('.truba-root')?.shadowRoot?.querySelector('.tr');
		return { doc: document.documentElement.scrollWidth, win: window.innerWidth, tr: tr ? tr.scrollWidth - tr.clientWidth : 0 };
	});
	result(wide.doc <= wide.win && wide.tr <= 0, 'длинное значение в предупреждении: без горизонтальной прокрутки на 375', JSON.stringify(wide));
	await page.screenshot({ path: `${out}/overview-long-warning-375.png`, fullPage: true });
	t0 = await time();
	await setPort(prevPort);
	result(await applied(t0, (st) => !(st.applied.invalid || []).length), 'порт DNS восстановлен');
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
