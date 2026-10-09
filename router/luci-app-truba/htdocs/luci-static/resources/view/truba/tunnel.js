'use strict';
'require view';
'require form';
'require poll';
'require uci';
'require ui';
'require truba.common as common';

// ---- Состояние Туннеля: строки постоянны, опрос раз в 5 с меняет только значения ----

const SW = 200, SH = 50;
const span = common.span, setState = common.setState;

function buildState() {
	const r = {};
	r.state = span('truba-badge');
	r.hs = span('truba-dot');
	r.rtt = span('truba-dot truba-num');
	r.loss = span('truba-dot truba-num');
	r.big = span('truba-dot');
	r.wd = span();
	r.table = span();
	r.iface = span('truba-num');
	r.scale = span('truba-num');
	const svg = common.svgEl('svg', { 'viewBox': '0 0 %d %d'.format(SW, SH), 'preserveAspectRatio': 'none', 'aria-hidden': 'true' });
	r.spark = svg.appendChild(common.svgEl('path', { 'class': 'line tunnel' }));

	r.el = E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('State'), ' ', r.state ]),
		E('div', { 'class': 'truba-cards' }, [
			common.kvTable([
				[ _('Last handshake'), r.hs ],
				[ _('Latency to the Truba'), r.rtt ],
				[ _('Packet loss'), r.loss ],
				[ _('Full-size packets'), r.big ],
				[ _('Tunnel watchdog'), r.wd ],
				[ _('Tunnel route table'), r.table ],
				[ _('Interface traffic'), [ r.iface,
					E('div', { 'class': 'truba-muted' }, _('since the interface came up, including the router\'s own traffic')) ] ]
			]),
			E('div', {}, [
				E('div', { 'class': 'truba-legend' }, _('Latency over 10 min')),
				E('div', { 'class': 'truba-chart small' }, svg),
				E('div', { 'class': 'truba-chart-axis' }, [ E('span', {}, _('10 min ago')), r.scale, E('span', {}, _('now')) ]),
				E('p', { 'class': 'truba-muted' }, _('Points are the watchdog checks; a gap is a lost ping.'))
			])
		])
	]);
	return r;
}

// Мини-график задержки по окну проверок watchdog; null — потерянный ping, разрыв линии.
function drawSpark(r, probes) {
	const got = probes.filter((x) => x != null);
	if (!got.length) {
		r.spark.setAttribute('d', '');
		common.setText(r.scale, '');
		return;
	}
	let lo = Math.min(...got), hi = Math.max(...got);
	const pad = Math.max((hi - lo) * 0.2, 1);
	lo = Math.max(0, lo - pad);
	hi += pad;
	const n = probes.length;
	const X = (i) => (n > 1 ? i * SW / (n - 1) : SW / 2).toFixed(1);
	const Y = (v) => (SH - (v - lo) / (hi - lo) * SH).toFixed(1);
	let d = '', pen = false;
	probes.forEach((v, i) => {
		if (v == null) {
			pen = false;
			return;
		}
		d += (pen ? 'L' : 'M') + X(i) + ',' + Y(v);
		pen = true;
	});
	r.spark.setAttribute('d', d);
	common.setText(r.scale, _('%d–%d ms').format(Math.round(lo), Math.round(hi)));
}

function updateState(r, st) {
	const t = st.tunnel || {}, awg = t.awg || {}, h = st.health || {};
	const wdOn = uci.get('truba', 'watchdog', 'enabled') != '0';
	const [ level, text ] = common.tunnelState(st);
	setState(r.state, level, text);

	const age = awg.handshake ? awg.handshake_age : null;
	setState(r.hs, age == null ? 'err' : age > 300 ? 'err' : age > 180 ? 'warn' : 'ok', common.fmtAge(age));

	// Окно пустое — проверок ещё не было (или не с чем: нет адреса для ping): не «нет ответа».
	const probes = Array.isArray(h.probes) ? h.probes : [];
	if (!wdOn || !probes.length || !t.up) {
		const why = !wdOn ? _('the watchdog is off') : '—';
		setState(r.rtt, '', why);
		setState(r.loss, '', why);
		setState(r.big, '', why);
		drawSpark(r, []);
	}
	else {
		const got = probes.filter((x) => x != null);
		const avg = got.length ? got.reduce((s, x) => s + x, 0) / got.length : null;
		setState(r.rtt, h.rtt != null ? 'ok' : 'err', h.rtt != null
			? _('%d ms').format(Math.round(h.rtt)) + (avg != null ? ' · ' + _('average %d ms').format(Math.round(avg)) : '')
			: _('no reply'));
		const lost = probes.length - got.length;
		const pct = Math.round(lost * 100 / probes.length);
		setState(r.loss, !lost ? 'ok' : pct < 20 ? 'warn' : 'err',
			_('%d%% over %d min').format(pct, Math.max(1, Math.round(probes.length * (h.interval || 30) / 60))));
		const b = h.big;
		if (!b)
			setState(r.big, '', _('not checked yet'));
		else
			setState(r.big, b.ok ? 'ok' : 'err', b.ok
				? _('get through · %d bytes, the whole MTU').format(b.size)
				: _('lost (%d of %d) · %d bytes: lower the MTU').format(b.sent - b.received, b.sent, b.size));
		drawSpark(r, probes);
	}

	common.setText(r.wd, h.state
		? '%s %s'.format(h.state == 'healthy' ? _('healthy since') : _('down since'), common.fmtTime(h.since))
		: _('no data'));
	const table = (st.table || '').trim();
	common.setText(r.table, !st.service ? _('service stopped')
		: /blackhole/.test(table) ? _('emergency block (tunnel traffic is dropped)')
		: /default dev/.test(table) ? _('via tunnel')
		: _('fallback to direct (no tunnel route)'));
	common.setText(r.iface, awg.rx != null ? '↓ %s · ↑ %s'.format(common.fmtBytes(awg.rx), common.fmtBytes(awg.tx)) : '—');
}

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
		const line = raw.trim();
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
		if (!nets.includes(iface))
			uci.set('firewall', zone['.name'], 'network', nets.concat([ iface ]));
	}
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('truba'), uci.load('network'), uci.load('firewall'), common.callStatus() ]);
	},

	handleImport: function(iface) {
		const ta = E('textarea', {
			'class': 'cbi-input-textarea truba-conf', 'rows': 16,
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

	render: function(data) {
		const iface = common.tunnelIface();
		const exists = !!uci.get('network', iface);
		const state = buildState();
		updateState(state, data[3] || {});
		poll.add(() => common.callStatus().then((st) => updateState(state, st)), 5);

		const mn = new form.Map('network');

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
			o = s.taboption('general', form.Value, 'mtu', _('MTU'),
				_('install-vps.sh picks it for the VPS network. If full-size packets do not get through (see State above), lower it on both sides.'));
			// install-vps.sh подбирает MTU под сеть VPS: при сети уже 1367 он ниже 1280.
			o.datatype = 'range(576,1500)';
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
			_('Pings the Truba inside the tunnel and checks the handshake age; restarts the interface after repeated failures. Every 5 minutes it also checks that full-size packets get through.'));
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
		// Что делать, пока Туннель не отвечает, — рядом с тем, как это определяется;
		// хранится в секции main.
		o = s.option(form.Flag, 'killswitch', _('Emergency block'),
			_('While the tunnel is down, traffic with action Tunnel is dropped instead of going direct.'));
		o.ucisection = 'main';
		o.default = '1';
		o.rmempty = false;

		const importBlock = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Connection')),
			E('div', { 'class': 'truba-toolbar' }, [
				E('span', { 'class': 'truba-grow' }, exists
					? _('Keys and parameters come from router.conf made by install-vps.sh on the VPS. To replace them, import a new file.')
					: E('strong', {}, _('The tunnel is not configured yet. Run install-vps.sh on the VPS and import the resulting router.conf.'))),
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'handleImport', iface) },
					_('Import .conf'))
			])
		]);
		// Заголовок страницы — свой, а не формы: после «Сохранить» LuCI перерисовывает форму
		// целиком, и вставленное в неё состояние пропало бы.
		return Promise.all([ mn.render(), mt.render() ]).then((els) => E('div', {}, [
			E('h2', { 'name': 'content' }, _('Tunnel')),
			E('div', { 'class': 'cbi-map-descr' },
				_('AmneziaWG interface %s. Settings are stored in the standard network configuration and are also visible in Network → Interfaces.').format(iface)),
			state.el,
			importBlock,
			els[0], els[1]
		]));
	}
});
