'use strict';
'require baseclass';
'require uci';

// Интерфейс Туннеля AmneziaWG (spec §5.4): разбор router.conf, перенос его в настройки network и проверки
// опций интерфейса. Это опции network, а не Трубы: в truba.schema их нет, пределы и проверки — свои.

// Ключи .conf (без регистра) → опции UCI протокола amneziawg.
const IFACE_KEYS = {
	privatekey: 'private_key', mtu: 'mtu', listenport: 'listen_port',
	jc: 'awg_jc', jmin: 'awg_jmin', jmax: 'awg_jmax',
	s1: 'awg_s1', s2: 'awg_s2', s3: 'awg_s3', s4: 'awg_s4',
	h1: 'awg_h1', h2: 'awg_h2', h3: 'awg_h3', h4: 'awg_h4',
	i1: 'awg_i1', i2: 'awg_i2', i3: 'awg_i3', i4: 'awg_i4', i5: 'awg_i5',
	headerprotectionkey: 'awg_header_protection_key',
	contentpaddingaddition: 'awg_content_padding_addition',
	rekeyaftertime: 'awg_rekey_after_time', rekeytimeout: 'awg_rekey_timeout',
	rejectaftertime: 'awg_reject_after_time', keepalivetimeout: 'awg_keepalive_timeout',
	maxhandshakeattempts: 'awg_max_handshake_attempts'
};
const IFACE_BOOL = { randomtrailers: 'awg_random_trailers', disablecookies: 'awg_disable_cookies' };
const PEER_KEYS = { publickey: 'public_key', presharedkey: 'preshared_key', persistentkeepalive: 'persistent_keepalive' };

// Параметры AWG на вкладке — опции awg_<имя>: числа (H — число или диапазон) и пакеты-приманки в формате CPS.
const NUM_PARAMS = [ 'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4' ];
const CPS_PARAMS = [ 'i1', 'i2', 'i3', 'i4', 'i5' ];

function parseConf(text) {
	const res = { iface: {}, peers: [] };
	let cur = null;
	for (let raw of String(text || '').split(/\r?\n/)) {
		const line = raw.trim();
		if (!line || line[0] == '#' || line[0] == ';')
			continue;
		const sec = line.match(/^\[(\w+)\]$/);
		if (sec) {
			const name = sec[1].toLowerCase();
			if (name == 'interface')
				cur = res.iface;
			else if (name == 'peer')
				res.peers.push(cur = {});
			else
				cur = null;
			continue;
		}
		const kv = line.match(/^([A-Za-z0-9]+)\s*=\s*(.*)$/);
		if (kv && cur)
			cur[kv[1].toLowerCase()] = kv[2];
	}
	if (!res.iface.privatekey)
		throw new Error(_('No PrivateKey in the [Interface] section'));
	if (!res.peers.length || !res.peers[0].publickey)
		throw new Error(_('No [Peer] section with PublicKey'));
	return res;
}

// Настройки network из router.conf — в UCI браузера: прежние опции AWG и пиры снимаются, чтобы от прошлого
// импорта ничего не осталось. zone — зона Туннеля (consts.fw_zone): интерфейс должен в неё входить.
function applyConf(iface, conf, zone) {
	if (!uci.get('network', iface))
		uci.add('network', 'interface', iface);
	uci.set('network', iface, 'proto', 'amneziawg');

	for (let k in IFACE_KEYS)
		uci.unset('network', iface, IFACE_KEYS[k]);
	for (let k in IFACE_BOOL)
		uci.unset('network', iface, IFACE_BOOL[k]);

	for (let k in conf.iface) {
		if (IFACE_KEYS[k])
			uci.set('network', iface, IFACE_KEYS[k], conf.iface[k]);
		else if (IFACE_BOOL[k])
			uci.set('network', iface, IFACE_BOOL[k], /^(on|1|true|yes)$/i.test(conf.iface[k]) ? '1' : '0');
	}
	if (conf.iface.address)
		uci.set('network', iface, 'addresses', conf.iface.address.split(',').map((a) => a.trim()).filter((a) => a));

	for (let s of uci.sections('network', 'amneziawg_' + iface))
		uci.remove('network', s['.name']);

	for (let p of conf.peers) {
		const sid = uci.add('network', 'amneziawg_' + iface);
		for (let k in PEER_KEYS)
			if (p[k] != null)
				uci.set('network', sid, PEER_KEYS[k], p[k]);
		if (p.endpoint) {
			const m = p.endpoint.match(/^\[?([^\]]+?)\]?:(\d+)$/);
			if (m) {
				uci.set('network', sid, 'endpoint_host', m[1]);
				uci.set('network', sid, 'endpoint_port', m[2]);
			}
		}
		uci.set('network', sid, 'allowed_ips', (p.allowedips || '0.0.0.0/0').split(',').map((a) => a.trim()).filter((a) => a));
		// Маршруты Туннеля ведёт служба truba (таблица 77), а не netifd.
		uci.set('network', sid, 'route_allowed_ips', '0');
		uci.set('network', sid, 'description', 'Truba');
	}

	const z = uci.sections('firewall', 'zone').find((s) => s.name == zone);
	if (z) {
		const nets = L.toArray(z.network);
		if (!nets.includes(iface))
			uci.set('firewall', z['.name'], 'network', nets.concat([ iface ]));
	}
}

// Пир Трубы — первая секция amneziawg_<iface>; null — пиров нет.
function peerSection(iface) {
	return uci.sections('network', 'amneziawg_' + iface)[0]?.['.name'] ?? null;
}

// Интерфейс Туннеля настроен — его секция есть в UCI браузера. Через sections, а не uci.get: get целой
// секции не видит, что её удалили в браузере.
function configured(iface) {
	return uci.sections('network', 'interface').some((s) => s['.name'] == iface);
}

// MTU интерфейса: install-vps.sh подбирает его под сеть VPS, при сети уже 1367 — ниже 1280.
const MTU_LO = 576, MTU_HI = 1500;   // опция network

function mtuError(v) {
	v = String(v ?? '');
	if (v === '' || (/^\d+$/.test(v) && +v >= MTU_LO && +v <= MTU_HI))
		return null;
	return _('Enter a whole number from %d to %d').format(MTU_LO, MTU_HI);
}

// Число или диапазон «от-до» (AmneziaWG 3.1: случайное значение из него) в пределах 0–max.
function rangeError(v, max) {
	v = String(v ?? '');
	const m = v.match(/^(\d+)(?:-(\d+))?$/);
	const lo = m ? +m[1] : NaN, hi = m ? +(m[2] ?? m[1]) : NaN;
	return (v === '' || (lo <= hi && hi <= max)) ? null : _('A number or a range «from-to» within 0–%d').format(max);
}

// Заголовки H1–H4 — 32-битные числа.
const H_MAX = 4294967295;

// Параметр AWG k (имя без awg_): проверки прежней страницы. S1–S4 и добавка к пакетам зависят от ключа
// защиты заголовков и RandomTrailers — они приходят импортом router.conf.
function paramError(iface, k, v) {
	v = String(v ?? '');
	if (v === '' || CPS_PARAMS.includes(k))
		return null;
	if (k == 'content_padding_addition') {
		// Добавку модуль берёт вместо RandomTrailers: с ними она их бы отменила.
		if (uci.get('network', iface, 'awg_random_trailers') == '1')
			return _('Leave empty with random trailers: the module would use the padding instead of them');
		return rangeError(v, 65535);
	}
	if (/^h\d$/.test(k))
		return rangeError(v, H_MAX);
	if (!/^\d+$/.test(v))
		return _('Enter a whole number');
	if (/^s\d$/.test(k) && uci.get('network', iface, 'awg_header_protection_key') && +v < 12)
		return _('With header protection S1–S4 must be at least 12');
	return null;
}

// Версия протокола, которая нужна параметрам интерфейса, — как её определяет install-vps.sh
// (awg_proto_supported): 3.1 — защита заголовков, DisableCookies, RandomTrailers, добавка к пакетам,
// диапазон Keepalive; 2.0 — S3/S4, диапазоны H, I1–I5; 1.0 — остальные параметры. Без них — null.
function version(iface) {
	const opt = (k) => String(uci.get('network', iface, 'awg_' + k) ?? '');
	const has = (k) => opt(k) !== '';
	const peer = peerSection(iface);
	const ka = String((peer && uci.get('network', peer, 'persistent_keepalive')) ?? '');
	if ([ 'header_protection_key', 'disable_cookies', 'random_trailers', 'content_padding_addition' ].some(has) || ka.includes('-'))
		return '3.1';
	if (has('s3') || has('s4') || CPS_PARAMS.some(has) || [ 'h1', 'h2', 'h3', 'h4' ].some((k) => opt(k).includes('-')))
		return '2.0';
	return NUM_PARAMS.some(has) ? '1.0' : null;
}

return baseclass.extend({
	IFACE_KEYS, IFACE_BOOL, PEER_KEYS, NUM_PARAMS, CPS_PARAMS,
	parseConf, applyConf, peerSection, configured, mtuError, rangeError, paramError, version
});
