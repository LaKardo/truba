'use strict';
'require view';
'require form';
'require poll';
'require uci';
'require ui';
'require truba.common as common';

// «Входящие»: Проверка NAT, UPnP / NAT-PMP и пробросы портов из Туннеля. Трафик входящих —
// в таблице «Трафик устройств» на «Обзоре», здесь он не повторяется.

// ---- Проверка NAT: строки постоянны, меняются значения; список серверов — по клику ----

function buildNat(view) {
	const span = (cls) => E('span', cls ? { 'class': cls } : {});
	const x = { busy: false, key: null };
	x.state = span('truba-badge');
	x.addr = span('truba-num');
	x.vps = span('truba-dot');
	x.port = span('truba-dot');
	x.same = span('truba-dot');
	x.when = span();
	x.servers = E('ul');
	x.btn = E('button', { 'class': 'btn cbi-button-action', 'type': 'button', 'click': ui.createHandlerFn(view, () => runNat(x)) },
		_('Check NAT'));
	const row = (label, value) => E('tr', {}, [ E('th', { 'scope': 'row' }, label), E('td', {}, value) ]);
	x.el = E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('NAT check'), ' ', x.state ]),
		E('table', { 'class': 'truba-kv' }, [
			row(_('External address'), x.addr),
			row(_('External IP is the Truba IP'), x.vps),
			row(_('Port preserved'), x.port),
			row(_('Same mapping for different servers'), x.same),
			row(_('Checked'), x.when)
		]),
		E('details', { 'class': 'truba-details' }, [ E('summary', {}, _('STUN servers')), x.servers ]),
		E('div', { 'class': 'truba-toolbar' }, [ x.btn ]),
		E('p', { 'class': 'truba-muted' },
			_('This checks the Truba layer only. For the full RFC 5780 test run NatTypeTester on a PC in the home network whose device policy is «All via tunnel».'))
	]);
	return x;
}

function setState(el, level, text) {
	common.setLevel(el, level);
	common.setText(el, text);
}

// Итог «Проверки NAT»: из status (последняя проверка) или сразу после нажатия кнопки.
function paintNat(x, n, wdOn) {
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

function runNat(x) {
	x.busy = true;
	setState(x.state, '', _('Testing…'));
	return common.callNatTest()
		.then((n) => paintNat(x, n, true))
		.catch((e) => paintNat(x, { time: Date.now() / 1000, error: e.message }, true))
		.finally(() => { x.busy = false; });
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('firewall'), L.resolveDefault(uci.load('upnpd'), null), common.callStatus(), uci.load('truba') ]);
	},

	render: function(data) {
		const st = data[2] || {};
		const up = st.upnp || {};
		const wdOn = uci.get('truba', 'watchdog', 'enabled') != '0';
		// Конфиг upnpd может остаться и без самого miniupnpd — смотрим на установленную службу.
		const haveUpnp = data[1] != null && up.installed !== false;
		const forwards = uci.sections('firewall', 'redirect').filter((r) => r.src == 'truba');

		const nat = buildNat(this);
		paintNat(nat, st.nat, wdOn);
		// Итог появляется сам через несколько секунд после подъёма Туннеля.
		poll.add(() => common.callStatus().then((s) => {
			if (!nat.busy)
				paintNat(nat, s.nat, wdOn);
		}), 10);

		const m = new form.Map('truba');
		const s = m.section(form.NamedSection, 'main', 'main', _('UPnP / NAT-PMP'));
		s.addremove = false;
		const o = s.option(form.Flag, 'upnp', _('Enable UPnP and NAT-PMP on the tunnel'),
			haveUpnp
				? _('Devices open ports themselves; miniupnpd reports the Truba IP as the external address.')
				: _('Package luci-app-upnp is not installed.'));
		o.default = '0';
		o.rmempty = false;
		o.readonly = !haveUpnp;

		let upnpState = '';
		if (up.enabled && !up.installed)
			upnpState = E('div', { 'class': 'alert-message warning' }, common.UPNP_MISSING);
		else if (up.enabled && !up.running)
			upnpState = E('div', { 'class': 'alert-message warning' }, _('UPnP is enabled, but miniupnpd is not running.'));
		const leases = (up.leases || []).map((l) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, l.proto),
			E('td', { 'class': 'td' }, String(l.ext_port)),
			E('td', { 'class': 'td' }, '%s:%d'.format(l.ip, l.port)),
			E('td', { 'class': 'td' }, l.descr || '—'),
			E('td', { 'class': 'td' }, l.expires ? common.fmtTime(l.expires) : _('no expiry'))
		]));

		const rows = forwards.map((r) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, r.name || '—'),
			E('td', { 'class': 'td' }, L.toArray(r.proto).join(', ') || 'tcp udp'),
			E('td', { 'class': 'td' }, r.src_dport || '—'),
			E('td', { 'class': 'td' }, '%s:%s'.format(r.dest_ip || '?', r.dest_port || r.src_dport || '?')),
			E('td', { 'class': 'td' }, r.enabled == '0' ? _('disabled') : _('enabled'))
		]));

		return m.render().then((mapEl) => E('div', {}, [
			E('h2', { 'name': 'content' }, _('Inbound')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('All ports of the Truba IP %s (except the VPS SSH and tunnel ports) reach the router. Full cone NAT keeps mappings open for any remote host; ports for home devices are opened manually or via UPnP.').format(st.vps_ip || '—'),
				' ', _('Replies always go back through the tunnel, even to Russian clients.'), ' ',
				E('a', { 'href': L.url('admin/services/truba/overview') }, _('Inbound traffic is on the Overview.'))
			]),
			nat.el,
			mapEl,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Active UPnP / NAT-PMP mappings')),
				upnpState,
				leases.length ? E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Protocol')), E('th', { 'class': 'th' }, _('External port')),
						E('th', { 'class': 'th' }, _('Device')), E('th', { 'class': 'th' }, _('Description')),
						E('th', { 'class': 'th' }, _('Expires'))
					])
				].concat(leases)) : E('p', {}, common.empty(_('No active mappings.')))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Port forwards from the tunnel')),
				rows.length ? E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Name')), E('th', { 'class': 'th' }, _('Protocol')),
						E('th', { 'class': 'th' }, _('External port')), E('th', { 'class': 'th' }, _('Device')),
						E('th', { 'class': 'th' }, _('State'))
					])
				].concat(rows)) : E('p', {}, common.empty(_('No port forwards with source zone «truba».'))),
				E('div', { 'class': 'truba-toolbar' }, [
					E('a', { 'class': 'btn cbi-button', 'href': L.url('admin/network/firewall/forwards') }, _('Edit port forwards')),
					E('span', { 'class': 'cbi-value-description' }, _('Choose source zone «truba».'))
				])
			])
		]));
	}
});
