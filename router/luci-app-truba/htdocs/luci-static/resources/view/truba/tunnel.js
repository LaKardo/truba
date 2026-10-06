'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require truba.common as common';

// Ключи .conf (без регистра) → опции UCI протокола amneziawg.
const IFACE_KEYS = {
	privatekey: 'private_key', mtu: 'mtu', listenport: 'listen_port',
	jc: 'awg_jc', jmin: 'awg_jmin', jmax: 'awg_jmax',
	s1: 'awg_s1', s2: 'awg_s2', s3: 'awg_s3', s4: 'awg_s4',
	h1: 'awg_h1', h2: 'awg_h2', h3: 'awg_h3', h4: 'awg_h4',
	i1: 'awg_i1', i2: 'awg_i2', i3: 'awg_i3', i4: 'awg_i4', i5: 'awg_i5',
	headerprotectionkey: 'awg_header_protection_key',
	contentpaddingaddition: 'awg_content_padding_addition',
	rekeyaftertime: 'awg_rekey_after_time', rekeytimeout: 'awg_rekey_timeout',
	rejectaftertime: 'awg_reject_after_time', keepalivetimeout: 'awg_keepalive_timeout',
	maxhandshakeattempts: 'awg_max_handshake_attempts'
};
const IFACE_BOOL = { randomtrailers: 'awg_random_trailers', disablecookies: 'awg_disable_cookies' };
const PEER_KEYS = { publickey: 'public_key', presharedkey: 'preshared_key', persistentkeepalive: 'persistent_keepalive' };

function parseConf(text) {
	const res = { iface: {}, peers: [] };
	let cur = null;
	for (let raw of text.split(/\r?\n/)) {
		const line = raw.replace(/^\s+|\s+$/g, '');
		if (!line || line[0] == '#' || line[0] == ';')
			continue;
		const sec = line.match(/^\[(\w+)\]$/);
		if (sec) {
			const name = sec[1].toLowerCase();
			if (name == 'interface')
				cur = res.iface;
			else if (name == 'peer')
				res.peers.push(cur = {});
			else
				cur = null;
			continue;
		}
		const kv = line.match(/^([A-Za-z0-9]+)\s*=\s*(.*)$/);
		if (kv && cur)
			cur[kv[1].toLowerCase()] = kv[2];
	}
	if (!res.iface.privatekey)
		throw new Error(_('No PrivateKey in the [Interface] section'));
	if (!res.peers.length || !res.peers[0].publickey)
		throw new Error(_('No [Peer] section with PublicKey'));
	return res;
}

function applyConf(iface, conf) {
	if (!uci.get('network', iface))
		uci.add('network', 'interface', iface);
	uci.set('network', iface, 'proto', 'amneziawg');

	for (let k in IFACE_KEYS)
		uci.unset('network', iface, IFACE_KEYS[k]);
	for (let k in IFACE_BOOL)
		uci.unset('network', iface, IFACE_BOOL[k]);

	for (let k in conf.iface) {
		if (IFACE_KEYS[k])
			uci.set('network', iface, IFACE_KEYS[k], conf.iface[k]);
		else if (IFACE_BOOL[k])
			uci.set('network', iface, IFACE_BOOL[k], /^(on|1|true|yes)$/i.test(conf.iface[k]) ? '1' : '0');
	}
	if (conf.iface.address)
		uci.set('network', iface, 'addresses', conf.iface.address.split(',').map((a) => a.trim()).filter((a) => a));

	for (let s of uci.sections('network', 'amneziawg_' + iface))
		uci.remove('network', s['.name']);

	for (let p of conf.peers) {
		const sid = uci.add('network', 'amneziawg_' + iface);
		for (let k in PEER_KEYS)
			if (p[k] != null)
				uci.set('network', sid, PEER_KEYS[k], p[k]);
		if (p.endpoint) {
			const m = p.endpoint.match(/^\[?([^\]]+?)\]?:(\d+)$/);
			if (m) {
				uci.set('network', sid, 'endpoint_host', m[1]);
				uci.set('network', sid, 'endpoint_port', m[2]);
			}
		}
		uci.set('network', sid, 'allowed_ips', (p.allowedips || '0.0.0.0/0').split(',').map((a) => a.trim()).filter((a) => a));
		// Маршруты Туннеля ведёт служба truba (таблица 77), а не netifd.
		uci.set('network', sid, 'route_allowed_ips', '0');
		uci.set('network', sid, 'description', 'Truba');
	}

	// Интерфейс должен входить в зону truba.
	const zone = uci.sections('firewall', 'zone').find((z) => z.name == 'truba');
	if (zone) {
		const nets = L.toArray(zone.network);
		if (nets.indexOf(iface) < 0)
			uci.set('firewall', zone['.name'], 'network', nets.concat([ iface ]));
	}
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('truba'), uci.load('network'), uci.load('firewall') ]);
	},

	handleImport: function(iface) {
		const ta = E('textarea', {
			'class': 'cbi-input-textarea', 'style': 'width:100%;font-family:monospace', 'rows': 16,
			'placeholder': '[Interface]\nPrivateKey = …\nAddress = 10.77.77.2/30\n…\n\n[Peer]\nPublicKey = …\nEndpoint = …'
		});
		const file = E('input', { 'type': 'file', 'accept': '.conf,text/plain', 'change': (ev) => {
			const f = ev.target.files[0];
			if (f)
				f.text().then((t) => { ta.value = t; });
		} });

		ui.showModal(_('Import tunnel configuration'), [
			E('p', {}, _('Paste router.conf produced by install-vps.sh on the VPS, or choose the file.')),
			file, E('br'), E('br'), ta,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => {
					let conf;
					try {
						conf = parseConf(ta.value);
					}
					catch (e) {
						ui.addNotification(null, E('p', {}, e.message), 'error');
						return;
					}
					applyConf(iface, conf);
					return uci.save().then(() => {
						ui.hideModal();
						window.location.reload();
					});
				}) }, _('Import'))
			])
		]);
	},

	render: function() {
		const iface = common.tunnelIface();
		const exists = !!uci.get('network', iface);

		const mn = new form.Map('network', _('Tunnel'),
			_('AmneziaWG interface %s. Settings are stored in the standard network configuration and are also visible in Network → Interfaces.').format(iface));

		let s, o;
		if (exists) {
			s = mn.section(form.NamedSection, iface, 'interface', _('Interface'));
			s.addremove = false;
			s.tab('general', _('General'));
			s.tab('obfs', _('Obfuscation'));

			o = s.taboption('general', form.Value, 'private_key', _('Private key'));
			o.password = true;
			o.rmempty = false;
			o = s.taboption('general', form.DynamicList, 'addresses', _('Tunnel address'));
			o.datatype = 'cidr';
			o = s.taboption('general', form.Value, 'mtu', _('MTU'));
			o.datatype = 'range(1280,1500)';
			o.placeholder = '1380';
			o = s.taboption('general', form.Value, 'listen_port', _('Listen port'), _('Not needed: the router connects to the Truba itself.'));
			o.datatype = 'port';
			o.optional = true;

			for (let k of [ 'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4' ]) {
				o = s.taboption('obfs', form.Value, 'awg_' + k, k.toUpperCase());
				o.datatype = 'uinteger';
				o.optional = true;
				if (k[0] == 's')
					o.validate = function(sid, v) {
						const hpk = this.section.formvalue(sid, 'awg_header_protection_key');
						return (hpk && v !== '' && +v < 12) ? _('With header protection S1–S4 must be at least 12') : true;
					};
			}
			for (let k of [ 'h1', 'h2', 'h3', 'h4' ]) {
				o = s.taboption('obfs', form.Value, 'awg_' + k, k.toUpperCase(), k == 'h1' ? _('A number or a range «from-to»; must match the Truba.') : null);
				o.optional = true;
			}
			for (let k of [ 'i1', 'i2', 'i3', 'i4', 'i5' ]) {
				o = s.taboption('obfs', form.Value, 'awg_' + k, k.toUpperCase(), k == 'i1' ? _('Decoy packets before the handshake (CPS format); may differ from the Truba.') : null);
				o.optional = true;
			}

			// AmneziaWG 3.1. Ключ и флаги приходят импортом router.conf; здесь — видеть и переключать.
			o = s.taboption('obfs', form.Value, 'awg_header_protection_key', _('Header protection key'),
				_('AmneziaWG 3.1: encrypts the header fields WireGuard is recognised by. Must match the Truba and needs S1–S4 of at least 12; comes with router.conf.'));
			o.password = true;
			o.optional = true;
			o = s.taboption('obfs', form.Flag, 'awg_disable_cookies', _('Disable cookies'),
				_('AmneziaWG 3.1: no cookie replies under load. Not needed with a single peer, and their size is recognisable.'));
			o = s.taboption('obfs', form.Flag, 'awg_random_trailers', _('Random trailers'),
				_('AmneziaWG 3.1, in reserve against DPI by packet sizes: pads packets to a random length, costly in traffic for small packets. Must match the Truba: on the VPS run «install-vps.sh random-trailers on» or «off» at the same time.'));

			s = mn.section(form.TypedSection, 'amneziawg_' + iface, _('Truba (peer)'));
			s.anonymous = true;
			s.addremove = false;
			o = s.option(form.Value, 'public_key', _('Truba public key'));
			o.rmempty = false;
			o = s.option(form.Value, 'preshared_key', _('Preshared key'));
			o.password = true;
			o.optional = true;
			o = s.option(form.Value, 'endpoint_host', _('Truba address'));
			o.datatype = 'host';
			o = s.option(form.Value, 'endpoint_port', _('Truba port'));
			o.datatype = 'port';
			o = s.option(form.Value, 'persistent_keepalive', _('Keepalive, s'),
				_('Keeps the provider NAT mapping open so inbound connections via the Truba IP reach the router.'));
			o.datatype = 'range(0,65535)';
			o.placeholder = '25';
		}

		const mt = new form.Map('truba');
		s = mt.section(form.NamedSection, 'watchdog', 'watchdog', _('Tunnel watchdog'),
			_('Pings the Truba inside the tunnel and checks the handshake age; restarts the interface after repeated failures. While the tunnel is down, the emergency block (Routing tab) applies.'));
		s.addremove = false;
		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.Value, 'interval', _('Check interval, s'));
		o.datatype = 'range(10,600)';
		o.placeholder = '30';
		o = s.option(form.Value, 'handshake_max', _('Max handshake age, s'));
		o.datatype = 'range(60,3600)';
		o.placeholder = '180';
		o = s.option(form.Value, 'fails', _('Failures before restart'));
		o.datatype = 'range(1,20)';
		o.placeholder = '3';
		o = s.option(form.Value, 'probe', _('Ping target'),
			_('Empty — the Truba address inside the tunnel. An internet address would not answer while the emergency block is active.'));
		o.datatype = 'ip4addr';
		o.optional = true;

		return Promise.all([ mn.render(), mt.render() ]).then((els) => E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, exists
					? _('To replace keys and parameters, import a new configuration.')
					: E('strong', {}, _('The tunnel is not configured yet. Run install-vps.sh on the VPS and import the resulting router.conf.'))),
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'handleImport', iface) },
					_('Import .conf'))
			]),
			els[0], els[1]
		]));
	}
});
