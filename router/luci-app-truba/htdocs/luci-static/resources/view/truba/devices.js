'use strict';
'require view';
'require uci';
'require truba.common as common';
'require truba.ui.app as app';
'require truba.ui.kit as kit';
'require truba.ui.chart as chart';

// «Устройства» (spec §5.2, ADR 0018): кто в домашней сети сколько качает и через что, Политика
// устройства. Список — устройства из истории службы и с Политикой; панель — выбранное устройство.

const POLL = 5000;   // devices, а при открытой панели ещё connections — раз в 5 с

const key = (d) => d.ip || d.mac;

// Имя: из секции устройства в настройках браузера (с несохранённым переименованием), иначе от службы.
function nameOf(d) {
	const sid = common.deviceSection(d.mac);
	return (sid && uci.get('truba', sid, 'name')) || d.name || d.ip || d.mac;
}

// Устройства службы и секции device с Политикой из настроек браузера, которых служба ещё не знает
// (добавлены «по MAC» и не применены): такие — «не в сети», как у службы устройство с Политикой без
// адреса. Секция «по правилам» ничего не меняет — в список она не попадает, как и у службы.
function withPending(devices) {
	const known = new Set(devices.map((d) => d.mac).filter(Boolean));
	const out = devices.filter((d) => d.ip || common.devicePolicy(d.mac) != 'rules');
	for (let s of uci.sections('truba', 'device')) {
		const mac = common.normMac(s.mac);
		if (!mac || known.has(mac) || common.devicePolicy(mac) == 'rules')
			continue;
		known.add(mac);
		out.push({ ip: null, mac, name: s.name || null, source: 'config', zone: null, rate: null, day: null, minutes: [], last: null });
	}
	return out;
}

function speed(d) {
	const r = common.devRate(d);
	return r ? r[0] + r[1] : -1;
}

// Политика в UCI браузера. «По правилам» — это отсутствие секции: секции этого MAC удаляются, и
// устройство без трафика уходит из списка. Иначе — первая секция MAC (она и действует у службы), а если
// её нет — новая с MAC и именем, если оно есть: адрес именем не становится, он меняется.
function setPolicy(mac, policy, name) {
	if (policy == 'rules') {
		for (let sid of common.deviceSections(mac))
			app.remove('truba', sid);
		return;
	}
	let sid = common.deviceSection(mac);
	if (!sid) {
		sid = app.add('truba', 'device');
		app.set('truba', sid, 'mac', mac);
	}
	if (name)
		app.set('truba', sid, 'name', name);
	app.set('truba', sid, 'policy', policy);
	if (uci.get('truba', sid, 'enabled') == '0')
		app.set('truba', sid, 'enabled', '1');
}

const POLICY_ITEMS = () => [ [ 'rules', _('By rules') ], [ 'tunnel', _('All via tunnel') ], [ 'direct', _('All direct') ] ];
const POLICY_SHORT = () => ({ tunnel: _('all via tunnel'), direct: _('all direct') });
const SOURCE = () => ({ dhcp: _('DHCP'), neigh: _('neighbour'), config: _('settings') });

function Row({ d, now, sel, onSel }) {
	const { html } = app.lib;
	const pol = common.devicePolicy(d.mac);
	const r = common.devRate(d), [ tun, dir ] = common.devShare(d, now);
	const day = d.day ? d.day.reduce((a, b) => a + b, 0) : null;
	const sid = common.deviceSection(d.mac);
	return html`<button type="button" class=${'dev' + (sel ? ' sel' : '')} data-ip=${d.ip || undefined} data-mac=${d.mac || undefined}
		aria-pressed=${String(!!sel)} onClick=${() => onSel(key(d))}>
		<span class="n">
			<b>${nameOf(d)}${app.pending('truba', sid) ? html` <${kit.Dot} level="warn" label=${_('changed, not applied yet')} />` : ''}</b>
			<span class="mu">${(d.ip || _('offline')) + (d.zone ? ' · ' + d.zone : '')}</span>
			${(pol != 'rules') ? html`<span class=${'pol ' + pol}>${POLICY_SHORT()[pol]}</span>` : ''}
		</span>
		<${kit.ShareBar} tunnel=${tun} direct=${dir} />
		<span class="r">${r ? html`↓ ${common.fmtRate(r[0])}<small>↑ ${common.fmtRate(r[1])}</small>` : '—'}</span>
		<span class="r day">${(day != null) ? common.fmtBytes(day) : '—'}</span>
	</button>`;
}

// Форма «Добавить по MAC»: Политика заранее — устройству, которого сейчас нет в сети. MAC, у которого
// секция уже есть, второй не заводит: Политика и имя из формы — его секции, выбирается его строка.
function AddMac({ onDone }) {
	const { html, useState } = app.lib;
	const [ mac, setMac ] = useState(''), [ name, setName ] = useState(''), [ pol, setPol ] = useState('tunnel');
	const m = common.normMac(mac);
	const add = (ev) => {
		ev.preventDefault();
		if (!m)
			return;
		setPolicy(m, pol, name.trim());
		onDone(m);
	};
	return html`<form class="addmac" onSubmit=${add}>
		<label><span class="mu">${_('MAC address')}</span>
			<input name="mac" autocomplete="off" value=${mac} onInput=${(ev) => setMac(ev.target.value)} /></label>
		${(mac.trim() && !m) ? html`<div class="err-text">${_('Not a MAC address')}</div>` : ''}
		<label><span class="mu">${_('Name')}</span>
			<input name="name" autocomplete="off" value=${name} onInput=${(ev) => setName(ev.target.value)} /></label>
		<${kit.Segmented} label=${_('Policy')} value=${pol} onChange=${setPol}
			items=${[ [ 'tunnel', _('All via tunnel') ], [ 'direct', _('All direct') ] ]} />
		<div class="acts">
			<button type="submit" class="btn p" data-act="add" disabled=${!m}>${_('Add')}</button>
			<button type="button" class="btn" onClick=${() => onDone(null)}>${_('Cancel')}</button>
		</div>
	</form>`;
}

function List({ devices, now, sel, onSel }) {
	const { html, useState } = app.lib;
	const [ q, setQ ] = useState(''), [ f, setF ] = useState('all'), [ adding, setAdding ] = useState(false);
	const active = (d) => common.devActive(d, now);
	const ruled = (d) => common.devicePolicy(d.mac) != 'rules';
	const qq = q.trim().toLowerCase();
	const shown = devices
		.filter((d) => (f == 'all') || (f == 'active' ? active(d) : ruled(d)))
		.filter((d) => !qq || [ d.name, d.ip, d.mac ].some((x) => String(x || '').toLowerCase().includes(qq)))
		.sort((a, b) => (speed(b) - speed(a)) || String(a.name || a.ip || a.mac).localeCompare(String(b.name || b.ip || b.mac)));
	// Секции с неверным MAC служба пропускает и предупреждает о них на «Обзоре» со ссылкой сюда:
	// здесь их видно и можно убрать.
	const bad = uci.sections('truba', 'device').filter((s) => s.mac && !common.normMac(s.mac));
	const done = (mac) => {
		setAdding(false);
		if (mac) {
			setF('all');
			setQ('');
			const d = devices.find((x) => x.mac == mac);
			onSel(d ? key(d) : mac);
		}
	};
	return html`<${kit.Card} cls="list" title=""
		aside=${html`<button type="button" class="btn" data-act="add-mac" onClick=${() => setAdding(true)}>${_('Add by MAC')}</button>`}>
		${adding ? html`<${AddMac} onDone=${done} />` : ''}
		${bad.map((s) => html`<div class="badmac">
			<span>${_('A device with an invalid MAC address «%s» is ignored.').format(s.mac)}</span>
			<button type="button" class="btn" data-act="remove-bad" onClick=${() => app.remove('truba', s['.name'])}>${_('Remove')}</button>
		</div>`)}
		<div class="toolbar">
			<input type="search" placeholder=${_('Name, IP or MAC')} value=${q} onInput=${(ev) => setQ(ev.target.value)} />
			<${kit.Chips} label=${_('Filter')} value=${f} onChange=${setF} items=${[
				[ 'all', _('All'), devices.length ],
				[ 'active', _('Active'), devices.filter(active).length ],
				[ 'policy', _('With a policy'), devices.filter(ruled).length ]
			]} />
		</div>
		${shown.length
			? html`<div class="devs">${shown.map((d) => html`<${Row} key=${key(d)} d=${d} now=${now} sel=${key(d) == sel} onSel=${onSel} />`)}</div>`
			: html`<${kit.Empty} text=${devices.length ? _('No devices match the filter.') : _('No devices with traffic in the last 24 hours yet.')} />`}
	</${kit.Card}>`;
}

// Мини-график по поминутным средним: Туннель и Напрямую, к устройству и от него вместе. Шаг и срок —
// у службы (truba.schema, consts.devices). Минут без трафика служба не пишет: их место — пропуск.
function HourChart({ d, now }) {
	const { html } = app.lib;
	const h = common.schema().consts.devices || {};
	const pts = chart.gaps((d.minutes || []).map((m) => [ m[0], (m[1] || 0) + (m[2] || 0), (m[3] || 0) + (m[4] || 0) ]), h.step);
	if (!pts.length)
		return html`<${kit.Empty} text=${_('No traffic in the last hour.')} />`;
	const series = [ { label: _('Tunnel'), color: 'tun' }, { label: _('Direct'), color: 'dir', dash: true } ];
	const data = [ pts.map((p) => p[0]), pts.map((p) => p[1] ?? null), pts.map((p) => p[2] ?? null) ];
	return html`<${chart.TimeChart} series=${series} data=${data} from=${now - h.span} to=${now} height=${90} />`;
}

// «Куда ходит сейчас»: адреса из conntrack. Скорость адреса — по разнице байт двух опросов: служба
// отдаёт байты с начала соединений.
function Conns({ ip }) {
	const { html, useRef, useMemo } = app.lib;
	const { data, offline } = app.usePoll(() => common.callConnections(ip), POLL, [ ip ]);
	const prev = useRef(null);
	const speeds = useMemo(() => {
		const t = Date.now() / 1000, cur = {}, out = {};
		for (let a of data?.addrs || [])
			if (a.up != null)
				cur[a.addr] = a.up + (a.down || 0);
		const p = prev.current;
		if (p && t - p.t >= 1)
			for (let k in cur)
				if (p.b[k] != null && cur[k] >= p.b[k])
					out[k] = (cur[k] - p.b[k]) / (t - p.t);
		prev.current = { t, b: cur };
		return out;
	}, [ data ]);
	if (!data)
		return html`<${kit.Empty} text=${offline ? _('No connection to the router') : _('Loading…')} />`;
	if (data.error)
		return html`<${kit.Empty} text=${_('The connection table is not available on the router.')} />`;
	if (!(data.addrs || []).length)
		return html`<${kit.Empty} text=${_('No connections right now.')} />`;
	return html`<div class="conns">
		${data.addrs.map((a) => html`<div class="conn">
			<span class="n"><b>${a.addr}</b><span class="mu">${common.connLabel(a)}</span></span>
			<${kit.ActionTag} action=${a.action} />
			<span class="r">${(speeds[a.addr] != null) ? common.fmtRate(speeds[a.addr]) : '—'}</span>
		</div>`)}
		<div class="mu">${_('Connections: %d').format(data.total)}</div>
	</div>`;
}

// «Проверить для этого устройства»: та же проверка, что на вкладке «Диагностика», с MAC — с Политикой.
function CheckBox({ mac }) {
	const { html, useState } = app.lib;
	const [ q, setQ ] = useState(''), [ res, setRes ] = useState(null), [ busy, setBusy ] = useState(false);
	const run = (ev) => {
		ev.preventDefault();
		const t = q.trim();
		if (!t)
			return;
		setBusy(true);
		common.callCheck(t, mac || null).then((r) => setRes(r), () => setRes({ error: 'rpc' })).finally(() => setBusy(false));
	};
	return html`<form class="check" onSubmit=${run}>
		<input name="target" autocomplete="off" placeholder=${_('domain or IP')} value=${q} onInput=${(ev) => setQ(ev.target.value)} />
		<button type="submit" class="btn" disabled=${busy}>${_('Check')}</button>
	</form>
	${res ? html`<div class="mu check-res">${(res.error || !res.action) ? _('The check failed.')
		: html`${res.target} → <${kit.ActionTag} action=${res.action} /> · ${common.REASON_LABELS[res.reason] || res.reason}`}</div>` : ''}`;
}

// Карточка своей разметкой, а не kit.Card: нужен сам элемент. При выборе устройства панель
// прокручивается в видимую область: на телефоне она липнет к низу экрана, но выше начала списка
// подняться не может, и при коротком списке её низ уходил бы за край.
function Panel({ d, now, onClose }) {
	const { html, useRef, useEffect } = app.lib;
	const ref = useRef(null);
	useEffect(() => { ref.current?.scrollIntoView?.({ block: 'nearest' }); }, [ key(d) ]);
	const src = SOURCE()[d.source];
	const sid = common.deviceSection(d.mac);
	return html`<section class="card panel" ref=${ref}>
		<div class="card-h"><h3>${nameOf(d)}</h3>
			<span class="aside"><button type="button" class="btn" data-act="close" onClick=${onClose}>${_('Close')}</button></span></div>
		<div class="mu">${[ d.ip || _('offline'), d.mac || _('no MAC'), src ].filter(Boolean).join(' · ')}</div>
		<div class="policy">
			<${kit.Segmented} label=${_('Policy')} items=${POLICY_ITEMS()} value=${common.devicePolicy(d.mac)} disabled=${!d.mac}
				onChange=${(p) => setPolicy(d.mac, p, sid ? null : d.name)} />
			<div class="mu">${d.mac ? _('«All via tunnel» is recommended for game consoles: then all their traffic gets the Truba IP and full cone NAT.')
				: _('The policy is tied to the MAC address; mesh VPN nodes have none.')}</div>
		</div>
		${sid ? html`<label class="rename"><span class="mu">${_('Name')}</span>
			<input name="devname" autocomplete="off" value=${uci.get('truba', sid, 'name') || ''}
				onChange=${(ev) => app.set('truba', sid, 'name', ev.target.value.trim() || null)} /></label>` : ''}
		<h4 class="sub">${_('Last hour')}</h4>
		<${HourChart} d=${d} now=${now} />
		<h4 class="sub">${_('Where it goes now')}</h4>
		${d.ip ? html`<${Conns} key=${d.ip} ip=${d.ip} />` : html`<${kit.Empty} text=${_('The device is offline.')} />`}
		<h4 class="sub">${_('Check for this device')}</h4>
		<${CheckBox} key=${key(d)} mac=${d.mac} />
	</section>`;
}

function Page({ store, view }) {
	const { html, useState } = app.lib;
	const { devices, offline } = app.use(store);
	app.use(app.changes);   // строки и панель читают UCI браузера — перерисовка после app.set
	const [ sel, setSel ] = useState(null);
	const list = withPending(devices?.devices || []);
	const now = devices?.now || Math.floor(Date.now() / 1000);
	const cur = sel ? list.find((d) => key(d) == sel) : null;
	return html`
		<div class="head">
			<h2>${_('Devices')}</h2>
			<span class="mu">${_('Who in the home network uses how much and through what. A device policy overrides the categories, except Block.')}</span>
			${offline ? html`<${kit.Badge} level="err"><${kit.Icon} name="wifi-off" />${_('No connection to the router')}</${kit.Badge}>` : ''}
		</div>
		<div class="split">
			<${List} devices=${list} now=${now} sel=${sel} onSel=${setSel} />
			${cur ? html`<${Panel} d=${cur} now=${now} onClose=${() => setSel(null)} />`
				: html`<div class="card panel-ph"><${kit.Empty} text=${_('Select a device to see its traffic and policy.')} /></div>`}
		</div>
		<${kit.ChangesBar} view=${view} />`;
}

return view.extend({
	load: function() {
		return Promise.all([ app.load(), common.loadSchema() ]).then(() =>
			Promise.all([ common.callDevices(), uci.load('truba') ]));
	},

	render: function(data) {
		const store = app.store({ devices: data[0] });
		app.poll(store, () => common.callDevices().then((d) => ({ devices: d })), POLL / 1000);
		return app.mount(this, Page, { store });
	},

	// Политика меняется прямо в браузере: сохранить — отправить эти изменения, сбросить — перечитать страницу.
	handleSave: function() {
		return uci.save().then(() => app.changes.set({ n: app.changeCount() }));
	},

	handleReset: function() {
		window.location.reload();
	}
});
