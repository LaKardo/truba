'use strict';
'require view';
'require ui';
'require truba.common as common';

// ---- Журнал ----

// Строка logread: «Wed Oct  7 22:47:05 2026 daemon.notice truba: текст»; у mosdns текст —
// «2026-10-07T17:59:32.409Z<TAB>WARN<TAB>сообщение<TAB>{поля}». mosdns пишет всё в stderr,
// поэтому syslog помечает каждую его строку как ошибку: уровень берётся из самой строки.
const LOG_RE = /^\w{3} (\w{3}) +(\d+) (\d\d:\d\d:\d\d) \d{4} \w+\.(\w+) ([\w.-]+?)(?:\[\d+\])?: (.*)$/;
const MONTHS = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };

function parseLog(text) {
	return (text || '').split('\n').filter((l) => l).map((l) => {
		const m = l.match(LOG_RE);
		if (!m)
			return { time: '', src: '', level: 'info', text: l };
		let level = /^(emerg|alert|crit|err)$/.test(m[4]) ? 'err' : /^warn/.test(m[4]) ? 'warn' : 'info';
		let msg = m[6];
		// busybox crond пишет каждый запуск задачи (обновление списков) с уровнем ошибки.
		if (m[5] == 'crond' && /^USER \S+ pid \d+ cmd /.test(msg))
			level = 'info';
		if (m[5] == 'mosdns') {
			const p = msg.split('\t');
			if (p.length >= 3 && /^\d{4}-\d\d-\d\dT/.test(p[0])) {
				const lv = p[1].toUpperCase();
				level = /ERROR|FATAL|PANIC/.test(lv) ? 'err' : lv == 'WARN' ? 'warn' : 'info';
				msg = p.slice(2).join(' ');
			}
			// Дампа кэша нет после каждой загрузки Роутера (он в памяти) — это не ошибка.
			if (/failed to load cache dump.*no such file/.test(msg))
				level = 'info';
		}
		return { time: '%02d.%02d %s'.format(+m[2], MONTHS[m[1]] || 0, m[3]), src: m[5], level, text: msg };
	});
}

const LOG_FILTERS = [ 'all', 'truba', 'mosdns', 'problems' ];

function showLog(box, lines, f) {
	const shown = lines.filter((l) => f == 'all' || (f == 'problems' ? l.level != 'info' : l.src == f));
	box.replaceChildren(...(shown.length
		? shown.map((l) => E('div', { 'class': l.level == 'info' ? '' : l.level },
			'%s  %s  %s'.format(l.time, (l.src + '      ').substring(0, 6), l.text)))
		: [ common.empty(_('Nothing to show.')) ]));
}

// ---- Проверка Туннеля ----

const TT_ERRORS = {
	not_configured: common.NAT_ERRORS.not_configured,
	tunnel_down: common.NAT_ERRORS.tunnel_down,
	timeout: common.NAT_ERRORS.timeout,
	no_target: _('no address to ping'),
	tmp: _('no room for temporary files on the router')
};

function renderTunnelTest(r) {
	if (!r || r.error)
		return E('p', {}, _('Not checked: %s').format(TT_ERRORS[r?.error] || r?.error || _('no answer')));
	const rows = (r.results || []).map((x) => E('tr', {}, [
		E('td', {}, (x.size == r.mtu ? _('%d bytes — the whole MTU') : _('%d bytes')).format(x.size)),
		E('td', {}, E('span', { 'class': 'truba-dot ' + (x.ok ? 'ok' : 'err') }, _('%d of %d').format(x.received, x.sent))),
		E('td', { 'class': 'truba-num' }, x.avg != null ? _('%d ms').format(Math.round(x.avg)) : '—')
	]));
	// Вывод: всё проходит; не проходят даже мелкие — Труба не отвечает вовсе (MTU ни при чём);
	// мелкие проходят, крупные нет — путь не пропускает полноразмерные пакеты.
	const small = (r.results || [])[0];
	const verdict = r.ok ? [ 'ok', _('Full-size packets get through'), _('MTU %d suits the path to the Truba.').format(r.mtu) ]
		: (small && !small.ok) ? [ 'err', _('No replies'), _('The Truba does not answer inside the tunnel: see the State on the Tunnel tab.') ]
		: [ 'err', _('Packets are lost'), _('If only the largest packets are lost, lower the tunnel MTU on both sides (Tunnel tab and install-vps.sh).') ];
	return E('div', {}, [
		E('table', { 'class': 'truba-grid' }, [
			E('tr', {}, [ E('th', {}, _('Packet size')), E('th', {}, _('Replies')), E('th', {}, _('Latency')) ])
		].concat(rows)),
		E('p', {}, [ common.pill(verdict[0], verdict[1]), ' ', E('span', { 'class': 'truba-muted' }, verdict[2]) ])
	]);
}

return view.extend({
	render: function() {
		const ttOut = E('div');
		const logBox = E('pre', { 'class': 'truba-log' });

		const runTunnelTest = () => {
			ttOut.replaceChildren(common.busy(_('Checking… about 5 seconds')));
			return common.runTunnelTest()
				.then((r) => ttOut.replaceChildren(renderTunnelTest(r)))
				.catch((e) => ttOut.replaceChildren(renderTunnelTest({ error: e.message })));
		};

		// Журнал: загружается целиком, фильтр — в браузере.
		let lines = [], filter = 'all';
		const FILTER_LABELS = { all: _('All'), truba: _('Truba'), mosdns: 'mosdns', problems: _('Warnings and errors') };
		const chips = common.chips(LOG_FILTERS.map((f) => [ f, FILTER_LABELS[f] ]), filter, (f) => {
			filter = f;
			showLog(logBox, lines, filter);
		});
		const loadLog = () => common.callLog(300).then((t) => {
			lines = parseLog(t);
			showLog(logBox, lines, filter);
		}).catch((e) => logBox.replaceChildren(common.empty(_('Error: %s').format(e.message))));
		loadLog();

		return E('div', {}, [
			E('h2', { 'name': 'content' }, _('Diagnostics')),
			E('div', { 'class': 'cbi-map-descr' }, _('Checks and the log. Nothing is configured on this tab.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Tunnel check')),
				E('p', { 'class': 'cbi-section-descr' },
					_('Pings the Truba inside the tunnel with packets of three sizes, up to the whole tunnel MTU. Shows loss of large packets that a normal ping does not see: with it pages open slowly and downloads stall.')),
				E('div', { 'class': 'truba-toolbar' },
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, runTunnelTest) }, _('Check the tunnel'))),
				ttOut
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Log: Truba and mosdns')),
				E('div', { 'class': 'truba-toolbar' }, [
					E('div', { 'class': 'truba-chips truba-grow', 'role': 'group', 'aria-label': _('Log filter') }, chips),
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, loadLog) }, _('Refresh'))
				]),
				logBox
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
