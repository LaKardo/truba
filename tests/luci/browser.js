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
const tabs = [ 'overview', 'devices', 'rules', 'tunnel', 'dns', 'inbound', 'log' ];
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

// Применение запущено («Применить» панели изменений) — дождаться его конца. Оно идёт с откатом: окно
// состояния висит, пока LuCI не подтвердит изменения. Уйти раньше — значит получить откат, а на следующей
// странице окно ожидания поверх своих окон.
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
		// «Loading view…» после ожидания — представление не отрисовалось: ошибку LuCI показывает над ним, вне #view.
		result(!/Unable to load|TypeError|ReferenceError|Error: |Authorization Required|Loading view/.test(text), `вкладка ${t}`,
			text.replace(/\s+/g, ' ').slice(0, 100));
		fs.writeFileSync(`${out}/${t}.txt`, text);
		await page.screenshot({ path: `${out}/${t}.png`, fullPage: true });
		// Подсказки полей — из схемы службы (truba.schema, ADR 0015), а не из представления.
		if (t == 'dns' || t == 'tunnel') {
			// Обе на новом интерфейсе: поле в Shadow DOM.
			const ph = await page.evaluate((t) => document.querySelector('.truba-root')?.shadowRoot?.querySelector(
				(t == 'dns') ? 'input[data-opt="truba.dns.port"]' : 'input[data-opt="truba.watchdog.handshake_max"]')?.placeholder, t);
			const sch = await ubus('truba', 'schema');
			const want = String(t == 'dns' ? sch.sections.dns.port.def : sch.sections.watchdog.handshake_max.def);
			result(ph === want, `вкладка ${t}: подсказка поля — умолчание схемы службы`, `${ph} / ${want}`);
		}
	}

	const el = async (sel) => (await shadowSel(page, sel)).asElement();
	const tap = async (sel) => { const e = await el(sel); if (e) await e.click(); return !!e; };
	const clickIn = (sel, re) => page.evaluate((sel, re) => [ ...document.querySelector('.truba-root').shadowRoot.querySelectorAll(sel) ]
		.find((b) => new RegExp(re).test(b.textContent))?.click(), sel, re);
	// Нажатый вариант группы сегментов.
	const pressed = (sel) => page.evaluate((sel) => [ ...document.querySelector('.truba-root').shadowRoot.querySelectorAll(sel + ' button') ]
		.find((b) => b.getAttribute('aria-pressed') == 'true')?.textContent, sel);

	// Старые адреса «Маршрутизации» и списков открывают «Правила» (spec §3.1).
	for (const old of [ 'routing', 'lists' ]) {
		await page.goto(url(old), { waitUntil: 'networkidle2' });
		await settled(page);
		result(await shadowHas(page, '.card.rules-cats'), `адрес ${old} открывает «Правила»`);
	}
	await page.goto(url('diagnostics'), { waitUntil: 'networkidle2' });
	await settled(page);
	result(await shadowHas(page, '.card.log'), 'адрес diagnostics открывает «Журнал»');

	// «Куда пойдёт» на «Правилах» (была «Проверить домен/IP» на «Диагностике»): IP из geoip:ru.
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	await (await el('.where input[name="target"]'))?.type('77.88.8.8');
	await page.keyboard.press('Enter');
	const verdict = await page.waitForFunction(() => /77\.88\.8\.8 →[^\n]*/.exec(
		document.querySelector('.truba-root')?.shadowRoot?.querySelector('.where .check-res')?.innerText || '')?.[0],
		{ timeout: 20000 }).then((h) => h.jsonValue()).catch(() => null);
	result(verdict != null, '«Правила»: «Куда пойдёт»', verdict);
	await page.screenshot({ path: `${out}/rules-check.png`, fullPage: true });

	// Последнюю Зону снять нельзя: без Зон служба взяла бы умолчание схемы. На стенде выбрана одна lan. Кнопка
	// не disabled, а aria-disabled: экранный чтец её объявляет, а нажатие объясняет запрет сообщением — и на телефоне.
	const zoneSel = (z) => `.zones button[data-zone="${z}"]`;
	const zoneOf = (z) => page.evaluate((s) => {
		const b = document.querySelector('.truba-root').shadowRoot.querySelector(s);
		return { on: b?.getAttribute('aria-pressed'), aria: b?.getAttribute('aria-disabled'), disabled: b?.disabled };
	}, zoneSel(z));
	const lastZone = await zoneOf('lan');
	await tap(zoneSel('lan'));
	lastZone.toast = await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.toast')?.innerText, { timeout: 3000 })
		.then((h) => h.jsonValue()).catch(() => '');
	lastZone.after = (await zoneOf('lan')).on;
	lastZone.changes = await shadowHas(page, '.changes');
	result(lastZone.on == 'true' && lastZone.aria == 'true' && !lastZone.disabled && /At least one zone/.test(lastZone.toast) && lastZone.after == 'true' &&
		!lastZone.changes, '«Правила»: последнюю Зону снять нельзя — нажатие объясняет', JSON.stringify(lastZone));
	// Зоны: добавить wan, снять lan — в UCI браузера список Зон; затем «Сбросить».
	const uciZone = () => page.evaluate(async () => (await L.require('uci')).get('truba', 'main', 'zone'));
	await tap(zoneSel('wan'));
	await sleep(300);
	const z1 = await uciZone();
	await tap(zoneSel('lan'));
	await sleep(300);
	const z2 = await uciZone();
	result(JSON.stringify(z1) == '["lan","wan"]' && JSON.stringify(z2) == '["wan"]', '«Правила»: Зоны — добавить и снять', JSON.stringify({ z1, z2 }));
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);

	// «Устройства» (ADR 0018): на стенде сосед с MAC и узел mesh-VPN без него (stand.sh).
	const rowSel = (ip) => `button.dev[data-ip="${ip}"]`;
	const panelText = () => page.evaluate(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.panel')?.innerText || '');
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

	// 1. «Правила»: youtube → Напрямую в Режиме «Всё в туннель», применение — панелью изменений.
	const catRow = '.rules-cats [data-cat="geosite:youtube"]';
	// Чип по умолчанию — «С Действием»: поиск всё равно находит Категорию без Действия.
	const findCat = async () => {
		await (await el('.rules-cats input[type="search"]'))?.type('youtube');
		// Список Категорий может прийти позже страницы (Наборы правил распаковываются) — ждём саму строку.
		await page.waitForFunction((s) => document.querySelector('.truba-root')?.shadowRoot?.querySelector(s), { timeout: 20000 }, catRow).catch(() => {});
	};
	let t0 = await time();
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	await findCat();
	await clickIn(catRow + ' .seg button', '^Direct$');
	const dotted = await shadowHas(page, catRow + ' .dot.warn[aria-label]');
	const oneChange = /Unapplied changes: 1/.test(await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.changes')?.innerText || ''));
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(dotted && oneChange && await applied(t0, (st) => (st.applied.geosite_order || []).includes('youtube=direct')),
		'«Правила»: Действие Категории — точка и одно изменение, «Применить» → служба перестроила правила', JSON.stringify({ dotted, oneChange }));

	// Режим «Выборочный», не применённый: Категории следуют за ним. «Применить» → служба в этом Режиме; затем обратно.
	t0 = await time();
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	await findCat();
	await clickIn('.card.mode .seg button', '^All via tunnel$');
	await clickIn(catRow + ' .seg button', '^Direct$');
	await sleep(300);
	result(!await shadowHas(page, '.changes'), '«Правила»: нажатие на уже выбранный Режим и Действие — без изменений');
	await clickIn(catRow + ' .seg button', '^By mode$');
	await sleep(300);
	await clickIn(catRow + ' .seg button', '^Tunnel$');
	await sleep(300);
	const viaMode = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.changes')?.innerText.replace(/\s+/g, ' ') || '');
	await clickIn(catRow + ' .seg button', '^Direct$');
	await sleep(300);
	result(/Unapplied changes: 1/.test(viaMode) && !await shadowHas(page, '.changes'), '«Правила»: Действие через «По режиму» — одно изменение, возврат — ни одного', viaMode);
	const viewLabel = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.rules-cats .card-h .seg')?.getAttribute('aria-label'));
	result(viewLabel == 'Show actions for mode', '«Правила»: сегмент вида Категорий — своя подпись', viewLabel);
	await clickIn('.card.mode .seg button', '^Selective$');
	const catMode = await pressed('.rules-cats .card-h .seg');
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(catMode == 'Selective' && await applied(t0, (st) => st.mode == 'selective'), '«Правила»: Режим «Выборочный» — Категории следуют, служба применила', catMode);
	t0 = await time();
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	result(await pressed('.rules-cats .card-h .seg') == 'Selective', '«Правила»: после применения Категории — Режима «Выборочный»');
	await clickIn('.card.mode .seg button', '^All via tunnel$');
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(await applied(t0, (st) => st.mode == 'all'), '«Правила»: Режим «Всё в туннель» снова');

	// «Стартовые настройки» — в UCI браузера, с подтверждением; затем «Сбросить».
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	await findCat();
	await clickIn(catRow + ' .seg button', '^Block$');
	await tap('.rules-cats [data-act="starting"]');
	// Окно открывается в эффекте Preact — после отрисовки, не сразу после клика.
	const dlgOpen = await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('dialog[open]'), { timeout: 5000 })
		.then(() => true).catch(() => false);
	const dlgName = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot, d = r.querySelector('dialog[open]');
		return d && r.getElementById(d.getAttribute('aria-labelledby'))?.textContent;
	});
	result(/Reset all category actions/.test(dlgName || ''), '«Правила»: у окна подтверждения — доступное имя', dlgName);
	await tap('dialog[open] [data-act="confirm"]');
	const startAct = (await ubus('truba', 'categories')).starting.find((r) => r.mode == 'all' && r.set == 'geosite' && r.tag == 'youtube')?.action || 'mode';
	const LABEL = { mode: 'By mode', direct: 'Direct', tunnel: 'Tunnel', block: 'Block' };
	await page.waitForFunction((s, want) => [ ...document.querySelector('.truba-root').shadowRoot.querySelectorAll(s + ' .seg button') ]
		.find((b) => b.getAttribute('aria-pressed') == 'true')?.textContent == want, { timeout: 5000 }, catRow, LABEL[startAct]).catch(() => {});
	const afterStart = await pressed(catRow + ' .seg');
	result(dlgOpen && afterStart == LABEL[startAct] && !await shadowHas(page, 'dialog[open]'),
		'«Правила»: «Стартовые настройки» — окно подтверждения, Действие как у новой установки', `${dlgOpen} ${afterStart} / ${LABEL[startAct]}`);
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);

	// Правило для Категории, которой нет в Наборе: предупреждение с «Remove», после применения секции нет.
	await ubus('uci', 'add', { config: 'truba', type: 'rule', values: { set: 'geosite', tag: 'zz-gone', action: 'tunnel' } });
	await ubus('uci', 'commit', { config: 'truba' });
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	const missText = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.rules-cats .missing')?.innerText || '');
	await tap('.rules-cats [data-act="remove-missing"]');
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	const ruleSecs = Object.values((await ubus('uci', 'get', { config: 'truba', type: 'rule' })).values || {});
	result(/zz-gone/.test(missText) && !ruleSecs.some((x) => x.tag == 'zz-gone'), '«Правила»: пропавшая Категория — предупреждение и «Remove»',
		missText.replace(/\s+/g, ' '));

	// Неверное время обновления уже в настройках (правка из консоли): блок с полем раскрыт — иначе «Применить»
	// недоступна без видимой причины.
	await ubus('uci', 'set', { config: 'truba', section: 'lists', values: { update_utc: '25:00' } });
	await ubus('uci', 'commit', { config: 'truba' });
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	await sleep(300);
	const shownBad = await page.evaluate(() => {
		const i = document.querySelector('.truba-root').shadowRoot.querySelector('input[data-opt="truba.lists.update_utc"]');
		return { invalid: i?.getAttribute('aria-invalid'), open: !!i?.closest('details')?.open };
	});
	result(shownBad.invalid == 'true' && shownBad.open, '«Правила»: неверное значение из настроек — блок с полем раскрыт', JSON.stringify(shownBad));
	await ubus('uci', 'set', { config: 'truba', section: 'lists', values: { update_utc: '12:00' } });
	await ubus('uci', 'commit', { config: 'truba' });

	// Наборы правил — на «Правилах» (были на «DNS и списках»): версии с датой.
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	const vers = await page.evaluate(() => [ ...document.querySelector('.truba-root').shadowRoot.querySelectorAll('.card.rule-sets .ver') ]
		.map((r) => [ r.dataset.set, r.innerText.replace(/\s+/g, ' ') ]));
	result(vers.length == 2 && vers.every(([ k, t ]) => [ 'geoip', 'geosite' ].includes(k) && /20\d\d/.test(t)), '«Правила»: Наборы правил — geoip и geosite с датой',
		JSON.stringify(vers));
	// «Откатить» — с подтверждением; на стенде предыдущих версий нет.
	const openDialog = () => page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('dialog[open]'), { timeout: 5000 })
		.then(() => true).catch(() => false);
	await tap('.rule-sets [data-act="rollback"]');
	const rbOpen = await openDialog();
	await tap('dialog[open] [data-act="confirm"]');
	const toast = await page.waitForFunction(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.toast')?.innerText, { timeout: 10000 })
		.then((h) => h.jsonValue()).catch(() => '');
	result(rbOpen && /No previous version/.test(toast), '«Правила»: «Откатить» — подтверждение и сообщение', `${rbOpen} ${toast}`);
	// Время обновления по схеме: неверное — ошибка у поля, в UCI не пишется, «Применить» недоступна; верное снимает запрет.
	await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelectorAll('.rule-sets details.fold').forEach((d) => { d.open = true; }));
	await tap('input[data-opt="truba.lists.via_tunnel"]');
	const utc = await el('input[data-opt="truba.lists.update_utc"]');
	const uciUtc = () => page.evaluate(async () => (await L.require('uci')).get('truba', 'lists', 'update_utc') ?? null);
	const utcBefore = await uciUtc();
	// Ввод заново — выделением в самом поле, а не тройным кликом: внизу экрана поле может быть под
	// прилипшей панелью изменений, и клик пришёлся бы в неё.
	const retype = async (v) => {
		await utc?.evaluate((e) => { e.focus(); e.select(); });
		await page.keyboard.type(v);
		return utc?.evaluate((e) => e.value);
	};
	await retype('25:00');
	const early = await shadowHas(page, '.rule-sets [role="alert"]');
	await page.waitForFunction(() => document.querySelector('.truba-root').shadowRoot.querySelector('.rule-sets [role="alert"]'), { timeout: 3000 }).catch(() => {});
	result(!early, '«Правила»: ошибка поля — после паузы в наборе, а не на каждое нажатие');
	const badUtc = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		return { err: r.querySelector('.rule-sets .field.bad [role="alert"]')?.textContent || '', apply: r.querySelector('.changes [data-act="apply"]')?.disabled,
			bar: r.querySelector('.changes')?.innerText.replace(/\s+/g, ' ') || '' };
	});
	badUtc.uci = await uciUtc();
	await page.evaluate(() => [ ...document.querySelectorAll('.cbi-page-actions *') ]
		.find((x) => x.childElementCount == 0 && x.textContent.trim() == 'Save & Apply')?.click());
	await sleep(2000);
	const footer = { via: (await ubus('uci', 'get', { config: 'truba', section: 'lists', option: 'via_tunnel' }).catch(() => ({}))).value,
		toast: await page.evaluate(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.toast')?.innerText || '') };
	result(footer.via == '1' && /Fix the highlighted fields/.test(footer.toast), '«Правила»: «Save & Apply» LuCI при неверном поле ничего не применяет',
		JSON.stringify(footer));
	const typed = await retype('05:30');
	// Счёт неверных полей меняет эффект Preact — после отрисовки кадра, не сразу после ввода.
	await page.waitForFunction(() => document.querySelector('.truba-root').shadowRoot.querySelector('.changes [data-act="apply"]')?.disabled === false,
		{ timeout: 3000 }).catch(() => {});
	const goodUtc = { typed, apply: await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.changes [data-act="apply"]')?.disabled),
		uci: await uciUtc() };
	result(!!utc && /Unapplied changes: 1/.test(badUtc.bar) && /HH:MM/.test(badUtc.err) && badUtc.apply === true && badUtc.uci === utcBefore &&
		goodUtc.apply === false && goodUtc.uci == '05:30', '«Правила»: время обновления — неверное не пишется и держит «Применить»', JSON.stringify({ badUtc, goodUtc }));
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);

	// «DNS» (spec §5.5): состояние mosdns и кэша — только то, что mosdns отдаёт (§6.3); поля кэша и порта; Наборов
	// правил здесь нет. Числа плиток — с разделителями разрядов браузера или «—», не NaN.
	await page.goto(url('dns'), { waitUntil: 'networkidle2' });
	await settled(page);
	const dns = await page.evaluate(() => { const r = document.querySelector('.truba-root').shadowRoot;
		return { h2: r.querySelector('.head h2')?.textContent, tiles: r.querySelectorAll('.card.state .stat').length,
			badge: r.querySelector('.card.state .badge')?.textContent, rs: /Rule sets/.test(r.textContent),
			fields: [ 'cache_size', 'lazy_cache_ttl', 'ttl_max', 'set_timeout', 'port' ].filter((o) => r.querySelector(`input[data-opt="truba.dns.${o}"]`)).length,
			vals: [ ...r.querySelectorAll('.card.state .stat b') ].map((b) => b.textContent) }; });
	result(dns.h2 == 'DNS' && dns.tiles == 4 && dns.badge == 'mosdns running' && !dns.rs && dns.fields == 5 &&
		dns.vals.every((v) => /^(—|\d[\d\s,. ]*%?)$/.test(v)), '«DNS»: состояние, 4 плитки без NaN, поля кэша и порта, без Наборов правил', JSON.stringify(dns));
	// Перехват DNS: «Применить» доходит до настроек и службы; затем прежнее значение.
	const hijack = async () => (await ubus('uci', 'get', { config: 'truba', section: 'main', option: 'dns_hijack' }).catch(() => ({}))).value;
	for (const want of [ '0', '1' ]) {
		t0 = await time();
		await tap('input[data-opt="truba.main.dns_hijack"]');
		await tap('.changes [data-act="apply"]');
		await waitApply(page);
		result(await applied(t0, async () => await hijack() == want), `«DNS»: перехват ${want == '0' ? 'выкл' : 'вкл'} — «Применить» дошло до службы`);
		await page.goto(url('dns'), { waitUntil: 'networkidle2' });
		await settled(page);
	}

	// «Туннель» (spec §5.4): состояние, подключение к Трубе, контроль. На стенде awg0 — dummy с пиром
	// 203.0.113.10:51820 (stand.sh).
	await page.goto(url('tunnel'), { waitUntil: 'networkidle2' });
	await settled(page);
	const tun = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		// Раскладка карточки: зона импорта — во всю ширину карточки, а не узкой колонкой чужой сетки.
		const card = r.querySelector('.card.peer'), drop = card?.querySelector('.drop');
		return { stats: r.querySelectorAll('.card.state .stat').length, on: r.querySelector('input[data-opt="network.awg0.disabled"]')?.checked,
			conn: (card?.innerText || '').replace(/\s+/g, ' ').slice(0, 100),
			wide: (card && drop) ? +(drop.getBoundingClientRect().width / card.clientWidth).toFixed(2) : 0 };
	});
	result(tun.stats == 4 && tun.on === true && /203\.0\.113\.10:51820/.test(tun.conn) && tun.wide >= 0.8,
		'«Туннель»: плитки состояния, переключатель, адрес Трубы; зона импорта во всю ширину карточки', JSON.stringify(tun));
	// MTU — опция network со своей проверкой: неверное не пишется и держит «Применить» и «Save & Apply» LuCI.
	// Ввод заново — выделением в самом поле: под прилипшей панелью изменений клик пришёлся бы в неё.
	const retypeIn = async (h, v) => {
		await h?.evaluate((e) => { e.focus(); e.select(); });
		await page.keyboard.type(v);
	};
	const uciKs = async () => (await ubus('uci', 'get', { config: 'truba', section: 'main', option: 'killswitch' }).catch(() => ({}))).value ?? null;
	const uciMtu = () => page.evaluate(async () => (await L.require('uci')).get('network', 'awg0', 'mtu') ?? null);
	const ksBefore = await uciKs(), mtuBefore = await uciMtu();
	await tap('input[data-opt="truba.main.killswitch"]');
	const mtu = await el('input[data-opt="network.awg0.mtu"]');
	await retypeIn(mtu, '9000');
	await page.waitForFunction(() => document.querySelector('.truba-root').shadowRoot.querySelector('.card.peer .field.bad [role="alert"]'), { timeout: 3000 }).catch(() => {});
	const badMtu = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		return { err: r.querySelector('.card.peer .field.bad [role="alert"]')?.textContent || '', apply: r.querySelector('.changes [data-act="apply"]')?.disabled };
	});
	badMtu.uci = await uciMtu();
	await page.evaluate(() => [ ...document.querySelectorAll('.cbi-page-actions *') ]
		.find((x) => x.childElementCount == 0 && x.textContent.trim() == 'Save & Apply')?.click());
	await sleep(2000);
	badMtu.ks = await uciKs();
	badMtu.toast = await page.evaluate(() => document.querySelector('.truba-root')?.shadowRoot?.querySelector('.toast')?.innerText || '');
	await retypeIn(mtu, '1280');
	await page.waitForFunction(() => document.querySelector('.truba-root').shadowRoot.querySelector('.changes [data-act="apply"]')?.disabled === false,
		{ timeout: 3000 }).catch(() => {});
	const goodMtu = { apply: await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.changes [data-act="apply"]')?.disabled),
		uci: await uciMtu() };
	result(!!mtu && /576/.test(badMtu.err) && badMtu.apply === true && badMtu.uci === mtuBefore && badMtu.ks === ksBefore && /Fix the highlighted fields/.test(badMtu.toast) &&
		goodMtu.apply === false && goodMtu.uci === '1280', '«Туннель»: MTU — неверное не пишется и держит «Применить» и «Save & Apply»', JSON.stringify({ badMtu, goodMtu }));
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);
	await settled(page);
	// Импорт router.conf (Решение 5): файл в зону — UCI браузера; адрес, строка «Протокол» и поля — новые. S1 меньше
	// 12 при защите заголовков — ошибка у поля.
	fs.writeFileSync(`${out}/router.conf`, [ '[Interface]', 'PrivateKey = cHJpdmF0ZS1rZXktZm9yLXRlc3RzLW9ubHk=', 'Address = 10.77.77.2/30', 'MTU = 1313',
		'Jc = 4', 'S1 = 20', 'S2 = 40', 'H1 = 100-200', 'HeaderProtectionKey = aHBrLWZvci10ZXN0cw==', '[Peer]', 'PublicKey = cHVibGljLWtleS1mb3ItdGVzdHMtb25seQ==',
		'Endpoint = 198.51.100.7:40243', 'PersistentKeepalive = 15-25', '' ].join('\r\n'));
	await (await el('.drop input[type="file"]'))?.uploadFile(`${out}/router.conf`);
	await page.waitForFunction(() => /AmneziaWG 3\.1/.test(document.querySelector('.truba-root')?.shadowRoot?.querySelector('.card.peer')?.innerText || ''),
		{ timeout: 5000 }).catch(() => {});
	await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelectorAll('.card.peer details.fold').forEach((d) => { d.open = true; }));
	const imp = await page.evaluate(async () => {
		const u = await L.require('uci'), r = document.querySelector('.truba-root').shadowRoot;
		return { text: (r.querySelector('.card.peer')?.innerText || '').replace(/\s+/g, ' ').slice(0, 160), proto: u.get('network', 'awg0', 'proto'),
			port: (u.sections('network', 'amneziawg_awg0')[0] || {}).endpoint_port, s1: r.querySelector('input[data-opt="network.awg0.awg_s1"]')?.value,
			bar: !!r.querySelector('.changes') };
	});
	// Уход из поля показывает ошибку сразу (пауза в наборе проверена на «Правилах»).
	await retypeIn(await el('input[data-opt="network.awg0.awg_s1"]'), '5');
	await page.keyboard.press('Tab');
	imp.s1Err = await page.waitForFunction(() => document.querySelector('.truba-root').shadowRoot.querySelector('.card.peer .field.bad [role="alert"]')?.textContent,
		{ timeout: 5000 }).then((h) => h.jsonValue()).catch(() => '');
	imp.s1Typed = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot, i = r.querySelector('input[data-opt="network.awg0.awg_s1"]');
		return { value: i?.value, invalid: i?.getAttribute('aria-invalid') };
	});
	result(/198\.51\.100\.7:40243/.test(imp.text) && /AmneziaWG 3\.1/.test(imp.text) && imp.proto == 'amneziawg' && imp.port == '40243' && imp.s1 == '20' && imp.bar &&
		/at least 12/.test(imp.s1Err), '«Туннель»: импорт router.conf — адрес, протокол и поля; S1 меньше 12 с защитой заголовков — ошибка', JSON.stringify(imp));
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);
	await settled(page);
	// Неверная вставка — ошибка под зоной, изменений нет.
	await (await el('.drop textarea'))?.type('[Peer]\nPublicKey = x');
	await tap('.drop [data-act="import"]');
	await sleep(300);
	const badConf = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		return { err: r.querySelector('.drop .err-text')?.textContent || '', bar: !!r.querySelector('.changes') };
	});
	result(/No PrivateKey/.test(badConf.err) && !badConf.bar, '«Туннель»: неверная вставка — ошибка под зоной, изменений нет', JSON.stringify(badConf));
	// Туннель не настроен (секции интерфейса нет): пояснение и импорт, переключатель недоступен.
	await page.evaluate(async () => (await L.require('truba.ui.app')).remove('network', 'awg0'));
	await sleep(300);
	const nc = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		return { text: (r.querySelector('.card.peer')?.innerText || '').replace(/\s+/g, ' ').slice(0, 100), drop: !!r.querySelector('.card.peer .drop'),
			sw: r.querySelector('input[data-opt="network.awg0.disabled"]')?.disabled };
	});
	result(/not configured yet/.test(nc.text) && nc.drop && nc.sw === true, '«Туннель»: не настроен — пояснение, импорт, переключатель недоступен', JSON.stringify(nc));
	await Promise.all([ page.waitForNavigation({ waitUntil: 'networkidle2' }).catch(() => {}), tap('.changes [data-act="reset"]') ]);
	await settled(page);
	// «Проверить Туннель» (была на «Диагностике»): итог — в карточке подключения.
	await tap('[data-act="tunnel-test"]');
	const tt = await page.waitForFunction(() => {
		const r = document.querySelector('.truba-root')?.shadowRoot, t = r?.querySelector('.card.peer .tt-res')?.innerText || '';
		return !r?.querySelector('.card.peer .spinning') && t.trim() && t;
	}, { timeout: 45000 }).then((h) => h.jsonValue()).catch(() => '');
	result(!!tt, '«Туннель»: «Проверить Туннель» — итог в карточке', tt.replace(/\s+/g, ' ').slice(0, 100));
	// Аварийная блокировка — «Применить» на «Туннеле» доходит до службы; затем прежнее значение.
	t0 = await time();
	const ksOn = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('input[data-opt="truba.main.killswitch"]')?.checked);
	await tap('input[data-opt="truba.main.killswitch"]');
	await tap('.changes [data-act="apply"]');
	await waitApply(page);
	result(await applied(t0, (st) => st.killswitch === !ksOn), '«Применить» на «Туннеле»: Аварийная блокировка → действует');
	await ubus('uci', 'set', { config: 'truba', section: 'main', values: { killswitch: ksOn ? '1' : '0' } });
	await ubus('uci', 'commit', { config: 'truba' });

	// «Журнал» (spec §5.7): строки Трубы, её watchdog, mosdns и интерфейса Туннеля — новые сверху; уровень,
	// источники, «Следить» и «Скачать». На стенде есть строки netifd об awg0 — источник awg.
	await page.goto(url('log'), { waitUntil: 'networkidle2' });
	await settled(page);
	const logState = () => page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot, rows = [ ...r.querySelectorAll('.loglines .ln') ];
		return { n: rows.length, levels: [ ...new Set(rows.map((x) => x.dataset.level)) ], sources: [ ...new Set(rows.map((x) => x.dataset.source)) ],
			top: rows[0]?.textContent || '', empty: !!r.querySelector('.loglines .empty') };
	});
	// Время и источник — одной строкой при любом моноширинном шрифте: у шрифтов пользователей (Consolas, SF Mono)
	// знак шире, чем у шрифта стенда, — эту разницу изображает межбуквенный интервал.
	const logCols = () => page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot;
		const st = r.appendChild(document.createElement('style'));
		st.textContent = '.loglines { letter-spacing: .1em; }';
		// Строки текста — по его прямоугольникам, а не по высоте ячейки: ячейка тянется на высоту строки журнала,
		// когда переносится длинное сообщение.
		const lines = (s) => {
			const rg = document.createRange();
			rg.selectNodeContents(s);
			return rg.getClientRects().length;
		};
		const rows = [ ...r.querySelectorAll('.loglines .ln') ];
		const bad = rows.filter((row) => [ ...row.children ].slice(0, 2).some((s) => s.offsetParent &&
			(lines(s) > 1 || s.scrollWidth > s.clientWidth + 1))).length;
		st.remove();
		return { rows: rows.length, bad };
	});
	const cols1280 = await logCols();
	result(cols1280.rows > 0 && cols1280.bad === 0, '«Журнал»: время и источник — одной строкой, без обрезки', JSON.stringify(cols1280));
	const log0 = await logState();
	await clickIn('.log-bar .chips button', '^Errors');
	await sleep(200);
	const logErr = await logState();
	await clickIn('.log-bar .chips button', '^All');
	await clickIn('.log-bar .chips button', '^truba');   // снять источник truba
	await sleep(200);
	const logNoTruba = await logState();
	await clickIn('.log-bar .chips button', '^truba');
	result(log0.n > 0 && log0.sources.includes('awg') && log0.sources.includes('truba') && (logErr.empty || logErr.levels.every((l) => l == 'err')) &&
		!logNoTruba.sources.includes('truba') && logNoTruba.n < log0.n, '«Журнал»: строки, уровень, источники (awg — строки netifd об интерфейсе Туннеля)',
		JSON.stringify({ n: log0.n, sources: log0.sources, err: [ logErr.n, logErr.levels ], noTruba: [ logNoTruba.n, logNoTruba.sources ] }));
	// «Следить»: строки после reload службы («применено: …») приходят сами; выключено — журнал не спрашивается.
	const follow = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.log-bar .sw input')?.checked);
	const top1 = (await logState()).top;
	t0 = await time();
	await ubus('rc', 'init', { name: 'truba', action: 'reload' });
	const fresh = await page.waitForFunction((t) => (document.querySelector('.truba-root').shadowRoot.querySelector('.loglines .ln')?.textContent || '') != t,
		{ timeout: 20000 }, top1).then(() => true).catch(() => false);
	await applied(t0, () => true);
	await tap('.log-bar .sw input');
	await sleep(500);
	const top2 = (await logState()).top;
	t0 = await time();
	await ubus('rc', 'init', { name: 'truba', action: 'reload' });
	await applied(t0, () => true);
	await sleep(12000);
	const top3 = (await logState()).top;
	result(follow === true && fresh && top3 === top2, '«Журнал»: «Следить» — новые строки сами, выключено — без опроса', JSON.stringify({ follow, fresh, same: top3 === top2 }));
	// «Скачать»: показанные строки в .txt; сама загрузка подменена — нужны только содержимое и имя файла.
	await page.evaluate(() => {
		window.__blob = null;
		window.__name = null;
		const make = URL.createObjectURL.bind(URL);
		URL.createObjectURL = (b) => { window.__blob = b; return make(b); };
		HTMLAnchorElement.prototype.click = function() { window.__name = this.download; };
	});
	await tap('[data-act="download"]');
	await sleep(300);
	const dl = await page.evaluate(async () => ({ name: window.__name, lines: window.__blob ? (await window.__blob.text()).split('\n').filter((l) => l).length : -1,
		n: document.querySelector('.truba-root').shadowRoot.querySelectorAll('.loglines .ln').length }));
	result(/^truba-log-\d{8}-\d{4}\.txt$/.test(dl.name || '') && dl.n > 0 && dl.lines === dl.n, '«Журнал»: «Скачать» — показанные строки в .txt', JSON.stringify(dl));

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

	// «Правила» на телефоне: около 1 700 Категорий — не больше 100 строк сразу, Действие — системный выбор,
	// без горизонтальной прокрутки.
	await page.goto(url('rules'), { waitUntil: 'networkidle2' });
	await settled(page);
	await clickIn('.rules-cats .chips button', '^All');
	await sleep(300);
	const phone = await page.evaluate(() => {
		const r = document.querySelector('.truba-root').shadowRoot, tr = r.querySelector('.tr'), row = r.querySelector('.rules-cats [data-cat]');
		return { doc: document.documentElement.scrollWidth, win: window.innerWidth, tr: tr.scrollWidth - tr.clientWidth,
			rows: r.querySelectorAll('.rules-cats [data-cat]').length, more: !!r.querySelector('.rules-cats [data-act="show-all"]'),
			sel: row && getComputedStyle(row.querySelector('.ap-sel')).display, seg: row && getComputedStyle(row.querySelector('.seg')).display };
	});
	result(phone.doc <= phone.win && phone.tr <= 0 && phone.rows > 0 && phone.rows <= 100 && phone.sel != 'none' && phone.seg == 'none',
		'«Правила» 375: не больше 100 строк, Действие — select, без горизонтальной прокрутки', JSON.stringify(phone));
	await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelectorAll('.rule-sets details.fold').forEach((d) => { d.open = true; }));
	const versText = await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelector('.rule-sets .vers')?.innerText || '');
	result(/Current version/.test(versText) && /Previous version/.test(versText), '«Правила» 375: версии с подписями', versText.replace(/\s+/g, ' '));
	await page.screenshot({ path: `${out}/rules-375.png`, fullPage: true });
	// «Туннель» на телефоне: плитки по две, поля и зона импорта — без горизонтальной прокрутки.
	await page.goto(url('tunnel'), { waitUntil: 'networkidle2' });
	await settled(page);
	await page.evaluate(() => document.querySelector('.truba-root').shadowRoot.querySelectorAll('details.fold').forEach((d) => { d.open = true; }));
	const tun375 = await page.evaluate(() => {
		const tr = document.querySelector('.truba-root').shadowRoot.querySelector('.tr');
		return { doc: document.documentElement.scrollWidth, win: window.innerWidth, tr: tr.scrollWidth - tr.clientWidth };
	});
	result(tun375.doc <= tun375.win && tun375.tr <= 0, '«Туннель» 375: без горизонтальной прокрутки', JSON.stringify(tun375));
	await page.screenshot({ path: `${out}/tunnel-375.png`, fullPage: true });
	// «Журнал» на телефоне: длинные строки переносятся, без горизонтальной прокрутки.
	await page.goto(url('log'), { waitUntil: 'networkidle2' });
	await settled(page);
	const log375 = await page.evaluate(() => {
		const tr = document.querySelector('.truba-root').shadowRoot.querySelector('.tr');
		return { doc: document.documentElement.scrollWidth, win: window.innerWidth, tr: tr.scrollWidth - tr.clientWidth };
	});
	const cols375 = await logCols();
	result(log375.doc <= log375.win && log375.tr <= 0 && cols375.rows > 0 && cols375.bad === 0,
		'«Журнал» 375: без горизонтальной прокрутки, время — одной строкой', JSON.stringify({ ...log375, cols375 }));
	await page.screenshot({ path: `${out}/log-375.png`, fullPage: true });
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
