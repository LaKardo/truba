#!/bin/sh
# Переустановка пакетов Трубы после sysupgrade (ADR 0004).
# Запускается из /etc/rc.local; если truba уже установлена — ничего не делает.

log() { logger -t truba-reinstall "$*"; }

apk list -I truba 2>/dev/null | grep -q '^truba-' && exit 0

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
	/etc/init.d/network reload
	/etc/init.d/truba enable
	/etc/init.d/truba start
else
	log "не удалось установить: $PKGS"
	exit 1
fi
