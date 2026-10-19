// Подсистема DNS: конфигурация mosdns, управление dnsmasq, проверка портов и сокетов.
'use strict';

import { readfile, writefile, stat, unlink, lsdir } from 'fs';
import { cursor } from 'uci';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as D from 'truba.dat';
import * as F from 'truba.conf';

// ---- Конфиг mosdns ----

// Сколько держать простаивающее соединение с сервером DNS, с. mosdns по умолчанию закрывает DoH
// через 30 с, хотя серверы держат его дольше (Cloudflare — 400 с, Google — 240 с), и первый промах
// кэша после паузы ждёт новые TCP и TLS: через Туннель это +100…170 мс. 360 с — чуть меньше, чем
// у Cloudflare (запасной DoH «Туннеля» по умолчанию): соединение закрывает mosdns, а не сервер в
// тот момент, когда к нему уходит запрос. Запасной DoH используется только при задержке или
// ошибке основного DNS на Трубе (ADR 0013). Если сервер закроет соединение раньше,
// mosdns откроет новое. У DoT срок действует только с pipelining (tls+pipeline://), у UDP
// соединений нет.
const UPSTREAM_IDLE = 360;

// Сколько кэш держит ответ свежим, с. Дольше — устаревший ответ живёт заметно дольше ttl_max:
// - после обновления списков домен, перешедший в другую Категорию, ещё получает ответ прежнего сервера
//   (маршрут при этом сразу по новой Категории);
// - mosdns 5.3.3 не пишет в дамп время сохранения, и после перезапуска ответы из дампа уходят
//   с TTL 1, пока запись не устареет: устройства переспрашивают раз в секунду.
// Час покрывает TTL большинства ответов, которые ttl_max обрезал бы (у 90 % — меньше 45 минут).
const CACHE_TTL_MAX = 3600;

// Адрес сервера в конфиге mosdns: «url@dial_ip» → { addr, dial_addr }. Неверные адреса conf.uc уже отбросил.
function upstream(u, mark) {
	let o = F.parse_upstream(u) ?? { addr: u };
	o.idle_timeout = UPSTREAM_IDLE;
	if (mark)
		o.so_mark = mark;
	return o;
}

// Серверы DNS одного пути (tag — up_tunnel или up_direct): основной и последовательный резерв.
// forward с concurrent выбирает сервер для каждого потока случайно и с повторами: при двух серверах
// половина запросов уходила бы дважды к одному, и зависший сервер держал бы их до тайм-аута (5 с).
// Поэтому у каждого сервера свой forward, а вместе их собирает fallback: резерв после 100 мс
// или ошибки основного. Ответ, кроме NOERROR и NXDOMAIN
// (SERVFAIL, REFUSED…), отбрасывается, как это делает forward: тогда ждём остальных.
function upstream_group(plugins, tag, list, mark) {
	if (length(list) == 1) {
		push(plugins, { tag, type: 'forward', args: { upstreams: [ upstream(list[0], mark) ] } });
		return;
	}
	let ok = [];
	for (let i, u in list) {
		let t = sprintf('%s_%d', tag, i);
		push(plugins, { tag: t, type: 'forward', args: { upstreams: [ upstream(u, mark) ] } });
		push(plugins, { tag: t + '_ok', type: 'sequence', args: [
			{ exec: '$' + t },
			{ matches: [ '!rcode 0 3' ], exec: 'drop_resp' },
		] });
		push(ok, t + '_ok');
	}
	// Пары с конца: mosdns ссылается только на уже объявленные теги.
	// threshold 100 мс: если первый сервер не ответил быстро (DoT на Трубе холодное соединение
	// или сервер недоступен), подключается второй. Если первый сервер отвечает ошибкой
	// или недоступен (закрытый порт), mosdns сразу идёт к secondary без ожидания threshold.
	let rest = ok[length(ok) - 1];
	for (let i = length(ok) - 2; i >= 0; i--) {
		let t = i ? sprintf('%s_%d_any', tag, i) : tag;
		push(plugins, { tag: t, type: 'fallback', args: { primary: ok[i], secondary: rest, threshold: 100 } });
		rest = t;
	}
}

// Дамп кэша — по поколению настроек, от которых зависит, у каких серверов спрошен ответ: серверы путей,
// Режим и Действия Категорий. Кэш хранит ответы с TTL сервера (до часа): после смены этих настроек
// mosdns начинает с пустым кэшем, а не отдаёт ответы прежних серверов. Остальные настройки
// (ttl_max, размер кэша) и обновление списков кэш сохраняют. Поколение — FNV-1a 32 бита.
export function cache_dump(cfg, plan) {
	let s = sprintf('%J', [ cfg.dns.tunnel, cfg.dns.direct, plan.mode_default, map(plan.geosite, g => g.tag + '=' + g.action) ]);
	return sprintf('%s/mosdns-cache-%08x.dump', C.DATA_DIR, U.fnv1a(s));
};

// Удалить дампы прежних поколений кэша.
export function prune_cache_dumps(keep) {
	for (let f in lsdir(C.DATA_DIR) ?? [])
		if (match(f, /^mosdns-cache-[0-9a-f]+\.dump$/) && C.DATA_DIR + '/' + f != keep)
			unlink(C.DATA_DIR + '/' + f);
};

// JSON-конфиг mosdns 5 со схлопыванием соседних категорий с одинаковым действием в один domain_set.
// JSON — подмножество YAML, mosdns читает его как обычный конфиг.
// gsdir — каталог списков доменов (по умолчанию распакованные в DATA_DIR/geosite).
export function mosdns(cfg, plan, router_hosts, gsdir) {
	let plugins = [];
	let main = [
		// AAAA и HTTPS (SVCB) → пусто: Маршрутизация только IPv4 (ADR 0005); ipv4hint/ipv6hint
		// в HTTPS-записи обошли бы nftset — клиент взял бы адрес не из A-ответа.
		{ matches: [ 'qtype 28 65' ], exec: 'reject 0' },
	];

	if (length(router_hosts)) {
		push(plugins, { tag: 'c_router', type: 'domain_set', args: { exps: map(router_hosts, h => 'full:' + h) } });
		push(main, { matches: [ 'qname $c_router' ], exec: 'goto flow_router' });
	}

	// Соседние Категории плана с одним Действием — один domain_set: план упорядочен по Приоритету,
	// и первое совпадение в группе решает то же, что решило бы первое среди её Категорий.
	// Несоседние не объединяются: между ними Категория с другим Действием.
	let groups = [], last = null;
	for (let g in plan.geosite) {
		if (last && last.action == g.action)
			push(last.tags, g.tag);
		else {
			last = { action: g.action, tags: [ g.tag ] };
			push(groups, last);
		}
	}

	let i = 0;
	for (let grp in groups) {
		let tag = sprintf('c_%d', i++);
		push(plugins, { tag, type: 'domain_set', args: { files: map(grp.tags, t => D.geosite_file(t, gsdir)) } });
		let ex = (grp.action == 'block') ? 'goto flow_block' : ((grp.action == 'tunnel') ? 'goto flow_tunnel' : 'goto flow_direct');
		push(main, { matches: [ 'qname $' + tag ], exec: ex });
	}
	push(main, { exec: 'goto flow_default' });

	upstream_group(plugins, 'up_tunnel', cfg.dns.tunnel, C.MARK_TUNNEL);
	upstream_group(plugins, 'up_direct', cfg.dns.direct, null);
	// Ленивый кэш: истёкшая запись отдаётся сразу (TTL 5 с) и проходит дальше по пути, в том числе
	// через nftset, а свежий ответ запрашивается в фоне у тех же серверов. 0 — выключен.
	// Дамп в /var (tmpfs): кэш переживает перезапуск mosdns, но не перезагрузку, и флеш не изнашивается.
	// Пишется при остановке и раз в 10 минут. Имя дампа — по поколению настроек DNS (cache_dump).
	let cache = { size: cfg.dns.cache_size, dump_file: cache_dump(cfg, plan) };
	if (cfg.dns.lazy_cache_ttl > 0)
		cache.lazy_cache_ttl = cfg.dns.lazy_cache_ttl;
	push(plugins, { tag: 'cache', type: 'cache', args: cache });

	let ttl = sprintf('ttl 0-%d', cfg.dns.ttl_max);
	// nftset в mosdns 5 — только встроенное действие: «семейство,таблица,набор,тип,маска».
	let nftset = (set) => sprintf('nftset inet,%s,%s,ipv4_addr,32', C.NFT_TABLE, set);
	// Путь ответа: fetch_* — кэш и серверы, затем, для Категорий, TTL и nftset. Кэш сохраняет ответ,
	// когда fetch_* завершилась, — с TTL сервера, но не дольше CACHE_TTL_MAX; устройства получают не
	// больше ttl_max и часто перепроверяют адрес, а запись в кэше не устаревает раньше срока и не
	// обновляется в фоне каждые ttl_max. Ответ из кэша тоже проходит через nftset — до ответа
	// устройству: после пересборки наборов IP возвращаются сами. Фоновое обновление ленивого кэша
	// идёт только в fetch_*: новые IP попадут в набор со следующим ответом устройству, тоже до него.
	let up_default = (plan.mode_default == 'tunnel') ? '$up_tunnel' : '$up_direct';
	for (let f in [ [ 'tunnel', '$up_tunnel', 'gs_tunnel4' ], [ 'direct', '$up_direct', 'gs_direct4' ],
	                [ 'router', '$up_direct' ], [ 'default', up_default ] ]) {
		push(plugins, { tag: 'fetch_' + f[0], type: 'sequence', args: [
			{ exec: '$cache' },
			{ matches: [ '!has_resp' ], exec: f[1] },
			{ exec: sprintf('ttl 0-%d', CACHE_TTL_MAX) },
		] });
		let flow = [ { exec: '$fetch_' + f[0] } ];
		if (f[2])
			push(flow, { exec: ttl }, { exec: nftset(f[2]) });
		push(plugins, { tag: 'flow_' + f[0], type: 'sequence', args: flow });
	}

	// Один коллектор для всех блокирующих Категорий: только запросы, отклонённые
	// нашими правилами, а не NXDOMAIN внешнего сервера или подавление AAAA/HTTPS.
	push(plugins, { tag: 'flow_block', type: 'sequence', args: [
		{ exec: 'metrics_collector block' },
		{ exec: 'reject 3' },
	] });
	push(plugins, { tag: 'main', type: 'sequence', args: main });

	let listen = sprintf('%s:%d', C.MOSDNS_ADDR, cfg.dns.port);
	push(plugins, { tag: 'udp_in', type: 'udp_server', args: { entry: 'main', listen } });
	push(plugins, { tag: 'tcp_in', type: 'tcp_server', args: { entry: 'main', listen } });

	// API — ради счётчиков кэша (/metrics) на «Обзоре». Только MOSDNS_ADDR: там же mosdns отдаёт
	// и /debug/pprof, снаружи Роутера их не видно. Нет адреса — порт занят, без API.
	let conf = { log: { level: 'warn' }, plugins };
	if (cfg.dns.api)
		conf.api = { http: cfg.dns.api };
	return conf;
};

// Свои хосты Роутера (F.router_hosts) mosdns проверяет раньше Категорий и резолвит напрямую (flow_router).
export function is_router_host(domain, router_hosts) {
	let d = lc(replace(domain, /\.$/, ''));
	for (let h in router_hosts)
		if (lc(h) == d)
			return true;
	return false;
};

// ---- dnsmasq: перенаправление в mosdns с сохранением исходных значений ----

function dnsmasq_section(c) {
	let sid = null;
	c.foreach('dhcp', 'dnsmasq', (s) => {
		if (sid == null)
			sid = s['.name'];
	});
	return sid;
}

export function dnsmasq_enable(port) {
	let c = cursor();
	c.load('dhcp');
	let sid = dnsmasq_section(c);
	if (!sid)
		return false;

	let want = C.MOSDNS_ADDR + '#' + port;
	let cur = U.to_list(c.get('dhcp', sid, 'server'));

	if (!stat(C.DNSMASQ_BACKUP)) {
		U.mkdirp(C.STATE_DIR);
		U.write_json(C.DNSMASQ_BACKUP, {
			sid,
			noresolv: c.get('dhcp', sid, 'noresolv'),
			cachesize: c.get('dhcp', sid, 'cachesize'),
			server: cur,
		});
	}

	// Серверы для отдельных доменов (/domain/ip) оставляем, общие заменяем на mosdns.
	let servers = filter(cur, s => index(s, '/') == 0);
	push(servers, want);

	let changed = (c.get('dhcp', sid, 'noresolv') != '1') || (c.get('dhcp', sid, 'cachesize') != '0') ||
	              (sprintf('%J', cur) != sprintf('%J', servers));
	if (!changed)
		return false;

	c.set('dhcp', sid, 'noresolv', '1');
	c.set('dhcp', sid, 'cachesize', '0');
	c.set('dhcp', sid, 'server', servers);
	c.commit('dhcp');
	system('/etc/init.d/dnsmasq restart >/dev/null 2>&1');
	return true;
};

export function dnsmasq_restore() {
	let b = U.read_json(C.DNSMASQ_BACKUP, null);
	if (!b)
		return false;
	let c = cursor();
	c.load('dhcp');
	let sid = b.sid;
	if (c.get('dhcp', sid) == null)
		sid = dnsmasq_section(c);
	if (sid) {
		for (let k in [ 'noresolv', 'cachesize' ]) {
			if (b[k] == null)
				c.delete('dhcp', sid, k);
			else
				c.set('dhcp', sid, k, b[k]);
		}
		if (length(b.server ?? []))
			c.set('dhcp', sid, 'server', b.server);
		else
			c.delete('dhcp', sid, 'server');
		c.commit('dhcp');
	}
	unlink(C.DNSMASQ_BACKUP);
	system('/etc/init.d/dnsmasq restart >/dev/null 2>&1');
	return true;
};

// ---- Порт API и адреса зон ----

// Порт API mosdns занят другой программой? Ошибка API останавливает mosdns целиком —
// весь DNS сети, поэтому тогда mosdns запускается без API (нет только счётчиков кэша).
// Конфликтуют слушатели этого порта на 127.0.0.1 и на всех адресах.
export function api_port_taken(api) {
	let port = split(api, ':')[1];
	for (let l in split(U.run('netstat -lntp').out, '\n')) {
		let f = split(trim(l), /\s+/);
		if (f[5] != 'LISTEN' || match(f[6] ?? '', /\/mosdns$/))
			continue;
		let i = rindex(f[3], ':');
		if (substr(f[3], i + 1) == port && (substr(f[3], 0, i) in [ C.MOSDNS_ADDR, '0.0.0.0', '::', '' ]))
			return true;
	}
	return false;
};

// Перехват DNS отправляет запрос устройства на первый адрес IPv4 устройства зоны, через которое он
// пришёл (redirect), — этот адрес должен слушать dnsmasq. С bind-dynamic он открывает сокеты на новые
// адреса сам, но иногда не открывает на адрес, появившийся вскоре после его старта (так бывает с
// адресом mesh-VPN при загрузке): DNS устройств этой зоны пропадает до перезапуска dnsmasq.
// devs — устройства зон, udp — вывод netstat -lnu, addrs — ip -4 -j addr show. Итог — [ { dev, addr } ]
// без сокета на :53; сокет на 0.0.0.0:53 слушает все адреса.
export function dns_unbound(devs, udp, addrs) {
	let bound = {};
	for (let l in split(udp ?? '', '\n')) {
		let f = split(trim(l), /\s+/);
		let m = (f[0] == 'udp') ? match(f[3] ?? '', /^(.+):53$/) : null;
		if (m)
			bound[m[1]] = true;
	}
	if (bound['0.0.0.0'])
		return [];
	let out = [];
	for (let l in addrs ?? []) {
		if (!(l.ifname in devs))
			continue;
		let a = filter(l.addr_info ?? [], (x) => x.family == 'inet' && !x.secondary)[0];
		if (a && !bound[a.local])
			push(out, { dev: l.ifname, addr: a.local });
	}
	return out;
};

function dns_probe(devs) {
	let addrs = null;
	try {
		addrs = json(U.run('ip -4 -j addr show').out);
	}
	catch (e) { }
	return dns_unbound(devs, U.run('netstat -lnu').out, addrs);
}

function dnsmasq_pid() {
	return trim(U.run('pidof dnsmasq').out);
}

const addr_list = (miss) => join(', ', map(miss, (m) => m.addr + ' (' + m.dev + ')'));
const addr_key = (miss) => join(' ', sort(map(miss, (m) => m.addr)));

function heal_failed(miss) {
	U.err('dnsmasq и после перезапуска не слушает ' + addr_list(miss) +
		': DNS устройств зоны не работает — проверьте, на каких интерфейсах dnsmasq принимает запросы');
}

// Адрес зоны без сокета dnsmasq — перезапуск dnsmasq: при старте он открывает сокеты на все адреса.
// Новому адресу сначала даётся до 3 с: dnsmasq открывает сокет по событию netlink, не мгновенно.
// Перезапуск — один на процесс dnsmasq и набор адресов: если и после него адрес не слушается
// (dnsmasq так настроен, например except-interface), повторять его на каждое применение и каждую
// минуту незачем — остаётся запись в журнале. Итог — адреса, которые так и не слушаются.
// fast — проверка раз в минуту из truba stats: без пауз, чтобы не задерживать замеры скорости. Итог её
// перезапуска (pending) подводит следующая проверка — если dnsmasq с тех пор не перезапускал никто другой.
export function dns_heal(devs, fast) {
	if (!length(devs) || dnsmasq_pid() == '')
		return [];
	let st = U.read_json(C.DNS_HEAL_FILE, {});
	let miss = dns_probe(devs);
	if (st.pending) {
		if (st.pid && st.pid != dnsmasq_pid())
			st = {};
		else {
			if (length(miss))
				heal_failed(miss);
			st = { pid: dnsmasq_pid(), key: addr_key(miss) };
			U.write_json(C.DNS_HEAL_FILE, st);
		}
	}
	let settled = (miss) => !length(miss) || (st.pid == dnsmasq_pid() && st.key == addr_key(miss));
	for (let i = 0; !fast && i < 3 && !settled(miss); i++) {
		sleep(1000);
		miss = dns_probe(devs);
	}
	if (settled(miss))
		return miss;

	U.warn_log('dnsmasq не слушает ' + addr_list(miss) + ' — DNS устройств зоны не работает, перезапуск dnsmasq');
	system('/etc/init.d/dnsmasq restart >/dev/null 2>&1');
	U.mkdirp(C.RUN_DIR);
	if (fast) {
		U.write_json(C.DNS_HEAL_FILE, { pending: true, pid: dnsmasq_pid() });
		return miss;
	}
	for (let i = 0; i < 10; i++) {
		sleep(500);
		miss = dns_probe(devs);
		if (!length(miss) && dnsmasq_pid() != '')
			break;
	}
	if (length(miss))
		heal_failed(miss);
	U.write_json(C.DNS_HEAL_FILE, { pid: dnsmasq_pid(), key: addr_key(miss) });
	return miss;
};

// ---- Применение ----

// DNS при включённой Маршрутизации — после загрузки таблицы nftables (ADR 0006): конфиг mosdns,
// дампы кэша, метка поколения, dnsmasq и адреса зон. Итог — адрес API mosdns или null.
export function apply(cfg, plan, hosts, gkey, lan_if) {
	if (api_port_taken(cfg.dns.api)) {
		U.warn_log(sprintf('порт %s занят другой программой: mosdns без API, счётчиков кэша на «Обзоре» не будет', cfg.dns.api));
		cfg.dns.api = null;
	}
	U.write_if_changed(C.MOSDNS_CONF, sprintf('%J', mosdns(cfg, plan, hosts)));
	// Дампы прежних поколений кэша mosdns больше не прочитает.
	prune_cache_dumps(cache_dump(cfg, plan));
	// Метка поколения меняется вместе с данными (списки, Режим, Действия Категорий):
	// procd сравнивает содержимое файла и перезапускает mosdns; mosdns.json он отслеживает сам.
	if (readfile(C.STAMP_FILE) != gkey)
		writefile(C.STAMP_FILE, gkey);
	dnsmasq_enable(cfg.dns.port);
	// Перехват направляет DNS устройств зон на адреса их устройств — их должен слушать dnsmasq.
	if (cfg.dns_hijack)
		dns_heal(lan_if);
	return cfg.dns.api;
};
