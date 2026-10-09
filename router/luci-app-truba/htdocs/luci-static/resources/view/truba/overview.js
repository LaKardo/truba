'use strict';
'require view';
'require poll';
'require uci';
'require truba.common as common';

// «Обзор» — сводка по всем частям Трубы: плитки со ссылками на вкладки, предупреждения
// и трафик устройств. Подробности и настройки каждой части — на её вкладке, здесь их нет.
// Страница строится один раз; опрос меняет только текст и классы готовых элементов,
// поэтому таблицы не пересчитывают ширину колонок и ничего не прыгает.

const POLL = 5;          // состояние — раз в 5 с
const NBSP = common.NBSP;

// Строки таблицы «Трафик устройств» и цвет точки перед названием.
const KINDS = [ 'tunnel', 'direct', 'inbound' ];
const KIND_LEVELS = { tunnel: common.ACTION_LEVELS.tunnel, direct: common.ACTION_LEVELS.direct, inbound: 'inbound' };

// ---- История скорости ----

// Историю ведёт сам Роутер (процесс truba stats), поэтому она не рвётся, когда вкладка
// свёрнута или браузер закрыт: страница при открытии забирает её целиком, дальше — только
// новые точки. Точка: [время Роутера, байт/с — Туннель ↓ ↑, Напрямую ↓ ↑, Входящие ↓ ↑,
// новых соединений в минуту — Туннель, Напрямую, Входящие]; [время] — разрыв (счётчики
// начаты заново). fine — точки по 5 с за час, min — поминутные средние за сутки (в них
// только значения графика), загружаются, когда выбраны 24 ч. now — время Роутера на
// последнем ответе: ось строится по нему, а не по часам компьютера — они могут расходиться.
const hist = {
	fine: { span: 3600, step: POLL, points: [], loaded: false },
	min: { span: 86400, step: 60, points: [], loaded: false },
	now: null
};

// Места значений в точке: к устройствам, от устройств, новых соединений в минуту.
const COLS = { tunnel: { down: 1, up: 2, conn: 7 }, direct: { down: 3, up: 4, conn: 8 }, inbound: { down: 5, up: 6, conn: 9 } };

// Сроки графика; выбранный запоминается в браузере. Больше часа — поминутные средние.
const SPANS = [
	{ span: 600, label: _('10 min'), from: _('10 min ago') },
	{ span: 3600, label: _('1 h'), from: _('1 h ago') },
	{ span: 86400, label: _('24 h'), from: _('24 h ago') }
];
const SPAN_KEY = 'truba.span';
let span = 600;
try {
	const s = +localStorage.getItem(SPAN_KEY);
	if (SPANS.some((x) => x.span == s))
		span = s;
}
catch (e) { }

const ring = () => (span > hist.fine.span) ? hist.min : hist.fine;
const lastT = (h) => h.points.length ? h.points[h.points.length - 1][0] : 0;

// Забрать точки новее уже известных и убрать вышедшие за срок. Ошибка — не беда:
// следующий опрос заберёт всё пропущенное.
function fetchRates(h) {
	const last = lastT(h);
	return common.callRates(h.span, last).then((res) => {
		if (!Array.isArray(res?.points))
			return;
		// Часы Роутера ушли назад — известные точки «из будущего», историю — заново.
		if (res.now < last)
			h.points = [];
		hist.now = res.now;
		h.step = res.step || h.step;
		h.loaded = true;
		h.points = h.points.concat(res.points.filter((p) => p[0] > last)).filter((p) => p[0] > res.now - h.span);
	}).catch(() => { });
}

function fetchHistory() {
	return Promise.all([ fetchRates(hist.fine), (span > hist.fine.span) ? fetchRates(hist.min) : null ]);
}

// Последняя точка, если она свежая: значит, история пишется. null — процесс stats не работает.
function latest() {
	const p = hist.fine.points[hist.fine.points.length - 1];
	return (p && hist.now != null && hist.now - p[0] <= 3 * hist.fine.step) ? p : null;
}

// ---- График ----

const SVGNS = 'http://www.w3.org/2000/svg';
const CW = 600, CH = 100;
// Ряды: место значения в точке и классы (цвет Действия, пунктир — от устройств).
const SERIES = [
	{ i: 1, cls: 'tunnel' }, { i: 2, cls: 'tunnel up' },
	{ i: 3, cls: 'direct' }, { i: 4, cls: 'direct up' }
];

function svgEl(tag, attrs) {
	const el = document.createElementNS(SVGNS, tag);
	for (let k in attrs)
		el.setAttribute(k, attrs[k]);
	return el;
}

// Верх шкалы — круглое число бит/с (1, 2, 5 × 10ⁿ), не меньше 1 Мбит/с. Возвращает байт/с.
function scaleTop(peak) {
	const bits = Math.max(peak * 8, 1e6);
	const p = Math.pow(10, Math.floor(Math.log10(bits)));
	return [ 1, 2, 5, 10 ].find((k) => bits <= k * p) * p / 8;
}

// onSpan — выбран другой срок.
function makeChart(onSpan) {
	const svg = svgEl('svg', { 'viewBox': '0 0 %d %d'.format(CW, CH), 'preserveAspectRatio': 'none', 'aria-hidden': 'true' });
	for (let y of [ 25, 50, 75 ])
		svg.appendChild(svgEl('line', { 'class': 'grid', 'x1': 0, 'x2': CW, 'y1': y, 'y2': y }));
	const paths = SERIES.map((s) => ({
		area: (s.i % 2 == 1) ? svg.appendChild(svgEl('path', { 'class': 'area ' + s.cls })) : null,
		line: svg.appendChild(svgEl('path', { 'class': 'line ' + s.cls }))
	}));
	const top = E('span', { 'class': 'truba-chart-max truba-num' });
	const note = E('div', { 'class': 'truba-chart-note' });
	const box = E('div', { 'class': 'truba-chart' }, [ svg, top, note ]);
	const from = E('span', {});
	const buttons = SPANS.map((x) => E('button', { 'type': 'button', 'click': () => onSpan(x.span) }, x.label));
	const legend = (cls, label) => E('span', {}, [ E('i', { 'class': cls }), label ]);
	return {
		paths, top, note, box, from, buttons,
		el: E('div', {}, [
			E('div', { 'class': 'truba-chart-head' }, [
				E('div', { 'class': 'truba-legend' }, [
					legend('tunnel', _('Tunnel') + ' ↓'), legend('tunnel up', _('Tunnel') + ' ↑'),
					legend('direct', _('Direct') + ' ↓'), legend('direct up', _('Direct') + ' ↑')
				]),
				E('div', { 'class': 'truba-seg', 'role': 'group', 'aria-label': _('Period') }, buttons)
			]),
			box,
			E('div', { 'class': 'truba-chart-axis' }, [ from, E('span', {}, _('now')) ])
		])
	};
}

function drawChart(c) {
	const h = ring(), now = hist.now ?? 0;
	SPANS.forEach((x, k) => {
		c.buttons[k].classList.toggle('active', x.span == span);
		c.buttons[k].setAttribute('aria-pressed', String(x.span == span));
	});
	common.setText(c.from, SPANS.find((x) => x.span == span).from);
	// Истории нет — пояснение поверх приглушённого графика: старые точки ещё видны, но не мешают читать.
	const rec = latest() != null;
	c.box.classList.toggle('stale', !rec);
	common.setText(c.note, rec ? '' : _('Speed is not being recorded: the Truba service is not running.'));

	const pts = h.points.filter((p) => p[0] > now - span);
	let peak = 0;
	for (let p of pts)
		for (let s of SERIES)
			if (p[s.i] > peak)
				peak = p[s.i];
	const top = scaleTop(peak);
	const X = (t) => Math.max(0, (t - now + span) / span * CW).toFixed(1);
	const Y = (v) => (CH - Math.min(v / top, 1) * CH).toFixed(1);

	SERIES.forEach((s, k) => {
		let line = '', area = '', seg = [], prevT = null;
		// Разрыв линии — там, где скорости нет или запись прерывалась (служба была остановлена).
		const flush = () => {
			if (seg.length > 1) {
				line += 'M' + seg.join('L');
				area += 'M%s,%dL%sL%s,%dZ'.format(seg[0].split(',')[0], CH, seg.join('L'), seg[seg.length - 1].split(',')[0], CH);
			}
			seg = [];
		};
		for (let p of pts) {
			const v = p[s.i] ?? null;
			if (v == null || (prevT != null && p[0] - prevT > 3 * h.step))
				flush();
			if (v != null)
				seg.push(X(p[0]) + ',' + Y(v));
			prevT = p[0];
		}
		flush();
		c.paths[k].line.setAttribute('d', line);
		if (c.paths[k].area)
			c.paths[k].area.setAttribute('d', area);
	});
	common.setText(c.top, common.fmtRate(top));
}

// Другой срок: нарисовать то, что уже есть; поминутные средние — забрать при первом выборе суток.
function setSpan(c, s) {
	span = s;
	try { localStorage.setItem(SPAN_KEY, String(s)); } catch (e) { }
	drawChart(c);
	if (s > hist.fine.span && !hist.min.loaded)
		fetchRates(hist.min).then(() => drawChart(c));
}

// ---- Состояние ----

// Наборы, которые последняя проверка не смогла скачать: «geoip: причина».
function failedSets(last) {
	const sets = last?.sets || {};
	return Object.keys(sets).filter((k) => !sets[k].ok).map((k) => '%s: %s'.format(k, (sets[k].errors || []).map(common.setError).join('; ') || '?'));
}

// Автообновление идёт раз в сутки; проверка старше 36 ч — cron не запускал его или он падал.
function listsStale(st) {
	const last = st.lists?.last;
	return st.routing && uci.get('truba', 'lists', 'auto_update') != '0' && !st.lists?.updating
		&& (!last || Date.now() / 1000 - last.time > 36 * 3600);
}

// Что действует, если применить настройки не удалось (applied.fallback, ADR 0006).
function fallbackText(a) {
	switch (a.fallback) {
	case 'kept': return _('The rules loaded before the error stay in effect.');
	case 'last_good': return _('The last working rules from %s are in effect.').format(common.fmtTime(a.good_time));
	case 'none': return _('No Truba rules are in effect: traffic and DNS go direct.');
	default: return '';
	}
}

// Предупреждения: текст и вкладка, где его исправляют. Ошибки «Туннель не настроен»
// и «не работает» видны по плитке Туннеля и сюда не попадают.
function warnings(st) {
	const a = st.applied || {}, nb = st.neighbours || {}, up = st.upnp || {}, big = st.health?.big;
	const res = [];
	const add = (text, tab) => res.push({ text, tab });
	const W_TABS = { lists_missing: 'dns', zones_without_devices: 'routing', tunnel_not_configured: 'tunnel', lists_rolled_back: 'dns' };
	for (let w of (a.warnings || []))
		add(common.WARNING_LABELS[w] || w, W_TABS[w]);
	if ((a.missing || []).length)
		add(common.missingText(a.missing), 'routing');
	if ((a.invalid || []).length)
		add(_('Invalid settings were skipped, defaults are used instead: %s').format(
			a.invalid.map((x) => '%s = «%s»'.format(x.key, x.value)).join(', ')), common.invalidTab(a.invalid));
	if (a.error)
		add([ _('Error while applying rules: %s').format(a.error), fallbackText(a) ].filter((x) => x).join(' '), 'diagnostics');
	if (nb.offload)
		res.push({ text: _('Software flow offloading is on: packets of offloaded connections bypass the Truba counters, so device traffic is undercounted.'),
			href: L.url('admin/network/firewall'), label: _('Firewall') });
	if (nb.openclash_fakeip)
		add(_('OpenClash runs in fake-ip mode: «Check NAT» may report a problem although full cone NAT works.'), 'inbound');
	if (up.enabled && !up.installed)
		add(common.UPNP_MISSING, 'inbound');
	if (st.tunnel?.up && big && !big.ok)
		add(_('Full-size packets do not get through the tunnel: pages open slowly and downloads stall. Lower the tunnel MTU.'), 'tunnel');
	if (st.nat && !st.nat.error && !st.nat.ok)
		add(_('The last NAT check found a problem.'), 'inbound');
	const failed = failedSets(st.lists?.last);
	if (listsStale(st))
		add(_('Rule sets have not been checked for more than 36 hours although auto-update is on: check that cron runs (System → Scheduled Tasks).'), 'dns');
	else if (st.routing && failed.length)
		add(_('The last rule set check failed: %s').format(failed.join('; ')), 'dns');
	return res;
}

// Значок или точка: уровень и текст.
function setState(el, level, text) {
	common.setLevel(el, level);
	common.setText(el, text);
}

function buildPage(iface) {
	const r = { warnKey: null };
	const span = (cls) => E('span', cls ? { 'class': cls } : {});
	const line = () => E('div', { 'class': 'truba-muted' }, NBSP);

	// Плитка: заголовок со значком, главная цифра, две строки, переключатель и ссылка на вкладку.
	const tile = (title, tab, linkText, sw) => {
		const t = { badge: span('truba-badge'), big: E('div', { 'class': 'truba-big' }, NBSP), l1: line(), l2: line() };
		t.el = E('div', { 'class': 'truba-tile' }, [
			E('div', { 'class': 'truba-tile-h' }, [ E('h3', {}, title), t.badge ]),
			t.big, t.l1, t.l2,
			sw || '',
			E('a', { 'class': 'truba-go', 'href': common.tabUrl(tab) }, linkText + ' →')
		]);
		return t;
	};
	// Переключатель меняет конфигурацию в браузере; сохраняет её кнопка «Сохранить и применить».
	const toggle = (label, checked, disabled, onchange) => {
		const input = E('input', { 'type': 'checkbox', 'change': (ev) => onchange(ev.target.checked) });
		input.checked = checked;
		input.disabled = disabled;
		return E('label', { 'class': 'truba-switch' }, [ input, label ]);
	};

	const ifaceExists = !!uci.get('network', iface);
	r.tTunnel = tile(_('Tunnel'), 'tunnel', _('State and settings'),
		toggle(_('Tunnel enabled'), ifaceExists && uci.get('network', iface, 'disabled') != '1', !ifaceExists, (on) => on
			? uci.unset('network', iface, 'disabled')
			: uci.set('network', iface, 'disabled', '1')));
	r.tRouting = tile(_('Routing'), 'routing', _('Mode and categories'),
		toggle(_('Routing enabled'), uci.get('truba', 'main', 'routing') != '0', false, (on) =>
			uci.set('truba', 'main', 'routing', on ? '1' : '0')));
	r.tDns = tile(_('DNS & lists'), 'dns', _('DNS and rule sets'));
	r.tInbound = tile(_('Inbound'), 'inbound', _('NAT and port forwards'));

	r.warnCount = span('truba-badge warn');
	r.warnList = E('ul', { 'class': 'truba-warns' });

	r.trDescr = E('p', { 'class': 'cbi-section-descr' });
	r.tr = {};
	// Ячейка: итог и под ним скорость (или пояснение).
	const cell = () => {
		const total = span('truba-num'), rate = span('truba-muted truba-num');
		return { total, rate, el: E('td', {}, [ total, rate ]) };
	};
	const label = (level, text) => E('td', {}, E('span', { 'class': 'truba-dot ' + level }, text));
	const trRow = (text, k) => {
		r.tr[k] = { down: cell(), up: cell(), conn: cell() };
		return E('tr', {}, [ label(KIND_LEVELS[k], text), r.tr[k].down.el, r.tr[k].up.el, r.tr[k].conn.el ]);
	};
	// Блок — отброшенные пакеты, а не соединения: трафика у них нет.
	r.block = cell();
	r.block.rate.textContent = _('packets dropped');
	r.shareText = E('div', { 'class': 'truba-muted truba-num' }, NBSP);
	r.share = { tunnel: span('tunnel'), direct: span('direct') };
	r.chart = makeChart((s) => setSpan(r.chart, s));

	r.el = E('div', {}, [
		E('div', { 'class': 'truba-head' }, [
			E('h2', { 'name': 'content' }, _('Truba')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Home network through your own VPS: the VPS gives the router its public IP, the router decides what goes through the tunnel.'))
		]),
		E('div', { 'class': 'truba-tiles' }, [ r.tTunnel.el, r.tRouting.el, r.tDns.el, r.tInbound.el ]),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ _('Warnings'), ' ', r.warnCount ]),
			r.warnList
		]),
		E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Device traffic')),
			r.trDescr,
			r.chart.el,
			E('table', { 'class': 'truba-grid' }, [
				E('tr', {}, [
					E('th', {}, _('Action')),
					E('th', {}, '↓ ' + _('To devices')),
					E('th', {}, '↑ ' + _('From devices')),
					E('th', {}, _('New connections'))
				]),
				trRow(_('Tunnel'), 'tunnel'),
				trRow(_('Direct'), 'direct'),
				trRow(_('Inbound via Truba'), 'inbound'),
				E('tr', {}, [ label(common.ACTION_LEVELS.block, _('Block')), E('td', {}, '—'), E('td', {}, '—'), r.block.el ])
			]),
			E('div', { 'class': 'truba-share' }, [ r.share.tunnel, r.share.direct ]),
			r.shareText
		])
	]);
	return r;
}

function paintWarnings(r, list) {
	const key = JSON.stringify(list);
	if (r.warnKey === key)
		return;
	r.warnKey = key;
	r.warnCount.style.display = list.length ? '' : 'none';
	common.setText(r.warnCount, String(list.length));
	r.warnList.replaceChildren(...(list.length ? list.map((w) => E('li', {}, [
		E('span', {}, w.text),
		(w.tab || w.href) ? E('a', { 'href': w.href || common.tabUrl(w.tab) }, (w.label || common.TABS[w.tab]) + ' →') : ''
	])) : [ E('li', {}, common.empty(_('No warnings'))) ]));
}

function update(r, st) {
	const t = st.tunnel || {}, awg = t.awg || {}, h = st.health || {}, c = st.counters || {};
	const a = st.applied || {}, l = st.lists || {}, n = st.nat, up = st.upnp || {};
	const wdOn = uci.get('truba', 'watchdog', 'enabled') != '0';
	const auto = uci.get('truba', 'lists', 'auto_update') != '0';

	// Туннель: задержка, handshake, потери и крупные пакеты — подробности на его вкладке.
	const [ tLevel, tText ] = common.tunnelState(st);
	setState(r.tTunnel.badge, tLevel, tText);
	const probes = Array.isArray(h.probes) ? h.probes : [];
	common.setText(r.tTunnel.big, (t.up && wdOn && h.rtt != null) ? _('%d ms').format(Math.round(h.rtt)) : '—');
	const age = awg.handshake ? awg.handshake_age : null;
	const lost = probes.filter((x) => x == null).length;
	common.setText(r.tTunnel.l1, !t.up ? NBSP : [ 'handshake ' + common.fmtAge(age),
		!wdOn ? _('the watchdog is off') : probes.length ? _('loss %d%%').format(Math.round(lost * 100 / probes.length)) : null
	].filter((x) => x).join(' · '));
	common.setText(r.tTunnel.l2, (t.up && h.big) ? (h.big.ok ? _('full-size packets get through') : _('full-size packets are lost')) : NBSP);

	// Маршрутизация: Режим и доля соединений через Туннель.
	setState(r.tRouting.badge, st.routing ? 'ok' : '', st.routing ? _('on') : _('off'));
	common.setText(r.tRouting.big, !st.routing ? _('Everything direct')
		: st.mode == 'selective' ? _('Selective') : _('All via tunnel'));
	const nt = c.tunnel?.packets || 0, nd = c.direct?.packets || 0;
	const pct = (nt + nd) ? Math.round(nt * 100 / (nt + nd)) : null;
	common.setText(r.tRouting.l1, !st.routing ? _('inbound via the Truba IP keeps working')
		: pct == null ? _('No outgoing connections yet.') : _('%d%% of new connections via tunnel').format(pct));
	common.setText(r.tRouting.l2, _('Zones: %s').format(L.toArray(uci.get('truba', 'main', 'zone')).join(', ') || 'lan'));

	// DNS и списки.
	const failed = failedSets(l.last).length > 0;
	if (!st.routing)
		setState(r.tDns.badge, '', _('not used'));
	else if (!st.mosdns)
		setState(r.tDns.badge, 'err', _('mosdns stopped'));
	else if (failed || listsStale(st))
		setState(r.tDns.badge, 'warn', _('check the lists'));
	else
		setState(r.tDns.badge, 'ok', _('in order'));
	const newest = Math.max(l.geoip?.mtime || 0, l.geosite?.mtime || 0);
	common.setText(r.tDns.big, newest ? _('Lists from %s').format(common.fmtDate(newest)) : _('No lists yet'));
	const dc = st.dns_cache;
	common.setText(r.tDns.l1, !st.routing ? _('not used: routing is off')
		: (st.mosdns ? _('mosdns running') : _('mosdns not running'))
			+ (dc?.query ? ' · ' + _('%d%% from cache').format(Math.round(dc.hit * 100 / dc.query)) : ''));
	common.setText(r.tDns.l2, !st.routing ? NBSP
		: l.updating ? _('update in progress')
		: !auto ? _('automatic update is off')
		: _('Next check: %s').format(common.fmtTime(l.next)));

	// Входящие: IP Трубы, итог Проверки NAT, пробросы.
	if (!n)
		setState(r.tInbound.badge, '', _('NAT not checked'));
	else if (n.error)
		setState(r.tInbound.badge, 'warn', _('NAT not checked'));
	else
		setState(r.tInbound.badge, n.ok ? 'ok' : 'err', n.ok ? _('Truba layer OK') : _('NAT problem'));
	common.setText(r.tInbound.big, st.vps_ip || '—');
	common.setText(r.tInbound.l1, !n ? (wdOn ? _('runs by itself after the tunnel comes up') : _('never'))
		: n.error ? (common.NAT_ERRORS[n.error] || n.error)
		: _('NAT checked %s').format(common.fmtTime(n.time)));
	const forwards = uci.sections('firewall', 'redirect').filter((x) => x.src == 'truba' && x.enabled != '0').length;
	common.setText(r.tInbound.l2, '%s · %s'.format(up.enabled ? _('UPnP mappings: %d').format((up.leases || []).length) : _('UPnP off'),
		_('manual forwards: %d').format(forwards)));

	paintWarnings(r, warnings(st));

	// Трафик устройств
	const since = a.counters_since;
	common.setText(r.trDescr, since
		? _('Traffic of devices in the routed zones since %s. The router\'s own traffic (DNS, list downloads) is not included.').format(common.fmtTime(since))
		: _('Traffic of devices in the routed zones. The router\'s own traffic (DNS, list downloads) is not included.'));
	// Скорость — из последней точки истории; «—» — точки нет или в ней разрыв.
	const tr = st.traffic || {}, cur = latest();
	for (let k of KINDS) {
		for (let dir of [ 'down', 'up' ]) {
			const cell = r.tr[k][dir], rate = cur?.[COLS[k][dir]];
			common.setText(cell.total, common.fmtBytes(tr[k]?.[dir]));
			common.setText(cell.rate, rate != null ? common.fmtRate(rate) : '—');
		}
		const conn = r.tr[k].conn, rate = cur?.[COLS[k].conn];
		common.setText(conn.total, common.fmtNum(c[k]?.packets));
		common.setText(conn.rate, rate != null ? _('%s per min').format(common.fmtNum(rate)) : '—');
	}
	common.setText(r.block.total, common.fmtNum(c.block?.packets));

	// Доля исходящих соединений устройств: насколько Режим и Категории уводят в Туннель.
	r.share.tunnel.style.width = (pct ?? 0) + '%';
	r.share.direct.style.width = (pct == null ? 0 : 100 - pct) + '%';
	common.setText(r.shareText, pct == null ? _('No outgoing connections yet.')
		: _('Outgoing connections: %d%% via tunnel, %d%% direct').format(pct, 100 - pct));

	drawChart(r.chart);
}

return view.extend({
	load: function() {
		return Promise.all([ common.callStatus(), uci.load('network'), uci.load('truba'), uci.load('firewall'), fetchHistory() ]);
	},

	render: function(data) {
		const page = buildPage(common.tunnelIface());
		update(page, data[0]);
		poll.add(() => Promise.all([ common.callStatus(), fetchHistory() ]).then((res) => update(page, res[0])), POLL);
		return page.el;
	},

	// Переключатели плиток меняют конфигурацию прямо в браузере, без формы: сохранить —
	// значит отправить эти изменения, сбросить — перечитать страницу.
	handleSave: function() {
		return uci.save();
	},

	handleReset: function() {
		window.location.reload();
	}
});
