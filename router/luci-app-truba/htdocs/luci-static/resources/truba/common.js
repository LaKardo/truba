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
const callSchema = rpc.declare({ object: 'truba', method: 'schema', expect: { '': {} } });
// Устройства с трафиком и Политиками; куда устройство ходит сейчас (ADR 0018).
const callDevices = rpc.declare({ object: 'truba', method: 'devices', expect: { '': {} } });
const callConnections = rpc.declare({ object: 'truba', method: 'connections', params: [ 'ip' ], expect: { '': {} } });

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
	mode: _('no category matched — the mode default applies'),
	changed: _('decided before the settings changed')
};

// Предупреждения службы (applied.warnings): текст и вкладка, где их исправляют.
const WARNINGS = {
	lists_missing: { tab: 'dns', text: _('Rule sets are not downloaded yet — only the mode default applies. Download is in progress.') },
	zones_without_devices: { tab: 'routing', text: _('The selected firewall zones have no active devices.') },
	tunnel_not_configured: { tab: 'tunnel', text: _('The tunnel is not configured yet — import the configuration on the Tunnel tab.') },
	lists_rolled_back: { tab: 'dns', text: _('The current rule sets could not be read, so the previous ones were restored.') }
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
const INVALID_TABS = { device: 'devices', dns: 'dns', lists: 'dns', watchdog: 'tunnel', main: 'tunnel' };

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

// Число в наибольших единицах, где оно не меньше 1: каждая следующая — в base раз больше.
function scaled(n, base, units) {
	let i = 0;
	while (n >= base && i < units.length - 1) { n /= base; i++; }
	return '%.1f %s'.format(n, units[i]);
}

const BYTE_UNITS = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
const RATE_UNITS = [ _('bit/s'), _('kbit/s'), _('Mbit/s'), _('Gbit/s') ];

function fmtBytes(n) {
	return scaled(+n || 0, 1024, BYTE_UNITS);
}

// Байт/с → бит/с в десятичных единицах, как у провайдеров.
function fmtRate(bps) {
	return scaled((+bps || 0) * 8, 1000, RATE_UNITS);
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

// ---- Элементы страниц ----

// Значок состояния. level: ok / warn / err / info или '' (нейтральный).
function pill(level, text) {
	return E('span', { 'class': 'truba-badge ' + (level || '') }, text);
}

// Пустой span под значение, которое опрос потом обновляет.
function span(cls) {
	return E('span', cls ? { 'class': cls } : {});
}

const SVGNS = 'http://www.w3.org/2000/svg';
function svgEl(tag, attrs) {
	const el = document.createElementNS(SVGNS, tag);
	for (let k in attrs)
		el.setAttribute(k, attrs[k]);
	return el;
}

// Таблица «название — значение»: rows — [ [ название, значение ], … ].
function kvTable(rows) {
	return E('table', { 'class': 'truba-kv' }, rows.map(([ label, value ]) =>
		E('tr', {}, [ E('th', { 'scope': 'row' }, label), E('td', {}, value) ])));
}

// Таблица LuCI: заголовки колонок и строки из row().
function table(headers, rows) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, headers.map((h) => E('th', { 'class': 'th' }, h))),
		...rows
	]);
}

// Строка таблицы LuCI: ячейки и, если нужно, свои атрибуты строки.
function row(cells, attrs) {
	return E('tr', { 'class': 'tr', ...attrs }, cells.map((c) => E('td', { 'class': 'td' }, c)));
}

// Кнопки-фильтры, нажата одна: items — [ [ значение, содержимое кнопки ], … ].
function chips(items, initial, onSelect) {
	const buttons = items.map(([ value, content ], k) => E('button', {
		'class': 'truba-chip', 'type': 'button', 'aria-pressed': String(value == initial),
		'click': () => {
			buttons.forEach((b, j) => b.setAttribute('aria-pressed', String(j == k)));
			onSelect(value);
		}
	}, content));
	return buttons;
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

// Значок или точка: уровень и текст.
function setState(el, level, text) {
	setLevel(el, level);
	setText(el, text);
}

// Неразрывный пробел: пустая строка ячейки сохраняет высоту.
const NBSP = ' ';

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

// ---- Схема настроек и константы службы (truba.schema, ADR 0015) ----
// Умолчания, пределы, имена и сроки — у службы, своих копий у интерфейса нет. Схема статична:
// один вызов на страницу, представления ждут его в load().

let schemaData = null, schemaLoading = null;

function loadSchema() {
	if (!schemaLoading)
		schemaLoading = callSchema().then((s) => schemaData = s);
	return schemaLoading;
}

function schema() {
	return schemaData || { sections: {}, upstream_schemes: [], consts: {} };
}

function schemaOpt(sec, key) {
	return schema().sections?.[sec]?.[key];
}

// Действующее значение опции — как его понимает служба (truba.conf): из UCI, а если его нет или
// оно неверное — умолчание схемы. sid — для секций без имени (устройства).
function get(sec, key, sid) {
	const o = schemaOpt(sec, key), v = uci.get('truba', sid || sec, key);
	if (!o)
		return v;
	if (v == null)
		return o.def;
	switch (o.type) {
	case 'bool':
		return [ '1', 'true', 'on', 'yes' ].includes(v);
	case 'int': {
		const n = /^\d+$/.test(v) ? +v : NaN;
		return (n >= o.lo && n <= o.hi && !(o.min && n > 0 && n < o.min)) ? n : o.def;
	}
	case 'list':
	case 'upstreams': {
		const l = L.toArray(v);
		return l.length ? l : o.def;
	}
	case 'enum':
		return o.values.includes(v) ? v : o.def;
	case 'pattern':
		return (v !== '' && new RegExp(o.re).test(v)) ? v : o.def;
	default:
		return v;
	}
}

// Поле формы по схеме: умолчание, подсказка и проверка. msg — текст ошибки поля с шаблоном.
function field(o, sec, key, msg) {
	const s = schemaOpt(sec, key);
	if (!s)
		return o;
	switch (s.type) {
	case 'bool':
		o.default = s.def ? '1' : '0';
		break;
	case 'enum':
	case 'list':
	case 'upstreams':
		o.default = s.def;
		break;
	case 'int':
		o.placeholder = String(s.def);
		o.datatype = s.min ? 'or(range(0,0),range(%d,%d))'.format(s.min, s.hi) : 'range(%d,%d)'.format(s.lo, s.hi);
		break;
	case 'pattern': {
		const re = new RegExp(s.re);
		o.placeholder = s.def;
		o.validate = (sid, v) => (!v || re.test(v)) ? true : msg;
		break;
	}
	case 'string':
		o.placeholder = s.def;
		break;
	case 'ipv4':
		o.datatype = 'ip4addr';
		break;
	}
	return o;
}

function tunnelIface() {
	return get('main', 'iface');
}

// ---- Устройства (truba.devices, ADR 0018) ----

// Активное устройство — с трафиком за последние 5 минут (чип «Активные», схема потоков «Обзора»).
const ACTIVE_SPAN = 300;

// Скорость устройства сейчас, байт/с: [ к нему, от него ] по всем Действиям; null — не известна.
function devRate(d) {
	const r = d?.rate;
	return r ? [ (r[0] || 0) + (r[2] || 0) + (r[4] || 0), (r[1] || 0) + (r[3] || 0) + (r[5] || 0) ] : null;
}

// Туннель и Напрямую за последнюю минуту (точка [ t, Туннель ↓, ↑, Напрямую ↓, ↑ ]), без неё — сейчас.
// Минуты без трафика служба не пишет: точка старше двух минут — уже не последняя минута.
function devShare(d, now) {
	const m = d?.minutes?.[d.minutes.length - 1];
	const v = (m && m.length > 1 && now - m[0] <= 120) ? m.slice(1) : (d?.rate || []);
	return [ (v[0] || 0) + (v[1] || 0), (v[2] || 0) + (v[3] || 0) ];
}

function devActive(d, now) {
	return d?.last != null && now - d.last <= ACTIVE_SPAN;
}

// Секции device с этим MAC — без учёта регистра (прежняя таблица «Маршрутизации» сохраняла его
// заглавными и не проверяла повторы). Действует первая, как у службы (conf.uc, device_sections).
function deviceSections(mac) {
	if (!mac)
		return [];
	const m = String(mac).toLowerCase();
	return uci.sections('truba', 'device').filter((s) => String(s.mac || '').toLowerCase() == m).map((s) => s['.name']);
}

function deviceSection(mac) {
	return deviceSections(mac)[0] || null;
}

// Политика устройства так, как её поймёт служба (truba.conf, device_sections), — по настройкам
// браузера, с несохранёнными изменениями. Незнакомая — «по правилам», а не умолчание схемы.
function devicePolicy(mac) {
	const sid = deviceSection(mac);
	if (!sid || !get('device', 'enabled', sid))
		return 'rules';
	const p = uci.get('truba', sid, 'policy') ?? schemaOpt('device', 'policy')?.def;
	return (p == 'tunnel' || p == 'direct') ? p : 'rules';
}

// MAC так, как его хранит служба: «aa:bb:cc:dd:ee:ff»; «AA-BB-…» тоже подходит. null — не MAC.
function normMac(s) {
	const m = String(s || '').trim().toLowerCase().replace(/-/g, ':');
	return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(m) ? m : null;
}

// Возраст рукопожатия Туннеля: норма — пока не старше max (handshake_max, так судит watchdog), дольше —
// «внимание», пока watchdog не объявил Туннель упавшим; рукопожатия не было или Туннель упал — ошибка.
// verdict — состояние из итога watchdog; его нет (watchdog выключен) — ошибка тогда, когда watchdog
// объявил бы Туннель упавшим: через grace (fails × interval) после порога.
function handshakeLevel(age, verdict, max, grace) {
	if (age == null)
		return 'err';
	if (age <= max)
		return 'ok';
	if (verdict)
		return verdict == 'down' ? 'err' : 'warn';
	return age > max + grace ? 'err' : 'warn';
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
	devices: _('Devices'),
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
	callSchema, loadSchema, schema, get, field, handshakeLevel, callDevices, callConnections,
	ACTIVE_SPAN, devRate, devShare, devActive, deviceSections, deviceSection, devicePolicy, normMac,
	runNatTest, runTunnelTest,
	ACTION_LABELS, ACTION_LEVELS, REASON_LABELS, WARNINGS, NAT_ERRORS, UPNP_MISSING, NBSP, TABS,
	fmtBytes, fmtRate, fmtAge, fmtTime, fmtDate, fmtNum, missingText,
	pill, busy, empty, span, svgEl, kvTable, table, row, chips,
	setText, setState, setResult, setError, tunnelIface, tunnelState, tabUrl, invalidTab
});
