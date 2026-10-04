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
		const haveUpnp = data[1] != null;
		const forwards = uci.sections('firewall', 'redirect').filter((r) => r.src == 'truba');

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

		const rows = forwards.map((r) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, r.name || '—'),
			E('td', { 'class': 'td' }, L.toArray(r.proto).join(', ') || 'tcp udp'),
			E('td', { 'class': 'td' }, r.src_dport || '—'),
			E('td', { 'class': 'td' }, '%s:%s'.format(r.dest_ip || '?', r.dest_port || r.src_dport || '?')),
			E('td', { 'class': 'td' }, r.enabled == '0' ? _('disabled') : _('enabled'))
		]));

		return m.render().then((mapEl) => E('div', {}, [
			mapEl,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Port forwards from the tunnel')),
				rows.length ? E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Name')), E('th', { 'class': 'th' }, _('Protocol')),
						E('th', { 'class': 'th' }, _('External port')), E('th', { 'class': 'th' }, _('Device')),
						E('th', { 'class': 'th' }, _('State'))
					])
				].concat(rows)) : E('p', {}, E('em', {}, _('No port forwards with source zone «truba».'))),
				E('p', {}, [
					E('a', { 'class': 'btn cbi-button', 'href': L.url('admin/network/firewall/forwards') }, _('Edit port forwards')),
					' ',
					E('span', { 'class': 'cbi-value-description' }, _('Choose source zone «truba».'))
				]),
				E('p', { 'class': 'cbi-value-description' },
					_('Inbound connections via the tunnel: %s. Replies always go back through the tunnel, even to Russian clients.').format(String(st.counters?.inbound?.packets ?? 0)))
			])
		]));
	}
});
