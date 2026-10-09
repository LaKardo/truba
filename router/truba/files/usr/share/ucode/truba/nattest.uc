// Проверка слоя Трубы через STUN: внешний IP = IP Трубы, порт сохраняется,
// отображение одинаково для разных серверов. Полный тест RFC 5780 — с ПК в сети.
// Запросы ко всем серверам уходят разом с одного сокета, поэтому худший случай —
// одно окно повторов (3 × 1,5 с), а не окно на каждый сервер. Итог сохраняется
// в NAT_FILE: «Обзор» показывает его без новой проверки.
'use strict';

import * as socket from 'socket';
import { rand } from 'math';
import * as C from 'truba.const';
import * as U from 'truba.util';
import * as F from 'truba.conf';
import * as N from 'truba.net';

const DEFAULT_SERVERS =[ 'stun.l.google.com:19302', 'stun.cloudflare.com:3478', 'stun1.l.google.com:19302' ];
const TRIES = 3, WAIT = 1500;

function be16(s, i) { return (ord(s, i) << 8) | ord(s, i + 1); }

function parse_mapped(resp, tid) {
	if (length(resp) < 20 || be16(resp, 0) != 0x0101 || substr(resp, 8, 12) != tid)
		return null;
	let len = be16(resp, 2), p = 20, end = 20 + len, mapped = null;
	while (p + 4 <= end && p + 4 <= length(resp)) {
		let at = be16(resp, p), al = be16(resp, p + 2);
		let v = p + 4;
		if ((at == 0x0020 || at == 0x0001) && al >= 8 && ord(resp, v + 1) == 0x01) {
			let port = be16(resp, v + 2);
			let a = [ ord(resp, v + 4), ord(resp, v + 5), ord(resp, v + 6), ord(resp, v + 7) ];
			if (at == 0x0020) {
				port ^= 0x2112;
				a = [ a[0] ^ 0x21, a[1] ^ 0x12, a[2] ^ 0xa4, a[3] ^ 0x42 ];
			}
			mapped = { address: arrtoip(a), port };
			if (at == 0x0020)
				break;
		}
		p = v + ((al + 3) & ~3);
	}
	return mapped;
}

// «host:port» → [ host, port ]; без порта — стандартный 3478. Деструктуризации в ucode нет.
function split_server(s) {
	let m = match(s, /^(.+):([0-9]+)$/);
	return m ? [ m[1], m[2] ] : [ s, '3478' ];
}

// Опросить серверы одним сокетом: сначала всем по запросу, затем повторы только тем,
// кто ещё не ответил. Записи servers дополняются mapped и rtt (мс) или error.
function query(s, servers) {
	let pending = [];
	for (let r in servers) {
		let hp = split_server(r.server);
		let ai = socket.addrinfo(hp[0], hp[1], { family: socket.AF_INET, socktype: socket.SOCK_DGRAM });
		if (!ai?.[0]) {
			r.error = 'dns';
			continue;
		}
		// Свой случайный transaction ID у каждого сервера: по нему ответ находит свой запрос.
		// rand() в ucode — целое от 0 до RAND_MAX, а не дробь.
		let tid = '';
		for (let i = 0; i < 12; i++)
			tid += chr(rand() % 256);
		r.error = 'timeout';
		push(pending, { r, tid, addr: ai[0].addr, req: chr(0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42) + tid });
	}

	for (let attempt = 0; attempt < TRIES && length(pending); attempt++) {
		let sent = U.now_ms();
		for (let p in pending)
			s.send(p.req, 0, p.addr);
		let left = WAIT;
		while (left > 0 && length(pending)) {
			let pr = socket.poll(int(left), [ s, socket.POLLIN ]);
			if (length(pr ?? []) && (pr[0][1] & socket.POLLIN)) {
				let resp = s.recv(2048);
				let tid = resp ? substr(resp, 8, 12) : null;
				for (let i = 0; i < length(pending); i++) {
					let p = pending[i];
					let mapped = (p.tid == tid) ? parse_mapped(resp, tid) : null;
					if (mapped) {
						p.r.mapped = mapped;
						p.r.rtt = int(U.now_ms() - sent + 0.5);
						delete p.r.error;
						splice(pending, i, 1);
						break;
					}
				}
			}
			left = WAIT - (U.now_ms() - sent);
		}
	}
}

// auto — проверку запустил watchdog после подъёма Туннеля, а не кнопка.
export function run(auto) {
	let cfg = F.load();
	let tinfo = F.tunnel_info(cfg.iface);
	let res = {
		time: time(), auto: !!auto, ok: false,
		vps_ip: U.read_json(C.APPLIED_FILE, null)?.vps ?? F.vps_ip(tinfo),
		servers: map(length(cfg.stun) ? cfg.stun : DEFAULT_SERVERS, (srv) => ({ server: srv })),
	};
	let save = () => {
		U.mkdirp(C.RUN_DIR);
		U.write_json(C.NAT_FILE, res);
		return res;
	};

	if (!tinfo.exists) {
		res.error = 'not_configured';
		return save();
	}
	if (tinfo.disabled || !N.iface_up(cfg.iface).up) {
		res.error = 'tunnel_down';
		return save();
	}

	let s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (!s || !s.setopt(socket.SOL_SOCKET, socket.SO_MARK, C.MARK_TUNNEL) || !s.bind({ address: '0.0.0.0', port: 0 })) {
		res.error = 'socket';
		res.detail = socket.error();
		s?.close();
		return save();
	}
	res.local_port = s.sockname()?.port;
	query(s, res.servers);
	s.close();

	let ok = filter(res.servers, (r) => r.mapped);
	res.answered = length(ok);
	if (!length(ok)) {
		res.error = 'no_answer';
		return save();
	}
	let all = (f) => length(filter(ok, f)) == length(ok);
	res.external_ip = ok[0].mapped.address;
	res.external_port = ok[0].mapped.port;
	res.ip_is_vps = res.vps_ip != null && all((r) => r.mapped.address == res.vps_ip);
	res.port_preserved = all((r) => r.mapped.port == res.local_port);
	// С одним ответом сравнить отображения не с чем: null — «не проверено», а не «нет».
	res.consistent = (length(ok) >= 2)
		? all((r) => r.mapped.address == res.external_ip && r.mapped.port == res.external_port)
		: null;
	res.ok = res.ip_is_vps && res.port_preserved && res.consistent !== false;
	return save();
};
