#!/bin/sh
# Проверка на стороне Роутера после tests/luci/apply.js (этап задаётся аргументом).
FAILS=0
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok    $name"; else echo "FAIL  $name"; FAILS=$((FAILS + 1)); fi; }

case "$1" in
step1)
	check "UCI: youtube=direct в Режиме all" sh -c "uci show truba | grep -q \"tag='youtube'\""
	check "служба перестроила порядок: youtube=direct" grep -q 'youtube=direct' /var/run/truba/applied.json
	check "mosdns получил новый конфиг (youtube.txt)" grep -q 'youtube.txt' /var/etc/truba/mosdns.json
	;;
step2)
	check "UCI: устройство console" sh -c "uci show truba | grep -q \"name='console'\""
	check "nft: MAC в dev_tunnel" sh -c "nft list set inet truba dev_tunnel | grep -qi '02:11:22:33:44:55'"
	;;
step3)
	check "UCI: routing=0" test "$(uci -q get truba.main.routing)" = 0
	check "nft: минимальная таблица" sh -c "! nft list table inet truba | grep -q classify"
	check "mosdns остановлен" sh -c "! pidof mosdns"
	check "dnsmasq восстановлен" sh -c "! uci -q get dhcp.@dnsmasq[0].server | grep -q 5335"
	;;
esac
exit "$FAILS"
