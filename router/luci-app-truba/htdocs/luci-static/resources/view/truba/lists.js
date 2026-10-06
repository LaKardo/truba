'use strict';
'require view';
'require form';
'require poll';
'require ui';
'require truba.common as common';

function versionRow(name, cur, prev) {
	const fmt = (v) => v ? E('span', {}, [
		E('code', {}, (v.sha256 || '').substring(0, 12)), ' · ', common.fmtTime(v.mtime), ' · ', common.fmtBytes(v.size)
	]) : E('em', {}, _('none'));
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td' }, E('strong', {}, name)),
		E('td', { 'class': 'td' }, fmt(cur)),
		E('td', { 'class': 'td' }, fmt(prev))
	]);
}

function renderVersions(st) {
	const l = st.lists || {};
	const last = l.last;
	const res = [];
	if (l.updating)
		res.push(E('p', {}, E('em', { 'class': 'spinning' }, _('Update in progress…'))));
	res.push(E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('File')),
			E('th', { 'class': 'th' }, _('Current version')),
			E('th', { 'class': 'th' }, _('Previous version'))
		]),
		versionRow('geoip.dat', l.geoip, l.prev_geoip),
		versionRow('geosite.dat', l.geosite, l.prev_geosite)
	]));
	if (last) {
		const parts = [];
		for (let k of [ 'geoip', 'geosite' ]) {
			const r = last.sets && last.sets[k];
			if (!r)
				continue;
			parts.push(E('li', {}, r.ok
				? _('%s: %s (via %s)').format(k, r.changed ? _('updated') : _('no changes'), r.via)
				: _('%s: failed — %s').format(k, (r.errors || []).join('; '))));
		}
		res.push(E('p', {}, _('Last check: %s').format(common.fmtTime(last.time))));
		res.push(E('ul', {}, parts));
	}
	return E('div', {}, res);
}

return view.extend({
	load: function() {
		return common.callStatus();
	},

	render: function(st) {
		const box = E('div', {}, renderVersions(st));

		const m = new form.Map('truba', _('Lists'),
			_('geoip.dat and geosite.dat from kirilllavrov/geoip-builder and kirilllavrov/geosite-builder. Files are used unchanged; the checksum is verified before every replacement.'));

		const s = m.section(form.NamedSection, 'lists', 'lists', _('Sources and schedule'));
		s.addremove = false;

		let o = s.option(form.Value, 'geoip_url', _('geoip.dat'));
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

		poll.add(() => common.callStatus().then((st) => box.replaceChildren(renderVersions(st))), 5);

		return m.render().then((mapEl) => E('div', {}, [
			mapEl,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Versions')),
				box,
				E('div', { 'style': 'display:flex;gap:.5em' }, [
					E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () =>
						common.callUpdateLists(false).then(() => ui.addNotification(null, E('p', {}, _('Update started.')), 'info'))) },
						_('Update now')),
					E('button', { 'class': 'btn cbi-button-reset', 'click': ui.createHandlerFn(this, () => {
						if (!confirm(_('Swap current and previous rule sets?')))
							return;
						return common.callRollbackLists().then((r) => ui.addNotification(null,
							E('p', {}, (r.swapped || []).length ? _('Rolled back: %s').format(r.swapped.join(', ')) : _('No previous version.')), 'info'));
					}) }, _('Roll back'))
				])
			])
		]));
	}
});
