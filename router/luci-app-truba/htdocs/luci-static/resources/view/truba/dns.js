'use strict';
'require view';
'require form';
'require poll';
'require uci';
'require truba.common as common';

// «DNS»: состояние mosdns и кэша, настройки DNS. Наборы правил — на «Правилах».
// Состояние строится один раз и обновляется на месте — опрос не перерисовывает его.

const NBSP = common.NBSP;

// Адрес DNS-сервера — та же проверка, что у службы (common.upstreamError).
function validateUpstream(sid, v) {
	return common.upstreamError(v) ?? true;
}

// ---- Состояние DNS: mosdns и кэш ----

function buildDnsState() {
	const r = {};
	r.state = common.span('truba-badge');
	r.hits = common.span('truba-num');
	r.fillBar = E('span');
	r.fill = common.span('truba-num');
	r.since = common.span();
	r.el = E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('DNS state'), ' ', r.state ]),
		common.kvTable([
			[ _('Answers from cache'), r.hits ],
			[ _('Cache filled'), [ E('span', { 'class': 'truba-meter' }, r.fillBar), r.fill ] ],
			[ _('Counted'), r.since ]
		])
	]);
	return r;
}

function updateDnsState(r, st) {
	const dc = st.dns_cache;
	common.setState(r.state, !st.routing ? '' : st.mosdns ? 'ok' : 'err',
		!st.routing ? _('not used: routing is off') : st.mosdns ? _('mosdns running') : _('mosdns not running'));
	if (st.routing && dc) {
		const pct = (n) => dc.query ? Math.round(n * 100 / dc.query) : 0;
		common.setText(r.hits, dc.query ? _('%d%% from cache · %d%% expired').format(pct(dc.hit), pct(dc.lazy_hit)) : _('no queries yet'));
		const fill = dc.max ? Math.min(100, Math.round(dc.size * 100 / dc.max)) : 0;
		r.fillBar.style.width = fill + '%';
		common.setText(r.fill, _('%s of %s entries').format(common.fmtNum(dc.size), common.fmtNum(dc.max)));
		common.setText(r.since, _('since mosdns started'));
	}
	else {
		common.setText(r.hits, st.routing ? _('no data') : '—');
		r.fillBar.style.width = '0';
		common.setText(r.fill, '—');
		common.setText(r.since, NBSP);
	}
}

return view.extend({
	load: function() {
		return Promise.all([ common.callStatus(), uci.load('truba'), common.loadSchema() ]);
	},

	render: function(data) {
		const dnsState = buildDnsState();
		updateDnsState(dnsState, data[0] || {});

		const m = new form.Map('truba');

		let s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'));
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		let o = s.taboption('general', form.DynamicList, 'tunnel_upstream', _('For «Tunnel»'),
			_('Used for categories with action Tunnel and, in mode «All via tunnel», for everything else. Requests go through the tunnel, each one to all servers at once. udp://10.77.77.1 is the DNS server on the Truba itself (install-vps.sh). Formats: https://…, tls://…, tls+pipeline://… (several requests in one connection), udp://…; «address@IP» sets the IP to connect to.'));
		common.field(o, 'dns', 'tunnel_upstream');
		o.validate = validateUpstream;

		o = s.taboption('general', form.DynamicList, 'direct_upstream', _('For «Direct»'),
			_('Used for categories with action Direct, for the router\'s own hosts (NTP, list mirrors) and, in mode «Selective», for everything else.'));
		common.field(o, 'dns', 'direct_upstream');
		o.validate = validateUpstream;

		// Перехват хранится в секции main, но по смыслу — здесь.
		o = s.taboption('general', form.Flag, 'dns_hijack', _('Intercept DNS (port 53)'),
			_('IPv4 DNS requests of devices to any server are redirected to the router, so domain categories work for them too. Encrypted DNS in browsers (DoH) is not affected.'));
		o.ucisection = 'main';
		common.field(o, 'main', 'dns_hijack');
		o.rmempty = false;

		// Подсказки и пределы числовых полей — из схемы службы (ADR 0015).
		o = s.taboption('general', form.Value, 'cache_size', _('Cache size, entries'));
		common.field(o, 'dns', 'cache_size');

		o = s.taboption('general', form.Value, 'lazy_cache_ttl', _('Keep expired answers, s'),
			_('An expired answer is returned at once and refreshed in the background, so familiar sites open without waiting for DNS. 0 — off.'));
		common.field(o, 'dns', 'lazy_cache_ttl');

		o = s.taboption('general', form.Value, 'ttl_max', _('Maximum TTL, s'),
			_('Upper limit for answers of classified domains, so devices re-resolve quickly after the rules change.'));
		common.field(o, 'dns', 'ttl_max');

		o = s.taboption('advanced', form.Value, 'set_timeout', _('Keep DNS addresses in routing sets, s'),
			_('IPs from answers for categories with action Tunnel or Direct stay in the routing sets this long after they were added; a later answer adds them again. A CDN address the domain no longer uses stops steering traffic at the latest after this time. 0 — keep until the rules or lists change.'));
		common.field(o, 'dns', 'set_timeout');

		o = s.taboption('advanced', form.Value, 'port', _('mosdns port'),
			_('Local port; dnsmasq forwards requests here. The next port is taken by the mosdns statistics API (127.0.0.1 only).'));
		common.field(o, 'dns', 'port');

		// Кэш DNS меняется постоянно — раз в 10 с.
		poll.add(() => common.callStatus().then((st) => updateDnsState(dnsState, st)), 10);

		// Заголовок страницы — свой, а не формы: после «Сохранить» LuCI перерисовывает форму,
		// а состояние DNS — не её часть.
		return m.render().then((mapEl) => E('div', {}, [
			E('h2', { 'name': 'content' }, _('DNS')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Router DNS goes through mosdns: it recognises geosite categories, picks the upstream and puts resolved IPs into the routing sets.')),
			dnsState.el,
			mapEl
		]));
	}
});
