'use strict';
'require view';
'require uci';
'require truba.common as common';
'require truba.ui.app as app';
'require truba.ui.kit as kit';

// «Входящие» (spec §5.6): «Проверка NAT», UPnP / NAT-PMP и пробросы портов из Туннеля. Трафик входящих —
// на «Обзоре», здесь он не повторяется. Страница — компоненты Preact в Shadow DOM (ADR 0017).

const POLL = 10;   // итог проверки NAT появляется сам через несколько секунд после подъёма Туннеля

// ---- Проверка NAT ----

// Итог — последняя проверка из status (её запускает и watchdog после подъёма Туннеля); своя проверка —
// её итог, пока опрос не принесёт другой (common.natPick). Типа NAT нет: служба его не определяет.
function NatCard({ st }) {
	const { html, useState } = app.lib;
	const [ mine, setMine ] = useState(null), [ busy, setBusy ] = useState(false);
	const run = () => {
		const base = st.nat?.time ?? null;
		setBusy(true);
		common.runNatTest().then((n) => setMine({ n, base }), (e) => setMine({ n: { time: Date.now() / 1000, error: e.message }, base }))
			.finally(() => setBusy(false));
	};
	const s = common.natSummary(common.natPick(st.nat, mine), common.get('watchdog', 'enabled'));
	const aside = html`${busy ? html`<${kit.Busy} text=${_('Testing…')} />` : html`<${kit.Badge} level=${s.level}>${s.text}</${kit.Badge}>`}
		<button type="button" class="btn" data-act="nat-test" disabled=${busy} onClick=${run}>${_('Check NAT')}</button>`;
	return html`<${kit.Card} cls="nat" title=${_('NAT check')} aside=${aside}>
		<${kit.KV} rows=${s.rows.map(([ k, v, lv ]) => [ k, lv ? html`<${kit.Dot} level=${lv} /> ${v}` : v ])} />
		<p class="mu">${'%s: %s'.format(_('Checked'), s.when)}</p>
		<${kit.Fold} title=${_('STUN servers')}>
			${s.servers.length ? html`<ul class="nat-srv">${s.servers.map((x) => html`<li class="num">${x}</li>`)}</ul>` : html`<${kit.Empty} text=${_('none')} />`}
		</${kit.Fold}>
		<p class="mu">${_('This checks the Truba layer only. For the full RFC 5780 test run NatTypeTester on a PC in the home network whose device policy is «All via tunnel».')}</p>
	</${kit.Card}>`;
}

// ---- UPnP / NAT-PMP ----

function UpnpCard({ st, devices }) {
	const { html } = app.lib;
	const on = common.get('main', 'upnp'), up = st.upnp || {}, s = common.upnpState(up, on), rows = common.upnpRows(up.leases, devices);
	return html`<${kit.Card} cls="upnp" title=${_('UPnP / NAT-PMP')}>
		<${kit.Switch} label=${_('Enable UPnP and NAT-PMP on the tunnel')} opt="truba.main.upnp" checked=${on}
			disabled=${s.locked} onChange=${(on) => app.set('truba', 'main', 'upnp', on ? '1' : '0')} />
		<p class="mu">${s.installed ? _('Devices open ports themselves; miniupnpd reports the Truba IP as the external address.')
			: _('Package luci-app-upnp is not installed.')}</p>
		${s.note ? html`<ul class="warns"><li><${kit.Dot} level="warn" /><span>${s.note}</span></li></ul>` : ''}
		<h4 class="sub">${_('Active UPnP / NAT-PMP mappings')}</h4>
		${rows.length ? html`<ul class="upnp-rows">${rows.map((r) => html`<li>
			<b>${r.descr}</b><span>${r.who}</span><span class="num">${'%s %s → %s'.format(r.proto, r.ext, r.port)}</span><span class="mu">${r.expires}</span>
		</li>`)}</ul>` : html`<${kit.Empty} text=${_('No active mappings.')} />`}
	</${kit.Card}>`;
}

// ---- Пробросы портов из Туннеля ----

const PROTOS = { 'tcp udp': 'TCP+UDP', tcp: 'TCP', udp: 'UDP' };
const OTHER = 'other';   // «Другой IP-адрес…» в выборе устройства

// Устройства с IP для выбора: сначала с именем — по имени, затем по IP.
function devChoices(devices) {
	const num = (ip) => ip.split('.').reduce((n, x) => n * 256 + +x, 0);
	return devices.filter((d) => d.ip).sort((a, b) => (!a.name - !b.name) || String(a.name || '').localeCompare(String(b.name || '')) || num(a.ip) - num(b.ip));
}

// Окно правки проброса (решения 2–6 плана этапа 6). Пишутся только опции, которые есть в окне; остальные
// (src_ip, reflection и другие из «Межсетевого экрана») остаются. Протокол того же смысла и зона при том же
// IP — как в настройках. У нового проброса ошибка поля видна после ухода из него, у сохранённого — сразу:
// неверное значение из настроек иначе держало бы «Save» без видимой причины. «Save» недоступна сразу.
function FwdDialog({ row, devices, onClose, onDeleted }) {
	const { html, useState } = app.lib;
	const choices = devChoices(devices);
	const [ v, setV ] = useState(() => row
		? { name: row.name, proto: row.proto, ext: row.ext, port: uci.get('firewall', row.sid, 'dest_port') || '',
			dev: choices.some((d) => d.ip == row.ip) ? row.ip : row.ip ? OTHER : '', ip: row.ip }
		: { name: '', proto: 'tcp udp', ext: '', port: '', dev: '', ip: '' });
	const [ touched, setTouched ] = useState(() => row ? { name: true, proto: true, ext: true, dev: true, ip: true, port: true } : {});
	const ip = (v.dev == OTHER) ? v.ip : v.dev;
	const errs = common.forwardErrors({ sid: row?.sid || null, name: v.name, proto: v.proto, ext: v.ext, ip, port: v.port });
	const shown = {
		ext: touched.ext && errs.ext,
		dev: touched.dev && v.dev != OTHER && errs.ip && _('Choose a device'),
		ip: touched.ip && v.dev == OTHER && errs.ip,
		port: touched.port && errs.port
	};
	const set = (k) => (ev) => setV((s) => ({ ...s, [k]: ev.target.value }));
	const touch = (k) => () => setTouched((t) => t[k] ? t : { ...t, [k]: true });

	const save = () => {
		const vals = common.forwardValues({ ...v, ip }, devices, row?.sid);
		let sid = row?.sid;
		if (!sid) {
			sid = app.add('firewall', 'redirect');
			app.set('firewall', sid, 'src', common.schema().consts.fw_zone);
			app.set('firewall', sid, 'target', 'DNAT');
		}
		for (let k in vals)
			app.set('firewall', sid, k, vals[k]);
	};
	const del = (ev) => {
		app.remove('firewall', row.sid);
		ev.currentTarget.closest('dialog')?.close();
		onDeleted();
	};

	// Поле окна: подпись, элемент, ошибка и подсказка — как у kit.Field.
	const field = (k, label, control, hint) => html`<div class=${'field' + (shown[k] ? ' bad' : '')}>
		<label for=${'fwd-' + k}>${label}</label>
		${control({ id: 'fwd-' + k, 'data-f': k, 'aria-invalid': shown[k] ? 'true' : undefined, 'aria-describedby': shown[k] ? 'fwd-' + k + '-e' : undefined,
			onBlur: touch(k) })}
		${shown[k] ? html`<div class="err-text" id=${'fwd-' + k + '-e'} role="alert">${shown[k]}</div>` : ''}
		${hint ? html`<div class="mu">${hint}</div>` : ''}
	</div>`;
	const input = (k, extra) => (a) => html`<input ...${a} autocomplete="off" value=${v[k]} onInput=${set(k)} ...${extra || {}} />`;
	const protos = PROTOS[v.proto] ? Object.entries(PROTOS) : [ ...Object.entries(PROTOS), [ v.proto, v.proto ] ];

	return html`<${kit.Dialog} open=${true} title=${row ? _('Port forward') : _('New port forward')} confirm=${_('Save')}
		disabled=${Object.keys(errs).length > 0} onConfirm=${save} onClose=${onClose}>
		<div class="fwd-form">
			${field('name', _('Name'), input('name'))}
			<div class="cols">
				${field('proto', _('Protocol'), (a) => html`<select ...${a} value=${v.proto} onChange=${set('proto')}>
					${protos.map(([ x, l ]) => html`<option value=${x} selected=${x == v.proto}>${l}</option>`)}
				</select>`)}
				${field('ext', _('External port'), input('ext', { placeholder: '8080' }), _('A port or a range «from-to»'))}
			</div>
			${field('dev', _('Device'), (a) => html`<select ...${a} value=${v.dev} onChange=${(ev) => { set('dev')(ev); touch('dev')(); }}>
				<option value="" disabled selected=${v.dev == ''}>${_('Choose a device')}</option>
				${choices.map((d) => html`<option value=${d.ip} selected=${d.ip == v.dev}>${d.name ? '%s (%s)'.format(d.name, d.ip) : d.ip}</option>`)}
				<option value=${OTHER} selected=${v.dev == OTHER}>${_('Other IP address…')}</option>
			</select>`)}
			${(v.dev == OTHER) ? field('ip', _('IP address'), input('ip', { inputmode: 'decimal', placeholder: '192.168.1.10' })) : ''}
			${field('port', _('Internal port'), input('port'), _('Empty — the same as external'))}
			${row ? html`<div><button type="button" class="btn del" data-act="fwd-delete" onClick=${del}>${_('Delete')}</button></div>` : ''}
		</div>
	</${kit.Dialog}>`;
}

// Пробросы из Туннеля: строка — имя, протокол, внешний порт → устройство:внутренний порт и переключатель.
// Выключение — enabled '0', включение — опция снимается (или '1', если так было в настройках): туда и обратно —
// ноль изменений. Нажатие на строку — окно правки.
function FwdCard({ devices }) {
	const { html, useState, useRef } = app.lib;
	const addRef = useRef(null);
	const [ edit, setEdit ] = useState(null);   // { row, n } открытого окна: row null — новый проброс
	const rows = common.forwardRows(devices);
	const open = (row) => setEdit((e) => ({ row, n: (e?.n || 0) + 1 }));
	const toggle = (sid, on) => app.set('firewall', sid, 'enabled', common.fwEnabled(uci.state?.values?.firewall?.[sid]?.enabled, on));
	// Строки, открывшей окно, после «Delete» нет — фокус на «Add», а не на странице (после перерисовки).
	const deleted = () => requestAnimationFrame(() => addRef.current?.focus());
	const aside = html`<button type="button" class="btn" data-act="fwd-add" ref=${addRef} onClick=${() => open(null)}><${kit.Icon} name="plus" />${_('Add')}</button>`;
	return html`<${kit.Card} cls="w3 fwd" title=${_('Port forwards from the tunnel')} aside=${aside}>
		${rows.length ? html`<ul class="fwd-rows">${rows.map((r) => html`<li data-sid=${r.sid} class=${r.on ? '' : 'off'}>
			<button type="button" class="fwd-b" data-act="fwd-edit" onClick=${() => open(r)}>
				<b>${r.name || '—'}${app.pending('firewall', r.sid) ? html` <${kit.Dot} level="warn" label=${_('changed, not applied yet')} />` : ''}</b>
				<span class="num">${'%s %s → %s:%s'.format(PROTOS[r.proto] || r.proto, r.ext, r.who || '?', r.port)}</span>
			</button>
			<${kit.Switch} label=${_('Enabled')} aria=${'%s: %s'.format(r.name || '%s %s'.format(PROTOS[r.proto] || r.proto, r.ext), _('Enabled'))}
				opt=${'firewall.' + r.sid + '.enabled'} dot=${false} checked=${r.on} onChange=${(on) => toggle(r.sid, on)} />
		</li>`)}</ul>` : html`<${kit.Empty} text=${_('No port forwards from the tunnel yet.')} />`}
		<div><${kit.Go} href=${L.url('admin/network/firewall/forwards')} label=${_('More options: Network → Firewall')} /></div>
		${edit ? html`<${FwdDialog} key=${edit.n} row=${edit.row} devices=${devices} onClose=${() => setEdit(null)} onDeleted=${deleted} />` : ''}
	</${kit.Card}>`;
}

function Page({ store, view, devices }) {
	const { html } = app.lib;
	const { status, offline } = app.use(store);
	app.use(app.changes);   // карточки читают UCI браузера — перерисовка после app.set
	const st = status || {};
	return html`
		<div class="head">
			<h2>${_('Inbound')}</h2>
			<span class="mu">${_('All ports of the Truba IP %s (except the VPS SSH and tunnel ports) reach the router. Full cone NAT keeps mappings open for any remote host; ports for home devices are opened manually or via UPnP.').format(st.vps_ip || '—')}
				${' '}${_('Replies always go back through the tunnel, even to Russian clients.')}
				${' '}<${kit.Go} tab="overview" label=${_('Inbound traffic is on the Overview.')} /></span>
			${offline ? html`<${kit.Badge} level="err"><${kit.Icon} name="wifi-off" />${_('No connection to the router')}</${kit.Badge}>` : ''}
		</div>
		<div class="grid g2">
			<${NatCard} st=${st} />
			<${UpnpCard} st=${st} devices=${devices} />
			<${FwdCard} devices=${devices} />
		</div>
		<${kit.ChangesBar} view=${view} />
		<${kit.Toast} />`;
}

return view.extend({
	load: function() {
		return Promise.all([ app.load(), common.loadSchema() ]).then(() => Promise.all([
			common.callStatus().catch(() => null), common.callDevices().catch(() => null), uci.load('truba'), uci.load('firewall'), uci.load('network') ]));
	},

	// Устройства — один раз при открытии: имена в строках и список для выбора; опрос — только status.
	render: function(data) {
		const store = app.store({ status: data[0], offline: data[0] == null });
		app.poll(store, () => common.callStatus().then((s) => ({ status: s })), POLL);
		return app.mount(this, Page, { store, devices: data[1]?.devices || [] });
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
