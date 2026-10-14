'use strict';
'require view';
'require uci';
'require truba.common as common';
'require truba.ui.app as app';
'require truba.ui.kit as kit';

// «Правила» (spec §5.3): куда пойдёт домен или IP, Режим и Зоны, Наборы правил, Категории с Действиями.
// Настройки пишутся в UCI браузера и применяются панелью изменений, как на «Устройствах».

const POLL = 5000;   // шаг опроса: status — каждый второй раз (10 с), lists и sets — по common.listsDue

const MODES = () => [ [ 'all', _('All via tunnel') ], [ 'selective', _('Selective') ] ];

// geoip раньше geosite, внутри — по тегу.
function sorted(cats) {
	return cats.slice().sort((a, b) => (a.set != b.set) ? (a.set == 'geoip' ? -1 : 1) : (a.tag < b.tag) ? -1 : (a.tag > b.tag) ? 1 : 0);
}

// Действие Категории в UCI браузера: правится имеющаяся секция rule, лишние того же ключа удаляются —
// одна смена даёт одно изменение в панели. «По режиму» — секций нет.
function setAction(mode, set, tag, action) {
	const secs = common.ruleSections(mode, set, tag);
	let sid = (action != 'mode') ? secs[0]?.['.name'] : null;
	for (let s of secs)
		if (s['.name'] != sid)
			app.remove('truba', s['.name']);
	if (action == 'mode')
		return;
	// Сохранённая секция этого ключа, удалённая в браузере («По режиму»), возвращается: A → «По режиму» → B —
	// одно изменение, а не удаление и новая секция.
	if (!sid) {
		const v = uci.state?.values?.truba || {}, d = uci.state?.deletes?.truba || {};
		sid = Object.keys(v).find((x) => d[x] === true && v[x]['.type'] == 'rule' && common.ruleOf(v[x], mode, set, tag)) || null;
		if (sid)
			app.restore('truba', sid);
	}
	if (!sid) {
		sid = app.add('truba', 'rule');
		app.set('truba', sid, 'mode', mode);
		app.set('truba', sid, 'set', set);
		app.set('truba', sid, 'tag', tag);
	}
	app.set('truba', sid, 'action', action);
}

// «Стартовые настройки» Режима: Действия Категорий — как у новой установки (categories.starting).
// Меняются только Категории, у которых Действие или число секций не такие: Действие, совпавшее со
// стартовым, не даёт лишнего изменения.
function toStarting(mode, starting) {
	const want = new Map(starting.filter((r) => r.mode == mode).map((r) => [ r.set + ':' + r.tag, r.action ]));
	const keys = new Set([ ...want.keys(), ...common.ruleSections(mode).map(common.ruleKey) ]);
	for (let k of keys) {
		const i = k.indexOf(':'), set = k.slice(0, i), tag = k.slice(i + 1), a = want.get(k) || 'mode';
		if (common.ruleAction(mode, set, tag) != a || common.ruleSections(mode, set, tag).length != (a == 'mode' ? 0 : 1))
			setAction(mode, set, tag, a);
	}
}

// Зоны fw4, устройства которых маршрутизируются: все зоны, кроме зоны Трубы, и выбранные, которых в fw4
// уже нет. Последнюю выбранную снять нельзя: без Зон служба взяла бы умолчание схемы. Её кнопка — aria-disabled,
// а не disabled: экранный чтец её объявляет, а нажатие объясняет запрет сообщением (title на телефоне не виден).
function Zones() {
	const { html } = app.lib;
	const own = common.schema().consts.fw_zone;
	const def = common.schema().sections.main?.zone?.def || [];
	const sel = common.get('main', 'zone');
	const fw = uci.sections('firewall', 'zone').map((z) => z.name).filter((n) => n && n != own);
	const lastText = _('At least one zone is needed: without zones %s is routed by default.').format(def.join(', '));
	const toggle = (z) => (sel.length == 1 && sel[0] == z) ? app.toast(lastText)
		: app.set('truba', 'main', 'zone', sel.includes(z) ? sel.filter((x) => x != z) : [ ...sel, z ]);
	return html`<div class="chips zones" role="group" aria-label=${_('Zones')}>
		${[ ...new Set([ ...fw, ...sel ]) ].map((z) => {
			const on = sel.includes(z), last = on && sel.length == 1, gone = !fw.includes(z);
			return html`<button type="button" class="chip zone" data-zone=${z} aria-pressed=${String(on)} aria-disabled=${last ? 'true' : undefined}
				title=${last ? lastText : gone ? _('There is no such zone in the firewall.') : undefined}
				onClick=${() => toggle(z)}>${z}${gone ? html` <span class="n">${_('missing')}</span>` : ''}</button>`;
		})}
	</div>`;
}

function ModeCard() {
	const { html } = app.lib;
	const mode = common.get('main', 'mode');
	return html`<${kit.Card} cls="mode" title=${_('Mode', 'truba')}
		aside=${html`<${kit.Switch} label=${_('Routing')} opt="truba.main.routing" checked=${common.get('main', 'routing')}
			onChange=${(on) => app.set('truba', 'main', 'routing', on ? '1' : '0')} />`}>
		<div class="wide-seg"><${kit.Segmented} label=${_('Mode', 'truba')} items=${MODES()} value=${mode}
			onChange=${(v) => app.set('truba', 'main', 'mode', v)} /></div>
		<p class="mu note">${(mode == 'all')
			? _('Traffic without a category goes through the Tunnel; Russian traffic goes Direct by the starting settings.')
			: _('Only categories with action Tunnel go through the Tunnel; everything else goes Direct.')}</p>
		<h4 class="sub">${_('Zones')}</h4>
		<${Zones} />
		<p class="mu note">${_('Firewall zones whose devices are routed. Forwarding from them to zone «truba» is added automatically, and IPv6 internet is closed to them. Other zones go direct.')}</p>
	</${kit.Card}>`;
}

// Наборы правил (spec §5.3): версии geoip и geosite, итог последней проверки, откуда скачан, сколько
// адресов в наборах сейчас, «Обновить сейчас» и «Откатить», следующая проверка, настройки обновления.
// lists и sets опрашивает страница (load): раз в 30 с, а пока идёт обновление или применение — раз в 5 с.

// Сколько подсетей и IP сейчас уходит по каждому Действию. Подсети geoip посчитаны при применении;
// в ядре соседние сливаются, там их меньше.
function inSets(sets) {
	const g = sets?.geoip, d = sets?.dns, A = common.ACTION_LABELS;
	if (!sets?.routing || !g)
		return _('nothing: routing is off');
	const parts = (pairs) => pairs.map(([ a, n ]) => '%s %s'.format(A[a], common.fmtNum(n))).join(' · ');
	return _('geoip subnets: %s').format(parts([ [ 'direct', g.direct ], [ 'tunnel', g.tunnel ], [ 'block', g.block ] ]))
		+ ' — ' + _('IPs from DNS: %s').format(parts([ [ 'tunnel', d?.tunnel ], [ 'direct', d?.direct ] ]));
}

// Версия файла: начало контрольной суммы, дата и размер; нет файла — «нет» обычным текстом.
function Version({ v }) {
	const { html } = app.lib;
	return v ? html`<span><code>${(v.sha256 || '').substring(0, 12)}</code> ${common.fmtTime(v.mtime)} · ${common.fmtBytes(v.size)}</span>`
		: html`<span class="mu">${_('none', 'truba')}</span>`;
}

function RuleSets({ store, timing }) {
	const { html, useState } = app.lib;
	const { lists, sets, status, cats } = app.use(store);
	const [ dlg, setDlg ] = useState(false);
	const l = lists || {}, st = status || {}, last = l.last;
	const auto = common.get('lists', 'auto_update');
	const busy = l.updating ? _('Update in progress…') : l.applying ? _('Applying settings…') : null;
	const count = (set) => (cats?.cats || []).filter((c) => c.set == set).length;
	const failed = (e) => app.toast(_('Error: %s').format(e?.message || e));
	// После запуска опрос частый 15 с: замок обновления служба берёт не сразу.
	const update = () => common.callUpdateLists(false).then(() => {
		timing.kickedAt = Date.now();
		app.toast(_('Update started.'));
	}, failed);
	// Файлы переставляются сразу, применение — в фоне: его ход видно в карточке.
	const rollback = () => common.callRollbackLists().then((r) => {
		timing.kickedAt = Date.now();
		app.toast(r.error == 'busy' ? _('Rule sets are being updated, try again later.')
			: (r.swapped || []).length ? _('Rolled back: %s').format(r.swapped.join(', ')) : _('No previous version.'));
	}, failed);
	const sw = (key, label) => html`<${kit.Switch} label=${label} opt=${'truba.lists.' + key} checked=${common.get('lists', key)}
		onChange=${(on) => app.set('truba', 'lists', key, on ? '1' : '0')} />`;

	return html`<${kit.Card} cls="rule-sets" title=${_('Rule sets')}
		aside=${common.get('lists', 'via_tunnel') ? common.VIA_LABELS.tunnel : common.VIA_LABELS.direct}>
		${[ 'geoip', 'geosite' ].map((k) => html`<div class="ver" data-set=${k}>
			<b>${k}</b>
			<span class="mu">${l[k] ? common.fmtTime(l[k].mtime) : _('none', 'truba')} · ${common.setResult(last?.sets?.[k])}</span>
			<span class="r" title=${_('Categories')}>${common.fmtNum(count(k))}</span>
		</div>`)}
		<div class="mu sets">${_('In the sets now')}: ${inSets(sets)}</div>
		${busy ? html`<div><${kit.Busy} text=${busy} /></div>` : ''}
		<div class="acts">
			<button type="button" class="btn" data-act="update" disabled=${!!busy} onClick=${update}>${_('Update now')}</button>
			<button type="button" class="btn" data-act="rollback" disabled=${!!busy} onClick=${() => setDlg(true)}>${_('Roll back')}</button>
			<span class="mu">${!st.routing ? '' : !auto ? _('automatic update is off') : _('Next check: %s').format(common.fmtTime(st.lists?.next))}</span>
		</div>
		<${kit.Fold} title=${_('Versions')}>
			<div class="vers">
				<span class="vh"></span><span class="vh mu">${_('Current version')}</span><span class="vh mu">${_('Previous version')}</span>
				${[ 'geoip', 'geosite' ].map((k) => html`<b>${k}.dat</b>
					<span><span class="vl mu">${_('Current version')}: </span><${Version} v=${l[k]} /></span>
					<span><span class="vl mu">${_('Previous version')}: </span><${Version} v=${l['prev_' + k]} /></span>`)}
			</div>
			<div class="mu">${last ? _('Last check: %s').format(common.fmtTime(last.time)) : _('not checked yet')}</div>
		</${kit.Fold}>
		<${kit.Fold} title=${_('Update settings')}>
			<div class="mu">${_('geoip.dat and geosite.dat from kirilllavrov/geoip-builder and kirilllavrov/geosite-builder. Files are used unchanged; the checksum is verified before every replacement.')}</div>
			<div class="sws">${sw('auto_update', _('Update automatically'))}${sw('via_tunnel', _('Download via tunnel'))}</div>
			<div class="mu">${_('The main source is fetched through the tunnel; the mirror always goes direct.')}</div>
			<${kit.Field} sec="lists" name="update_utc" label=${_('Update time (UTC)')} msg=${_('Format: HH:MM')} disabled=${!auto}
				hint=${_('geoip.dat is published every three days around 10–11 UTC, geosite.dat irregularly, usually by 09 UTC; at 12:00 a new release is picked up the same day. Converted to the router time zone for cron.')} />
			<${kit.Field} sec="lists" name="geoip_url" label=${_('geoip.dat')} />
			<${kit.Field} sec="lists" name="geoip_mirror" label=${_('geoip.dat mirror')} hint=${_('Downloaded directly if the main source failed.')} />
			<${kit.Field} sec="lists" name="geosite_url" label=${_('geosite.dat')} />
			<${kit.Field} sec="lists" name="geosite_mirror" label=${_('geosite.dat mirror')} />
		</${kit.Fold}>
		<${kit.Dialog} open=${dlg} title=${_('Swap current and previous rule sets?')} confirm=${_('Roll back')}
			onConfirm=${rollback} onClose=${() => setDlg(false)}>
			${_('The files are swapped at once; the rules are rebuilt in the background.')}
		</${kit.Dialog}>
	</${kit.Card}>`;
}

function Cat({ c, mode, action, changed }) {
	const { html } = app.lib;
	const meta = [ (c.set == 'geoip' ? _('geoip · %s subnets') : _('geosite · %s entries')).format(common.fmtNum(c.count)) ];
	if ((c.subset_of || []).length)
		meta.push(_('in %s').format(c.subset_of.join(', ')));
	return html`<div class="cat" data-cat=${c.set + ':' + c.tag}>
		<span class="n"><b>${c.tag}</b>${changed ? html` <${kit.Dot} level="warn" label=${_('changed, not applied yet')} />` : ''}
			<span class="mu">${meta.join(' · ')}</span></span>
		<${kit.ActionPicker} label=${_('Action for %s').format(c.tag)} value=${action} onChange=${(a) => setAction(mode, c.set, c.tag, a)} />
	</div>`;
}

// Категории одного Режима: по умолчанию — Режима страницы (и несохранённого), сегмент в шапке
// показывает Действия другого, не меняя Режим.
function Categories({ cats, snap }) {
	const { html, useState, useEffect, useMemo } = app.lib;
	const pageMode = common.get('main', 'mode');
	const [ shown, setShown ] = useState(null);
	useEffect(() => setShown(null), [ pageMode ]);
	const mode = shown || pageMode;
	const [ q, setQ ] = useState(''), [ f, setF ] = useState('explicit'), [ dlg, setDlg ] = useState(false);
	// «Показать все» — для поиска, чипа и Режима, при которых нажата: смена любого снова даёт первые строки.
	const [ fullFor, setFullFor ] = useState(null);
	const list = useMemo(() => sorted(cats?.cats || []), [ cats ]);
	const acts = common.ruleActions(mode), was = snap[mode];
	const act = (c) => acts.get(c.set + ':' + c.tag) || 'mode';

	const n = { all: list.length, explicit: 0, tunnel: 0, direct: 0, block: 0 };
	for (let c of list) {
		const a = act(c);
		if (a != 'mode') {
			n.explicit++;
			n[a]++;
		}
	}
	const sig = [ mode, f, q.trim().toLowerCase() ].join('\n');
	const { rows, total } = common.catRows(list, act, q, f, fullFor == sig);
	// Поиск при чипе «С Действием» (он по умолчанию) ищет среди всех: найти Категорию без Действия и
	// задать его — главный сценарий карточки.
	const search = (ev) => {
		setQ(ev.target.value);
		if (f == 'explicit' && ev.target.value.trim())
			setF('all');
	};
	// Правила для Категорий, которых нет в текущем Наборе: служба их пропускает (applied.missing).
	const present = new Set(list.map((c) => c.set + ':' + c.tag));
	const missing = list.length ? [ ...acts.keys() ].filter((k) => !present.has(k)) : [];
	const removeMissing = () => {
		for (let s of common.ruleSections(mode))
			if (missing.includes(common.ruleKey(s)))
				app.remove('truba', s['.name']);
	};
	const A = common.ACTION_LABELS;

	return html`<${kit.Card} cls="w3 rules-cats" title=${_('Categories')}
		aside=${html`<span class="mu">${_('%s · with an action %s').format(common.fmtNum(n.all), common.fmtNum(n.explicit))}</span>
			<${kit.Segmented} label=${_('Show actions for mode')} items=${MODES()} value=${mode} onChange=${setShown} />`}>
		${missing.length ? html`<div class="missing">
			<span>${common.missingText(missing)}</span>
			<button type="button" class="btn" data-act="remove-missing" onClick=${removeMissing}>${_('Remove', 'truba')}</button>
		</div>` : ''}
		<div class="toolbar">
			<input type="search" aria-label=${_('Find a category')} placeholder=${_('Find a category')} value=${q} onInput=${search} />
			<${kit.Chips} label=${_('Filter by action')} value=${f} onChange=${setF} items=${[
				[ 'all', _('All'), n.all ], [ 'explicit', _('With an action'), n.explicit ],
				[ 'tunnel', A.tunnel, n.tunnel ], [ 'direct', A.direct, n.direct ], [ 'block', A.block, n.block ]
			]} />
			<button type="button" class="btn" data-act="starting" disabled=${!list.length} onClick=${() => setDlg(true)}>${_('Starting settings')}</button>
		</div>
		${!list.length ? html`<${kit.Empty} text=${cats?.busy ? _('Rule sets are being unpacked — the list will appear in a minute.')
			: _('Rule sets are not downloaded yet — see Rule sets above.')} />`
			: !total ? html`<${kit.Empty} text=${_('No categories match the filter.')} />`
			: html`<div class="cats">${rows.map((c) => html`<${Cat} key=${c.set + ':' + c.tag} c=${c} mode=${mode} action=${act(c)}
				changed=${(was.get(c.set + ':' + c.tag) || 'mode') != act(c)} />`)}</div>`}
		${(total > rows.length) ? html`<button type="button" class="btn more" data-act="show-all" onClick=${() => setFullFor(sig)}>
			${_('Show all (%d)').format(total)}</button>` : ''}
		<${kit.Dialog} open=${dlg} title=${_('Reset all category actions of this mode to the starting settings?')} confirm=${_('Reset', 'truba')}
			onConfirm=${() => toStarting(mode, cats?.starting || [])} onClose=${() => setDlg(false)}>
			${_('Mode: %s. The change is applied with the Apply button, like the others.').format(MODES().find(([ v ]) => v == mode)[1])}
		</${kit.Dialog}>
	</${kit.Card}>`;
}

function Page({ store, snap, timing, view }) {
	const { html } = app.lib;
	const { cats, offline } = app.use(store);
	app.use(app.changes);   // карточки читают UCI браузера — перерисовка после app.set
	return html`
		<div class="head">
			<h2>${_('Rules')}</h2>
			<span class="mu">${_('Which traffic goes through the tunnel. Categories are taken from geoip.dat and geosite.dat as they are; new categories are never created.')}</span>
			${offline ? html`<${kit.Badge} level="err"><${kit.Icon} name="wifi-off" />${_('No connection to the router')}</${kit.Badge}>` : ''}
		</div>
		<div class="grid g2">
			<${kit.Card} cls="w3 where" title=${_('Where it goes')} aside=${_('for all devices')}><${kit.Check} full /></${kit.Card}>
			<${ModeCard} />
			<${RuleSets} store=${store} timing=${timing} />
			<${Categories} cats=${cats} snap=${snap} />
		</div>
		<${kit.ChangesBar} view=${view} />
		<${kit.Toast} />`;
}

return view.extend({
	load: function() {
		return Promise.all([ app.load(), common.loadSchema() ]).then(() => Promise.all([
			common.callCategories(), common.callLists(), common.callStatus().catch(() => null), common.callSets().catch(() => null),
			uci.load('truba'), uci.load('firewall') ]));
	},

	render: function(data) {
		const store = app.store({ cats: data[0], lists: data[1], status: data[2], sets: data[3], offline: data[2] == null });
		// Действия при загрузке страницы — для точки «изменено»: секции rule удаляются и заводятся заново,
		// поэтому несохранённое у секции не говорит, другое ли Действие.
		const snap = { all: common.ruleActions('all'), selective: common.ruleActions('selective') };
		// kickedAt — когда нажали «Обновить сейчас»: замок обновления берётся не сразу, опрос чаще 15 с.
		const timing = { polledAt: Date.now(), kickedAt: -Infinity };
		let tick = 0;
		app.poll(store, () => {
			const st = store.get(), now = Date.now(), patch = {}, calls = [];
			if (tick++ % 2)
				calls.push(common.callStatus().then((s) => { patch.status = s; }));
			if (common.listsDue(now, timing.polledAt, timing.kickedAt, st.lists)) {
				timing.polledAt = now;
				// Категории — следом за lists, когда Наборы правил распаковываются, ещё не скачаны или сменились.
				calls.push(common.callLists().then((l) => {
					patch.lists = l;
					if (common.catsDue(st.cats, st.lists, l))
						return common.callCategories().then((c) => { patch.cats = c; });
				}), common.callSets().then((s) => { patch.sets = s; }, () => {}));
			}
			return Promise.all(calls).then(() => patch);
		}, POLL / 1000);
		return app.mount(this, Page, { store, snap, timing });
	},

	// «Применить» панели изменений и «Сохранить и применить» LuCI: пока есть неверные поля, ничего не
	// сохраняется (spec §3.6) — иначе применилось бы остальное, а введённое значение молча пропало бы.
	handleSaveApply: function(ev, mode) {
		if (app.changes.get().bad) {
			app.toast(_('Fix the highlighted fields'));
			return Promise.resolve();
		}
		return this.super('handleSaveApply', [ ev, mode ]);
	},

	// Настройки меняются прямо в браузере: сохранить — отправить эти изменения, сбросить — перечитать страницу.
	handleSave: function() {
		return uci.save().then(() => app.changes.set({ n: app.changeCount() }));
	},

	handleReset: function() {
		window.location.reload();
	}
});
