'use strict';
'require baseclass';
'require rpc';
'require uci';

const callStatus = rpc.declare({ object: 'truba', method: 'status', expect: { '': {} } });
const callLists = rpc.declare({ object: 'truba', method: 'lists', expect: { '': {} } });
const callCategories = rpc.declare({ object: 'truba', method: 'categories', expect: { '': {} } });
const callSets = rpc.declare({ object: 'truba', method: 'sets', expect: { '': {} } });
const callCheck = rpc.declare({ object: 'truba', method: 'check', params: [ 'target', 'mac' ], expect: { '': {} } });
const callNatTest = rpc.declare({ object: 'truba', method: 'nat_test', expect: { '': {} } });
const callNatResult = rpc.declare({ object: 'truba', method: 'nat_result', expect: { '': {} } });
const callTunnelTest = rpc.declare({ object: 'truba', method: 'tunnel_test', expect: { '': {} } });
const callTunnelResult = rpc.declare({ object: 'truba', method: 'tunnel_result', expect: { '': {} } });
const callUpdateLists = rpc.declare({ object: 'truba', method: 'update_lists', params: [ 'force' ], expect: { '': {} } });
const callRollbackLists = rpc.declare({ object: 'truba', method: 'rollback_lists', expect: { '': {} } });
// История скорости с Роутера (её пишет процесс truba stats): точки новее since за span секунд.
const callRates = rpc.declare({ object: 'truba', method: 'rates', params: [ 'span', 'since' ], expect: { '': {} } });
const callLog = rpc.declare({ object: 'truba', method: 'log', params: [ 'lines' ], expect: { log: '' } });
const callLeases = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} } });

// Общие стили — один раз на страницу; ?v= — как у модулей LuCI.
if (!document.querySelector('link[data-truba]'))
	document.head.appendChild(E('link', {
		'rel': 'stylesheet', 'data-truba': '',
		'href': L.resource('truba/truba.css') + (L.env.resource_version ? '?v=' + L.env.resource_version : '')
	}));

const ACTION_LABELS = {
	mode: _('By mode'),
	direct: _('Direct'),
	tunnel: _('Tunnel'),
	block: _('Block')
};

// Цвет Действия — один на всех вкладках: значки, точки, график.
const ACTION_LEVELS = { tunnel: 'info', direct: 'ok', block: 'err' };

const REASON_LABELS = {
	local: _('local network or the Truba itself — never routed'),
	geoip_block: _('geoip category with action Block'),
	device: _('device policy'),
	geosite: _('geosite category'),
	geosite_ip: _('IP was resolved for a geosite category'),
	geosite_block: _('geosite category with action Block (DNS answers NXDOMAIN)'),
	shared_ip: _('shared CDN address: Tunnel wins over Direct'),
	geoip: _('geoip category'),
	mode: _('no category matched — the mode default applies')
};

const WARNING_LABELS = {
	lists_missing: _('Rule sets are not downloaded yet — only the mode default applies. Download is in progress.'),
	zones_without_devices: _('The selected firewall zones have no active devices.'),
	tunnel_not_configured: _('The tunnel is not configured yet — import the configuration on the Tunnel tab.'),
	lists_rolled_back: _('The current rule sets could not be read, so the previous ones were restored.')
};

// Почему «Проверка NAT» не дала результата (поле error итога).
const NAT_ERRORS = {
	not_configured: _('the tunnel is not configured'),
	tunnel_down: _('the tunnel is down'),
	socket: _('cannot open a socket'),
	no_answer: _('no STUN server answered'),
	timeout: _('no result in time')
};

// Неверные значения настроек, которые служба пропустила (applied.invalid), — вкладка, где их исправить.
const INVALID_TABS = { device: 'routing', dns: 'dns', lists: 'dns', watchdog: 'tunnel', main: 'tunnel' };

function invalidTab(list) {
	return INVALID_TABS[String(list[0]?.key || '').split('.')[0]] || 'routing';
}

// Долгая проверка (NAT, Туннель): rpcd запускает её в фоне и отвечает сразу, а итог —
// первый, у которого время не раньше запуска. limit — сколько секунд ждать.
function runInBackground(start, result, limit) {
	return start().then((s) => {
		const since = s.started || 0, until = Date.now() + limit * 1000;
		const wait = () => new Promise((resolve) => setTimeout(resolve, 1000)).then(() => result()).then((r) =>
			(r && r.time >= since) ? r : (Date.now() < until) ? wait() : { time: Date.now() / 1000, error: 'timeout' });
		return wait();
	});
}

function runNatTest() {
	return runInBackground(callNatTest, callNatResult, 20);
}

function runTunnelTest() {
	return runInBackground(callTunnelTest, callTunnelResult, 30);
}

// Тексты, которые показывают несколько вкладок.
const UPNP_MISSING = _('UPnP is enabled, but miniupnpd is not installed: install luci-app-upnp.');

function missingText(list) {
	return _('Configured but missing from the current rule set (ignored): %s').format(list.join(', '));
}

function fmtBytes(n) {
	n = +n || 0;
	const u = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	let i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return '%.1f %s'.format(n, u[i]);
}

// Байт/с → бит/с в десятичных единицах, как у провайдеров.
function fmtRate(bps) {
	let n = (+bps || 0) * 8;
	const u = [ _('bit/s'), _('kbit/s'), _('Mbit/s'), _('Gbit/s') ];
	let i = 0;
	while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
	return '%.1f %s'.format(n, u[i]);
}

function fmtAge(sec) {
	if (sec == null)
		return _('never');
	if (sec < 60)
		return _('%d s ago').format(sec);
	if (sec < 3600)
		return _('%d min ago').format(Math.floor(sec / 60));
	return _('%d h ago').format(Math.floor(sec / 3600));
}

function fmtTime(ts) {
	return ts ? new Date(ts * 1000).toLocaleString() : '—';
}

function fmtDate(ts) {
	return ts ? new Date(ts * 1000).toLocaleDateString() : '—';
}

// Целое с разделителями разрядов: 14 296.
function fmtNum(n) {
	return (+n || 0).toLocaleString();
}

// Значок состояния. level: ok / warn / err / info или '' (нейтральный).
function pill(level, text) {
	return E('span', { 'class': 'truba-badge ' + (level || '') }, text);
}

// Идёт загрузка или проверка.
function busy(text) {
	return E('em', { 'class': 'spinning' }, text);
}

// Пустой список или нет данных.
function empty(text) {
	return E('em', { 'class': 'truba-muted' }, text);
}

// Обновить текст, только если он изменился: без лишних перерисовок.
function setText(el, text) {
	text = (text == null) ? '' : String(text);
	if (el.textContent !== text)
		el.textContent = text;
}

// Уровень значка, точки или сводки (ok / warn / err / info, '' — нейтральный): меняются только
// классы уровня, остальные классы элемента остаются.
const LEVELS = [ 'ok', 'warn', 'err', 'info' ];
function setLevel(el, level) {
	for (let l of LEVELS)
		el.classList.toggle(l, l == level);
}

// Неразрывный пробел: пустая строка ячейки сохраняет высоту.
const NBSP = String.fromCharCode(160);

// Откуда скачан Набор правил и почему не скачался: бэкенд пишет «tunnel», «direct»,
// «mirror» и ошибки вида «tunnel: download failed».
const VIA_LABELS = { tunnel: _('via the tunnel'), direct: _('directly'), mirror: _('from the mirror') };
const SET_ERRORS = { 'download failed': _('download failed'), 'sha256 mismatch': _('checksum mismatch'),
	'parse failed': _('the file cannot be read, the current one is kept') };
function setError(e) {
	const m = String(e).match(/^(\w+): (.+)$/);
	return m ? '%s: %s'.format(VIA_LABELS[m[1]] || m[1], SET_ERRORS[m[2]] || m[2]) : String(e);
}

// Итог проверки одного Набора правил (запись lists.last.sets[…]).
function setResult(s) {
	if (!s)
		return '—';
	return s.ok
		? '%s, %s'.format(s.changed ? _('updated') : _('no changes'), VIA_LABELS[s.via] || s.via)
		: _('failed — %s').format((s.errors || []).map(setError).join('; ') || '?');
}

function tunnelIface() {
	return uci.get('truba', 'main', 'iface') || 'awg0';
}

// Состояние Туннеля по status: [уровень, текст] — для плитки «Обзора» и вкладки «Туннель».
function tunnelState(st) {
	const t = st.tunnel || {}, h = st.health || {};
	if (!st.service)
		return [ 'err', _('service stopped') ];
	if (!t.configured)
		return [ 'warn', _('not configured') ];
	if (t.disabled)
		return [ 'warn', _('disabled') ];
	if (!t.up)
		return [ 'err', _('down') ];
	if (h.state == 'down')
		return [ 'err', _('not responding') ];
	return [ 'ok', _('working') ];
}

// Вкладки Трубы: адрес и название — для ссылок из плиток и предупреждений «Обзора».
const TABS = {
	tunnel: _('Tunnel'),
	routing: _('Routing'),
	dns: _('DNS & lists'),
	inbound: _('Inbound'),
	diagnostics: _('Diagnostics')
};
function tabUrl(tab) {
	return L.url('admin/services/truba/' + tab);
}

return baseclass.extend({
	callStatus, callLists, callCategories, callSets, callCheck, callUpdateLists, callRollbackLists, callRates, callLog, callLeases,
	runNatTest, runTunnelTest,
	ACTION_LABELS, ACTION_LEVELS, REASON_LABELS, WARNING_LABELS, NAT_ERRORS, UPNP_MISSING, NBSP, TABS,
	fmtBytes, fmtRate, fmtAge, fmtTime, fmtDate, fmtNum, pill, busy, empty, missingText,
	setText, setLevel, setResult, setError, tunnelIface, tunnelState, tabUrl, invalidTab
});
