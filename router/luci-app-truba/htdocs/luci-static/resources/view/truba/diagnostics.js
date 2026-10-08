'use strict';
'require view';
'require ui';
'require truba.common as common';

function actionBadge(a) {
	return common.pill(common.ACTION_LEVELS[a] || '', common.ACTION_LABELS[a] || a);
}

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
		if (m[5] == 'mosdns') {
			const p = msg.split('\t');
			if (p.length >= 3 && /^\d{4}-\d\d-\d\dT/.test(p[0])) {
				const lv = p[1].toUpperCase();
				level = /ERROR|FATAL|PANIC/.test(lv) ? 'err' : lv == 'WARN' ? 'warn' : 'info';
				msg = p.slice(2).join(' ');
			}
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
	no_target: _('no address to ping')
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

function renderCheck(r) {
	if (!r || r.error || !r.action)
		return E('p', {}, _('Error: %s').format((r && r.error) || 'no answer'));

	const parts = [
		E('p', { 'class': 'truba-target' }, [ E('strong', {}, r.target), ' → ', actionBadge(r.action) ]),
		E('p', {}, _('Why: %s').format(common.REASON_LABELS[r.reason] || r.reason))
	];

	if (r.kind == 'domain') {
		const hits = r.geosite || [];
		parts.push(E('h4', {}, _('geosite categories containing the domain')));
		parts.push(hits.length ? E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Category')), E('th', { 'class': 'th' }, _('Matching entry')),
				E('th', { 'class': 'th' }, _('Entries')), E('th', { 'class': 'th' }, _('Action'))
			])
		].concat(hits.map((h) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, (r.decisive && r.decisive.tag == h.tag) ? E('strong', {}, h.tag + ' ✓') : h.tag),
			E('td', { 'class': 'td' }, E('code', {}, h.entry)),
			E('td', { 'class': 'td' }, common.fmtNum(h.count)),
			E('td', { 'class': 'td' }, common.ACTION_LABELS[h.action] || h.action)
		])))) : E('p', {}, common.empty(_('none'))));
		if (r.decisive)
			parts.push(E('p', {}, _('Decisive category (the narrowest one with an explicit action): %s').format(r.decisive.tag)));
	}

	const ips = r.ips || [];
	if (ips.length) {
		parts.push(E('h4', {}, _('Addresses')));
		parts.push(E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, 'IP'), E('th', { 'class': 'th' }, _('geoip categories')),
				E('th', { 'class': 'th' }, _('Action')), E('th', { 'class': 'th' }, _('Why'))
			])
		].concat(ips.map((v) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, v.ip),
			E('td', { 'class': 'td' }, (v.geoip || []).join(', ') || '—'),
			E('td', { 'class': 'td' }, actionBadge(v.action)),
			E('td', { 'class': 'td' }, (common.REASON_LABELS[v.reason] || v.reason) + (v.device ? ' (%s)'.format(v.device) : ''))
		])))));
	}
	return E('div', {}, parts);
}

return view.extend({
	load: function() {
		return common.callLeases().catch(() => ({}));
	},

	render: function(leasesData) {
		const leases = (leasesData && leasesData.dhcp_leases) || [];
		const input = E('input', { 'type': 'text', 'class': 'cbi-input-text truba-grow',
			'placeholder': _('domain or IPv4, e.g. gosuslugi.ru') });
		const dev = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, _('— any device —')) ].concat(
			leases.filter((l) => l.macaddr).map((l) => E('option', { 'value': l.macaddr }, '%s (%s)'.format(l.hostname || l.ipaddr || '?', l.macaddr)))));
		const out = E('div');
		const ttOut = E('div');
		const logBox = E('pre', { 'class': 'truba-log' });

		const runCheck = () => {
			const t = input.value.trim();
			if (!t)
				return;
			out.replaceChildren(common.busy(_('Checking…')));
			// Без устройства аргумент mac не передаётся вовсе: rpcd отклоняет null вместо строки.
			const call = dev.value ? common.callCheck(t, dev.value) : common.callCheck(t);
			return call.then((r) => out.replaceChildren(renderCheck(r)));
		};
		input.addEventListener('keydown', (ev) => { if (ev.key == 'Enter') runCheck(); });

		const runTunnelTest = () => {
			ttOut.replaceChildren(common.busy(_('Checking… about 5 seconds')));
			return common.callTunnelTest()
				.then((r) => ttOut.replaceChildren(renderTunnelTest(r)))
				.catch((e) => ttOut.replaceChildren(renderTunnelTest({ error: e.message })));
		};

		// Журнал: загружается целиком, фильтр — в браузере.
		let lines = [], filter = 'all';
		const FILTER_LABELS = { all: _('All'), truba: _('Truba'), mosdns: 'mosdns', problems: _('Warnings and errors') };
		const chips = LOG_FILTERS.map((f) => {
			const b = E('button', { 'class': 'truba-chip', 'type': 'button', 'aria-pressed': f == filter ? 'true' : 'false', 'click': () => {
				filter = f;
				for (let x of chips)
					x.setAttribute('aria-pressed', x === b ? 'true' : 'false');
				showLog(logBox, lines, filter);
			} }, FILTER_LABELS[f]);
			return b;
		});
		const loadLog = () => common.callLog(300).then((t) => {
			lines = parseLog(t);
			showLog(logBox, lines, filter);
		});
		loadLog();

		return E('div', {}, [
			E('h2', { 'name': 'content' }, _('Diagnostics')),
			E('div', { 'class': 'cbi-map-descr' }, _('Checks and the log. Nothing is configured on this tab.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Check domain / IP')),
				E('p', { 'class': 'cbi-section-descr' },
					_('Shows which category and action apply and why. A domain is resolved through the router, the same way a device would.')),
				E('div', { 'class': 'truba-toolbar' }, [
					input, dev,
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, runCheck) }, _('Check'))
				]),
				out
			]),
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
