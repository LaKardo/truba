'use strict';
'require view';
'require uci';
'require truba.common as common';
'require truba.awg as awg';
'require truba.ui.app as app';
'require truba.ui.kit as kit';
'require truba.ui.chart as chart';
'require truba.ui.flow as flow';

// «Обзор» — сводка по всем частям Трубы: строка состояния с переключателями, схема потоков,
// задержка Туннеля, скорость, DNS и входящие, предупреждения. Подробности и настройки каждой части —
// на её вкладке. Страница — компоненты Preact в Shadow DOM (ADR 0017); опрос меняет только данные.

const POLL = 5;          // состояние — раз в 5 с
const NBSP = common.NBSP;

// ---- История скорости ----

// Историю ведёт сам Роутер (процесс truba stats), поэтому она не рвётся, когда вкладка
// свёрнута или браузер закрыт: страница при открытии забирает её целиком, дальше — только
// новые точки. Точка: [время Роутера, байт/с — Туннель ↓ ↑, Напрямую ↓ ↑, Входящие ↓ ↑,
// новых соединений в минуту — Туннель, Напрямую, Входящие]; [время] — разрыв (счётчики
// начаты заново). fine — точки по 5 с за час, min — поминутные средние за сутки (в них
// только значения графика), загружаются, когда выбраны 24 ч. now — время Роутера на
// последнем ответе: ось строится по нему, а не по часам компьютера — они могут расходиться.
// Шаг и срок (span, step) — у службы (truba.schema, consts.history): их задаёт load().
const hist = {
	fine: { span: null, step: null, points: [], loaded: false },
	min: { span: null, step: null, points: [], loaded: false },
	now: null
};

function setHistory(h) {
	for (const k of [ 'fine', 'min' ])
		Object.assign(hist[k], { span: h[k].span, step: h[k].step });
}

// Места значений в точке: к устройствам, от устройств, новых соединений в минуту.
const COLS = { tunnel: { down: 1, up: 2, conn: 7 }, direct: { down: 3, up: 4, conn: 8 }, inbound: { down: 5, up: 6, conn: 9 } };

// Сроки графика; выбранный запоминается в браузере. Больше часа — поминутные средние. Подписи — при отрисовке.
const SPANS = [ 600, 3600, 86400 ];
const spanLabel = (s) => ({ 600: _('10 min'), 3600: _('1 h'), 86400: _('24 h') })[s];
const SPAN_KEY = 'truba.span';

function savedSpan() {
	try {
		const s = +localStorage.getItem(SPAN_KEY);
		if (SPANS.includes(s))
			return s;
	}
	catch (e) { }
	return 600;
}

// Выбранный срок и приход поминутных средних — хранилище страницы (view, его заводит render): смена
// перерисовывает карточку «Скорость», как ответы опроса. Срок нужен и опросу — он читает его оттуда же.
const ring = (span) => (span > hist.fine.span) ? hist.min : hist.fine;
const lastT = (h) => h.points.length ? h.points[h.points.length - 1][0] : 0;

// Забрать точки новее уже известных и убрать вышедшие за срок. Ошибка — не беда:
// следующий опрос заберёт всё пропущенное.
function fetchRates(h) {
	const last = lastT(h);
	h.fetched = Date.now();
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

// Поминутная точка появляется раз в минуту — чаще её не спрашивать: Роутер читал бы файл зря.
function fetchHistory(span) {
	const minDue = span > hist.fine.span && Date.now() - (hist.min.fetched || 0) >= hist.min.step * 1000;
	return Promise.all([ fetchRates(hist.fine), minDue ? fetchRates(hist.min) : null ]);
}

// Устройства (ADR 0018) — число активных на схеме и карточка «Устройства»; если служба не ответила,
// остальной «Обзор» работает без них.
function fetchDevices() {
	return common.callDevices().catch(() => null);
}

// Последняя точка, если она свежая: значит, история пишется. null — процесс stats не работает.
function latest() {
	const p = hist.fine.points[hist.fine.points.length - 1];
	return (p && hist.now != null && hist.now - p[0] <= 3 * hist.fine.step) ? p : null;
}

// ---- Состояние ----

// Наборы, которые последняя проверка не смогла скачать: «geoip: причина».
function failedSets(last) {
	const sets = last?.sets || {};
	return Object.keys(sets).filter((k) => !sets[k].ok).map((k) => '%s: %s'.format(k, (sets[k].errors || []).map(common.setError).join('; ') || '?'));
}

// Автообновление проверяет списки каждый час; проверка старше 36 ч — cron не запускал его или он падал.
function listsStale(st) {
	const last = st.lists?.last;
	return st.routing && common.get('lists', 'auto_update') && !st.lists?.updating
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
// и «не работает» видны по строке состояния и сюда не попадают.
function warnings(st) {
	const a = st.applied || {}, nb = st.neighbours || {}, up = st.upnp || {}, big = st.health?.big;
	const res = [];
	const add = (text, tab) => res.push({ text, tab });
	for (let w of (a.warnings || []))
		add(common.WARNINGS[w]?.text || w, common.WARNINGS[w]?.tab);
	if ((a.missing || []).length)
		add(common.missingText(a.missing), 'rules');
	if ((a.invalid || []).length)
		add(_('Invalid settings were skipped, defaults are used instead: %s').format(
			a.invalid.map((x) => '%s = «%s»'.format(x.key, x.value)).join(', ')), common.invalidTab(a.invalid));
	if (a.error)
		add([ _('Error while applying rules: %s').format(a.error), fallbackText(a) ].filter((x) => x).join(' '), 'log');
	if (nb.offload)
		res.push({ text: _('Software flow offloading is on: packets of offloaded connections bypass the Truba counters, so device traffic is undercounted.'),
			href: L.url('admin/network/firewall'), label: _('Firewall') });
	if (up.enabled && !up.installed)
		add(common.UPNP_MISSING, 'inbound');
	if (st.tunnel?.up && big && !big.ok)
		add(_('Full-size packets do not get through the tunnel: pages open slowly and downloads stall. Lower the tunnel MTU.'), 'tunnel');
	if (st.nat && !st.nat.error && !st.nat.ok)
		add(_('The last NAT check found a problem.'), 'inbound');
	const failed = failedSets(st.lists?.last);
	if (listsStale(st))
		add(_('Rule sets have not been checked for more than 36 hours although auto-update is on: check that cron runs (System → Scheduled Tasks).'), 'rules');
	else if (st.routing && failed.length)
		add(_('The last rule set check failed: %s').format(failed.join('; ')), 'rules');
	return res;
}

// Доля новых исходящих соединений устройств через Туннель, %; null — соединений ещё не было.
function tunnelShare(c) {
	const nt = c.tunnel?.packets || 0, nd = c.direct?.packets || 0;
	return (nt + nd) ? Math.round(nt * 100 / (nt + nd)) : null;
}

// ---- Карточки ----

// Строка состояния: итог, задержка и рукопожатие, IP Трубы и главные переключатели. Переключатели меняют
// конфигурацию в браузере; применяет её панель изменений или «Сохранить и применить» LuCI.
function Hero({ st, iface, warns }) {
	const { html } = app.lib;
	const t = st.tunnel || {}, h = st.health || {}, peer = t.awg || {};
	const wdOn = !!st.watchdog;   // как у службы, а не в UCI браузера
	let [ level, title ] = common.tunnelState(st);
	if (level == 'ok') {
		title = warns ? _('Works · warnings: %d').format(warns) : _('Everything works');
		level = warns ? 'warn' : 'ok';
	}
	const probes = common.probes(h);
	const loss = common.lossPct(probes);
	const sub = !t.up ? NBSP : [
		(wdOn && h.rtt != null) ? _('%d ms').format(Math.round(h.rtt)) : null,
		_('handshake %s').format(common.fmtAge(peer.handshake ? peer.handshake_age : null)),
		!wdOn ? _('the watchdog is off') : (loss != null) ? _('loss %d%%').format(loss) : null
	].filter((x) => x).join(' · ');
	const ifaceExists = awg.configured(iface);
	return html`<div class="hero">
		<div class="st"><${kit.Dot} level=${level} /><div><h3>${title}</h3><p class="mu">${sub}</p></div></div>
		<div class="ip mu">${_('Truba IP')}<b class="num">${st.vps_ip || '—'}</b></div>
		<div class="tg">
			<${kit.Switch} label=${_('Tunnel')} opt=${'network.' + iface + '.disabled'} disabled=${!ifaceExists}
				checked=${ifaceExists && uci.get('network', iface, 'disabled') != '1'}
				onChange=${(on) => app.set('network', iface, 'disabled', on ? null : '1')} />
			<${kit.Switch} label=${_('Routing')} opt="truba.main.routing" checked=${common.get('main', 'routing')}
				onChange=${(on) => app.set('truba', 'main', 'routing', on ? '1' : '0')} />
		</div>
	</div>`;
}

// devices — ответ truba.devices или null (служба не ответила): тогда у узла «Устройства» нет числа.
function FlowCard({ st, devices }) {
	const { html } = app.lib;
	const p = latest(), c = st.counters || {}, pct = tunnelShare(c);
	const active = devices ? (devices.devices || []).filter((d) => common.devActive(d, devices.now)).length : null;
	return html`<${kit.Card} cls="w2" title=${_('Where traffic goes')} aside=${_('now')}>
		<${flow.Flow} devices=${active} block=${c.block?.packets || 0}
			tunnel=${p ? [ p[COLS.tunnel.down], p[COLS.tunnel.up] ] : null}
			direct=${p ? [ p[COLS.direct.down], p[COLS.direct.up] ] : null}
			caption=${(pct == null) ? _('No outgoing connections yet.') : _('%d%% of new connections via tunnel').format(pct)} />
	</${kit.Card}>`;
}

// Туннель: задержка, мини-график по окну проверок watchdog, потери и крупные пакеты.
function TunnelCard({ st, iface }) {
	const { html } = app.lib;
	const t = st.tunnel || {}, h = st.health || {};
	const wdOn = !!st.watchdog;
	const [ level, text ] = common.tunnelState(st);
	const probes = common.probes(h);
	const loss = common.lossPct(probes);
	const mtu = uci.get('network', iface, 'mtu');
	return html`<${kit.Card} title=${_('Tunnel')} aside=${html`<${kit.Badge} level=${level}>${text}</${kit.Badge}>`}>
		<div class="big">${(t.up && wdOn && h.rtt != null) ? _('%d ms').format(Math.round(h.rtt)) : '—'}</div>
		<${chart.Spark} values=${probes} />
		<div class="lines mu">
			<div>${!t.up ? NBSP : !wdOn ? _('the watchdog is off') : (loss != null) ? _('loss %d%%').format(loss) : NBSP}</div>
			<div>${(t.up && h.big) ? (h.big.ok ? _('full-size packets get through') : _('full-size packets are lost')) : NBSP}</div>
			${mtu ? html`<div>MTU ${mtu}</div>` : ''}
		</div>
		<${kit.Go} tab="tunnel" label=${_('State and settings')} />
	</${kit.Card}>`;
}

// Ряды графика: к устройствам — линией с заливкой, от устройств — пунктиром.
const SERIES = () => [
	{ i: COLS.tunnel.down, label: _('Tunnel') + ' ↓', color: 'tun' },
	{ i: COLS.tunnel.up, label: _('Tunnel') + ' ↑', color: 'tun', dash: true },
	{ i: COLS.direct.down, label: _('Direct') + ' ↓', color: 'dir' },
	{ i: COLS.direct.up, label: _('Direct') + ' ↑', color: 'dir', dash: true }
];

// Скорость за 10 минут, час или сутки и объёмы по Действиям с начала счёта.
function SpeedCard({ st, view }) {
	const { html } = app.lib;
	const { span } = app.use(view);
	const onSpan = (s) => {
		try { localStorage.setItem(SPAN_KEY, String(s)); } catch (e) { }
		view.set({ span: s });
		// Поминутные средние — при первом выборе суток.
		if (s > hist.fine.span && !hist.min.loaded)
			fetchRates(hist.min).then(() => view.set({ minAt: Date.now() }));
	};
	const now = hist.now ?? Date.now() / 1000;
	const h = ring(span);
	const pts = chart.gaps(h.points.filter((p) => p[0] > now - span), h.step);
	const series = SERIES();
	const data = [ pts.map((p) => p[0]), ...series.map((s) => pts.map((p) => p[s.i] ?? null)) ];
	// Истории нет — пояснение поверх приглушённого графика: старые точки ещё видны, но не мешают читать.
	const rec = latest() != null;
	const tr = st.traffic || {}, since = st.applied?.counters_since;
	const b = (k, d) => common.fmtBytes(tr[k]?.[d]);
	return html`<${kit.Card} cls="w3" title=${_('Speed')}
			aside=${html`<${kit.Segmented} label=${_('Period')} items=${SPANS.map((s) => [ s, spanLabel(s) ])} value=${span} onChange=${onSpan} />`}>
		<div class=${'chart' + (rec ? '' : ' stale')}>
			<${chart.TimeChart} series=${series} data=${data} from=${now - span} to=${now} />
			${rec ? '' : html`<div class="chart-note">${_('Speed is not being recorded: the Truba service is not running.')}</div>`}
		</div>
		<div class="mu">${(since ? _('Since %s').format(common.fmtTime(since)) + ': ' : '')
			+ _('Tunnel ↓ %s ↑ %s · Direct ↓ %s ↑ %s · Inbound ↓ %s ↑ %s').format(
				b('tunnel', 'down'), b('tunnel', 'up'), b('direct', 'down'), b('direct', 'up'), b('inbound', 'down'), b('inbound', 'up'))}</div>
	</${kit.Card}>`;
}

// Пять устройств с наибольшей скоростью к ним сейчас: доля Туннеля и Напрямую, скорость.
function DevicesCard({ devices }) {
	const { html } = app.lib;
	const down = (d) => common.devRate(d)?.[0] ?? -1;
	const top = (devices?.devices || []).filter((d) => d.ip).sort((a, b) => (down(b) - down(a)) || ((b.last || 0) - (a.last || 0))).slice(0, 5);
	return html`<${kit.Card} cls="w2 devs" title=${_('Devices')} aside=${_('tunnel / direct · now')}>
		${top.length ? top.map((d) => {
			const [ tun, dir ] = common.devShare(d, devices.now), r = common.devRate(d);
			return html`<div class="devrow">
				<span class="n">${common.deviceName(d)}</span>
				<${kit.ShareBar} tunnel=${tun} direct=${dir} />
				<span class="r">${r ? '↓ ' + common.fmtRate(r[0]) : '—'}</span>
			</div>`;
		}) : html`<${kit.Empty} text=${devices ? _('No devices with traffic in the last 24 hours yet.') : _('No device data: the router did not answer.')} />`}
		<${kit.Go} tab="devices" />
	</${kit.Card}>`;
}

// DNS и списки, входящие: значки, строки и скорость входящих сейчас.
function InfoCard({ st }) {
	const { html } = app.lib;
	const l = st.lists || {}, n = st.nat, up = st.upnp || {}, dc = st.dns_cache;
	const wdOn = !!st.watchdog;
	const auto = common.get('lists', 'auto_update');

	const [ dLevel, dText ] = !st.routing ? [ '', _('not used') ]
		: !st.mosdns ? [ 'err', _('mosdns stopped') ]
		: (failedSets(l.last).length || listsStale(st)) ? [ 'warn', _('check the lists') ]
		: [ 'ok', _('in order') ];
	const newest = Math.max(l.geoip?.mtime || 0, l.geosite?.mtime || 0);

	const [ nLevel, nText ] = !n ? [ '', _('NAT not checked') ]
		: n.error ? [ 'warn', _('NAT not checked') ]
		: [ n.ok ? 'ok' : 'err', n.ok ? _('Truba layer OK') : _('NAT problem') ];
	const forwards = common.forwardRows([]).filter((r) => r.on).length;
	const p = latest();

	// Одна колонка рядом с карточкой «Устройства»: «DNS и списки» над «Входящими».
	return html`<${kit.Card}>
		<div class="stack">
			<div>
				<div class="card-h"><h3>${_('DNS & lists')}</h3><${kit.Badge} level=${dLevel}>${dText}</${kit.Badge}></div>
				<div class="big">${newest ? _('Lists from %s').format(common.fmtDate(newest)) : _('No lists yet')}</div>
				<div class="lines mu">
					<div>${!st.routing ? _('not used: routing is off')
						: (st.mosdns ? _('mosdns running') : _('mosdns not running'))
							+ (dc?.query ? ' · ' + _('%d%% from cache').format(Math.round(dc.hit * 100 / dc.query)) : '')}</div>
					<div>${!st.routing ? NBSP : l.updating ? _('update in progress')
						: !auto ? _('automatic update is off') : _('Next check: %s').format(common.fmtTime(l.next))}</div>
				</div>
				<div class="gos"><${kit.Go} tab="dns" /><${kit.Go} tab="rules" label=${_('Rule sets')} /></div>
			</div>
			<div>
				<div class="card-h"><h3>${_('Inbound')}</h3><${kit.Badge} level=${nLevel}>${nText}</${kit.Badge}></div>
				<div class="lines mu">
					<div>${!n ? (wdOn ? _('runs by itself after the tunnel comes up') : _('never'))
						: n.error ? (common.NAT_ERRORS[n.error] || n.error) : _('NAT checked %s').format(common.fmtTime(n.time))}</div>
					<div>${'%s · %s'.format(up.enabled ? _('UPnP mappings: %d').format((up.leases || []).length) : _('UPnP off'),
						_('manual forwards: %d').format(forwards))}</div>
					<div>${p ? _('Inbound now: ↓ %s ↑ %s').format(common.fmtRate(p[COLS.inbound.down]), common.fmtRate(p[COLS.inbound.up])) : NBSP}</div>
				</div>
				<${kit.Go} tab="inbound" label=${_('NAT and port forwards')} />
			</div>
		</div>
	</${kit.Card}>`;
}

function WarningsCard({ list }) {
	const { html } = app.lib;
	return html`<${kit.Card} cls="w3" title=${_('Warnings')} aside=${html`<${kit.Badge} level="warn">${list.length}</${kit.Badge}>`}>
		<ul class="warns">${list.map((w) => html`<li>
			<span>${w.text}</span>
			${(w.tab || w.href) ? html`<${kit.Go} tab=${w.tab} href=${w.href} label=${w.label} />` : ''}
		</li>`)}</ul>
	</${kit.Card}>`;
}

function Page({ store, view, iface, chartView }) {
	const { html } = app.lib;
	const { status, devices, offline } = app.use(store);
	app.use(app.changes);   // переключатели читают UCI — перерисовка после app.set
	const st = status || {};
	const list = warnings(st);
	return html`
		<${kit.PageHead} title=${_('Truba')} offline=${offline}
			text=${_('Home network through your own VPS: the VPS gives the router its public IP, the router decides what goes through the tunnel.')} />
		<${Hero} st=${st} iface=${iface} warns=${list.length} />
		<div class="grid">
			<${FlowCard} st=${st} devices=${devices} />
			<${TunnelCard} st=${st} iface=${iface} />
			<${SpeedCard} st=${st} view=${chartView} />
			<${DevicesCard} devices=${devices} />
			<${InfoCard} st=${st} />
			${list.length ? html`<${WarningsCard} list=${list} />` : ''}
		</div>
		<${kit.ChangesBar} view=${view} />
		<${kit.Toast} />`;
}

return view.extend({
	...app.actions,

	load: function() {
		// Сроки истории — из схемы службы: без них fetchHistory не знает, сколько точек просить.
		return Promise.all([ app.load(), common.loadSchema() ]).then(([ , s ]) => {
			setHistory(s.consts.history);
			return Promise.all([ common.callStatus().catch(() => null), uci.load('network'), uci.load('truba'), uci.load('firewall'),
				fetchHistory(savedSpan()), fetchDevices() ]);
		});
	},

	render: function(data) {
		const store = app.store({ status: data[0], devices: data[5], offline: data[0] == null });
		const chartView = app.store({ span: savedSpan(), minAt: 0 });
		app.poll(store, () => Promise.all([ common.callStatus(), fetchHistory(chartView.get().span), fetchDevices() ])
			.then(([ st, , dv ]) => ({ status: st, devices: dv })), POLL);
		return app.mount(this, Page, { store, chartView, iface: common.tunnelIface() });
	}
});
