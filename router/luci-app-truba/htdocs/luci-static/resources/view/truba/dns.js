'use strict';
'require view';
'require uci';
'require truba.common as common';
'require truba.ui.app as app';
'require truba.ui.kit as kit';

// «DNS»: состояние mosdns и кэша, серверы двух путей, перехват и кэш. Задержек серверов и
// гистограммы нет: mosdns их не отдаёт. Наборы правил — на «Правилах».
// Страница — компоненты Preact в Shadow DOM (ADR 0017).

const POLL = 10;   // кэш DNS меняется постоянно — раз в 10 с

// ---- Состояние ----

function StateCard({ st }) {
	const { html } = app.lib;
	const s = common.dnsStats(st);
	return html`<${kit.Card} cls="state" title=${_('State')} aside=${html`<${kit.Badge} level=${s.level}>${s.text}</${kit.Badge}>`}>
		<div class="stats">${s.tiles.map(([ label, value ]) => html`<${kit.Stat} label=${label} value=${value} />`)}</div>
		${s.note ? html`<p class="mu">${s.note}</p>` : ''}
	</${kit.Card}>`;
}

// ---- Серверы ----

// Серверы одного пути: запрос идёт ко всем сразу, ответ — первый годный (dns.uc, upstream_group).
function ServersCard({ cls, title, name, hint }) {
	const { html } = app.lib;
	return html`<${kit.Card} cls=${cls} title=${title} aside=${_('queried all at once')}>
		<${kit.UpstreamList} sec="dns" name=${name} label=${title} />
		<p class="mu">${hint}</p>
	</${kit.Card}>`;
}

// ---- Перехват и кэш ----

function SettingsCard() {
	const { html } = app.lib;
	return html`<${kit.Card} cls="dns-set" title=${_('Settings')}>
		<${kit.Switch} label=${_('Intercept DNS (port 53)')} opt="truba.main.dns_hijack" checked=${common.get('main', 'dns_hijack')}
			onChange=${(on) => app.set('truba', 'main', 'dns_hijack', on ? '1' : '0')} />
		<p class="mu">${_('IPv4 DNS requests of devices to any server are redirected to the router, so domain categories work for them too. Encrypted DNS in browsers (DoH) is not affected.')}</p>
		<${kit.Fold} title=${_('Cache')}>
			<div class="cols">
				<${kit.Field} sec="dns" name="cache_size" label=${_('Cache size, entries')} />
				<${kit.Field} sec="dns" name="lazy_cache_ttl" label=${_('Keep expired answers, s')}
					hint=${_('An expired answer is returned at once and refreshed in the background, so familiar sites open without waiting for DNS. 0 — off.')} />
				<${kit.Field} sec="dns" name="ttl_max" label=${_('Maximum TTL, s')}
					hint=${_('Upper limit for answers of classified domains, so devices re-resolve quickly after the rules change.')} />
			</div>
		</${kit.Fold}>
		<${kit.Fold} title=${_('Advanced')}>
			<div class="cols">
				<${kit.Field} sec="dns" name="set_timeout" label=${_('Keep DNS addresses in routing sets, s')}
					hint=${_('IPs from answers for categories with action Tunnel or Direct stay in the routing sets this long after they were added; a later answer adds them again. A CDN address the domain no longer uses stops steering traffic at the latest after this time. 0 — keep until the rules or lists change.')} />
				<${kit.Field} sec="dns" name="port" label=${_('mosdns port')}
					hint=${_('Local port; dnsmasq forwards requests here. The next port is taken by the mosdns statistics API (127.0.0.1 only).')} />
			</div>
		</${kit.Fold}>
	</${kit.Card}>`;
}

function Page({ store, view }) {
	const { html } = app.lib;
	const { status, offline } = app.use(store);
	app.use(app.changes);   // карточки читают UCI браузера — перерисовка после app.set
	return html`
		<${kit.PageHead} title=${_('DNS')} offline=${offline}
			text=${_('Router DNS goes through mosdns: it recognises geosite categories, picks the upstream and puts resolved IPs into the routing sets.')} />
		<div class="grid g2">
			<${StateCard} st=${status || {}} />
			<${ServersCard} cls="ups-tunnel" title=${_('Servers for «Tunnel»')} name="tunnel_upstream"
				hint=${_('Used for categories with action Tunnel and, in mode «All via tunnel», for everything else. Requests go through the tunnel, each one to all servers at once. udp://10.77.77.1 is the DNS server on the Truba itself (install-vps.sh). Formats: https://…, tls://…, tls+pipeline://… (several requests in one connection), quic://…, udp://…, tcp://…; without a scheme — udp; «address@IP» sets the IP to connect to.')} />
			<${ServersCard} cls="ups-direct" title=${_('Servers for «Direct»')} name="direct_upstream"
				hint=${_('Used for categories with action Direct, for the router\'s own hosts (NTP, list mirrors) and, in mode «Selective», for everything else.')} />
			<${SettingsCard} />
		</div>
		<${kit.ChangesBar} view=${view} />
		<${kit.Toast} />`;
}

return view.extend({
	...app.actions,

	load: function() {
		return Promise.all([ app.load(), common.loadSchema() ]).then(() => Promise.all([ common.callStatus().catch(() => null), uci.load('truba') ]));
	},

	render: function(data) {
		const store = app.store({ status: data[0], offline: data[0] == null });
		app.poll(store, () => common.callStatus().then((s) => ({ status: s })), POLL);
		return app.mount(this, Page, { store });
	}
});
