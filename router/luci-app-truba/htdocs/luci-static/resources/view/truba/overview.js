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

function renderStatus(st) {
	const t = st.tunnel || {}, awg = t.awg || {}, h = st.health || {}, c = st.counters || {};
	const a = st.applied || {};

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
		row(_('Received / sent'), awg.rx != null ? '%s / %s'.format(common.fmtBytes(awg.rx), common.fmtBytes(awg.tx)) : '—'),
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
		row(_('Traffic by action'), E('span', {}, [
			_('Tunnel'), ': ', common.fmtBytes(c.tunnel?.bytes), ' · ',
			_('Direct'), ': ', common.fmtBytes(c.direct?.bytes), ' · ',
			_('Blocked'), ': ', String(c.block?.packets ?? 0), ' ', _('packets'), ' · ',
			_('Inbound via Truba'), ': ', String(c.inbound?.packets ?? 0), ' ', _('connections')
		])),
		row(_('Rule sets'), E('span', {}, [
			'geoip.dat: ', st.lists?.geoip ? common.fmtTime(st.lists.geoip.mtime) : _('missing'), ' · ',
			'geosite.dat: ', st.lists?.geosite ? common.fmtTime(st.lists.geosite.mtime) : _('missing')
		]))
	];

	const warns = [];
	for (let w of (a.warnings || []))
		warns.push(E('li', {}, common.WARNING_LABELS[w] || w));
	for (let m of (a.missing || []))
		warns.push(E('li', {}, _('Category %s is configured but missing from the current rule set — the rule is ignored.').format(m)));
	if (a.error)
		warns.push(E('li', {}, _('Error while applying rules: %s').format(a.error)));

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
		return Promise.all([ common.callStatus(), uci.load('network') ]);
	},

	render: function(data) {
		const st = data[0];
		const iface = common.tunnelIface();
		const statusBox = E('div', {}, renderStatus(st));
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
			statusBox.replaceChildren(renderStatus(st));
		}), 5);

		return m.render().then((mapEl) => E('div', {}, [
			mapEl,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				statusBox
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
