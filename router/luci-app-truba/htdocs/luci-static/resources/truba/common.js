'use strict';
'require baseclass';
'require rpc';
'require uci';

const callStatus = rpc.declare({ object: 'truba', method: 'status', expect: { '': {} } });
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

function badge(ok, yes, no) {
	return pill(ok ? 'ok' : 'err', ok ? yes : no);
}

// Обновить текст, только если он изменился: без лишних перерисовок.
function setText(el, text) {
	text = (text == null) ? '' : String(text);
	if (el.textContent !== text)
		el.textContent = text;
}

function setClass(el, cls) {
	if (el.className !== cls)
		el.className = cls;
}

// Ближайший запуск ежедневного задания в HH:MM UTC, unix-время; null — время не задано.
function nextDaily(hhmm) {
	const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm || '');
	if (!m)
		return null;
	const now = new Date();
	let t = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), +m[1], +m[2]);
	if (t <= now.getTime())
		t += 86400000;
	return Math.floor(t / 1000);
}

function tunnelIface() {
	return uci.get('truba', 'main', 'iface') || 'awg0';
}

return baseclass.extend({
	callStatus, callCategories, callSets, callCheck, callNatTest, callUpdateLists, callRollbackLists, callLog, callLeases,
	ACTION_LABELS, REASON_LABELS, WARNING_LABELS,
	fmtBytes, fmtRate, fmtAge, fmtTime, fmtDate, fmtNum, pill, badge, setText, setClass, nextDaily, tunnelIface
});
