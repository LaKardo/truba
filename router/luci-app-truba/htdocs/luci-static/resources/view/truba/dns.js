'use strict';
'require view';
'require form';
'require poll';
'require ui';
'require truba.common as common';

// «DNS и списки»: две подвкладки одной формы. Версии Наборов правил строятся один раз
// и обновляются на месте — опрос не перерисовывает таблицу.

const NBSP = String.fromCharCode(160);   // неразрывный пробел

function buildVersions() {
	const r = { files: {} };
	r.busy = E('div', { 'class': 'truba-line' }, NBSP);
	const cell = () => {
		const sha = E('code', {}, NBSP), date = E('div', { 'class': 'truba-num' }, NBSP), size = E('div', { 'class': 'truba-muted truba-num' }, NBSP);
		return { sha, date, size, el: E('td', {}, [ sha, date, size ]) };
	};
	const row = (k, name) => {
		r.files[k] = { cur: cell(), prev: cell(), check: E('td', {}, NBSP) };
		return E('tr', {}, [ E('td', {}, E('strong', {}, name)), r.files[k].cur.el, r.files[k].prev.el, r.files[k].check ]);
	};
	r.last = E('p', { 'class': 'truba-muted' }, NBSP);
	r.el = E('div', {}, [
		E('h3', {}, _('Versions')),
		r.busy,
		E('table', { 'class': 'truba-traffic truba-versions' }, [
			E('tr', {}, [
				E('th', {}, _('File')), E('th', {}, _('Current version')),
				E('th', {}, _('Previous version')), E('th', {}, _('Last check'))
			]),
			row('geoip', 'geoip.dat'),
			row('geosite', 'geosite.dat')
		]),
		r.last
	]);
	return r;
}

function updateVersions(r, st) {
	const l = st.lists || {}, last = l.last;
	if (r.updating !== !!l.updating) {
		r.updating = !!l.updating;
		r.busy.replaceChildren(r.updating ? E('em', { 'class': 'spinning' }, _('Update in progress…')) : NBSP);
	}
	// Нет версии — «отсутствует» обычным текстом, а не моноширинным, как контрольная сумма.
	const ver = (c, v) => {
		c.sha.style.display = v ? '' : 'none';
		common.setText(c.sha, v ? (v.sha256 || '').substring(0, 12) : '');
		common.setText(c.date, v ? common.fmtTime(v.mtime) : _('none'));
		common.setText(c.size, v ? common.fmtBytes(v.size) : NBSP);
	};
	for (let k of [ 'geoip', 'geosite' ]) {
		ver(r.files[k].cur, l[k]);
		ver(r.files[k].prev, l['prev_' + k]);
		const s = last?.sets?.[k];
		common.setText(r.files[k].check, !s ? '—' : s.ok
			? _('%s (via %s)').format(s.changed ? _('updated') : _('no changes'), s.via)
			: _('failed — %s').format((s.errors || []).join('; ')));
	}
	common.setText(r.last, last ? _('Last check: %s').format(common.fmtTime(last.time)) : _('not checked yet'));
}

return view.extend({
	load: function() {
		return common.callStatus();
	},

	render: function(st) {
		const versions = buildVersions();
		updateVersions(versions, st);

		const m = new form.Map('truba', _('DNS & lists'),
			_('Router DNS goes through mosdns: it recognises geosite categories, picks the upstream and puts resolved IPs into the routing sets.'));
		m.tabbed = true;

		let s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'));
		s.addremove = false;

		let o = s.option(form.DynamicList, 'tunnel_upstream', _('For «Tunnel»'),
			_('Used for categories with action Tunnel and, in mode «All via tunnel», for everything else. Requests go through the tunnel. Formats: https://…, tls://…, udp://…; «address@IP» sets the IP to connect to.'));
		o.default = [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ];

		o = s.option(form.DynamicList, 'direct_upstream', _('For «Direct»'),
			_('Used for categories with action Direct, for the router\'s own hosts (NTP, list mirrors) and, in mode «Selective», for everything else.'));
		o.default = [ 'tls://common.dot.dns.yandex.net@77.88.8.8' ];

		// Перехват хранится в секции main, но по смыслу — здесь.
		o = s.option(form.Flag, 'dns_hijack', _('Intercept DNS (port 53)'),
			_('IPv4 DNS requests of devices to any server are redirected to the router, so domain categories work for them too. Encrypted DNS in browsers (DoH) is not affected.'));
		o.ucisection = 'main';
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'ttl_max', _('Maximum TTL, s'),
			_('Upper limit for answers of classified domains, so devices re-resolve quickly after the rules change.'));
		o.datatype = 'range(30,86400)';
		o.placeholder = '300';

		o = s.option(form.Value, 'cache_size', _('Cache size, entries'));
		o.datatype = 'range(1024,1048576)';
		o.placeholder = '65536';

		o = s.option(form.Value, 'lazy_cache_ttl', _('Keep expired answers, s'),
			_('An expired answer is returned at once and refreshed in the background, so familiar sites open without waiting for DNS. 0 — off.'));
		o.datatype = 'range(0,604800)';
		o.placeholder = '86400';

		o = s.option(form.Value, 'port', _('mosdns port'),
			_('Local port; dnsmasq forwards requests here. The next port is taken by the mosdns statistics API (127.0.0.1 only).'));
		o.datatype = 'port';
		o.placeholder = '5335';

		s = m.section(form.NamedSection, 'lists', 'lists', _('Lists'),
			_('geoip.dat and geosite.dat from kirilllavrov/geoip-builder and kirilllavrov/geosite-builder. Files are used unchanged; the checksum is verified before every replacement.'));
		s.addremove = false;

		o = s.option(form.Value, 'geoip_url', _('geoip.dat'));
		o.datatype = 'string';
		o = s.option(form.Value, 'geoip_mirror', _('geoip.dat mirror'), _('Downloaded directly if the main source failed.'));
		o = s.option(form.Value, 'geosite_url', _('geosite.dat'));
		o = s.option(form.Value, 'geosite_mirror', _('geosite.dat mirror'));

		o = s.option(form.Flag, 'via_tunnel', _('Download via tunnel'),
			_('The main source is fetched through the tunnel; the mirror always goes direct.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'auto_update', _('Update automatically'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'update_utc', _('Update time (UTC)'),
			_('geoip.dat is published every three days around 10–11 UTC, geosite.dat irregularly, usually by 09 UTC; at 12:00 a new release is picked up the same day. Converted to the router time zone for cron.'));
		o.placeholder = '12:00';
		o.depends('auto_update', '1');
		o.validate = (sid, v) => (!v || /^([01]?\d|2[0-3]):[0-5]\d$/.test(v)) ? true : _('Format: HH:MM');

		// Версии и кнопки — частью подвкладки «Списки». Один и тот же узел: форма
		// после сохранения перерисовывается, а опрос продолжает обновлять его.
		o = s.option(form.DummyValue, '_versions');
		o.render = () => Promise.resolve(E('div', { 'class': 'cbi-value' }, [
			versions.el,
			E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap' }, [
				E('button', { 'class': 'btn cbi-button-action', 'type': 'button', 'click': ui.createHandlerFn(this, () =>
					common.callUpdateLists(false).then(() => ui.addNotification(null, E('p', {}, _('Update started.')), 'info'))) },
					_('Update now')),
				E('button', { 'class': 'btn cbi-button-reset', 'type': 'button', 'click': ui.createHandlerFn(this, () => {
					if (!confirm(_('Swap current and previous rule sets?')))
						return;
					return common.callRollbackLists().then((r) => ui.addNotification(null,
						E('p', {}, (r.swapped || []).length ? _('Rolled back: %s').format(r.swapped.join(', ')) : _('No previous version.')), 'info'));
				}) }, _('Roll back'))
			])
		]));

		poll.add(() => common.callStatus().then((st) => updateVersions(versions, st)), 5);

		return m.render();
	}
});
