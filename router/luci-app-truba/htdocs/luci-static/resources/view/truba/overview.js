'use strict';
'require view';
'require form';
'require poll';
'require uci';
'require ui';
'require truba.common as common';

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		E('td', { 'class': 'td left' }, value)
	]);
}

// Скорость — по разнице с прошлым опросом (раз в 5 с).
let prevSample = null;

function takeRates(st) {
	const now = Date.now() / 1000, awg = st.tunnel?.awg || {}, tr = st.traffic || {};
	const cur = { t: now, rx: awg.rx, tx: awg.tx, tr };
	const p = prevSample;
	prevSample = cur;
	if (!p || now - p.t < 1)
		return null;
	const dt = now - p.t;
	const d = (a, b) => (a != null && b != null && a >= b) ? (a - b) / dt : null;
	const r = { rx: d(cur.rx, p.rx), tx: d(cur.tx, p.tx) };
	for (let k of [ 'tunnel', 'direct', 'inbound' ])
		r[k] = { down: d(tr[k]?.down, p.tr[k]?.down), up: d(tr[k]?.up, p.tr[k]?.up) };
	return r;
}

function rateText(down, up) {
	return (down == null || up == null) ? '—' : '↓ %s · ↑ %s'.format(common.fmtRate(down), common.fmtRate(up));
}

function renderTraffic(st, rates) {
	const tr = st.traffic || {}, since = st.applied?.counters_since;
	const rows = [
		[ _('Tunnel'), 'tunnel' ],
		[ _('Direct'), 'direct' ],
		[ _('Inbound via Truba'), 'inbound' ]
	].map(([ label, k ]) => E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left' }, label),
		E('td', { 'class': 'td left' }, common.fmtBytes(tr[k]?.down)),
		E('td', { 'class': 'td left' }, common.fmtBytes(tr[k]?.up)),
		E('td', { 'class': 'td left' }, rates ? rateText(rates[k].down, rates[k].up) : '—')
	]));
	return E('div', {}, [
		E('p', { 'class': 'cbi-section-descr' }, since
			? _('Traffic of devices in the routed zones since %s. The router\'s own traffic (DNS, list downloads) is not included.').format(common.fmtTime(since))
			: _('Traffic of devices in the routed zones. The router\'s own traffic (DNS, list downloads) is not included.')),
		E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Action')),
				E('th', { 'class': 'th' }, _('To devices')),
				E('th', { 'class': 'th' }, _('From devices')),
				E('th', { 'class': 'th' }, _('Now'))
			])
		].concat(rows))
	]);
}

// Наборы, которые последняя проверка не смогла скачать: «geoip: причина».
function failedSets(last) {
	const sets = last?.sets || {};
	return Object.keys(sets).filter((k) => !sets[k].ok).map((k) => '%s: %s'.format(k, (sets[k].errors || []).join(', ') || '?'));
}

function checkResult(last) {
	const failed = failedSets(last);
	if (failed.length)
		return _('failed (%s)').format(failed.join('; '));
	return last.changed ? _('updated') : _('no newer versions');
}

function renderStatus(st, rates) {
	const t = st.tunnel || {}, awg = t.awg || {}, h = st.health || {}, c = st.counters || {};
	const a = st.applied || {}, nb = st.neighbours || {}, up = st.upnp || {};
	const lastCheck = st.lists?.last;

	let tunnelState;
	if (!t.configured)
		tunnelState = E('em', {}, _('not configured'));
	else if (t.disabled)
		tunnelState = common.badge(false, '', _('disabled'));
	else
		tunnelState = common.badge(t.up && h.state != 'down', _('working'), t.up ? _('not responding') : _('down'));

	let table = (st.table || '').trim();
	let tableState = !st.service ? _('service stopped')
		: /blackhole/.test(table) ? _('emergency block (tunnel traffic is dropped)')
		: /default dev/.test(table) ? _('via tunnel')
		: _('fallback to direct (no tunnel route)');

	const rows = [
		row(_('Tunnel'), tunnelState),
		row(_('Last handshake'), awg.handshake ? common.fmtAge(awg.handshake_age) : _('never')),
		row(_('Tunnel: received / sent'), awg.rx != null ? E('span', {}, [
			'%s / %s'.format(common.fmtBytes(awg.rx), common.fmtBytes(awg.tx)),
			E('span', { 'class': 'cbi-value-description' }, ' · %s · %s'.format(
				_('since the interface came up, including the router\'s own traffic'),
				rates ? _('now %s').format(rateText(rates.rx, rates.tx)) : _('speed after the next update')))
		]) : '—'),
		row(_('Truba IP (VPS)'), st.vps_ip || '—'),
		row(_('Tunnel address'), t.address ? '%s ↔ %s'.format(t.address, t.peer || '?') : '—'),
		row(_('Routing'), st.routing
			? '%s, %s'.format(_('enabled'), st.mode == 'selective' ? _('mode «Selective»') : _('mode «All via tunnel»'))
			: _('disabled — everything goes direct')),
		row(_('Tunnel route table'), tableState),
		row(_('Tunnel watchdog'), h.state
			? '%s %s'.format(h.state == 'healthy' ? _('healthy since') : _('down since'), common.fmtTime(h.since))
			: _('no data')),
		row(_('DNS classifier (mosdns)'), st.routing ? common.badge(st.mosdns, _('running'), _('not running')) : '—'),
		row(_('New connections'), E('span', {}, [
			_('Tunnel'), ': ', String(c.tunnel?.packets ?? 0), ' · ',
			_('Direct'), ': ', String(c.direct?.packets ?? 0), ' · ',
			_('Inbound via Truba'), ': ', String(c.inbound?.packets ?? 0), ' · ',
			_('Blocked'), ': ', String(c.block?.packets ?? 0), ' ', _('packets'),
			a.counters_since ? E('span', { 'class': 'cbi-value-description' }, ' · ' + _('since %s').format(common.fmtTime(a.counters_since))) : ''
		])),
		row(_('Rule sets'), E('span', {}, [
			'geoip.dat: ', st.lists?.geoip ? common.fmtTime(st.lists.geoip.mtime) : _('missing'), ' · ',
			'geosite.dat: ', st.lists?.geosite ? common.fmtTime(st.lists.geosite.mtime) : _('missing'),
			// Даты — когда файл скачан; если источник не выпускал новых, они не меняются.
			E('span', { 'class': 'cbi-value-description' }, ' · ' + (st.lists?.updating
				? _('update in progress')
				: lastCheck ? _('checked %s: %s').format(common.fmtTime(lastCheck.time), checkResult(lastCheck)) : _('not checked yet')))
		]))
	];

	const warns = [];
	for (let w of (a.warnings || []))
		warns.push(E('li', {}, common.WARNING_LABELS[w] || w));
	for (let m of (a.missing || []))
		warns.push(E('li', {}, _('Category %s is configured but missing from the current rule set — the rule is ignored.').format(m)));
	if (a.error)
		warns.push(E('li', {}, _('Error while applying rules: %s').format(a.error)));
	if (nb.offload)
		warns.push(E('li', {}, _('Software flow offloading is on (Network → Firewall): packets of offloaded connections bypass the Truba counters, so device traffic is undercounted.')));
	if (nb.openclash_fakeip)
		warns.push(E('li', {}, _('OpenClash runs in fake-ip mode: «Check NAT» may report a problem although full cone NAT works.')));
	if (up.enabled && !up.installed)
		warns.push(E('li', {}, _('UPnP is enabled on the Inbound tab, but miniupnpd is not installed: install luci-app-upnp.')));
	// Автообновление идёт раз в сутки; проверка старше 36 ч — cron не запускал его или он падал.
	if (st.routing && uci.get('truba', 'lists', 'auto_update') != '0' && !st.lists?.updating) {
		const failed = failedSets(lastCheck);
		if (!lastCheck || Date.now() / 1000 - lastCheck.time > 36 * 3600)
			warns.push(E('li', {}, _('Rule sets have not been checked for more than 36 hours although auto-update is on: check that cron runs (System → Scheduled Tasks).')));
		else if (failed.length)
			warns.push(E('li', {}, _('The last rule set check failed: %s').format(failed.join('; '))));
	}

	return E('div', {}, [
		warns.length ? E('div', { 'class': 'alert-message warning' }, E('ul', {}, warns)) : '',
		E('table', { 'class': 'table' }, rows)
	]);
}

function renderNat(r) {
	if (r.error)
		return E('p', {}, _('Test failed: %s').format(r.error));
	return E('div', {}, [
		E('p', {}, [ common.badge(r.ok, _('OK'), _('problem')), ' ',
			_('External IP: %s (Truba IP: %s), local port %s').format(r.external_ip || '—', r.vps_ip || '—', r.local_port) ]),
		E('ul', {}, [
			E('li', {}, [ _('External IP is the Truba IP'), ': ', r.ip_is_vps ? _('yes') : _('no') ]),
			E('li', {}, [ _('Port preserved'), ': ', r.port_preserved ? _('yes') : _('no') ]),
			E('li', {}, [ _('Same mapping for different servers'), ': ', r.consistent ? _('yes') : _('no') ])
		]),
		E('p', { 'class': 'cbi-value-description' },
			_('This checks the Truba layer only. For the full RFC 5780 test run NatTypeTester on a PC in the home network whose device policy is «All via tunnel».'))
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ common.callStatus(), uci.load('network'), uci.load('truba') ]);
	},

	render: function(data) {
		const st = data[0];
		const iface = common.tunnelIface();
		takeRates(st);   // первая точка отсчёта скорости
		const statusBox = E('div', {}, renderStatus(st, null));
		const trafficBox = E('div', {}, renderTraffic(st, null));
		const natBox = E('div');

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

		poll.add(() => common.callStatus().then((st) => {
			const rates = takeRates(st);
			statusBox.replaceChildren(renderStatus(st, rates));
			trafficBox.replaceChildren(renderTraffic(st, rates));
		}), 5);

		return m.render().then((mapEl) => E('div', {}, [
			mapEl,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				statusBox
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Device traffic')),
				trafficBox
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('NAT check')),
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, () => {
						natBox.replaceChildren(E('em', { 'class': 'spinning' }, _('Testing…')));
						return common.callNatTest().then((r) => natBox.replaceChildren(renderNat(r)));
					})
				}, _('Check NAT')),
				natBox
			])
		]));
	}
});
