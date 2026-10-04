// Проверка слоя Трубы через STUN: внешний IP = IP Трубы, порт сохраняется,
// отображение одинаково для разных серверов. Полный тест RFC 5780 — с ПК в сети.
'use strict';

import * as socket from 'socket';
import { rand } from 'math';
import * as C from 'truba.const';
import * as F from 'truba.conf';

const SERVERS = [ [ 'stun.l.google.com', '19302' ], [ 'stun.cloudflare.com', '3478' ] ];

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

export function run() {
	let cfg = F.load();
	let vps = F.vps_ip(F.tunnel_info(cfg.iface));
	let s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (!s)
		return { ok: false, error: 'socket: ' + socket.error() };
	s.setopt(socket.SOL_SOCKET, socket.SO_MARK, C.MARK_TUNNEL);
	if (!s.bind({ address: '0.0.0.0', port: 0 }))
		return { ok: false, error: 'bind: ' + socket.error() };
	let local = s.sockname()?.port;

	let results = [];
	for (let srv in SERVERS) {
		let ai = socket.addrinfo(srv[0], srv[1], { family: socket.AF_INET, socktype: socket.SOCK_DGRAM });
		if (!ai?.[0]) {
			push(results, { server: srv[0], error: 'dns' });
			continue;
		}
		let tid = '';
		for (let i = 0; i < 12; i++)
			tid += chr(int(rand() * 256) & 255);
		let req = chr(0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42) + tid;
		let mapped = null;
		for (let attempt = 0; attempt < 3 && !mapped; attempt++) {
			s.send(req, 0, ai[0].addr);
			let pr = socket.poll(1500, [ s, socket.POLLIN ]);
			if (!length(pr ?? []) || !(pr[0][1] & socket.POLLIN))
				continue;
			let resp = s.recv(2048);
			mapped = resp ? parse_mapped(resp, tid) : null;
		}
		push(results, mapped ? { server: srv[0], mapped } : { server: srv[0], error: 'timeout' });
	}
	s.close();

	let ok = filter(results, r => r.mapped);
	let res = { local_port: local, vps_ip: vps, results };
	res.external_ip = ok[0]?.mapped?.address;
	res.ip_is_vps = (length(ok) > 0 && vps != null && length(filter(ok, r => r.mapped.address == vps)) == length(ok));
	res.port_preserved = (length(ok) > 0 && length(filter(ok, r => r.mapped.port == local)) == length(ok));
	res.consistent = (length(ok) >= 2 && ok[0].mapped.address == ok[1].mapped.address && ok[0].mapped.port == ok[1].mapped.port);
	res.ok = res.ip_is_vps && res.port_preserved && (length(ok) < 2 || res.consistent);
	return res;
};
