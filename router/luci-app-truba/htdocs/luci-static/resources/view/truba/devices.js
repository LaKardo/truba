'use strict';
'require view';
'require form';
'require uci';
'require truba.common as common';

return view.extend({
	load: function() {
		return Promise.all([ common.callLeases().catch(() => ({})), uci.load('truba') ]);
	},

	render: function(data) {
		const leases = (data[0] && data[0].dhcp_leases) || [];

		const m = new form.Map('truba', _('Devices'),
			_('Per-device exceptions. A device is recognised by its MAC address, also behind roamd mesh nodes (4-address mode keeps client MACs). Block still applies to all devices.'));

		const s = m.section(form.GridSection, 'device', _('Device policies'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;

		let o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'mac', _('MAC address'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		for (let l of leases) {
			if (l.macaddr)
				o.value(l.macaddr.toUpperCase(), '%s (%s, %s)'.format(l.macaddr.toUpperCase(), l.hostname || '?', l.ipaddr || '?'));
		}

		o = s.option(form.ListValue, 'policy', _('Policy'));
		o.value('tunnel', _('All via tunnel'));
		o.value('direct', _('All direct'));
		o.value('rules', _('By rules'));
		o.default = 'tunnel';
		o.editable = true;
		o.description = _('«All via tunnel» is recommended for game consoles: then all their traffic gets the Truba IP and full cone NAT.');

		return m.render();
	}
});
