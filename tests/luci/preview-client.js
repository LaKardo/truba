// Заглушки только для dev-стенда: компоненты и CSS загружаются без копирования.
window.addEventListener('error', (e) => { document.getElementById('error').textContent = e.error?.stack || e.message; });
window.addEventListener('unhandledrejection', (e) => { document.getElementById('error').textContent = e.reason?.stack || String(e.reason); });
const { schema, translations } = await (await fetch('/fixtures.json')).json();
const params = new URLSearchParams(location.search);
document.documentElement.lang = params.get('lang') == 'en' ? 'en' : 'ru';
const tabs = ['overview', 'devices', 'rules', 'tunnel', 'dns', 'inbound', 'log'];
for (const id of ['tab', 'theme', 'lang', 'size']) {
	const el = document.getElementById(id);
	if (id == 'tab') for (const [i, t] of tabs.entries()) el.add(new Option(
		params.get('lang') == 'en' ? t : ['Обзор', 'Устройства', 'Правила', 'Туннель', 'DNS', 'Входящие', 'Журнал'][i], t));
	el.value = params.get(id) || el.options[0].value;
	el.onchange = () => { params.set(id, el.value); location.search = params; };
}
document.body.classList.toggle('dark', params.get('theme') == 'dark');
document.body.classList.toggle('phone', params.get('size') == 'phone');
window._ = (s, ctx) => params.get('lang') == 'en' ? s : translations[(ctx || '') + '\u0001' + s] || s;
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%(?:\.(\d+))?([%sdf])/g, (_, precision, t) => {
		if (t == '%') return '%';
		const value = args[i++];
		return t == 'f' ? Number(value).toFixed(Number(precision || 0)) : String(value);
	});
};
window.L = { resource: (s) => '/' + s, url: (...p) => {
	const query = new URLSearchParams(params);
	query.set('tab', tabs.includes(p.at(-1)) ? p.at(-1) : 'overview');
	return '/?' + query;
}, env: {} };
window.E = (tag, attrs = {}, children = []) => {
	const el = document.createElement(tag);
	for (const [k, v] of Object.entries(attrs || {})) {
		if (typeof v == 'function') el.addEventListener(k, v); else el.setAttribute(k, v);
	}
	for (const child of (Array.isArray(children) ? children : [children]).flat(Infinity))
		if (child != null) el.append(child instanceof Node ? child : document.createTextNode(String(child)));
	return el;
};
const values = { truba: {}, network: { awg0: { '.name': 'awg0', '.type': 'interface', proto: 'amneziawg', mtu: '1380' },
	peer: { '.name': 'peer', '.type': 'amneziawg_awg0', endpoint_host: '203.0.113.10', endpoint_port: '51820', public_key: 'DEMO' } },
	firewall: { lan: { '.name': 'lan', '.type': 'zone', name: 'lan' } } };
for (const s of ['main', 'dns', 'lists', 'watchdog']) values.truba[s] = { '.name': s, '.type': s };
let n = 0;
const uci = {
	state: { values, changes: {}, creates: {}, deletes: {} },
	load: async () => {}, unload() { this.state.changes = {}; this.state.creates = {}; this.state.deletes = {}; }, save: async () => {},
	get(c, s, o) {
		if (this.state.deletes[c]?.[s] === true || this.state.deletes[c]?.[s]?.[o]) return undefined;
		const section = { ...values[c]?.[s], ...this.state.changes[c]?.[s] };
		return o ? section[o] : section;
	},
	sections(c, t) { return Object.keys(values[c] || {}).filter((s) => this.state.deletes[c]?.[s] !== true)
		.map((s) => this.get(c, s)).filter((s) => !t || s['.type'] == t); },
	set(c, s, o, v) { ((this.state.changes[c] ||= {})[s] ||= {})[o] = v; },
	unset(c, s, o) { ((this.state.deletes[c] ||= {})[s] ||= {})[o] = true; },
	add(c, t) { const s = 'demo' + ++n; values[c][s] = { '.name': s, '.type': t }; (this.state.creates[c] ||= {})[s] = values[c][s]; return s; },
	remove(c, s) { (this.state.deletes[c] ||= {})[s] = true; }
};
const now = Math.floor(Date.now() / 1000);
const devices = Array.from({length: 24}, (_, i) => ({ ip: '192.168.1.' + (50 + i), mac: '02:11:22:33:44:' + i.toString(16).padStart(2, '0'),
	name: ['Ноутбук — рабочее устройство', 'Телефон', 'Игровая консоль'][i % 3] + ' ' + (i + 1), zone: 'lan', source: 'dhcp', last: now,
	rate: [180000, 12000, 23000, 2000, 0, 0], day: [1200000000, 50000000, 30000000, 1000000, 0, 0], history: [] }));
values.truba.demoRule = { '.name': 'demoRule', '.type': 'rule', mode: 'all', set: 'geosite', tag: 'youtube', action: 'tunnel' };
values.truba.demoDirect = { '.name': 'demoDirect', '.type': 'rule', mode: 'all', set: 'geosite', tag: 'ru', action: 'direct' };
const status = { service: true, routing: true, mosdns: true, vps_ip: '203.0.113.10', mode: 'all', zones: ['lan'],
	tunnel: { configured: true, up: true, iface: 'awg0', awg: { handshake: now - 20, handshake_age: 20, rx: 123000000, tx: 4500000 } },
	applied: { time: now, routing: true, mode: 'all', zones: ['lan'], dns_hijack: true },
	dns: { running: true }, health: { state: 'up', rtt: 32, probes: [31, 32, 34, 30, 32, 33], big: { ok: true } },
	watchdog: { alive: true }, upnp: { installed: true, leases: [] } };
async function rpcCall(method) {
	switch (method) {
	case 'schema': return schema;
	case 'status': return status;
	case 'devices': return { now, devices };
	case 'connections': return { addrs: [
		{ addr: '198.51.100.7', domain: 'www.example.org', proto: 'tcp', port: 443, action: 'tunnel', reason: 'geosite_ip', conns: 2, up: 12000, down: 350000 },
		{ addr: '192.0.2.8', proto: 'udp', port: 443, action: 'direct', conns: 1, up: 500, down: 1200 }
	], total: 3, acct: true };
	case 'rates': return { now, step: 5, points: Array.from({length: 120}, (_, i) => [now - 600 + i * 5, 180000 + Math.sin(i / 7) * 80000, 12000, 23000, 2000, 0, 0]) };
	case 'categories': return { cats: ['youtube', 'telegram', 'games', 'ru'].map((tag) => ({ set: 'geosite', tag })), starting: [] };
	case 'lists': return {};
	case 'sets': return {};
	case 'log': return Array.from({length: 60}, (_, i) => `Fri Oct 16 12:00:${String(i % 60).padStart(2, '0')} 2026 daemon.info truba: Предпросмотр — строка журнала ${i}`).join('\n');
	default: throw new Error('Предпросмотр: операция ' + method + ' не поддерживается (роутер не изменён)');
	}
}
const cache = new Map(Object.entries({ baseclass: { extend: (x) => x }, uci,
	rpc: { declare: ({method}) => (...args) => rpcCall(method, ...args) }, poll: { add() {} },
	view: { extend: (x) => x } }));
async function load(name) {
	if (cache.has(name)) return cache.get(name);
	const promise = (async () => {
		const response = await fetch('/' + name.replaceAll('.', '/') + '.js');
		if (!response.ok) throw new Error('Модуль не найден: ' + name);
		const src = await response.text();
		const deps = [...src.matchAll(/'require ([\w.]+)(?: as (\w+))?';/g)];
		const names = deps.map((m) => m[2] || m[1].split('.').at(-1));
		return new Function(...names, src)(...await Promise.all(deps.map((m) => load(m[1]))));
	})();
	cache.set(name, promise); return promise;
}
try {
	const view = await load('view.truba.' + (params.get('tab') || 'overview'));
	view.handleSaveApply = async () => {
		const app = await load('truba.ui.app');
		app.toast('Это макет: настройки не применены.');
	};
	document.getElementById('view').append(view.render(await view.load()));
	document.body.dataset.ready = 'true';
} catch (e) { document.getElementById('error').textContent = e.stack; document.body.dataset.ready = 'error'; }
