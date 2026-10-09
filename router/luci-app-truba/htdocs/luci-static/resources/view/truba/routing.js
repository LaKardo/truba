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

// Фильтр по Действию: все, с явным Действием или одно Действие.
const FILTERS = [ 'all', 'explicit', 'tunnel', 'direct', 'block' ];

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
			apply();
		} }, ACTIONS.map((a) => E('option', { 'value': a }, common.ACTION_LABELS[a])));
		sel.value = currentAction(mode, c.set, c.tag);
		return E('tr', { 'class': 'tr', 'data-search': (c.set + ':' + c.tag).toLowerCase(), 'data-action': sel.value }, [
			E('td', { 'class': 'td' }, c.set),
			E('td', { 'class': 'td' }, E('strong', {}, c.tag)),
			E('td', { 'class': 'td' }, common.fmtNum(c.count)),
			E('td', { 'class': 'td' }, E('small', {}, typesText(c))),
			E('td', { 'class': 'td' }, E('small', {}, (c.subset_of || []).join(', ') || '—')),
			E('td', { 'class': 'td' }, sel)
		]);
	});
	const table = E('table', { 'class': 'table' }, [ header ].concat(rows));

	// Поиск и фильтр по Действию; числа на кнопках фильтра — Категории этого Режима.
	function apply() {
		const q = filterBox.text.value.trim().toLowerCase();
		const f = filterBox.value;
		const n = { all: rows.length, explicit: 0, tunnel: 0, direct: 0, block: 0 };
		for (let r of rows) {
			const a = r.getAttribute('data-action');
			if (a != 'mode') {
				n.explicit++;
				n[a]++;
			}
			const hit = (!q || r.getAttribute('data-search').indexOf(q) >= 0)
				&& (f == 'all' || (f == 'explicit' ? a != 'mode' : a == f));
			r.style.display = hit ? '' : 'none';
		}
		for (let k of FILTERS)
			common.setText(filterBox.counts[k], ' ' + common.fmtNum(n[k]));
	}
	filterBox.text.addEventListener('input', apply);
	filterBox.apply = apply;
	apply();
	return table;
}

return view.extend({
	load: function() {
		return Promise.all([ common.callCategories(), uci.load('truba'), uci.load('firewall'), common.callLeases().catch(() => ({})),
			common.callSets().catch(() => null) ]);
	},

	// Не handleReset: так LuCI называет обработчик кнопки «Сброс» внизу страницы.
	handleResetRules: function(mode, starting) {
		if (!confirm(_('Reset all category actions of this mode to the starting settings?')))
			return;
		// Сначала — несохранённые правки формы (Политики устройств): перезагрузка их потеряла бы.
		return this.map.parse().then(() => {
			for (let s of ruleSections(mode))
				uci.remove('truba', s['.name']);
			for (let r of starting.filter((x) => x.mode == mode)) {
				const sid = uci.add('truba', 'rule');
				uci.set('truba', sid, 'mode', r.mode);
				uci.set('truba', sid, 'set', r.set);
				uci.set('truba', sid, 'tag', r.tag);
				uci.set('truba', sid, 'action', r.action);
			}
			return uci.save();
		}).then(() => window.location.reload());
	},

	render: function(data) {
		const info = data[0] || {};
		const cats = (info.cats || []).slice().sort((a, b) =>
			(a.set == b.set) ? (a.tag < b.tag ? -1 : 1) : (a.set == 'geoip' ? -1 : 1));
		const present = {};
		for (let c of cats)
			present[c.set + ':' + c.tag] = true;

		const m = this.map = new form.Map('truba', _('Routing'),
			_('Which traffic goes through the tunnel. Categories are taken from geoip.dat and geosite.dat as they are; new categories are never created.'));

		const s = m.section(form.NamedSection, 'main', 'main');
		s.addremove = false;

		let o = s.option(form.ListValue, 'mode', _('Mode'),
			_('What happens to traffic that no category with an explicit action matched. «All via tunnel» — everything except categories with action Direct (by default, Russian traffic). «Selective» — only categories with action Tunnel go through the tunnel.'));
		o.value('all', _('All via tunnel'));
		o.value('selective', _('Selective'));
		o.widget = 'radio';
		o.orientation = 'horizontal';
		o.default = 'all';

		o = s.option(widgets.ZoneSelect, 'zone', _('Zones'),
			_('Firewall zones whose devices are routed. Other zones go direct.'));
		o.multiple = true;
		o.nocreate = true;
		o.default = 'lan';

		// Размеры наборов — сколько подсетей и IP сейчас уходит по каждому Действию.
		// Подсети geoip посчитаны при применении; в ядре соседние сливаются, там их меньше.
		const sets = data[4];
		o = s.option(form.DummyValue, '_sets', _('In the sets now'));
		o.rawhtml = false;
		o.cfgvalue = () => {
			const g = sets?.geoip, d = sets?.dns, A = common.ACTION_LABELS;
			if (!sets?.routing || !g)
				return _('nothing: routing is off');
			const parts = (pairs) => pairs.map(([ a, n ]) => '%s %s'.format(A[a], common.fmtNum(n))).join(' · ');
			return _('geoip subnets: %s').format(parts([ [ 'direct', g.direct ], [ 'tunnel', g.tunnel ], [ 'block', g.block ] ]))
				+ ' — ' + _('IPs from DNS: %s').format(parts([ [ 'tunnel', d?.tunnel ], [ 'direct', d?.direct ] ]));
		};

		// Исключения для устройств — до Категорий: политика устройства сильнее их.
		const leases = (data[3] && data[3].dhcp_leases) || [];
		const ds = m.section(form.GridSection, 'device', _('Device policies'),
			_('Per-device exceptions. A device is recognised by its MAC address, also behind roamd mesh nodes (4-address mode keeps client MACs). Block still applies to all devices.'));
		ds.anonymous = true;
		ds.addremove = true;
		ds.sortable = true;
		ds.nodescriptions = true;

		o = ds.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = ds.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = ds.option(form.Value, 'mac', _('MAC address'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		for (let l of leases) {
			if (l.macaddr)
				o.value(l.macaddr.toUpperCase(), '%s (%s, %s)'.format(l.macaddr.toUpperCase(), l.hostname || '?', l.ipaddr || '?'));
		}

		// Кто это сейчас в сети: имя и IP из DHCP по MAC.
		o = ds.option(form.DummyValue, '_host', _('In the network'));
		o.modalonly = false;
		o.cfgvalue = (sid) => {
			const mac = (uci.get('truba', sid, 'mac') || '').toUpperCase();
			const l = leases.find((x) => (x.macaddr || '').toUpperCase() == mac);
			return l ? '%s · %s'.format(l.hostname || '?', l.ipaddr || '?') : _('not online');
		};

		o = ds.option(form.ListValue, 'policy', _('Policy'));
		o.value('tunnel', _('All via tunnel'));
		o.value('direct', _('All direct'));
		o.value('rules', _('By rules'));
		o.default = 'tunnel';
		o.editable = true;
		o.description = _('«All via tunnel» is recommended for game consoles: then all their traffic gets the Truba IP and full cone NAT.');

		const FILTER_LABELS = { all: _('All'), explicit: _('With an explicit action'), tunnel: common.ACTION_LABELS.tunnel,
			direct: common.ACTION_LABELS.direct, block: common.ACTION_LABELS.block };
		const sections = [];
		for (let mode of [ 'all', 'selective' ]) {
			const missing = ruleSections(mode).filter((r) => !present[r.set + ':' + r.tag]);
			const filterBox = {
				text: E('input', { 'type': 'search', 'class': 'cbi-input-text', 'placeholder': _('Search category…') }),
				value: 'all',
				counts: {}
			};
			// Кнопки фильтра: нажатая — aria-pressed; число Категорий — после названия.
			const chips = FILTERS.map((f) => {
				filterBox.counts[f] = E('span', { 'class': 'truba-num' });
				const b = E('button', { 'class': 'truba-chip', 'type': 'button', 'aria-pressed': f == 'all' ? 'true' : 'false', 'click': () => {
					filterBox.value = f;
					for (let x of chips)
						x.setAttribute('aria-pressed', x === b ? 'true' : 'false');
					filterBox.apply();
				} }, [ common.ACTION_LEVELS[f] ? E('span', { 'class': 'truba-dot ' + common.ACTION_LEVELS[f] }) : '', FILTER_LABELS[f], filterBox.counts[f] ]);
				return b;
			});
			// Пропавшие Категории не применяются: их можно убрать из настроек одной кнопкой.
			const missingBox = missing.length ? E('div', { 'class': 'alert-message warning truba-toolbar' }, [
				E('span', { 'class': 'truba-grow' }, common.missingText(missing.map((r) => '%s:%s'.format(r.set, r.tag)))),
				E('button', { 'class': 'btn cbi-button', 'type': 'button', 'click': (ev) => {
					for (let r of missing)
						uci.remove('truba', r['.name']);
					ev.target.closest('.alert-message').remove();
				} }, _('Remove'))
			]) : '';
			sections.push(E('div', { 'class': 'cbi-section', 'data-tab': mode,
				'data-tab-title': mode == 'all' ? _('Actions: «All via tunnel»') : _('Actions: «Selective»') }, [
				E('p', { 'class': 'cbi-section-descr' }, mode == 'all'
					? _('By mode = Tunnel. Narrower categories are checked first; on a tie: Block → Tunnel → Direct. A domain category wins over a geoip category.')
					: _('By mode = Direct. Only categories with action Tunnel go through the tunnel.')),
				missingBox,
				cats.length ? '' : E('div', { 'class': 'alert-message' }, info.busy
					? _('Rule sets are being unpacked — reload the page in a minute.')
					: _('Rule sets are not downloaded yet — see the DNS & lists tab.')),
				E('div', { 'class': 'truba-toolbar' }, [
					filterBox.text,
					E('div', { 'class': 'truba-chips truba-grow', 'role': 'group', 'aria-label': _('Filter by action') }, chips),
					E('button', { 'class': 'btn cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleResetRules', mode, info.starting || []) },
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
