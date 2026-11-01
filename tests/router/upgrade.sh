#!/bin/sh
# Настоящая установка и обновление пакетов через apk (ADR 0019): postinst запускает службу посреди
# транзакции, как на Роутере. Только в CI (build.yml): нужны собранные .apk. Один случай — один
# контейнер под procd без сети; зависимости уже в образе, пакеты — из смонтированных каталогов:
#   /new — новые truba и luci-app-truba, /old — прежняя truba из опубликованного фида.
#   sh upgrade.sh 1 — чистая установка; 2 — обновление изменённого конфига;
#   3 — обновление конфига без правок (только вывод); 4 — удаление и повторная установка.
. /repo/tests/lib/check.sh

CASE="$1"
NEW_TRUBA="$(ls /new/truba-[0-9]*.apk)"
NEW_LUCI="$(ls /new/luci-app-truba-[0-9]*.apk)"
OLD_TRUBA="$(ls /old/truba-[0-9]*.apk 2>/dev/null)"
add() { apk add --allow-untrusted --no-network "$@"; }
ver() { apk list -I "$1" 2>/dev/null | sed -n "s/^$1-\([0-9][^ ]*\) .*/\1/p"; }
rt() { uci -q get truba.main.routing; }
rules() { uci -q show truba | grep -c '=rule$'; }
no_default() { ! ip route show table 77 2>/dev/null | grep -q default; }
started() { [ -s "$APPLIED" ]; }

# DNS сети — свой сервер, который знает только up.trubatest: отвечает он, значит dnsmasq не ушёл в mosdns.
dnsmasq --conf-file=/dev/null --port=5399 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
	--address=/up.trubatest/5.6.7.8 --pid-file=/tmp/dm-up.pid
uci -q batch <<-EOF
	delete dhcp.@dnsmasq[0].server
	add_list dhcp.@dnsmasq[0].server='127.0.0.1#5399'
	set dhcp.@dnsmasq[0].noresolv='1'
	commit dhcp
EOF
/etc/init.d/dnsmasq restart >/dev/null 2>&1
up_ok() { nslookup up.trubatest 127.0.0.1 2>&1 | grep -q 5.6.7.8; }
wait_for 15 up_ok || fail "стенд: DNS сети не отвечает до установки"

# Сеть не тронута: Маршрутизация выкл, в таблице 77 нет default, mosdns не запущен, DNS — прежний.
untouched() {
	check "$1: служба запущена, applied.json — routing: false" eval 'wait_for 30 started && [ "$(applied "@.routing")" = false ]'
	check "$1: Маршрутизация выключена" test "$(rt)" = 0
	check "$1: в таблице 77 нет default" no_default
	check "$1: mosdns не запущен" eval '! pidof mosdns'
	check "$1: dnsmasq не направлен в mosdns, DNS сети отвечает" \
		eval '! uci -q get dhcp.@dnsmasq[0].server | grep -q "127.0.0.1#5335" && up_ok'
}

# Прежняя версия с включённой Маршрутизацией, как у владельца с настроенным Туннелем.
old() {
	check "прежняя версия установлена" add "$OLD_TRUBA"
	wait_for 30 started
	uci set truba.main.routing='1'; uci commit truba
	echo "прежняя версия: $(ver truba)"
}

case "$CASE" in
1)
	section "чистая установка (CUJ 1)"
	check "apk add truba luci-app-truba одной командой" add "$NEW_TRUBA" "$NEW_LUCI"
	check "оба пакета установлены" eval '[ -n "$(ver truba)" ] && [ -n "$(ver luci-app-truba)" ]'
	untouched "чистая установка"
	;;
2)
	section "обновление изменённого конфига (CUJ 4)"
	old
	N="$(rules)"
	mkdir -p /tmp/old && apk extract --allow-untrusted --destination /tmp/old "$OLD_TRUBA" >/dev/null 2>&1
	check "конфиг отличается от поставляемого" eval '! cmp -s /etc/config/truba /tmp/old/etc/config/truba'
	check "apk add новой версии" add "$NEW_TRUBA"
	check "версия новая" eval '[ "$(ver truba)" = "$(basename "$NEW_TRUBA" .apk | sed "s/^truba-//")" ]'
	check "Маршрутизация осталась включённой" test "$(rt)" = 1
	check "Категории на месте: $N" test "$(rules)" = "$N"
	[ -f /etc/config/truba.apk-new ] && echo "рядом с конфигом — /etc/config/truba.apk-new"
	;;
3)
	section "обновление конфига без правок (только вывод)"
	old
	mkdir -p /tmp/old
	if apk extract --allow-untrusted --destination /tmp/old "$OLD_TRUBA" >/dev/null 2>&1; then
		cp /tmp/old/etc/config/truba /etc/config/truba
		add "$NEW_TRUBA" >/dev/null 2>&1
		echo "конфиг как поставлялся → после обновления routing='$(rt)', Категорий: $(rules)$([ -f /etc/config/truba.apk-new ] && echo ', есть truba.apk-new')"
	else
		echo "apk extract не смог распаковать прежнюю версию — случай пропущен"
	fi
	;;
4)
	section "удаление и повторная установка (CUJ 4b)"
	old
	check "apk del truba" apk del truba
	check "конфиг остался после удаления" eval '[ -f /etc/config/truba ] && [ "$(rt)" = 1 ]'
	check "apk add новой версии" add "$NEW_TRUBA" "$NEW_LUCI"
	untouched "повторная установка"
	;;
*)
	fail "неизвестный случай: $CASE"
	;;
esac

kill "$(cat /tmp/dm-up.pid)" 2>/dev/null
finish
