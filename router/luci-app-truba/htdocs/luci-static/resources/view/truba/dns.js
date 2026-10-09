'use strict';
'require view';
'require form';
'require poll';
'require uci';
'require ui';
'require truba.common as common';

// «DNS и списки» — одна страница: состояние DNS, настройки DNS и Наборы правил с версиями.
// Состояние и версии строятся один раз и обновляются на месте — опрос не перерисовывает их.

const NBSP = common.NBSP;
// Версии меняются раз в сутки: опрос раз в 30 с, а пока идёт обновление — раз в 5 с.
const SLOW_POLL = 30000;

// Адрес DNS-сервера в том виде, что понимает mosdns 5 (та же проверка — upstream_ok в conf.uc):
// с опечаткой в схеме mosdns не запустился бы, а с ним пропал бы DNS всей сети.
const UPSTREAM_RE = /^(([a-z0-9+]+):\/\/)?(\[[0-9a-fA-F:.]+\]|[^\]\[\s\/@:]+)(:\d+)?(\/[^\s@]*)?(@[0-9.]+)?$/;
const UPSTREAM_SCHEMES = [ 'udp', 'tcp', 'tcp+pipeline', 'tls', 'tls+pipeline', 'https', 'h3', 'quic', 'doq' ];

function validateUpstream(sid, v) {
	if (!v)
		return true;
	const m = UPSTREAM_RE.exec(v);
	const ok = m && (m[2] == null ? m[5] == null : UPSTREAM_SCHEMES.indexOf(m[2]) >= 0);
	return ok ? true : _('Expected https://…, tls://…, quic://…, h3://…, tcp://… or udp://… (optionally «@IP»)');
}

// ---- Состояние DNS: mosdns и кэш ----

function buildDnsState() {
	const r = {};
	const span = (cls) => E('span', cls ? { 'class': cls } : {});
	r.state = span('truba-badge');
	r.hits = span('truba-num');
	r.fillBar = E('span');
	r.fill = span('truba-num');
	r.since = span();
	const row = (label, value) => E('tr', {}, [ E('th', { 'scope': 'row' }, label), E('td', {}, value) ]);
	r.el = E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('DNS state'), ' ', r.state ]),
		E('table', { 'class': 'truba-kv' }, [
			row(_('Answers from cache'), r.hits),
			row(_('Cache filled'), [ E('span', { 'class': 'truba-meter' }, r.fillBar), r.fill ]),
			row(_('Counted'), r.since)
		])
	]);
	return r;
}

function updateDnsState(r, st) {
	const dc = st.dns_cache;
	if (!st.routing)
		common.setLevel(r.state, '');
	else
		common.setLevel(r.state, st.mosdns ? 'ok' : 'err');
	common.setText(r.state, !st.routing ? _('not used: routing is off') : st.mosdns ? _('mosdns running') : _('mosdns not running'));
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

// ---- Версии Наборов правил ----

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
	r.last = E('span', { 'class': 'truba-muted' }, NBSP);
	r.next = E('span', { 'class': 'truba-muted' }, NBSP);
	r.el = E('div', {}, [
		r.busy,
		E('table', { 'class': 'truba-grid truba-versions' }, [
			E('tr', {}, [
				E('th', {}, _('File')), E('th', {}, _('Current version')),
				E('th', {}, _('Previous version')), E('th', {}, _('Last check'))
			]),
			row('geoip', 'geoip.dat'),
			row('geosite', 'geosite.dat')
		]),
		E('p', {}, [ r.last, ' · ', r.next ])
	]);
	return r;
}

function updateVersions(r, l) {
	l = l || {};
	const last = l.last;
	// Применение идёт и после отката, и после обновления списков — в фоне.
	const busy = l.updating ? 'updating' : l.applying ? 'applying' : '';
	if (r.busyState !== busy) {
		r.busyState = busy;
		r.updating = !!busy;
		r.busy.replaceChildren(busy == 'updating' ? common.busy(_('Update in progress…'))
			: busy == 'applying' ? common.busy(_('Applying settings…')) : NBSP);
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
		common.setText(r.files[k].check, common.setResult(last?.sets?.[k]));
	}
	common.setText(r.last, last ? _('Last check: %s').format(common.fmtTime(last.time)) : _('not checked yet'));
}

// Следующая проверка — по строке cron Роутера, она приходит в status.
function updateNext(r, st) {
	common.setText(r.next, !st.routing ? NBSP
		: uci.get('truba', 'lists', 'auto_update') == '0' ? _('automatic update is off')
		: _('Next check: %s').format(common.fmtTime(st.lists?.next)));
}

return view.extend({
	load: function() {
		return Promise.all([ common.callLists(), common.callStatus(), uci.load('truba') ]);
	},

	render: function(data) {
		const versions = buildVersions();
		const dnsState = buildDnsState();
		updateVersions(versions, data[0]);
		updateDnsState(dnsState, data[1] || {});
		updateNext(versions, data[1] || {});

		const m = new form.Map('truba');

		let s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'));
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('advanced', _('Advanced'));

		let o = s.taboption('general', form.DynamicList, 'tunnel_upstream', _('For «Tunnel»'),
			_('Used for categories with action Tunnel and, in mode «All via tunnel», for everything else. Requests go through the tunnel. Formats: https://…, tls://…, udp://…; «address@IP» sets the IP to connect to.'));
		o.default = [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ];
		o.validate = validateUpstream;

		o = s.taboption('general', form.DynamicList, 'direct_upstream', _('For «Direct»'),
			_('Used for categories with action Direct, for the router\'s own hosts (NTP, list mirrors) and, in mode «Selective», for everything else.'));
		o.default = [ 'tls://common.dot.dns.yandex.net@77.88.8.8', 'tls://common.dot.dns.yandex.net@77.88.8.1' ];
		o.validate = validateUpstream;

		// Перехват хранится в секции main, но по смыслу — здесь.
		o = s.taboption('general', form.Flag, 'dns_hijack', _('Intercept DNS (port 53)'),
			_('IPv4 DNS requests of devices to any server are redirected to the router, so domain categories work for them too. Encrypted DNS in browsers (DoH) is not affected.'));
		o.ucisection = 'main';
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'cache_size', _('Cache size, entries'));
		o.datatype = 'range(1024,1048576)';
		o.placeholder = '65536';

		o = s.taboption('general', form.Value, 'lazy_cache_ttl', _('Keep expired answers, s'),
			_('An expired answer is returned at once and refreshed in the background, so familiar sites open without waiting for DNS. 0 — off.'));
		o.datatype = 'range(0,604800)';
		o.placeholder = '86400';

		o = s.taboption('general', form.Value, 'ttl_max', _('Maximum TTL, s'),
			_('Upper limit for answers of classified domains, so devices re-resolve quickly after the rules change.'));
		o.datatype = 'range(30,86400)';
		o.placeholder = '300';

		o = s.taboption('advanced', form.Value, 'port', _('mosdns port'),
			_('Local port; dnsmasq forwards requests here. The next port is taken by the mosdns statistics API (127.0.0.1 only).'));
		o.datatype = 'port';
		o.placeholder = '5335';

		s = m.section(form.NamedSection, 'lists', 'lists', _('Rule sets'),
			_('geoip.dat and geosite.dat from kirilllavrov/geoip-builder and kirilllavrov/geosite-builder. Files are used unchanged; the checksum is verified before every replacement.'));
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('sources', _('Sources'));

		// Версии и кнопки — первыми в Наборах правил. Один и тот же узел: форма после
		// сохранения перерисовывается, а опрос продолжает обновлять его.
		o = s.taboption('general', form.DummyValue, '_versions');
		// data-field — как у обычных полей: иначе форма считает поле скрытым и при каждой
		// проверке зависимостей «включает» его заново.
		o.render = () => Promise.resolve(E('div', { 'class': 'cbi-value', 'data-field': o.cbid('lists') }, [
			versions.el,
			E('div', { 'class': 'truba-toolbar' }, [
				E('button', { 'class': 'btn cbi-button-action', 'type': 'button', 'click': ui.createHandlerFn(this, () =>
					common.callUpdateLists(false).then(() => {
						versions.kicked = Date.now();   // опрос раз в 5 с, пока обновление не начнётся
						ui.addNotification(null, E('p', {}, _('Update started.')), 'info');
					})) },
					_('Update now')),
				E('button', { 'class': 'btn cbi-button-reset', 'type': 'button', 'click': ui.createHandlerFn(this, () => {
					if (!confirm(_('Swap current and previous rule sets?')))
						return;
					// Файлы переставляются сразу, применение — в фоне; его ход видно над таблицей.
					return common.callRollbackLists().then((r) => {
						versions.kicked = Date.now();
						ui.addNotification(null, E('p', {}, r.error == 'busy' ? _('Rule sets are being updated, try again later.')
							: (r.swapped || []).length ? _('Rolled back: %s').format(r.swapped.join(', ')) : _('No previous version.')), 'info');
					});
				}) }, _('Roll back'))
			])
		]));

		o = s.taboption('general', form.Flag, 'auto_update', _('Update automatically'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'update_utc', _('Update time (UTC)'),
			_('geoip.dat is published every three days around 10–11 UTC, geosite.dat irregularly, usually by 09 UTC; at 12:00 a new release is picked up the same day. Converted to the router time zone for cron.'));
		o.placeholder = '12:00';
		o.depends('auto_update', '1');
		o.validate = (sid, v) => (!v || /^([01]?\d|2[0-3]):[0-5]\d$/.test(v)) ? true : _('Format: HH:MM');

		o = s.taboption('general', form.Flag, 'via_tunnel', _('Download via tunnel'),
			_('The main source is fetched through the tunnel; the mirror always goes direct.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('sources', form.Value, 'geoip_url', _('geoip.dat'));
		o.datatype = 'string';
		o = s.taboption('sources', form.Value, 'geoip_mirror', _('geoip.dat mirror'), _('Downloaded directly if the main source failed.'));
		o = s.taboption('sources', form.Value, 'geosite_url', _('geosite.dat'));
		o = s.taboption('sources', form.Value, 'geosite_mirror', _('geosite.dat mirror'));

		let polled = Date.now();
		poll.add(() => {
			const fast = versions.updating || Date.now() - (versions.kicked || 0) < 15000;
			if (!fast && Date.now() - polled < SLOW_POLL)
				return Promise.resolve();
			polled = Date.now();
			return common.callLists().then((l) => updateVersions(versions, l));
		}, 5);
		// Кэш DNS меняется постоянно — раз в 10 с, как и время следующей проверки.
		poll.add(() => common.callStatus().then((st) => {
			updateDnsState(dnsState, st);
			updateNext(versions, st);
		}), 10);

		// Заголовок страницы — свой, а не формы: после «Сохранить» LuCI перерисовывает форму,
		// а состояние DNS — не её часть.
		return m.render().then((mapEl) => E('div', {}, [
			E('h2', { 'name': 'content' }, _('DNS & lists')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Router DNS goes through mosdns: it recognises geosite categories, picks the upstream and puts resolved IPs into the routing sets.')),
			dnsState.el,
			mapEl
		]));
	}
});
