'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require tools.widgets as widgets';
'require truba.common as common';

const ACTIONS = [ 'mode', 'direct', 'tunnel', 'block' ];

function ruleSections(mode) {
	return uci.sections('truba', 'rule').filter((s) => (s.mode || 'all') == mode);
}

function currentAction(mode, set, tag) {
	const s = ruleSections(mode).find((r) => r.set == set && r.tag == tag);
	return s ? s.action : 'mode';
}

function setAction(mode, set, tag, action) {
	for (let s of ruleSections(mode))
		if (s.set == set && s.tag == tag)
			uci.remove('truba', s['.name']);
	if (action != 'mode') {
		const sid = uci.add('truba', 'rule');
		uci.set('truba', sid, 'mode', mode);
		uci.set('truba', sid, 'set', set);
		uci.set('truba', sid, 'tag', tag);
		uci.set('truba', sid, 'action', action);
	}
}

function typesText(c) {
	if (c.set == 'geoip')
		return 'IPv4 %d · IPv6 %d'.format(c.count4 || 0, c.count6 || 0);
	return Object.keys(c.types || {}).filter((k) => c.types[k]).map((k) => '%s %d'.format(k, c.types[k])).join(' · ');
}

function renderTable(mode, cats, filterBox) {
	const header = E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Rule set')),
		E('th', { 'class': 'th' }, _('Category')),
		E('th', { 'class': 'th' }, _('Entries')),
		E('th', { 'class': 'th' }, _('Types')),
		E('th', { 'class': 'th' }, _('Included in')),
		E('th', { 'class': 'th' }, _('Action'))
	]);
	const rows = cats.map((c) => {
		const sel = E('select', { 'class': 'cbi-input-select', 'change': (ev) => {
			setAction(mode, c.set, c.tag, ev.target.value);
			ev.target.closest('tr').setAttribute('data-action', ev.target.value);
		} }, ACTIONS.map((a) => E('option', { 'value': a }, common.ACTION_LABELS[a])));
		sel.value = currentAction(mode, c.set, c.tag);
		return E('tr', { 'class': 'tr', 'data-search': (c.set + ':' + c.tag).toLowerCase(), 'data-action': sel.value }, [
			E('td', { 'class': 'td' }, c.set),
			E('td', { 'class': 'td' }, E('strong', {}, c.tag)),
			E('td', { 'class': 'td' }, String(c.count)),
			E('td', { 'class': 'td' }, E('small', {}, typesText(c))),
			E('td', { 'class': 'td' }, E('small', {}, (c.subset_of || []).join(', ') || '—')),
			E('td', { 'class': 'td' }, sel)
		]);
	});
	const table = E('table', { 'class': 'table' }, [ header ].concat(rows));

	const apply = () => {
		const q = filterBox.text.value.trim().toLowerCase();
		const onlySet = filterBox.only.checked;
		for (let r of rows) {
			const hit = (!q || r.getAttribute('data-search').indexOf(q) >= 0) && (!onlySet || r.getAttribute('data-action') != 'mode');
			r.style.display = hit ? '' : 'none';
		}
	};
	filterBox.text.addEventListener('input', apply);
	filterBox.only.addEventListener('change', apply);
	return table;
}

return view.extend({
	load: function() {
		return Promise.all([ common.callCategories(), uci.load('truba'), uci.load('firewall') ]);
	},

	handleReset: function(mode, starting) {
		if (!confirm(_('Reset all category actions of this mode to the starting settings?')))
			return;
		for (let s of ruleSections(mode))
			uci.remove('truba', s['.name']);
		for (let r of starting.filter((x) => x.mode == mode)) {
			const sid = uci.add('truba', 'rule');
			uci.set('truba', sid, 'mode', r.mode);
			uci.set('truba', sid, 'set', r.set);
			uci.set('truba', sid, 'tag', r.tag);
			uci.set('truba', sid, 'action', r.action);
		}
		return uci.save().then(() => window.location.reload());
	},

	render: function(data) {
		const info = data[0] || {};
		const cats = (info.cats || []).slice().sort((a, b) =>
			(a.set == b.set) ? (a.tag < b.tag ? -1 : 1) : (a.set == 'geoip' ? -1 : 1));
		const present = {};
		for (let c of cats)
			present[c.set + ':' + c.tag] = true;

		const m = new form.Map('truba', _('Routing'),
			_('Which traffic goes through the tunnel. Categories are taken from geoip.dat and geosite.dat as they are; new categories are never created.'));

		const s = m.section(form.NamedSection, 'main', 'main');
		s.addremove = false;

		let o = s.option(form.ListValue, 'mode', _('Mode'),
			_('What happens to traffic that no category with an explicit action matched.'));
		o.value('all', _('All via tunnel (Russian traffic goes direct)'));
		o.value('selective', _('Selective (only chosen categories via tunnel)'));
		o.default = 'all';

		o = s.option(form.Flag, 'killswitch', _('Emergency block'),
			_('While the tunnel is down, traffic with action Tunnel is dropped instead of going direct.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(widgets.ZoneSelect, 'zone', _('Zones'),
			_('Firewall zones whose devices are routed. Other zones go direct.'));
		o.multiple = true;
		o.nocreate = true;
		o.default = 'lan';

		const sections = [];
		for (let mode of [ 'all', 'selective' ]) {
			const missing = ruleSections(mode).filter((r) => !present[r.set + ':' + r.tag]);
			const filterBox = {
				text: E('input', { 'type': 'search', 'class': 'cbi-input-text', 'placeholder': _('Search category…') }),
				only: E('input', { 'type': 'checkbox' })
			};
			sections.push(E('div', { 'class': 'cbi-section', 'data-tab': mode,
				'data-tab-title': mode == 'all' ? _('Actions: «All via tunnel»') : _('Actions: «Selective»') }, [
				E('p', { 'class': 'cbi-section-descr' }, mode == 'all'
					? _('By mode = Tunnel. Narrower categories are checked first; on a tie: Block → Tunnel → Direct. A domain category wins over a geoip category.')
					: _('By mode = Direct. Only categories with action Tunnel go through the tunnel.')),
				missing.length ? E('div', { 'class': 'alert-message warning' }, [
					_('Configured but missing from the current rule set (ignored): '),
					missing.map((r) => '%s:%s'.format(r.set, r.tag)).join(', ')
				]) : '',
				cats.length ? '' : E('div', { 'class': 'alert-message' }, _('Rule sets are not downloaded yet — see the Lists tab.')),
				E('div', { 'style': 'display:flex;gap:1em;align-items:center;margin:.5em 0' }, [
					filterBox.text,
					E('label', {}, [ filterBox.only, ' ', _('only with an explicit action') ]),
					E('button', { 'class': 'btn cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleReset', mode, info.starting || []) },
						_('Reset to starting settings'))
				]),
				renderTable(mode, cats, filterBox)
			]));
		}

		return m.render().then((mapEl) => {
			const tabs = E('div', {}, sections);
			// initTabGroup вставляет меню вкладок перед группой — у группы уже должен быть родитель.
			const page = E('div', {}, [ mapEl, tabs ]);
			ui.tabs.initTabGroup(tabs.childNodes);
			return page;
		});
	}
});
