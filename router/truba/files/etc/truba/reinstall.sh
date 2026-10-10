#!/bin/sh
# Переустановка пакетов Трубы после sysupgrade (ADR 0004).
# Запускается из /etc/rc.local; если truba уже установлена — ничего не делает.

log() { logger -t truba-reinstall "$*"; }

# sysupgrade сохраняет /etc/config/dhcp, где Труба направила dnsmasq в mosdns, а пакетов
# Трубы и mosdns после прошивки ещё нет: dnsmasq шлёт запросы в пустой порт. Без DNS остаётся
# вся сеть и сам Роутер (dnsmasq — его системный резолвер, localuse), поэтому ни nslookup ниже,
# ни apk не прошли бы никогда. Исходные значения — из бэкапа Трубы (/etc/truba в keep.d),
# как при truba teardown; после установки служба снова направит dnsmasq в mosdns.
restore_dnsmasq() {
	local b=/etc/truba/state/dnsmasq.json sid k v port
	if [ -f "$b" ]; then
		sid="$(jsonfilter -q -i "$b" -e '@.sid')"
		[ -n "$sid" ] && [ "$(uci -q get "dhcp.$sid")" = dnsmasq ] || sid='@dnsmasq[0]'
		for k in noresolv cachesize; do
			v="$(jsonfilter -q -i "$b" -e "@.$k")"
			if [ -n "$v" ]; then uci -q set "dhcp.$sid.$k=$v"; else uci -q delete "dhcp.$sid.$k"; fi
		done
		uci -q delete "dhcp.$sid.server"
		for v in $(jsonfilter -q -i "$b" -e '@.server[*]'); do
			uci -q add_list "dhcp.$sid.server=$v"
		done
		rm -f "$b"
	else
		# Бэкапа нет — убрать хотя бы адрес mosdns; без других серверов — снова DNS провайдера.
		port="$(uci -q get truba.dns.port)"
		v="127.0.0.1#${port:-5335}"
		uci -q get dhcp.@dnsmasq[0].server | grep -qF "$v" || return 0
		uci -q del_list "dhcp.@dnsmasq[0].server=$v"
		[ -n "$(uci -q get dhcp.@dnsmasq[0].server)" ] || uci -q delete dhcp.@dnsmasq[0].noresolv
	fi
	uci -q commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	log "DNS сети возвращён к настройкам до Трубы: mosdns появится вместе с пакетами"
}

apk list -I truba 2>/dev/null | grep -q '^truba-' && exit 0

restore_dnsmasq

# Ждём интернет (до 10 минут).
i=0
until nslookup downloads.immortalwrt.org >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -ge 60 ] && { log "нет интернета — пакеты Трубы не переустановлены"; exit 1; }
	sleep 10
done

. /etc/os-release
LIST=/etc/apk/repositories.d/truba.list
if [ ! -f "$LIST" ]; then
	log "нет $LIST — фид Трубы не настроен"
	exit 1
fi

# Каталог фида — под текущую версию ImmortalWrt.
sed -i -E "s#/[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?/#/${VERSION}/#" "$LIST"

if ! apk update >/dev/null 2>&1; then
	log "apk update не прошёл (фид: $(cat "$LIST"))"
	exit 1
fi

if apk add kmod-amneziawg >/dev/null 2>&1; then
	log "kmod-amneziawg установлен для ${VERSION}"
else
	# Остальное всё равно ставим: служба и интерфейс покажут, что Туннеля нет.
	log "под ImmortalWrt ${VERSION} в фиде ещё нет kmod-amneziawg — Туннель не поднимется. Когда сборка появится: apk update && apk add kmod-amneziawg && /etc/init.d/network restart"
fi

PKGS="amneziawg-tools luci-proto-amneziawg truba luci-app-truba"
apk list -I luci-i18n-base-ru 2>/dev/null | grep -q '^luci-i18n-base-ru-' && PKGS="$PKGS luci-i18n-truba-ru"

if apk add $PKGS >/dev/null 2>&1; then
	log "пакеты Трубы переустановлены: $PKGS"
	# restart, а не reload: обработчик протокола amneziawg netifd находит только при запуске,
	# без этого Туннель остаётся «proto none, NO_DEVICE» до перезагрузки.
	/etc/init.d/network restart
	/etc/init.d/truba enable
	/etc/init.d/truba start
else
	log "не удалось установить: $PKGS"
	exit 1
fi
