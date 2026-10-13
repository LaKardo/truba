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
// её итог, пока опрос не принесёт новее. Типа NAT нет: служба его не определяет.
function NatCard({ st }) {
	const { html, useState } = app.lib;
	const [ mine, setMine ] = useState(null), [ busy, setBusy ] = useState(false);
	const run = () => {
		setBusy(true);
		common.runNatTest().then(setMine, (e) => setMine({ time: Date.now() / 1000, error: e.message })).finally(() => setBusy(false));
	};
	const polled = st.nat || null;
	const s = common.natSummary((mine && !(polled?.time > mine.time)) ? mine : polled, common.get('watchdog', 'enabled'));
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
	const up = st.upnp || {}, s = common.upnpState(up), rows = common.upnpRows(up.leases, devices);
	return html`<${kit.Card} cls="upnp" title=${_('UPnP / NAT-PMP')}>
		<${kit.Switch} label=${_('Enable UPnP and NAT-PMP on the tunnel')} opt="truba.main.upnp" checked=${common.get('main', 'upnp')}
			disabled=${!s.installed} onChange=${(on) => app.set('truba', 'main', 'upnp', on ? '1' : '0')} />
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

function FwdCard() {
	const { html } = app.lib;
	return html`<${kit.Card} cls="w3 fwd" title=${_('Port forwards from the tunnel')}>
		<${kit.Go} href=${L.url('admin/network/firewall/forwards')} label=${_('Edit port forwards')} />
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
			<${FwdCard} />
		</div>
		<${kit.ChangesBar} view=${view} />
		<${kit.Toast} />`;
}

return view.extend({
	load: function() {
		return Promise.all([ app.load(), common.loadSchema() ]).then(() => Promise.all([
			common.callStatus(), common.callDevices().catch(() => null), uci.load('truba'), uci.load('firewall'), uci.load('network') ]));
	},

	// Устройства — один раз при открытии: имена в строках и список для выбора; опрос — только status.
	render: function(data) {
		const store = app.store({ status: data[0] });
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
