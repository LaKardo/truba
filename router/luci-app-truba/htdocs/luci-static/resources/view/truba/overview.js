'use strict';
'require view';
'require form';
'require poll';
'require uci';
'require ui';
'require truba.common as common';

// Страница строится один раз; опрос меняет только текст и классы готовых элементов,
// поэтому таблицы не пересчитывают ширину колонок и ничего не прыгает.

const POLL = 5;          // состояние — раз в 5 с
const SETS_POLL = 60;    // размеры наборов дороже — раз в минуту
const WINDOW = 600;      // график — последние 10 минут
const STORE = 'truba.rates';

// История скорости — в sessionStorage браузера: переживает переход по вкладкам LuCI
// (это перезагрузка страницы), но не закрытие вкладки. На Роутере ничего не хранится.
let hist = { last: null, points: [] };
try {
	const h = JSON.parse(sessionStorage.getItem(STORE));
	if (h && Array.isArray(h.points))
		hist = h;
}
catch (e) { }

function saveHist() {
	try { sessionStorage.setItem(STORE, JSON.stringify(hist)); } catch (e) { }
}

// Строки таблицы «Трафик устройств» и цвет точки перед названием.
const KINDS = [ 'tunnel', 'direct', 'inbound' ];
const KIND_LEVELS = { tunnel: common.ACTION_LEVELS.tunnel, direct: common.ACTION_LEVELS.direct, inbound: '' };

// Скорость по разнице с прошлым опросом. null — сравнивать не с чем: первый опрос,
// долгий перерыв или счётчики начаты заново (служба перезапущена, интерфейс переподнят).
// conn — новых соединений в секунду (счётчики c_tunnel, c_direct, c_inbound).
function takeRates(st) {
	const awg = st.tunnel?.awg || {}, tr = st.traffic || {}, c = st.counters || {};
	const cur = { t: Date.now() / 1000, since: st.applied?.counters_since ?? null, rx: awg.rx ?? null, tx: awg.tx ?? null,
		tr: { tunnel: tr.tunnel || {}, direct: tr.direct || {}, inbound: tr.inbound || {} },
		conn: { tunnel: c.tunnel?.packets ?? null, direct: c.direct?.packets ?? null, inbound: c.inbound?.packets ?? null } };
	const p = hist.last;
	hist.last = cur;
	const dt = p ? cur.t - p.t : 0;
	let r = null;
	if (p && dt >= 1 && dt <= 60 && p.since == cur.since) {
		const d = (a, b) => (a != null && b != null && a >= b) ? (a - b) / dt : null;
		r = {};
		for (let k of KINDS)
			r[k] = { down: d(cur.tr[k].down, p.tr[k]?.down), up: d(cur.tr[k].up, p.tr[k]?.up), conn: d(cur.conn[k], p.conn?.[k]) };
	}
	hist.points.push({ t: cur.t, v: r ? [ r.tunnel.down, r.tunnel.up, r.direct.down, r.direct.up ] : null });
	hist.points = hist.points.filter((x) => x.t > cur.t - WINDOW);
	saveHist();
	return r;
}

// ---- График ----

const SVGNS = 'http://www.w3.org/2000/svg';
const CW = 600, CH = 100;
// Ряды: индекс в точке истории и классы (цвет Действия, пунктир — от устройств).
const SERIES = [
	{ i: 0, cls: 'tunnel' }, { i: 1, cls: 'tunnel up' },
	{ i: 2, cls: 'direct' }, { i: 3, cls: 'direct up' }
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

function makeChart() {
	const svg = svgEl('svg', { 'viewBox': '0 0 %d %d'.format(CW, CH), 'preserveAspectRatio': 'none', 'aria-hidden': 'true' });
	for (let y of [ 25, 50, 75 ])
		svg.appendChild(svgEl('line', { 'class': 'grid', 'x1': 0, 'x2': CW, 'y1': y, 'y2': y }));
	const paths = SERIES.map((s) => ({
		area: (s.i % 2 == 0) ? svg.appendChild(svgEl('path', { 'class': 'area ' + s.cls })) : null,
		line: svg.appendChild(svgEl('path', { 'class': 'line ' + s.cls }))
	}));
	const top = E('span', { 'class': 'truba-chart-max truba-num' });
	const legend = (cls, label) => E('span', {}, [ E('i', { 'class': cls }), label ]);
	return {
		paths, top,
		el: E('div', {}, [
			E('div', { 'class': 'truba-legend' }, [
				legend('tunnel', _('Tunnel') + ' ↓'), legend('tunnel up', _('Tunnel') + ' ↑'),
				legend('direct', _('Direct') + ' ↓'), legend('direct up', _('Direct') + ' ↑')
			]),
			E('div', { 'class': 'truba-chart' }, [ svg, top ]),
			E('div', { 'class': 'truba-chart-axis' }, [ E('span', {}, _('10 min ago')), E('span', {}, _('now')) ])
		])
	};
}

function drawChart(c) {
	const now = Date.now() / 1000, pts = hist.points;
	let peak = 0;
	for (let p of pts)
		for (let v of (p.v || []))
			if (v > peak)
				peak = v;
	const top = scaleTop(peak);
	const X = (t) => Math.max(0, (t - now + WINDOW) / WINDOW * CW).toFixed(1);
	const Y = (v) => (CH - Math.min(v / top, 1) * CH).toFixed(1);

	SERIES.forEach((s, k) => {
		let line = '', area = '', seg = [], prevT = null;
		// Разрыв линии — там, где скорости нет или опрос надолго прерывался.
		const flush = () => {
			if (seg.length > 1) {
				line += 'M' + seg.join('L');
				area += 'M%s,%dL%sL%s,%dZ'.format(seg[0].split(',')[0], CH, seg.join('L'), seg[seg.length - 1].split(',')[0], CH);
			}
			seg = [];
		};
		for (let p of pts) {
			const v = p.v ? p.v[s.i] : null;
			if (v == null || (prevT != null && p.t - prevT > 3 * POLL))
				flush();
			if (v != null)
				seg.push(X(p.t) + ',' + Y(v));
			prevT = p.t;
		}
		flush();
		c.paths[k].line.setAttribute('d', line);
		if (c.paths[k].area)
			c.paths[k].area.setAttribute('d', area);
	});
	common.setText(c.top, common.fmtRate(top));
}

// ---- Состояние ----

// Наборы, которые последняя проверка не смогла скачать: «geoip: причина».
function failedSets(last) {
	const sets = last?.sets || {};
	return Object.keys(sets).filter((k) => !sets[k].ok).map((k) => '%s: %s'.format(k, (sets[k].errors || []).join('; ') || '?'));
}

function checkResult(last) {
	const failed = failedSets(last);
	if (failed.length)
		return _('failed (%s)').format(failed.join('; '));
	return last.changed ? _('updated') : _('no newer versions');
}

// Состояние Туннеля: [уровень, текст].
function tunnelState(st) {
	const t = st.tunnel || {}, h = st.health || {};
	if (!st.service)
		return [ 'err', _('service stopped') ];
	if (!t.configured)
		return [ 'warn', _('not configured') ];
	if (t.disabled)
		return [ 'warn', _('disabled') ];
	if (!t.up)
		return [ 'err', _('down') ];
	if (h.state == 'down')
		return [ 'err', _('not responding') ];
	return [ 'ok', _('working') ];
}

function warnings(st) {
	const a = st.applied || {}, nb = st.neighbours || {}, up = st.upnp || {}, last = st.lists?.last;
	const res = [];
	for (let w of (a.warnings || []))
		res.push(common.WARNING_LABELS[w] || w);
	if ((a.missing || []).length)
		res.push(common.missingText(a.missing));
	if (a.error)
		res.push(_('Error while applying rules: %s').format(a.error));
	if (nb.offload)
		res.push(_('Software flow offloading is on (Network → Firewall): packets of offloaded connections bypass the Truba counters, so device traffic is undercounted.'));
	if (nb.openclash_fakeip)
		res.push(_('OpenClash runs in fake-ip mode: «Check NAT» may report a problem although full cone NAT works.'));
	if (up.enabled && !up.installed)
		res.push(common.UPNP_MISSING);
	// Ошибки «не настроен» и «не работает» уже видны по состоянию Туннеля.
	if (st.nat && !st.nat.error && !st.nat.ok)
		res.push(_('The last NAT check found a problem: see the «NAT check» card.'));
	// Автообновление идёт раз в сутки; проверка старше 36 ч — cron не запускал его или он падал.
	if (st.routing && uci.get('truba', 'lists', 'auto_update') != '0' && !st.lists?.updating) {
		const failed = failedSets(last);
		if (!last || Date.now() / 1000 - last.time > 36 * 3600)
			res.push(_('Rule sets have not been checked for more than 36 hours although auto-update is on: check that cron runs (System → Scheduled Tasks).'));
		else if (failed.length)
			res.push(_('The last rule set check failed: %s').format(failed.join('; ')));
	}
	return res;
}

function kv(rows) {
	return E('table', { 'class': 'truba-kv' }, rows.map(([ label, value ]) =>
		E('tr', {}, [ E('th', { 'scope': 'row' }, label), E('td', {}, value) ])));
}

// Пустая вторая строка ячейки — неразрывный пробел: высота строки не меняется.
const NBSP = common.NBSP;

function buildPage() {
	const r = { warns: [], warnOpen: false, warnKey: null };
	const span = (cls) => E('span', cls ? { 'class': cls } : {});
	const note = () => E('div', { 'class': 'truba-muted' }, NBSP);

	// Сводка: одна строка постоянной высоты; список предупреждений раскрывается по клику.
	r.sumState = span('truba-badge');
	r.sumText = span('truba-summary-text');
	r.warnBtn = E('button', { 'class': 'btn cbi-button', 'type': 'button', 'click': () => {
		r.warnOpen = !r.warnOpen;
		paintWarnings(r);
	} });
	r.warnBox = E('div', { 'class': 'alert-message warning truba-warnings', 'style': 'display:none' });
	r.summary = E('div', { 'class': 'truba-summary' }, [ r.sumState, r.sumText, r.warnBtn ]);

	r.tState = span('truba-badge');
	r.tHs = span('truba-dot');
	r.tRtt = span('truba-dot truba-num');
	r.tLoss = span('truba-dot truba-num');
	r.tWd = span();
	r.tAddr = span('truba-num');
	r.tTable = span();
	r.tIface = span('truba-num');

	r.dMosdns = span('truba-badge');
	r.dCache = span('truba-num');
	r.dCacheNote = note();
	r.dGeoip = span('truba-num');
	r.dGeosite = span('truba-num');
	r.dCheck = span('truba-dot');
	r.dNext = span('truba-num');
	r.dSets = span('truba-num');
	r.dSetsNote = note();

	// Проверка NAT: строки постоянны, меняются значения; список серверов — по клику.
	r.nat = { busy: false, key: null };
	r.nat.state = span('truba-badge');
	r.nat.addr = span('truba-num');
	r.nat.vps = span('truba-dot');
	r.nat.port = span('truba-dot');
	r.nat.same = span('truba-dot');
	r.nat.when = span();
	r.nat.servers = E('ul');
	r.nat.btn = E('button', { 'class': 'btn cbi-button', 'type': 'button', 'click': ui.createHandlerFn(r, () => runNat(r)) },
		_('Check NAT'));

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
	r.chart = makeChart();

	r.el = E('div', {}, [
		r.summary,
		r.warnBox,
		E('div', { 'class': 'truba-cards' }, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Tunnel')),
				kv([
					[ _('State'), r.tState ],
					[ _('Last handshake'), r.tHs ],
					[ _('Latency to the Truba'), r.tRtt ],
					[ _('Packet loss'), r.tLoss ],
					[ _('Tunnel watchdog'), r.tWd ],
					[ _('Tunnel address'), r.tAddr ],
					[ _('Tunnel route table'), r.tTable ],
					[ _('Interface traffic'), [ r.tIface,
						E('div', { 'class': 'truba-muted' }, _('since the interface came up, including the router\'s own traffic')) ] ]
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('NAT check')),
				kv([
					[ _('Result'), r.nat.state ],
					[ _('External address'), r.nat.addr ],
					[ _('External IP is the Truba IP'), r.nat.vps ],
					[ _('Port preserved'), r.nat.port ],
					[ _('Same mapping for different servers'), r.nat.same ],
					[ _('Checked'), r.nat.when ]
				]),
				E('details', { 'class': 'truba-details' }, [ E('summary', {}, _('STUN servers')), r.nat.servers ]),
				E('div', { 'class': 'truba-toolbar' }, [ r.nat.btn ]),
				E('p', { 'class': 'truba-muted' },
					_('This checks the Truba layer only. For the full RFC 5780 test run NatTypeTester on a PC in the home network whose device policy is «All via tunnel».'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('DNS & lists')),
				kv([
					[ _('DNS classifier (mosdns)'), r.dMosdns ],
					[ _('DNS cache'), [ r.dCache, r.dCacheNote ] ],
					[ 'geoip.dat', r.dGeoip ],
					[ 'geosite.dat', r.dGeosite ],
					[ _('Last check'), r.dCheck ],
					[ _('Next check'), r.dNext ],
					[ _('Set sizes'), [ r.dSets, r.dSetsNote ] ]
				])
			])
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

// Итог «Проверки NAT»: из status (последняя проверка) или сразу после нажатия кнопки.
function paintNat(r, n, wdOn) {
	const x = r.nat;
	const yesNo = (el, v, unknown) => setState(el, v == null ? '' : v ? 'ok' : 'err', v == null ? unknown : v ? _('yes') : _('no'));
	if (!n || n.error) {
		if (!n)
			setState(x.state, '', _('not run yet'));
		else
			setState(x.state, (n.error == 'tunnel_down' || n.error == 'not_configured') ? 'warn' : 'err',
				_('not checked: %s').format(common.NAT_ERRORS[n.error] || n.error));
		common.setText(x.addr, '—');
		for (let el of [ x.vps, x.port, x.same ])
			setState(el, '', '—');
	}
	else {
		setState(x.state, n.ok ? 'ok' : 'err', n.ok ? _('Truba layer OK') : _('problem'));
		common.setText(x.addr, '%s:%d'.format(n.external_ip, n.external_port));
		yesNo(x.vps, n.ip_is_vps);
		yesNo(x.port, n.port_preserved);
		yesNo(x.same, n.consistent, _('nothing to compare: one server answered'));
	}
	common.setText(x.when, !n
		? (wdOn ? _('runs by itself after the tunnel comes up') : _('never'))
		: '%s · %s'.format(common.fmtTime(n.time), n.auto ? _('automatically after the tunnel came up') : _('manually')));

	// Список серверов меняется только с новой проверкой.
	const key = n ? String(n.time) + (n.error || '') : '';
	if (x.key !== key) {
		x.key = key;
		const why = { dns: _('name not resolved'), timeout: _('no answer') };
		x.servers.replaceChildren(...((n?.servers || []).map((s) => E('li', { 'class': 'truba-num' }, s.mapped
			? '%s — %s:%d, %s'.format(s.server, s.mapped.address, s.mapped.port, _('%d ms').format(s.rtt))
			: '%s — %s'.format(s.server, why[s.error] || s.error || '—')))));
		if (!x.servers.childNodes.length)
			x.servers.appendChild(E('li', {}, common.empty(_('none'))));
	}
}

function runNat(r) {
	r.nat.busy = true;
	setState(r.nat.state, '', _('Testing…'));
	return common.callNatTest()
		.then((n) => paintNat(r, n, true))
		.catch((e) => paintNat(r, { time: Date.now() / 1000, error: e.message }, true))
		.finally(() => { r.nat.busy = false; });
}

function paintWarnings(r) {
	const n = r.warns.length;
	if (!n)
		r.warnOpen = false;
	common.setText(r.warnBtn, n ? _('Warnings: %d').format(n) + (r.warnOpen ? ' ▾' : ' ▸') : _('No warnings'));
	r.warnBtn.disabled = !n;
	r.warnBtn.setAttribute('aria-expanded', r.warnOpen ? 'true' : 'false');
	r.warnBox.style.display = r.warnOpen ? '' : 'none';
	const key = r.warns.join('\n');
	if (r.warnKey !== key) {
		r.warnKey = key;
		r.warnBox.replaceChildren(E('ul', {}, r.warns.map((w) => E('li', {}, w))));
	}
}

// Значок или точка: уровень и текст.
function setState(el, level, text) {
	common.setLevel(el, level);
	common.setText(el, text);
}

function update(r, st, rates) {
	const t = st.tunnel || {}, awg = t.awg || {}, h = st.health || {}, c = st.counters || {};
	const a = st.applied || {}, l = st.lists || {}, last = l.last;
	const [ tLevel, tText ] = tunnelState(st);
	const wdOn = uci.get('truba', 'watchdog', 'enabled') != '0';

	// Сводка
	r.warns = warnings(st);
	const sumLevel = (tLevel == 'ok' && r.warns.length) ? 'warn' : tLevel;
	common.setLevel(r.summary, sumLevel);
	setState(r.sumState, tLevel, tText);
	const routing = st.routing
		? '%s: %s'.format(_('Routing'), st.mode == 'selective' ? _('mode «Selective»') : _('mode «All via tunnel»'))
		: _('disabled — everything goes direct');
	const sum = '%s: %s · %s'.format(_('Truba IP (VPS)'), st.vps_ip || '—', routing);
	common.setText(r.sumText, sum);
	r.sumText.title = sum;
	paintWarnings(r);

	// Туннель
	setState(r.tState, tLevel, tText);
	const age = awg.handshake ? awg.handshake_age : null;
	setState(r.tHs, age == null ? 'err' : age > 300 ? 'err' : age > 180 ? 'warn' : 'ok', common.fmtAge(age));

	// Окно пустое — проверок ещё не было (или не с чем: нет адреса для ping): не «нет ответа».
	const probes = Array.isArray(h.probes) ? h.probes : [];
	if (!wdOn || !probes.length || !t.up) {
		const why = !wdOn ? _('the watchdog is off') : '—';
		setState(r.tRtt, '', why);
		setState(r.tLoss, '', why);
	}
	else {
		const got = probes.filter((x) => x != null);
		const avg = got.length ? got.reduce((s, x) => s + x, 0) / got.length : null;
		setState(r.tRtt, h.rtt != null ? 'ok' : 'err', h.rtt != null
			? _('%d ms').format(Math.round(h.rtt)) + (avg != null ? ' · ' + _('average %d ms').format(Math.round(avg)) : '')
			: _('no reply'));
		const lost = probes.length - got.length;
		const pct = Math.round(lost * 100 / probes.length);
		setState(r.tLoss, !lost ? 'ok' : pct < 20 ? 'warn' : 'err',
			_('%d%% over %d min').format(pct, Math.max(1, Math.round(probes.length * (h.interval || 30) / 60))));
	}

	common.setText(r.tWd, h.state
		? '%s %s'.format(h.state == 'healthy' ? _('healthy since') : _('down since'), common.fmtTime(h.since))
		: _('no data'));
	common.setText(r.tAddr, t.address ? '%s ↔ %s'.format(t.address, t.peer || '?') : '—');
	const table = (st.table || '').trim();
	common.setText(r.tTable, !st.service ? _('service stopped')
		: /blackhole/.test(table) ? _('emergency block (tunnel traffic is dropped)')
		: /default dev/.test(table) ? _('via tunnel')
		: _('fallback to direct (no tunnel route)'));
	common.setText(r.tIface, awg.rx != null ? '↓ %s · ↑ %s'.format(common.fmtBytes(awg.rx), common.fmtBytes(awg.tx)) : '—');

	// DNS и списки
	if (st.routing)
		setState(r.dMosdns, st.mosdns ? 'ok' : 'err', st.mosdns ? _('running') : _('not running'));
	else
		setState(r.dMosdns, '', _('not used: routing is off'));
	const dc = st.dns_cache;
	if (st.routing && dc) {
		const pct = (n) => dc.query ? Math.round(n * 100 / dc.query) : 0;
		common.setText(r.dCache, dc.query
			? _('%d%% from cache · %d%% expired').format(pct(dc.hit), pct(dc.lazy_hit))
			: _('no queries yet'));
		common.setText(r.dCacheNote, _('%s of %s entries · since mosdns started').format(common.fmtNum(dc.size), common.fmtNum(dc.max)));
	}
	else {
		common.setText(r.dCache, st.routing ? _('no data') : '—');
		common.setText(r.dCacheNote, NBSP);
	}
	const fileText = (f) => f ? _('downloaded %s').format(common.fmtDate(f.mtime)) + ' · ' + common.fmtBytes(f.size) : _('missing');
	common.setText(r.dGeoip, fileText(l.geoip));
	common.setText(r.dGeosite, fileText(l.geosite));
	if (l.updating)
		setState(r.dCheck, '', _('update in progress'));
	else if (!last)
		setState(r.dCheck, 'warn', _('not checked yet'));
	else
		setState(r.dCheck, failedSets(last).length ? 'err' : (Date.now() / 1000 - last.time > 36 * 3600) ? 'warn' : 'ok',
			'%s — %s'.format(common.fmtTime(last.time), checkResult(last)));
	// Время следующего запуска считает Роутер по своей строке cron.
	const auto = uci.get('truba', 'lists', 'auto_update') != '0';
	common.setText(r.dNext, !st.routing ? '—'
		: !auto ? _('automatic update is off')
		: common.fmtTime(l.next));

	// Трафик устройств
	const since = a.counters_since;
	common.setText(r.trDescr, since
		? _('Traffic of devices in the routed zones since %s. The router\'s own traffic (DNS, list downloads) is not included.').format(common.fmtTime(since))
		: _('Traffic of devices in the routed zones. The router\'s own traffic (DNS, list downloads) is not included.'));
	const tr = st.traffic || {};
	for (let k of KINDS) {
		for (let dir of [ 'down', 'up' ]) {
			const cell = r.tr[k][dir], rate = rates?.[k]?.[dir];
			common.setText(cell.total, common.fmtBytes(tr[k]?.[dir]));
			common.setText(cell.rate, rate != null ? common.fmtRate(rate) : '—');
		}
		const conn = r.tr[k].conn, rate = rates?.[k]?.conn;
		common.setText(conn.total, common.fmtNum(c[k]?.packets));
		common.setText(conn.rate, rate != null ? _('%s per min').format(common.fmtNum(Math.round(rate * 60))) : '—');
	}
	common.setText(r.block.total, common.fmtNum(c.block?.packets));

	// Доля исходящих соединений устройств: насколько Режим и Категории уводят в Туннель.
	const nt = c.tunnel?.packets || 0, nd = c.direct?.packets || 0;
	const pct = (nt + nd) ? Math.round(nt * 100 / (nt + nd)) : null;
	r.share.tunnel.style.width = (pct ?? 0) + '%';
	r.share.direct.style.width = (pct == null ? 0 : 100 - pct) + '%';
	common.setText(r.shareText, pct == null ? _('No outgoing connections yet.')
		: _('Outgoing connections: %d%% via tunnel, %d%% direct').format(pct, 100 - pct));

	if (!r.nat.busy)
		paintNat(r, st.nat, wdOn);
	drawChart(r.chart);
}

function updateSets(r, s) {
	const g = s?.geoip, d = s?.dns;
	if (!s?.routing || !g) {
		common.setText(r.dSets, '—');
		common.setText(r.dSetsNote, NBSP);
		return;
	}
	// Подсети geoip — сколько взято из Категорий; в ядре соседние сливаются, там их меньше.
	const A = common.ACTION_LABELS;
	const parts = (pairs) => pairs.map(([ a, n ]) => '%s %s'.format(A[a], common.fmtNum(n))).join(' · ');
	common.setText(r.dSets, _('geoip subnets: %s').format(parts([ [ 'direct', g.direct ], [ 'tunnel', g.tunnel ], [ 'block', g.block ] ])));
	common.setText(r.dSetsNote, _('IPs from DNS: %s').format(parts([ [ 'tunnel', d?.tunnel ], [ 'direct', d?.direct ] ])));
}

return view.extend({
	load: function() {
		return Promise.all([ common.callStatus(), common.callSets().catch(() => null), uci.load('network'), uci.load('truba') ]);
	},

	render: function(data) {
		const iface = common.tunnelIface();
		const page = buildPage();
		update(page, data[0], takeRates(data[0]));
		updateSets(page, data[1]);

		const m = new form.Map('truba', _('Truba'),
			_('Home network through your own VPS: the VPS gives the router its public IP, the router decides what goes through the tunnel.'));
		m.chain('network');

		const s = m.section(form.NamedSection, 'main', 'main', _('Main switches'));
		s.addremove = false;

		let o = s.option(form.Flag, '_tunnel', _('Tunnel'),
			_('Brings the AmneziaWG interface %s up or down.').format(iface));
		o.rmempty = false;
		o.cfgvalue = () => (uci.get('network', iface, 'disabled') == '1') ? '0' : '1';
		o.write = (sid, v) => (v == '1') ? uci.unset('network', iface, 'disabled') : uci.set('network', iface, 'disabled', '1');
		o.remove = () => uci.set('network', iface, 'disabled', '1');

		o = s.option(form.Flag, 'routing', _('Routing'),
			_('Distributes traffic by actions. When off, everything goes direct, but inbound connections via the Truba IP keep working.'));
		o.rmempty = false;
		o.default = '1';

		poll.add(() => common.callStatus().then((st) => update(page, st, takeRates(st))), POLL);
		poll.add(() => common.callSets().then((s) => updateSets(page, s)).catch(() => {}), SETS_POLL);

		return m.render().then((mapEl) => E('div', {}, [ mapEl, page.el ]));
	}
});
