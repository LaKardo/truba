'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		const m = new form.Map('truba', _('DNS'),
			_('Router DNS goes through mosdns: it recognises geosite categories, picks the upstream and puts resolved IPs into the routing sets.'));

		let s = m.section(form.NamedSection, 'dns', 'dns', _('Upstream servers'));
		s.addremove = false;

		let o = s.option(form.DynamicList, 'tunnel_upstream', _('For «Tunnel»'),
			_('Used for categories with action Tunnel and, in mode «All via tunnel», for everything else. Requests go through the tunnel. Formats: https://…, tls://…, udp://…; «address@IP» sets the IP to connect to.'));
		o.default = [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ];

		o = s.option(form.DynamicList, 'direct_upstream', _('For «Direct»'),
			_('Used for categories with action Direct, for the router\'s own hosts (NTP, list mirrors) and, in mode «Selective», for everything else.'));
		o.default = [ 'tls://common.dot.dns.yandex.net@77.88.8.8' ];

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

		o = s.option(form.Value, 'port', _('mosdns port'), _('Local port; dnsmasq forwards requests here.'));
		o.datatype = 'port';
		o.placeholder = '5335';

		s = m.section(form.NamedSection, 'main', 'main', _('Interception'));
		s.addremove = false;
		o = s.option(form.Flag, 'dns_hijack', _('Intercept DNS (port 53)'),
			_('IPv4 DNS requests of devices to any server are redirected to the router, so domain categories work for them too. Encrypted DNS in browsers (DoH) is not affected.'));
		o.default = '1';
		o.rmempty = false;

		return m.render();
	}
});
