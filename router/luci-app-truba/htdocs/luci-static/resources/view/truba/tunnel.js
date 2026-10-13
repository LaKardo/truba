'use strict';
'require view';
'require uci';
'require truba.common as common';
'require truba.awg as awg';
'require truba.ui.app as app';
'require truba.ui.kit as kit';
'require truba.ui.chart as chart';

// «Туннель» (spec §5.4): состояние Туннеля; подключение к Трубе — импорт router.conf, «Проверка Туннеля»,
// параметры AmneziaWG; что делать, когда Туннель не отвечает. Интерфейс — в стандартной конфигурации
// network, контроль и Аварийная блокировка — в truba. Страница — компоненты Preact в Shadow DOM (ADR 0017).

const POLL = 5;   // состояние — раз в 5 с

// Подсказки полей интерфейса: в схеме службы их нет — это опции network, а не Трубы.
const MTU_HINT = '1380';           // опция network
const KEEPALIVE_HINT = '15-25';    // опция network

// ---- Состояние ----

// Плитки, мини-график задержки по окну проверок watchdog, объём с подъёма интерфейса и чем сейчас идёт
// трафик Туннеля (видно, действует ли Аварийная блокировка).
function StateCard({ st, iface }) {
	const { html } = app.lib;
	const t = st.tunnel || {}, a = t.awg || {}, h = st.health || {};
	const wdOn = common.get('watchdog', 'enabled');
	const [ level, text ] = common.tunnelState(st);
	const on = awg.configured(iface);

	// Итог выключенного watchdog в health.json устарел: пороги — из настроек, вердикта нет.
	const age = a.handshake ? a.handshake_age : null;
	const wd = wdOn ? h : {};
	const max = wd.handshake_max || common.get('watchdog', 'handshake_max');
	const grace = common.get('watchdog', 'fails') * (wd.interval || common.get('watchdog', 'interval'));

	// Окно пустое — проверок ещё не было (или не с чем: нет адреса для ping): не «нет ответа».
	// Длина окна во времени (окно — в truba.const) зависит от интервала проверки.
	const probes = Array.isArray(h.probes) ? h.probes : [];
	const interval = h.interval || common.get('watchdog', 'interval');
	const win = Math.max(1, Math.round((probes.length || common.schema().consts.probe_window) * interval / 60));
	const measured = wdOn && t.up && probes.length > 0;
	const lost = probes.filter((x) => x == null).length;
	const pct = probes.length ? Math.round(lost * 100 / probes.length) : 0;
	const b = h.big;
	const table = (st.table || '').trim();

	return html`<${kit.Card} cls="w3 state" title=${_('State')} aside=${html`<${kit.Badge} level=${level}>${text}</${kit.Badge}>
			<${kit.Switch} label=${_('Tunnel')} opt=${'network.' + iface + '.disabled'} disabled=${!on}
				checked=${on && uci.get('network', iface, 'disabled') != '1'}
				onChange=${(x) => app.set('network', iface, 'disabled', x ? null : '1')} />`}>
		<div class="stats">
			<${kit.Stat} label=${_('Latency')} level=${(measured && h.rtt == null) ? 'err' : ''}
				value=${!measured ? '—' : (h.rtt != null) ? _('%d ms').format(Math.round(h.rtt)) : _('no reply')} />
			<${kit.Stat} label=${_('Handshake')} value=${common.fmtAge(age)} level=${common.handshakeLevel(age, wd.state, max, grace)} />
			<${kit.Stat} label=${_('Loss over %d min').format(win)} value=${measured ? '%d%%'.format(pct) : '—'}
				level=${(!measured || !lost) ? '' : (pct < 20) ? 'warn' : 'err'} />
			<${kit.Stat} label=${_('Full-size packets')} level=${(measured && b) ? (b.ok ? 'ok' : 'err') : ''}
				value=${!measured ? '—' : !b ? _('not checked yet') : b.ok ? _('get through') : _('lost')} />
		</div>
		${measured ? html`<${chart.Spark} values=${probes} height=${70} />`
			: html`<div class="spark-empty"><${kit.Empty} text=${!wdOn ? _('the watchdog is off') : _('no data')} /></div>`}
		<div class="chart-axis"><span>${_('%d min ago').format(win)}</span><span>${_('now')}</span></div>
		${(t.up && b && !b.ok) ? html`<p class="note err-text">${_('Full-size packets do not get through the tunnel: pages open slowly and downloads stall. Lower the tunnel MTU.')}</p>` : ''}
		<${kit.KV} rows=${[
			[ _('Tunnel watchdog'), !wdOn ? _('the watchdog is off') : h.state
				? '%s %s'.format(h.state == 'healthy' ? _('healthy since') : _('down since'), common.fmtTime(h.since)) : _('no data') ],
			[ _('Tunnel route table'), !st.service ? _('service stopped')
				: /blackhole/.test(table) ? _('emergency block (tunnel traffic is dropped)')
				: /default dev/.test(table) ? _('via tunnel') : _('fallback to direct (no tunnel route)') ],
			[ _('Interface traffic'), (a.rx != null)
				? '↓ %s · ↑ %s — %s'.format(common.fmtBytes(a.rx), common.fmtBytes(a.tx), _('since the interface came up, including the router\'s own traffic')) : '—' ]
		]} />
	</${kit.Card}>`;
}

// ---- Проверка Туннеля ----

// Почему проверка не дала результата (поле error итога).
function testError(e) {
	const why = {
		not_configured: common.NAT_ERRORS.not_configured,
		tunnel_down: common.NAT_ERRORS.tunnel_down,
		timeout: common.NAT_ERRORS.timeout,
		no_target: _('no address to ping'),
		tmp: _('no room for temporary files on the router')
	};
	return why[e] || e || _('no answer');
}

// Итог: три размера пакетов до всего MTU и вывод. Не проходят даже мелкие — Труба не отвечает вовсе
// (MTU ни при чём); мелкие проходят, крупные нет — путь не пропускает полноразмерные пакеты.
function TestResult({ r }) {
	const { html } = app.lib;
	if (!r || r.error)
		return html`<div class="tt-res"><p class="err-text">${_('Not checked: %s').format(testError(r?.error))}</p></div>`;
	const res = r.results || [], small = res[0];
	const [ lv, head, note ] = r.ok ? [ 'ok', _('Full-size packets get through'), _('MTU %d suits the path to the Truba.').format(r.mtu) ]
		: (small && !small.ok) ? [ 'err', _('No replies'), _('The Truba does not answer inside the tunnel: see the State above.') ]
		: [ 'err', _('Packets are lost'), _('If only the largest packets are lost, lower the MTU here and in install-vps.sh on the VPS.') ];
	return html`<div class="tt-res">
		<table>
			<tr><th>${_('Packet size')}</th><th>${_('Replies')}</th><th>${_('Latency')}</th></tr>
			${res.map((x) => html`<tr>
				<td>${((x.size == r.mtu) ? _('%d bytes — the whole MTU') : _('%d bytes')).format(x.size)}</td>
				<td><${kit.Dot} level=${x.ok ? 'ok' : 'err'} /> ${_('%d of %d').format(x.received, x.sent)}</td>
				<td class="num">${(x.avg != null) ? _('%d ms').format(Math.round(x.avg)) : '—'}</td>
			</tr>`)}
		</table>
		<div class="verdict"><${kit.Badge} level=${lv}>${head}</${kit.Badge}><span class="mu">${note}</span></div>
	</div>`;
}

// ---- Подключение к Трубе ----

const label = (k) => k[0].toUpperCase() + k.slice(1);   // jmin → Jmin, s1 → S1

// Параметры AmneziaWG с прежними проверками; ключ защиты заголовков и флаги AWG 3.1 приходят с router.conf —
// здесь они видны, потому что от них зависят проверки S1–S4 и добавки к пакетам.
function AwgParams({ iface }) {
	const { html } = app.lib;
	const field = (k, hint, cls) => html`<div class=${cls || ''}><${kit.Field} config="network" sec=${iface} name=${'awg_' + k}
		label=${(k == 'content_padding_addition') ? _('Content padding') : label(k)} hint=${hint}
		check=${(v) => awg.paramError(iface, k, v)} /></div>`;
	const flag = (o) => (uci.get('network', iface, o) == '1') ? _('on') : _('off');
	return html`<${kit.Fold} title=${_('AmneziaWG parameters')}>
		<div class="fields">${awg.NUM_PARAMS.map((k) => field(k))}</div>
		<p class="mu">${_('H1–H4: a number or a range «from-to»; must match the Truba.')}</p>
		<div class="fields">
			${awg.CPS_PARAMS.map((k) => field(k, (k == 'i1') ? _('Decoy packets before the handshake (CPS format); may differ from the Truba.') : null, 'wide'))}
			${field('content_padding_addition', _('AmneziaWG 3.1: random bytes added to data packets instead of padding to a multiple of 16, so packet lengths do not share one remainder; a range «from-to». May differ from the Truba; comes with router.conf.'), 'wide')}
		</div>
		<${kit.KV} rows=${[
			[ _('Header protection key'), uci.get('network', iface, 'awg_header_protection_key') ? _('set') : _('not set') ],
			[ _('Random trailers'), flag('awg_random_trailers') ],
			[ _('Disable cookies'), flag('awg_disable_cookies') ]
		]} />
		<${kit.Go} href=${L.url('admin/network/network')} label=${_('Other interface settings')} />
	</${kit.Fold}>`;
}

// Адрес и порт Трубы, протокол, MTU и Keepalive, «Проверить Туннель», импорт router.conf и параметры AWG.
// Импорт меняет UCI браузера, а применяет его панель изменений; после него карточка монтируется заново
// (onImport меняет её key), и поля читают новые значения.
function ConnCard({ iface, onImport }) {
	const { html, useState } = app.lib;
	const [ err, setErr ] = useState(null), [ tt, setTt ] = useState(null), [ busy, setBusy ] = useState(false);
	const ok = awg.configured(iface), peer = awg.peerSection(iface);

	const run = () => {
		setBusy(true);
		common.runTunnelTest().then(setTt, (e) => setTt({ error: e.message })).finally(() => setBusy(false));
	};
	const imp = (text) => {
		let conf;
		try {
			conf = awg.parseConf(text);
		}
		catch (e) {
			setErr(e.message);
			return;
		}
		awg.applyConf(iface, conf, common.schema().consts.fw_zone);
		app.changes.set({ n: app.changeCount() });
		app.toast(_('router.conf imported: apply the changes to use it.'));
		onImport();
	};

	const zone = html`<${kit.DropZone} label=${_('Drop router.conf here or choose the file')} accept=".conf,text/plain"
		placeholder=${_('…or paste its text')} error=${err} onText=${imp} />`;
	const aside = html`<button type="button" class="btn" data-act="tunnel-test" disabled=${!ok || busy} onClick=${run}>${_('Check the tunnel')}</button>`;
	if (!ok)
		return html`<${kit.Card} cls="peer" title=${_('Connection to the Truba')} aside=${aside}>
			<p class="note"><b>${_('The tunnel is not configured yet. Run install-vps.sh on the VPS and import the resulting router.conf.')}</b></p>
			${zone}
		</${kit.Card}>`;

	const host = peer ? uci.get('network', peer, 'endpoint_host') : null, port = peer ? uci.get('network', peer, 'endpoint_port') : null;
	const ver = awg.version(iface);
	const rows = [ [ _('Address'), host ? ((/:/.test(host) ? '[' + host + ']' : host) + (port ? ':' + port : '')) : '—' ] ];
	if (ver)
		rows.push([ _('Protocol'), 'AmneziaWG ' + ver ]);
	return html`<${kit.Card} cls="peer" title=${_('Connection to the Truba')} aside=${aside}>
		<${kit.KV} rows=${rows} />
		<div class="cols conn-f">
			<${kit.Field} config="network" sec=${iface} name="mtu" label=${_('MTU')} check=${awg.mtuError} placeholder=${MTU_HINT}
				hint=${_('install-vps.sh picks it for the VPS network. If full-size packets do not get through (see State above), lower it on both sides.')} />
			${peer ? html`<${kit.Field} config="network" sid=${peer} name="persistent_keepalive" label=${_('Keepalive, s')}
				check=${(v) => awg.rangeError(v, 65535)} placeholder=${KEEPALIVE_HINT}
				hint=${_('Keeps the provider NAT mapping open so inbound connections via the Truba IP reach the router. A range «from-to» (AmneziaWG 3.1) gives a random period, so an idle tunnel has no steady rhythm.')} />` : ''}
		</div>
		${busy ? html`<${kit.Busy} text=${_('Checking… about 5 seconds')} />` : tt ? html`<${TestResult} r=${tt} />`
			: html`<p class="mu tt-hint">${_('Pings the Truba inside the tunnel with packets of three sizes, up to the whole tunnel MTU. Shows loss of large packets that a normal ping does not see: with it pages open slowly and downloads stall.')}</p>`}
		<p class="mu">${_('Keys and parameters come from router.conf made by install-vps.sh on the VPS. To replace them, import a new file.')}</p>
		${zone}
		<${AwgParams} iface=${iface} />
	</${kit.Card}>`;
}

// ---- Если Туннель не отвечает ----

// Контроль Туннеля (секция watchdog) и Аварийная блокировка (main) — рядом с тем, как это определяется.
// Пока контроль выключен, его поля недоступны.
function WatchdogCard() {
	const { html } = app.lib;
	const on = common.get('watchdog', 'enabled');
	return html`<${kit.Card} cls="wd" title=${_('If the tunnel does not respond')}
			aside=${html`<${kit.Switch} label=${_('Watchdog')} opt="truba.watchdog.enabled" checked=${on}
				onChange=${(x) => app.set('truba', 'watchdog', 'enabled', x ? '1' : '0')} />`}>
		<p class="mu">${_('Pings the Truba inside the tunnel and checks the handshake age; restarts the interface after repeated failures. Every tenth check also makes sure that full-size packets get through.')}</p>
		<div class="cols">
			<${kit.Field} sec="watchdog" name="interval" label=${_('Check interval, s')} disabled=${!on} />
			<${kit.Field} sec="watchdog" name="handshake_max" label=${_('Max handshake age, s')} disabled=${!on} />
			<${kit.Field} sec="watchdog" name="fails" label=${_('Failures before restart')} disabled=${!on} />
			<${kit.Field} sec="watchdog" name="probe" label=${_('Ping target')} disabled=${!on}
				hint=${_('Empty — the Truba address inside the tunnel. An internet address would not answer while the emergency block is active.')} />
		</div>
		<div class="ks">
			<${kit.Switch} label=${_('Emergency block')} opt="truba.main.killswitch" checked=${common.get('main', 'killswitch')}
				onChange=${(x) => app.set('truba', 'main', 'killswitch', x ? '1' : '0')} />
			<p class="mu">${_('While the tunnel is down, traffic with action Tunnel is dropped instead of going direct.')}</p>
		</div>
	</${kit.Card}>`;
}

function Page({ store, view, iface }) {
	const { html, useState } = app.lib;
	const { status, offline } = app.use(store);
	app.use(app.changes);   // карточки читают UCI браузера — перерисовка после app.set
	const [ gen, setGen ] = useState(0);
	return html`
		<div class="head">
			<h2>${_('Tunnel')}</h2>
			<span class="mu">${_('AmneziaWG interface %s. Settings are stored in the standard network configuration and are also visible in Network → Interfaces.').format(iface)}</span>
			${offline ? html`<${kit.Badge} level="err"><${kit.Icon} name="wifi-off" />${_('No connection to the router')}</${kit.Badge}>` : ''}
		</div>
		<div class="grid g2">
			<${StateCard} st=${status || {}} iface=${iface} />
			<${ConnCard} key=${gen} iface=${iface} onImport=${() => setGen((g) => g + 1)} />
			<${WatchdogCard} />
		</div>
		<${kit.ChangesBar} view=${view} />
		<${kit.Toast} />`;
}

return view.extend({
	load: function() {
		return Promise.all([ app.load(), common.loadSchema() ]).then(() => Promise.all([
			common.callStatus().catch(() => null), uci.load('truba'), uci.load('network'), uci.load('firewall') ]));
	},

	render: function(data) {
		const store = app.store({ status: data[0], offline: data[0] == null });
		app.poll(store, () => common.callStatus().then((s) => ({ status: s })), POLL);
		return app.mount(this, Page, { store, iface: common.tunnelIface() });
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
