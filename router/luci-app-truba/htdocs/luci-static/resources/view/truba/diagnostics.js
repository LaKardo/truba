'use strict';
'require view';
'require ui';
'require truba.common as common';

function actionBadge(a) {
	return common.pill(common.ACTION_LEVELS[a] || '', common.ACTION_LABELS[a] || a);
}

function renderCheck(r) {
	if (!r || r.error || !r.action)
		return E('p', {}, _('Error: %s').format((r && r.error) || 'no answer'));

	const parts = [
		E('p', { 'class': 'truba-target' }, [ E('strong', {}, r.target), ' → ', actionBadge(r.action) ]),
		E('p', {}, _('Why: %s').format(common.REASON_LABELS[r.reason] || r.reason))
	];

	if (r.kind == 'domain') {
		const hits = r.geosite || [];
		parts.push(E('h4', {}, _('geosite categories containing the domain')));
		parts.push(hits.length ? E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Category')), E('th', { 'class': 'th' }, _('Matching entry')),
				E('th', { 'class': 'th' }, _('Entries')), E('th', { 'class': 'th' }, _('Action'))
			])
		].concat(hits.map((h) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, (r.decisive && r.decisive.tag == h.tag) ? E('strong', {}, h.tag + ' ✓') : h.tag),
			E('td', { 'class': 'td' }, E('code', {}, h.entry)),
			E('td', { 'class': 'td' }, common.fmtNum(h.count)),
			E('td', { 'class': 'td' }, common.ACTION_LABELS[h.action] || h.action)
		])))) : E('p', {}, common.empty(_('none'))));
		if (r.decisive)
			parts.push(E('p', {}, _('Decisive category (the narrowest one with an explicit action): %s').format(r.decisive.tag)));
	}

	const ips = r.ips || [];
	if (ips.length) {
		parts.push(E('h4', {}, _('Addresses')));
		parts.push(E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, 'IP'), E('th', { 'class': 'th' }, _('geoip categories')),
				E('th', { 'class': 'th' }, _('Action')), E('th', { 'class': 'th' }, _('Why'))
			])
		].concat(ips.map((v) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, v.ip),
			E('td', { 'class': 'td' }, (v.geoip || []).join(', ') || '—'),
			E('td', { 'class': 'td' }, actionBadge(v.action)),
			E('td', { 'class': 'td' }, (common.REASON_LABELS[v.reason] || v.reason) + (v.device ? ' (%s)'.format(v.device) : ''))
		])))));
	}
	return E('div', {}, parts);
}

return view.extend({
	load: function() {
		return common.callLeases().catch(() => ({}));
	},

	render: function(leasesData) {
		const leases = (leasesData && leasesData.dhcp_leases) || [];
		const input = E('input', { 'type': 'text', 'class': 'cbi-input-text truba-grow',
			'placeholder': _('domain or IPv4, e.g. gosuslugi.ru') });
		const dev = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, _('— any device —')) ].concat(
			leases.filter((l) => l.macaddr).map((l) => E('option', { 'value': l.macaddr }, '%s (%s)'.format(l.hostname || l.ipaddr || '?', l.macaddr)))));
		const out = E('div');
		const logBox = E('pre', { 'class': 'truba-log' });

		const runCheck = () => {
			const t = input.value.trim();
			if (!t)
				return;
			out.replaceChildren(common.busy(_('Checking…')));
			// Без устройства аргумент mac не передаётся вовсе: rpcd отклоняет null вместо строки.
			const call = dev.value ? common.callCheck(t, dev.value) : common.callCheck(t);
			return call.then((r) => out.replaceChildren(renderCheck(r)));
		};
		input.addEventListener('keydown', (ev) => { if (ev.key == 'Enter') runCheck(); });

		const loadLog = () => common.callLog(300).then((t) => { logBox.textContent = t || _('Log is empty.'); });
		loadLog();

		return E('div', {}, [
			E('h2', {}, _('Diagnostics')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Check domain / IP')),
				E('p', { 'class': 'cbi-section-descr' },
					_('Shows which category and action apply and why. A domain is resolved through the router, the same way a device would.')),
				E('div', { 'class': 'truba-toolbar' }, [
					input, dev,
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, runCheck) }, _('Check'))
				]),
				out
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Log: Truba and mosdns')),
				E('div', { 'class': 'truba-toolbar' }, E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, loadLog) }, _('Refresh'))),
				logBox
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
