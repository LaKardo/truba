#!/bin/sh
# Интеграционный тест пакета truba внутри контейнера ImmortalWrt с procd (/sbin/init).
# Туннель имитируется dummy-интерфейсом: модуля amneziawg в ядре контейнера нет.
# Ожидает: /repo — корень репозитория, /dat — каталог с geoip.dat и geosite.dat.

set -u
FAILS=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }
# wait_for N cmd… — ждать до N секунд, пока команда не выполнится успешно.
wait_for() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 1; n=$((n - 1)); done; return 1; }
# apply / update-lists / rollback-lists и rc.common Трубы. Скобки в шаблонах — чтобы
# pgrep не находил собственную обёртку sh -c, в командной строке которой есть шаблон.
busy() { pgrep -f '/usr/sbin/truba [aur]'; pgrep -f 'init[.]d/truba'; }
# Нет ни одного такого процесса (взаимоблок оставил бы их висеть).
idle() { [ -z "$(busy)" ]; }
wait_idle() { wait_for "$1" idle; }
# После провала — снять зависшие процессы, чтобы остальные проверки не повисли следом.
unstick() { for p in $(busy) $(pgrep -f 'flock 1000'); do kill "$p" 2>/dev/null; done; return 0; }

echo "== зависимости (ставятся в образ заранее: под procd у контейнера нет сети)"
for p in mosdns ucode-mod-socket curl ip-full; do
	apk list -I "$p" 2>/dev/null | grep -q "^$p-" || { echo "нет пакета $p в образе"; exit 1; }
done

echo "== копирование файлов пакета"
cp -a /repo/router/truba/files/. /
chmod +x /usr/sbin/truba /etc/init.d/truba /etc/truba/reinstall.sh /usr/share/truba/uninstall.sh /etc/uci-defaults/90-truba
mkdir -p /etc/truba/lists
cp /dat/geoip.dat /dat/geosite.dat /etc/truba/lists/
for f in geoip.dat geosite.dat; do sha256sum /etc/truba/lists/$f | awk '{print $1"  "FILENAME}' FILENAME=$f > /etc/truba/lists/$f.sha256sum; done

echo "== домашняя сеть и имитация Туннеля"
ip link add lan0 type dummy 2>/dev/null
ip link add awg0 type dummy 2>/dev/null
ip link set awg0 up
uci -q batch <<-'EOF'
	set network.brlan=device
	set network.brlan.name='br-lan'
	set network.brlan.type='bridge'
	add_list network.brlan.ports='lan0'
	set network.lan=interface
	set network.lan.device='br-lan'
	set network.lan.proto='static'
	set network.lan.ipaddr='192.168.1.1'
	set network.lan.netmask='255.255.255.0'
EOF
uci -q batch <<-'EOF'
	set network.awg0=interface
	set network.awg0.proto='static'
	set network.awg0.device='awg0'
	set network.awg0.ipaddr='10.77.77.2'
	set network.awg0.netmask='255.255.255.252'
	add network amneziawg_awg0
	set network.@amneziawg_awg0[-1].endpoint_host='203.0.113.10'
	set network.@amneziawg_awg0[-1].endpoint_port='51820'
	commit network
EOF
/etc/init.d/network reload; sleep 3

echo "== uci-defaults"
sh /etc/uci-defaults/90-truba
check "зона truba создана" test "$(uci -q get firewall.truba.name)" = truba
check "форвардинг lan→truba" test "$(uci -q get firewall.lan_truba.dest)" = truba
check "fullcone включён" test "$(uci -q get firewall.@defaults[0].fullcone)" = 1
check "аппаратное ускорение выключено" test "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 0
check "IPv6 lan→wan REJECT" test "$(uci -q get firewall.truba_no_ipv6_inet.family)" = ipv6
check "IPv6 lan не тронут (ra)" test "$(uci -q get dhcp.lan.ra)" != disabled
check "Стартовые настройки: 8 правил" test "$(uci -q show truba | grep -c '=rule$')" -eq 8
/etc/init.d/firewall reload >/dev/null 2>&1

echo "== apply (Маршрутизация вкл)"
uci set truba.watchdog.enabled='0'; uci commit truba
/etc/init.d/truba enable
/etc/init.d/truba start; sleep 4
APPLIED="$(cat /var/run/truba/applied.json 2>/dev/null)"
echo "$APPLIED" | head -c 600; echo
check "applied.json без ошибки" sh -c "! grep -q '\"error\"' /var/run/truba/applied.json"
check "таблица inet truba есть" nft list table inet truba
check "набор gi_direct4 наполнен geoip:ru" sh -c "nft list set inet truba gi_direct4 | grep -q '5\.'"
check "bypass4 содержит IP Трубы" sh -c "nft list set inet truba bypass4 | grep -q '203.0.113.10'"
check "bypass4 содержит подсеть Туннеля" sh -c "nft list set inet truba bypass4 | grep -q '10.77.77.0/30'"
check "lan_if = br-lan" sh -c "nft list set inet truba lan_if | grep -q br-lan"
check "перехват DNS (только IPv4)" sh -c "nft list chain inet truba dns_hijack | grep -q 'meta nfproto ipv4'"
check "IPv6 пропускается первым правилом" sh -c "nft list chain inet truba prerouting | grep -q 'meta nfproto != ipv4 return'"
check "ip rule fwmark → 77" sh -c "ip rule show | grep -q 'fwmark 0x10000/0xff0000 lookup 77'"
check "ip rule oif awg0 → 77" sh -c "ip rule show | grep -q 'oif awg0 lookup 77'"
check "table 77: default dev awg0" sh -c "ip route show table 77 | grep -q 'default dev awg0'"
check "table 77: подсеть Туннеля" sh -c "ip route show table 77 | grep -q '10.77.77.0/30 dev awg0'"
check "dnsmasq → mosdns" sh -c "uci -q get dhcp.@dnsmasq[0].server | grep -q '127.0.0.1#5335'"
check "dnsmasq без кэша" test "$(uci -q get dhcp.@dnsmasq[0].cachesize)" = 0
check "бэкап dnsmasq сохранён" test -f /etc/truba/state/dnsmasq.json
check "cron: блок обновления" grep -q 'truba update-lists' /etc/crontabs/root
check "mosdns запущен" pidof mosdns
check "mosdns слушает 5335" sh -c "netstat -lnu 2>/dev/null | grep -q ':5335' || ss -lnu | grep -q ':5335'"

echo "== порядок Категорий (узкие раньше широких)"
grep -o '"geosite_order":[^]]*' /var/run/truba/applied.json
check "category-cdn-ru раньше category-ru" sh -c "grep -o '\"geosite_order\":[^]]*' /var/run/truba/applied.json | grep -q 'category-cdn-ru=direct.*category-ru=direct'"

echo "== DNS через mosdns: Категория «Напрямую» (Яндекс DoT)"
nslookup gosuslugi.ru 127.0.0.1 >/tmp/ns.out 2>&1; cat /tmp/ns.out | tail -4
if grep -q '^Name:' /tmp/ns.out; then
	check "IP gosuslugi.ru попал в gs_direct4" sh -c "nft list set inet truba gs_direct4 | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'"
else
	echo "skip  нет доступа к Яндекс DoT из контейнера"
fi
ADS="$(sed -n '1s/^domain://p' /var/lib/truba/geosite/category-ads.txt)"
check "AAAA → пусто" sh -c "! nslookup -type=AAAA google.com 127.0.0.1 2>/dev/null | grep -q 'has AAAA\|Address: .*:'"
check "Блок: $ADS (category-ads) → NXDOMAIN" sh -c "nslookup $ADS 127.0.0.1 2>&1 | grep -qiE 'NXDOMAIN|can.t find'"
check "Блок: поддомен sub.$ADS тоже" sh -c "nslookup sub.$ADS 127.0.0.1 2>&1 | grep -qiE 'NXDOMAIN|can.t find'"

echo "== truba check"
/usr/sbin/truba check 77.88.8.8 > /tmp/chk.json; head -c 400 /tmp/chk.json; echo
check "check IP из geoip:ru → direct" grep -q '"action": "direct"' /tmp/chk.json
/usr/sbin/truba check "$ADS" > /tmp/chk2.json
check "check $ADS → block" grep -q '"action": "block"' /tmp/chk2.json
FULL="$(sed -n 's/^full://p' /var/lib/truba/geosite/youtube.txt | head -1)"
/usr/sbin/truba check "x.$FULL" > /tmp/chk5.json
check "full:$FULL не совпадает с поддоменом x.$FULL" sh -c "! grep -q '\"entry\": \"full:$FULL\"' /tmp/chk5.json"
/usr/sbin/truba check "$FULL" > /tmp/chk6.json
check "full:$FULL совпадает точно" grep -q "\"entry\": \"full:$FULL\"" /tmp/chk6.json
/usr/sbin/truba check "dualstack.apiproxy-x1.amazonaws.com" > /tmp/chk7.json
check "regexp из netflix срабатывает" grep -q '"tag": "netflix"' /tmp/chk7.json
/usr/sbin/truba check 8.8.8.8 > /tmp/chk3.json
check "check 8.8.8.8 → tunnel (Режим «Всё в туннель»)" grep -q '"action": "tunnel"' /tmp/chk3.json
/usr/sbin/truba check 192.0.2.55 > /tmp/chk3b.json
check "check 192.0.2.55 → direct (geoip:private)" grep -q '"reason": "geoip"' /tmp/chk3b.json

echo "== Политика устройства"
uci -q batch <<-'EOF'
	add truba device
	set truba.@device[-1].name='ps5'
	set truba.@device[-1].mac='AA:BB:CC:DD:EE:FF'
	set truba.@device[-1].policy='tunnel'
	commit truba
EOF
/etc/init.d/truba reload; sleep 3
check "MAC в dev_tunnel" sh -c "nft list set inet truba dev_tunnel | grep -qi 'aa:bb:cc:dd:ee:ff'"
if grep -q '^Name:' /tmp/ns.out; then
	check "gs_direct4 сохранён при перезагрузке правил" sh -c "nft list set inet truba gs_direct4 | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'"
else
	nft add element inet truba gs_direct4 '{ 198.51.100.7 }'
	/etc/init.d/truba reload; sleep 3
	check "gs_direct4 сохранён при перезагрузке правил" sh -c "nft list set inet truba gs_direct4 | grep -q 198.51.100.7"
fi

echo "== Аварийная блокировка"
echo '{"state":"down"}' > /var/run/truba/health.json
uci set truba.watchdog.enabled='1'; uci commit truba
/usr/sbin/truba routes
check "down + блокировка → blackhole" sh -c "ip route show table 77 | grep -q 'blackhole default'"
uci set truba.main.killswitch='0'; uci commit truba
/usr/sbin/truba routes
check "down без блокировки → нет default" sh -c "! ip route show table 77 | grep -q default"
echo '{"state":"healthy"}' > /var/run/truba/health.json
uci set truba.main.killswitch='1'; uci set truba.watchdog.enabled='0'; uci commit truba
/usr/sbin/truba routes
check "healthy → default dev awg0" sh -c "ip route show table 77 | grep -q 'default dev awg0'"

echo "== Маршрутизация выкл (минимальный режим)"
uci set truba.main.routing='0'; uci commit truba
/etc/init.d/truba reload; sleep 3
check "минимальная таблица: нет classify" sh -c "! nft list table inet truba | grep -q classify"
check "минимальная таблица: INBOUND остаётся" sh -c "nft list chain inet truba prerouting | grep -q 'ct mark set 0x00040000'"
check "dnsmasq восстановлен" sh -c "! uci -q get dhcp.@dnsmasq[0].server | grep -q 5335"
check "бэкап dnsmasq удалён" test ! -f /etc/truba/state/dnsmasq.json
check "mosdns остановлен" sh -c "! pidof mosdns"
check "cron: блок снят" sh -c "! grep -q 'truba update-lists' /etc/crontabs/root"
check "ip rule остаются (ответы на входящие)" sh -c "ip rule show | grep -q 'lookup 77'"

echo "== Режим «Выборочный»"
uci set truba.main.routing='1'; uci set truba.main.mode='selective'; uci commit truba
/etc/init.d/truba reload; sleep 3
check "Выборочный: по умолчанию Напрямую" sh -c "nft list chain inet truba classify | tail -3 | grep -q 'meta mark set 0x00020000'"
/usr/sbin/truba check 8.8.8.8 > /tmp/chk4.json
check "check 8.8.8.8 → direct (Режим)" grep -q '"reason": "mode"' /tmp/chk4.json
check "смена Режима сбрасывает gs_direct4" sh -c "! nft list set inet truba gs_direct4 | grep -q 198.51.100.7"

echo "== update-lists: скачивание в /tmp (tmpfs) и перенос на /etc"
# На роутере /tmp — tmpfs, а /etc — overlay: rename между ними не работает (EXDEV).
mount | grep -q ' on /tmp type tmpfs' && echo "/tmp — tmpfs, как на роутере" || echo "внимание: /tmp не tmpfs, перенос между ФС не проверяется"
mkdir -p /root/src
for f in geoip.dat geosite.dat; do
	cp "/dat/$f" "/root/src/$f"
	(cd /root/src && sha256sum "$f" > "$f.sha256sum")
done
uci -q batch <<-'EOF'
	set truba.lists.via_tunnel='0'
	set truba.lists.geoip_url='file:///root/src/geoip.dat'
	set truba.lists.geoip_mirror='file:///root/src/geoip.dat'
	set truba.lists.geosite_url='file:///root/src/geosite.dat'
	set truba.lists.geosite_mirror='file:///root/src/geosite.dat'
	commit truba
EOF
/usr/sbin/truba update-lists -f > /tmp/ul.json 2>&1 &
check "update-lists -f и его reload завершились" wait_idle 60
unstick
head -c 400 /tmp/ul.json; echo
check "update-lists: оба набора ok" test "$(grep -o '"ok": true' /etc/truba/state/lists.json | wc -l)" -eq 2
for f in geoip.dat geosite.dat; do
	check "update-lists: $f записан в /etc/truba/lists" sh -c "[ \"\$(sha256sum < /etc/truba/lists/$f)\" = \"\$(sha256sum < /root/src/$f)\" ]"
	check "update-lists: $f.sha256sum рядом" test -s "/etc/truba/lists/$f.sha256sum"
	check "update-lists: прежний $f в prev" test -s "/etc/truba/lists/prev/$f"
	check "update-lists: $f не остался в /tmp" test ! -e "/tmp/truba-dl/$f"
done
/usr/sbin/truba rollback-lists > /tmp/rb.json 2>&1 &
check "rollback-lists и его reload завершились" wait_idle 60
unstick
check "rollback-lists: оба набора" grep -q 'geosite.dat' /tmp/rb.json
check "rollback-lists: текущие на месте" test -s /etc/truba/lists/geoip.dat

echo "== свежая установка без списков: apply сам скачивает их в фоне"
# Так было на роутере: фоновый update-lists наследовал блокировки apply и rc.common,
# а его собственный reload ждал их вечно.
rm -f /etc/truba/lists/*.dat /etc/truba/lists/*.sha256sum /etc/truba/lists/prev/*
/etc/init.d/truba reload
check "фоновое скачивание: списки появились" wait_for 60 test -s /etc/truba/lists/geosite.dat
check "фоновое скачивание: нет зависших apply/update-lists/reload" wait_idle 60
unstick
check "после фонового скачивания нет lists_missing" sh -c "! grep -q lists_missing /var/run/truba/applied.json"
check "блокировки truba свободны" sh -c "! grep -q ' -> FLOCK' /proc/locks"

echo "== status"
/usr/sbin/truba status > /tmp/st.json; head -c 300 /tmp/st.json; echo
check "status — валидный JSON" sh -c "ucode -e 'json(readfile(\"/tmp/st.json\"))' 2>/dev/null || jsonfilter -i /tmp/st.json -e '@.routing'"

echo "== teardown"
/etc/init.d/truba stop; sleep 1
check "таблица удалена" sh -c "! nft list table inet truba"
check "ip rule удалены" sh -c "! ip rule show | grep -q 'lookup 77'"
check "table 77 пуста" sh -c "[ -z \"\$(ip route show table 77)\" ]"

echo "== uninstall"
sh /usr/share/truba/uninstall.sh
check "зона truba удалена" test -z "$(uci -q get firewall.truba)"
check "аппаратное ускорение возвращено" test "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1

echo
[ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"
exit "$FAILS"
