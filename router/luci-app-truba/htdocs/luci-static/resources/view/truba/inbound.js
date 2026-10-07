'use strict';
'require view';
'require form';
'require uci';
'require truba.common as common';

return view.extend({
	load: function() {
		return Promise.all([ uci.load('firewall'), L.resolveDefault(uci.load('upnpd'), null), common.callStatus() ]);
	},

	render: function(data) {
		const st = data[2] || {};
		const up = st.upnp || {};
		// Конфиг upnpd может остаться и без самого miniupnpd — смотрим на установленную службу.
		const haveUpnp = data[1] != null && up.installed !== false;
		const forwards = uci.sections('firewall', 'redirect').filter((r) => r.src == 'truba');
		const tr = st.traffic?.inbound || {}, since = st.applied?.counters_since;

		const m = new form.Map('truba', _('Inbound'),
			_('All ports of the Truba IP %s (except the VPS SSH and tunnel ports) reach the router. Full cone NAT keeps mappings open for any remote host; ports for home devices are opened manually or via UPnP.').format(st.vps_ip || '—'));

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

		// Те же счётчики, что в строке «Входящие через Трубу» на «Обзоре».
		const num = (v) => E('td', { 'class': 'truba-num' }, v);
		return m.render().then((mapEl) => E('div', {}, [
			mapEl,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Inbound via Truba')),
				E('table', { 'class': 'truba-grid' }, [
					E('tr', {}, [
						E('th', {}, _('Counted since')),
						E('th', {}, '↓ ' + _('To devices')),
						E('th', {}, '↑ ' + _('From devices')),
						E('th', {}, _('New connections'))
					]),
					E('tr', {}, [
						num(since ? common.fmtTime(since) : '—'),
						num(common.fmtBytes(tr.down)),
						num(common.fmtBytes(tr.up)),
						num(common.fmtNum(st.counters?.inbound?.packets))
					])
				]),
				E('p', { 'class': 'cbi-section-descr' }, _('Replies always go back through the tunnel, even to Russian clients.'))
			]),
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
