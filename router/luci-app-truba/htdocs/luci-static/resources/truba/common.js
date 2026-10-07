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
const callUpdateLists = rpc.declare({ object: 'truba', method: 'update_lists', params: [ 'force' ], expect: { '': {} } });
const callRollbackLists = rpc.declare({ object: 'truba', method: 'rollback_lists', expect: { '': {} } });
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
	tunnel_not_configured: _('The tunnel is not configured yet — import the configuration on the Tunnel tab.')
};

// Почему «Проверка NAT» не дала результата (поле error итога).
const NAT_ERRORS = {
	not_configured: _('the tunnel is not configured'),
	tunnel_down: _('the tunnel is down'),
	socket: _('cannot open a socket'),
	no_answer: _('no STUN server answered')
};

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

// Итог проверки одного Набора правил (запись lists.last.sets[…]).
function setResult(s) {
	if (!s)
		return '—';
	return s.ok
		? _('%s (via %s)').format(s.changed ? _('updated') : _('no changes'), s.via)
		: _('failed — %s').format((s.errors || []).join('; ') || '?');
}

function tunnelIface() {
	return uci.get('truba', 'main', 'iface') || 'awg0';
}

return baseclass.extend({
	callStatus, callLists, callCategories, callSets, callCheck, callNatTest, callUpdateLists, callRollbackLists, callLog, callLeases,
	ACTION_LABELS, ACTION_LEVELS, REASON_LABELS, WARNING_LABELS, NAT_ERRORS, UPNP_MISSING, NBSP,
	fmtBytes, fmtRate, fmtAge, fmtTime, fmtDate, fmtNum, pill, busy, empty, missingText,
	setText, setLevel, setResult, tunnelIface
});
