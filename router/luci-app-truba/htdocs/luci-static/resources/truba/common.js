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
	lists_missing: { tab: 'rules', text: _('Rule sets are not downloaded yet — only the mode default applies. Download is in progress.') },
	zones_without_devices: { tab: 'rules', text: _('The selected firewall zones have no active devices.') },
	tunnel_not_configured: { tab: 'tunnel', text: _('The tunnel is not configured yet — import the configuration on the Tunnel tab.') },
	lists_rolled_back: { tab: 'rules', text: _('The current rule sets could not be read, so the previous ones were restored.') }
};

// Почему «Проверка NAT» не дала результата (поле error итога).
const NAT_ERRORS = {
	not_configured: _('the tunnel is not configured'),
	tunnel_down: _('the tunnel is down'),
	socket: _('cannot open a socket'),
	no_answer: _('no STUN server answered'),
	timeout: _('no result in time')
};

// Неверные значения настроек, которые служба пропустила (applied.invalid), — вкладка, где их исправить:
// сначала по опции («main.zone»), затем по секции. Режим, Зоны, Маршрутизация, Наборы правил и правила — «Правила».
const INVALID_TABS = { 'main.mode': 'rules', 'main.zone': 'rules', 'main.routing': 'rules',
	device: 'devices', dns: 'dns', lists: 'rules', rule: 'rules', watchdog: 'tunnel', main: 'tunnel' };

function invalidTab(list) {
	const k = String(list[0]?.key || '');
	return INVALID_TABS[k] || INVALID_TABS[k.split('.')[0]] || 'rules';
}

// Почему «Проверить домен/IP» не дала результата (поле error итога check).
const CHECK_ERRORS = {
	busy: _('the rule sets are being unpacked, try again in a minute')
};

// Текст неудачной проверки: причина службы или текст ошибки вызова (rpcd, нет связи).
function checkErrorText(r) {
	if (CHECK_ERRORS[r?.error])
		return _('Not checked: %s').format(CHECK_ERRORS[r.error]);
	return r?.message ? _('The check failed: %s').format(r.message) : _('The check failed.');
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

// Текст ошибки поля по схеме или null — та же проверка, что у службы (conf.uc, check_value): неверное
// значение служба пропустила бы и взяла умолчание. Пустое — умолчание, не ошибка; string не проверяется.
const IPV4 = /^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$/;

function fieldError(sec, key, v) {
	const o = schemaOpt(sec, key);
	v = (v == null) ? '' : String(v);
	if (!o || v === '')
		return null;
	switch (o.type) {
	case 'int': {
		const n = /^\d+$/.test(v) ? +v : NaN;
		if (n >= o.lo && n <= o.hi && !(o.min && n > 0 && n < o.min))
			return null;
		return o.min ? _('Enter 0 or a whole number from %d to %d').format(o.min, o.hi)
			: _('Enter a whole number from %d to %d').format(o.lo, o.hi);
	}
	case 'pattern':
		return new RegExp(o.re).test(v) ? null : _('Invalid value');
	case 'enum':
		return o.values.includes(v) ? null : _('Choose one of: %s').format(o.values.join(', '));
	case 'ipv4':
		return IPV4.test(v) ? null : _('Enter an IPv4 address');
	default:
		return null;
	}
}

function tunnelIface() {
	return get('main', 'iface');
}

// ---- DNS ----

// Адрес DNS-сервера в том виде, что понимает mosdns 5 (та же проверка — upstream_ok в conf.uc):
// с опечаткой в схеме mosdns не запустился бы, а с ним пропал бы DNS всей сети. Список схем —
// у службы (truba.schema).
const UPSTREAM_RE = /^(([a-z0-9+]+):\/\/)?(\[[0-9a-fA-F:.]+\]|[^\]\[\s\/@:]+)(:\d+)?(\/[^\s@]*)?(@[0-9.]+)?$/;

// Текст ошибки адреса или null; пустое — не ошибка (его не добавляют).
function upstreamError(v) {
	if (!v)
		return null;
	const m = UPSTREAM_RE.exec(v);
	const ok = m && (m[2] == null ? m[5] == null : schema().upstream_schemes.includes(m[2]));
	return ok ? null : _('Expected https://…, tls://…, quic://…, h3://…, tcp://… or udp://… (optionally «@IP»)');
}

// Состояние mosdns и плитки кэша для «DNS». Счётчики — с запуска mosdns: hit — ответы из кэша вместе
// с истёкшими, lazy_hit — истёкшие. Без данных (маршрутизация выкл, mosdns стоит, нет API) — «—».
function dnsStats(st) {
	const dc = (st.routing && st.mosdns) ? st.dns_cache : null;
	const pct = (n, all) => all ? Math.round(n * 100 / all) + '%' : '—';
	const [ level, text ] = !st.routing ? [ '', _('not used: routing is off') ]
		: !st.mosdns ? [ 'err', _('mosdns not running') ] : [ 'ok', _('mosdns running') ];
	return {
		level, text,
		tiles: [
			[ _('From cache'), dc ? pct(dc.hit, dc.query) : '—' ],
			[ _('From expired cache'), dc ? pct(dc.lazy_hit, dc.query) : '—' ],
			[ _('Cache filled'), dc ? pct(Math.min(dc.size, dc.max), dc.max) : '—' ],
			[ _('Queries since mosdns start'), dc ? fmtNum(dc.query) : '—' ]
		],
		note: (st.routing && st.mosdns && !dc) ? _('mosdns does not report statistics')
			: (dc && !dc.query) ? _('no queries yet') : null
	};
}

// ---- Входящие ----

// Итог «Проверки NAT» (spec §5.6): значок, четыре строки [ название, значение, уровень ], когда проверено
// и ответы серверов STUN. Без проверки и при ошибке — «—»: адреса и порта тогда нет. Типа NAT нет — служба
// его не определяет: STUN видит отображение, но не фильтрацию.
function natSummary(n, wdOn) {
	const done = !!n && !n.error;
	const yesNo = (v, unknown) => (!done || v == null) ? [ (done && unknown) || '—', '' ] : v ? [ _('yes'), 'ok' ] : [ _('no'), 'err' ];
	const [ level, text ] = !n ? [ '', _('not run yet') ]
		: n.error ? [ (n.error == 'tunnel_down' || n.error == 'not_configured') ? 'warn' : 'err', _('not checked: %s').format(NAT_ERRORS[n.error] || n.error) ]
		: n.ok ? [ 'ok', _('Truba layer OK') ] : [ 'err', _('problem') ];
	const why = { dns: _('name not resolved'), timeout: _('no answer') };
	return {
		level, text,
		rows: [
			[ _('External address'), (done && n.external_ip) ? ((n.external_port != null) ? '%s:%d'.format(n.external_ip, n.external_port) : n.external_ip) : '—', '' ],
			[ _('External IP is the Truba IP'), ...yesNo(n?.ip_is_vps) ],
			[ _('Port preserved'), ...yesNo(n?.port_preserved) ],
			[ _('Same mapping for different servers'), ...yesNo(n?.consistent, _('nothing to compare: one server answered')) ]
		],
		when: !n ? (wdOn ? _('runs by itself after the tunnel comes up') : _('never'))
			: '%s · %s'.format(fmtTime(n.time), n.auto ? _('automatically after the tunnel came up') : _('manually')),
		servers: (n?.servers || []).map((s) => s.mapped
			? '%s — %s:%d, %s'.format(s.server, s.mapped.address, s.mapped.port, _('%d ms').format(s.rtt))
			: '%s — %s'.format(s.server, why[s.error] || s.error || '—'))
	};
}

// Итог на карточке «Проверки NAT»: своя проверка (mine — { n, base }: её итог и время итога в status на момент
// нажатия), пока опрос не принесёт другой итог. Время браузера с временем Роутера не сравнивается: часы могут
// расходиться, а неудача в браузере (нет ответа за 20 с) помечена временем браузера.
function natPick(polled, mine) {
	return (mine && (polled?.time ?? null) === mine.base) ? mine.n : (polled || null);
}

// UPnP (status.upnp): переключатель доступен, пока miniupnpd установлен, а без него — только чтобы выключить
// (иначе предупреждение не убрать); on — значение переключателя. Предупреждение — включён, а служба не
// установлена или не работает.
function upnpState(up, on) {
	up = up || {};
	return {
		installed: up.installed !== false,
		locked: up.installed === false && !on,
		note: (up.enabled && !up.installed) ? UPNP_MISSING
			: (up.enabled && !up.running) ? _('UPnP is enabled, but miniupnpd is not running.') : null
	};
}

// Отображения UPnP / NAT-PMP: устройство — по имени из devices, без него — IP.
function upnpRows(leases, devices) {
	const names = new Map((devices || []).filter((d) => d.ip && d.name).map((d) => [ d.ip, d.name ]));
	return (leases || []).map((l) => ({
		descr: l.descr || '—', who: names.get(l.ip) || l.ip, proto: l.proto, ext: l.ext_port, port: l.port,
		expires: l.expires ? fmtTime(l.expires) : _('no expiry')
	}));
}

// Пробросы портов из Туннеля (spec §5.6) — секции firewall.redirect с src = зона Туннеля, кроме правил SNAT
// (их LuCI тоже не считает пробросами), по настройкам браузера (с несохранёнными изменениями). Опции,
// удалённые в браузере (uci.unset), uci.sections не снимает — их снимает здесь, как uci.get: иначе снова
// включённый проброс (enabled снят) оставался бы выключенным.
function forwardSections() {
	const del = uci.state?.deletes?.firewall || {};
	return uci.sections('firewall', 'redirect').map((s) => {
		const d = del[s['.name']];
		if (!d || d === true)
			return s;
		const x = Object.assign({}, s);
		for (let o in d)
			delete x[o];
		return x;
	}).filter((s) => s.src == schema().consts.fw_zone && s.target != 'SNAT');
}

// enabled — как его читает fw4 (parse_bool): 0, off, false, no — выключен, остальное и без опции — включён.
const FW_OFF = [ '0', 'off', 'false', 'no' ], FW_ON = [ '1', 'on', 'true', 'yes' ];

function fwOn(v) {
	return !FW_OFF.includes(v);
}

// Значение enabled от переключателя строки: из настроек, если оно уже значит нужное, — туда и обратно ноль
// изменений; иначе выкл — '0', вкл — без опции.
function fwEnabled(saved, on) {
	return (saved != null && (on ? FW_ON : FW_OFF).includes(saved)) ? saved : on ? null : '0';
}

// Протоколы секции: без опции — tcp и udp, как у fw4; tcpudp, all, any — оба.
function fwProtos(p) {
	const l = L.toArray(p);
	if (!l.length || l.some((x) => [ 'tcpudp', 'all', 'any', '*' ].includes(x)))
		return [ 'tcp', 'udp' ];
	return l;
}

// Протокол строкой, как его пишет форма LuCI: tcp, udp или «tcp udp».
function fwProto(p) {
	const l = fwProtos(p);
	return (l.includes('tcp') && l.includes('udp')) ? 'tcp udp' : l.join(' ');
}

// Строки карточки: кто — имя устройства с этим IP, иначе IP; внутренний порт — без своего тот же, что внешний.
function forwardRows(devices) {
	const names = new Map((devices || []).filter((d) => d.ip && d.name).map((d) => [ d.ip, d.name ]));
	return forwardSections().map((s) => ({
		sid: s['.name'], name: s.name || '', proto: fwProto(s.proto), ext: s.src_dport || '', ip: s.dest_ip || '',
		who: names.get(s.dest_ip) || s.dest_ip || '', port: s.dest_port || s.src_dport || '', on: fwOn(s.enabled)
	}));
}

// Порт или диапазон «от-до» в 1–65535 → [ от, до ]; иначе null.
function portRange(v) {
	const m = /^(\d+)(?:[-:](\d+))?$/.exec(String(v ?? '').trim());
	if (!m)
		return null;
	const a = +m[1], b = (m[2] != null) ? +m[2] : a;
	return (a >= 1 && b <= 65535 && a <= b) ? [ a, b ] : null;
}

// Ошибка поля порта или null; optional — пустое можно (внутренний порт: тот же, что внешний). Диапазон —
// через «-» или «:», как у fw4 (parse_port).
function portError(v, optional) {
	const t = String(v ?? '').trim();
	if (t === '' && optional)
		return null;
	return portRange(t) ? null : _('Enter a port or a range «from-to» within 1–65535');
}

// Ошибки формы проброса: { ext, ip, port } — только неверные. Внешний порт, который уже пробрасывает другой
// включённый проброс Туннеля по тому же протоколу, — ошибка: иначе второй молча не работал бы.
function forwardErrors(f) {
	const e = {};
	const ext = portError(f.ext);
	if (ext)
		e.ext = ext;
	else {
		const [ a, b ] = portRange(f.ext), mine = fwProtos(f.proto);
		const other = forwardSections().find((s) => s['.name'] != f.sid && fwOn(s.enabled) && fwProtos(s.proto).some((p) => mine.includes(p)) &&
			((r) => r && r[0] <= b && a <= r[1])(portRange(s.src_dport)));
		if (other)
			e.ext = _('This external port is already forwarded: %s').format(other.name || other.src_dport);
	}
	if (!IPV4.test(String(f.ip ?? '').trim()))
		e.ip = _('Enter an IPv4 address');
	const port = portError(f.port, true);
	if (port)
		e.port = port;
	return e;
}

// IPv4 → число; null — не IPv4.
function ip4(v) {
	return IPV4.test(v) ? String(v).split('.').reduce((n, x) => n * 256 + +x, 0) : null;
}

// Зона межсетевого экрана для IP: у устройства — его зона (служба знает её по интерфейсу), иначе — зона сети
// со статическим адресом, в которую IP входит. Не нашлась — null: fw4 пробросит порт и без dest, а неверная
// зона хуже никакой.
function zoneOfIp(ip, devices) {
	const d = (devices || []).find((x) => x.ip == ip && x.zone);
	if (d)
		return d.zone;
	const n = ip4(ip);
	if (n == null)
		return null;
	for (let s of uci.sections('network', 'interface')) {
		if (s.proto != 'static')
			continue;
		const inside = L.toArray(s.ipaddr).some((a) => {
			const [ addr, len ] = String(a).split('/');
			const mask = (len != null) ? (len > 0 ? (~0 << (32 - len)) >>> 0 : 0) : ip4(s.netmask || '255.255.255.255');
			return ip4(addr) != null && mask != null && ((ip4(addr) & mask) >>> 0) == ((n & mask) >>> 0);
		});
		const z = inside && uci.sections('firewall', 'zone').find((z) => L.toArray(z.network).includes(s['.name']));
		if (z)
			return z.name || null;
	}
	return null;
}

// Значения секции из формы: пустое — null (опция снимается); dest — зона по IP. sid — правка сохранённой секции:
// протокол того же смысла (список, tcpudp, без опции) остаётся как в настройках, а при том же IP dest не пишется —
// зону могли задать в «Межсетевом экране».
function forwardValues(f, devices, sid) {
	const t = (v) => { v = String(v ?? '').trim(); return (v === '') ? null : v; };
	const ip = t(f.ip);
	const v = { name: t(f.name), proto: f.proto || 'tcp udp', src_dport: t(f.ext), dest_ip: ip, dest_port: t(f.port), dest: ip ? zoneOfIp(ip, devices) : null };
	if (sid) {
		const proto = uci.get('firewall', sid, 'proto');
		if (fwProto(proto) == v.proto)
			v.proto = proto ?? null;
		if (ip == (uci.get('firewall', sid, 'dest_ip') ?? null))
			delete v.dest;
	}
	return v;
}

// ---- Правила Категорий ----

// Действия правила, которые служба принимает (const.uc, ACTIONS); остальные она пропускает.
const RULE_ACTIONS = [ 'direct', 'tunnel', 'block' ];

// Ключ Категории секции rule «набор:тег» — как его читает служба (conf.uc): set не «geoip» — «geosite»,
// тег в нижнем регистре.
function ruleKey(s) {
	return ((s.set == 'geoip') ? 'geoip' : 'geosite') + ':' + String(s.tag || '').toLowerCase();
}

// Секция — правило Режима (и Категории, если заданы set и tag) так, как его читает служба (conf.uc):
// без set или tag она пропускается, mode не «selective» — «all».
function ruleOf(s, mode, set, tag) {
	return !!(s.set && s.tag) && ((s.mode == 'selective') ? 'selective' : 'all') == mode &&
		(set == null || ruleKey(s) == set + ':' + String(tag).toLowerCase());
}

function ruleSections(mode, set, tag) {
	return uci.sections('truba', 'rule').filter((s) => ruleOf(s, mode, set, tag));
}

// Действия Режима одним проходом: «набор:тег» → Действие. Из секций одного ключа действует последняя
// с верным Действием — служба перезаписывает Действие ключа по порядку секций.
function ruleActions(mode) {
	const m = new Map();
	for (let s of ruleSections(mode))
		if (RULE_ACTIONS.includes(s.action))
			m.set(ruleKey(s), s.action);
	return m;
}

// Действие Категории в Режиме; нет правила — «По режиму».
function ruleAction(mode, set, tag) {
	return ruleActions(mode).get(set + ':' + String(tag).toLowerCase()) || 'mode';
}

// Строки Категорий (spec §5.3): поиск по «набор:тег» без учёта регистра и чип по Действию (actOf —
// Действие Категории); сразу — не больше CAT_LIMIT: около 1 700 строк по четыре кнопки телефон рисовал
// бы долго, всё — по «Показать все». total — сколько подошло.
const CAT_LIMIT = 100;

function catRows(list, actOf, q, f, full) {
	const qq = String(q || '').trim().toLowerCase();
	const hit = list.filter((c) => (!qq || (c.set + ':' + c.tag).toLowerCase().includes(qq)) &&
		(f == 'all' || (f == 'explicit' ? actOf(c) != 'mode' : actOf(c) == f)));
	return { rows: full ? hit : hit.slice(0, CAT_LIMIT), total: hit.length };
}

// Перечитать categories вместе с этим ответом lists: Наборы правил распаковываются или ещё не скачаны,
// на прошлом опросе шли обновление или применение, или сменились файлы Наборов (обновление по расписанию,
// откат) — иначе список, счётчики и пропавшие Категории устарели бы до перезагрузки страницы.
function catsDue(cats, prev, next) {
	const sha = (l) => [ l?.geoip?.sha256, l?.geosite?.sha256 ].join();
	return !!(cats?.busy || !(cats?.cats || []).length || prev?.updating || prev?.applying || next?.applying || sha(prev) != sha(next));
}

// Пора ли спросить lists и sets (spec §5.3): раз в 30 с, а пока идёт обновление или применение
// и 15 с после «Обновить сейчас» (замок обновления берётся не сразу) — каждый опрос. Время — в мс.
function listsDue(now, polledAt, kickedAt, l) {
	return !!(l?.updating || l?.applying) || now - kickedAt < 15000 || now - polledAt >= 30000;
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

// Подпись адреса в «Куда ходит сейчас» (truba.connections). «Решено до смены настроек» и Политика
// устройства — раньше тега geoip: иначе «geoip ru · Туннель» противоречил бы Действию Категории ru.
// Без причины (Маршрутизация выключена) — протокол и порт.
function connLabel(a) {
	if (a.reason == 'changed' || a.reason == 'device')
		return REASON_LABELS[a.reason];
	if ((a.geoip || []).length)
		return 'geoip ' + a.geoip.join(', ');
	if (a.reason)
		return REASON_LABELS[a.reason] || a.reason;
	return a.port ? a.proto + '/' + a.port : a.proto;
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

// ---- Журнал (truba.log) ----

// Строка logread: «Wed Oct  7 22:47:05 2026 daemon.notice truba: текст»; у mosdns текст —
// «2026-10-07T17:59:32.409Z<TAB>WARN<TAB>сообщение<TAB>{поля}». mosdns пишет всё в stderr,
// поэтому syslog помечает каждую его строку как ошибку: уровень берётся из самой строки.
const LOG_RE = /^\w{3} (\w{3}) +(\d+) (\d\d:\d\d:\d\d) \d{4} \w+\.(\w+) ([\w.-]+?)(?:\[\d+\])?: (.*)$/;
const MONTHS = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };

// Источник строки на «Журнале» — по тегу: у watchdog свой (truba-watchdog), строки интерфейса Туннеля
// пишут netifd и ядро. Остальное, что отдаёт truba.log (Труба, её переустановка, cron с её задачей), — Труба.
const LOG_SOURCES = { mosdns: 'mosdns', 'truba-watchdog': 'watchdog', netifd: 'awg', kernel: 'awg' };

function logSource(src) {
	return LOG_SOURCES[src] || 'truba';
}

// Строки журнала по порядку текста: время, тег, источник, уровень, текст и исходная строка (для «Скачать»).
function parseLog(text) {
	return (text || '').split('\n').filter((l) => l).map((l) => {
		const m = l.match(LOG_RE);
		if (!m)
			return { time: '', src: '', source: 'truba', level: 'info', text: l, raw: l };
		let level = /^(emerg|alert|crit|err)$/.test(m[4]) ? 'err' : /^warn/.test(m[4]) ? 'warn' : 'info';
		let msg = m[6];
		// busybox crond пишет каждый запуск задачи (обновление списков) с уровнем ошибки.
		if (m[5] == 'crond' && /^USER \S+ pid \d+ cmd /.test(msg))
			level = 'info';
		if (m[5] == 'mosdns') {
			const p = msg.split('\t');
			if (p.length >= 3 && /^\d{4}-\d\d-\d\dT/.test(p[0])) {
				const lv = p[1].toUpperCase();
				level = /ERROR|FATAL|PANIC/.test(lv) ? 'err' : lv == 'WARN' ? 'warn' : 'info';
				msg = p.slice(2).join(' ');
			}
			// Дампа кэша нет после каждой загрузки Роутера (он в памяти) — это не ошибка.
			if (/failed to load cache dump.*no such file/.test(msg))
				level = 'info';
		}
		return { time: '%02d.%02d %s'.format(+m[2], MONTHS[m[1]] || 0, m[3]), src: m[5], source: logSource(m[5]), level, text: msg, raw: l };
	});
}

// Строки под фильтром «Журнала»: уровень — порог (warn — предупреждения и ошибки, err — только ошибки),
// sources — включённые источники.
function logShown(lines, level, sources) {
	return lines.filter((l) => (level == 'all' || (level == 'err' ? l.level == 'err' : l.level != 'info')) && sources.includes(l.source));
}

// Вкладки Трубы: адрес и название — для ссылок из плиток и предупреждений «Обзора».
const TABS = {
	devices: _('Devices'),
	rules: _('Rules'),
	tunnel: _('Tunnel'),
	dns: _('DNS'),
	inbound: _('Inbound'),
	log: _('Log')
};
function tabUrl(tab) {
	return L.url('admin/services/truba/' + tab);
}

return baseclass.extend({
	callStatus, callLists, callCategories, callSets, callCheck, callUpdateLists, callRollbackLists, callRates, callLog,
	callSchema, loadSchema, schema, get, field, fieldError, handshakeLevel, callDevices, callConnections,
	ACTIVE_SPAN, devRate, devShare, devActive, deviceSections, deviceSection, devicePolicy, normMac, connLabel,
	RULE_ACTIONS, ruleKey, ruleOf, ruleSections, ruleActions, ruleAction, catRows, catsDue, listsDue, checkErrorText,
	runNatTest, runTunnelTest, parseLog, logSource, logShown, upstreamError, dnsStats, natSummary, upnpState, upnpRows,
	forwardRows, fwProto, fwEnabled, portError, forwardErrors, zoneOfIp, forwardValues, natPick,
	ACTION_LABELS, ACTION_LEVELS, REASON_LABELS, VIA_LABELS, WARNINGS, NAT_ERRORS, CHECK_ERRORS, UPNP_MISSING, NBSP, TABS,
	fmtBytes, fmtRate, fmtAge, fmtTime, fmtDate, fmtNum, missingText,
	pill, busy, empty, span, svgEl, kvTable, table, row, chips,
	setText, setState, setResult, setError, tunnelIface, tunnelState, tabUrl, invalidTab
});
