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

# Входящее из интернета через Туннель: 203.0.113.77 → 10.77.77.2:48080 → DNAT → lanhost:8080.
# Ответ доходит, только если Труба отправила его обратно в Туннель, а не в WAN (eth0).
probe() { ip netns exec vps ucode /repo/tests/router/tcp_probe.uc client 203.0.113.77 10.77.77.2 48080; }
# Как qosmate: в postrouting перезаписывает ct mark целиком (DSCP | 0x80).
qosmate_on() {
	nft -f - <<-'EOF'
		table inet t_qosmate {
			chain dscptag {
				type filter hook postrouting priority filter; policy accept;
				iifname "eth0" accept
				ct mark set ip dscp | 0x80
			}
		}
	EOF
}
qosmate_off() { nft delete table inet t_qosmate 2>/dev/null; return 0; }
inbound_checks() {
	check "входящее через Туннель: ответ вернулся ($1)" probe
	qosmate_on
	check "входящее через Туннель при qosmate ($1)" probe
	qosmate_off
}

# Свои сокеты Роутера с меткой Туннеля (mosdns, nat-test) → сервер за Туннелем (netns vps).
# UDP-ответ «vps» — дошло через Туннель, «clash» — перехватил «Clash» на самом Роутере.
udp_out() { ucode /repo/tests/router/udp_probe.uc client 203.0.113.77 40001 "$@"; }
tcp_out() { ucode /repo/tests/router/tcp_probe.uc client 0.0.0.0 203.0.113.77 48081 "$@"; }
# Как OpenClash с router_self_proxy: цепочка output перезаписывает meta mark целиком,
# правило 999 уводит 0x162 в таблицу 354 (local default dev lo → Clash). Маршрута по
# умолчанию в контейнере нет: 203.0.113.0/24 через br-lan изображает WAN для трафика без метки.
openclash_on() {
	nft -f - <<-'EOF'
		table inet t_openclash {
			set localnetwork {
				type ipv4_addr; flags interval;
				elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16,
				             172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
			}
			chain openclash_mangle_output {
				type route hook output priority mangle; policy accept;
				meta skgid 65534 return
				ip daddr @localnetwork return
				ct direction reply return
				meta l4proto udp ip daddr 198.18.0.0/16 meta mark set 0x162 accept
				meta mark set 0x162 accept
			}
		}
	EOF
	ip rule add fwmark 0x162 lookup 354 priority 999
	ip route add local default dev lo table 354
	ip route add 203.0.113.0/24 dev br-lan
}
openclash_off() {
	nft delete table inet t_openclash 2>/dev/null
	ip rule del priority 999 2>/dev/null
	ip route flush table 354 2>/dev/null
	ip route del 203.0.113.0/24 dev br-lan 2>/dev/null
	return 0
}
own_checks() {
	check "свой UDP с меткой Туннеля → Туннель ($1)" test "$(udp_out 0x10000)" = vps
	check "свой TCP с меткой Туннеля → Туннель ($1)" tcp_out 0x10000
	if ! grep -q '"socket_mark":true' /var/run/truba/applied.json; then
		echo "skip  в ядре нет nft_socket (kmod-nft-socket): свои сокеты при OpenClash не проверяются ($1)"
		check "без nft_socket таблица загружена, цепочки output нет ($1)" sh -c "nft list table inet truba && ! nft list chain inet truba output"
		return
	fi
	openclash_on
	check "свой UDP с меткой Туннеля при OpenClash → Туннель ($1)" test "$(udp_out 0x10000)" = vps
	check "свой TCP с меткой Туннеля при OpenClash → Туннель ($1)" tcp_out 0x10000
	check "свой UDP без метки при OpenClash → OpenClash ($1)" test "$(udp_out)" = clash
	openclash_off
}

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
# veth в отдельные netns: «vps» — другой конец Туннеля, через него приходят клиенты
# из интернета (203.0.113.77), «lanhost» — устройство в домашней сети.
ip netns add vps; ip netns add lanhost
ip link add awg0 type veth peer name vps0
ip link set vps0 netns vps
ip -n vps link set lo up; ip -n vps link set vps0 up
ip -n vps addr add 10.77.77.1/30 dev vps0
ip -n vps addr add 203.0.113.77/32 dev lo
ip -n vps route add default via 10.77.77.2 src 203.0.113.77
ip link add lan0 type veth peer name lh0
ip link set lh0 netns lanhost
ip -n lanhost link set lo up; ip -n lanhost link set lh0 up
ip -n lanhost addr add 192.168.1.50/24 dev lh0
ip -n lanhost route add default via 192.168.1.1
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
check "программное ускорение включено" test "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1
# В ядре Docker нет nf_flow_table: с flowtable fw4 не загружается целиком (без зон).
uci set firewall.@defaults[0].flow_offloading='0'; uci commit firewall
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
check "persist: решение пишется в ct mark после всех" sh -c "nft list chain inet truba persist | grep -q 'priority 300'"
# nft печатает «& 0xff00ffff | 0x00040000» как «& 0xff04ffff | 0x00040000» — то же самое.
check "persist: ct mark меняется только в байте Трубы" sh -c "nft list chain inet truba persist | grep -qE 'ct mark set ct mark & 0xff0[0-9a-f]ffff \| 0x00040000'"

echo "== входящие через Туннель (Маршрутизация вкл)"
# Обычный проброс порта из зоны truba, как его создаёт вкладка «Входящие».
uci -q batch <<-'EOF'
	set firewall.t_in=redirect
	set firewall.t_in.name='test inbound'
	set firewall.t_in.src='truba'
	set firewall.t_in.src_dport='48080'
	set firewall.t_in.dest='lan'
	set firewall.t_in.dest_ip='192.168.1.50'
	set firewall.t_in.dest_port='8080'
	set firewall.t_in.proto='tcp'
	set firewall.t_in.target='DNAT'
	commit firewall
EOF
/etc/init.d/firewall reload >/dev/null 2>&1; sleep 2
check "fw4: проброс из зоны truba загружен" sh -c "nft list chain inet fw4 dstnat_truba | grep -q 48080"
ip netns exec lanhost ucode /repo/tests/router/tcp_probe.uc server 8080 >/dev/null 2>&1 &
sleep 1
inbound_checks "Маршрутизация вкл"

echo "== свои сокеты Роутера с меткой Туннеля при OpenClash (Маршрутизация вкл)"
ip netns exec vps ucode /repo/tests/router/udp_probe.uc server 203.0.113.77 40001 vps >/dev/null 2>&1 &
ip netns exec vps ucode /repo/tests/router/tcp_probe.uc server 48081 >/dev/null 2>&1 &
ucode /repo/tests/router/udp_probe.uc server 0.0.0.0 40001 clash >/dev/null 2>&1 &
sleep 1
own_checks "Маршрутизация вкл"
# Контроль: без цепочки output Трубы та же имитация уводит в Clash и меченый трафик.
nft delete chain inet truba output 2>/dev/null
openclash_on
check "контроль: без цепочки output меченый UDP уходит в OpenClash" test "$(udp_out 0x10000)" = clash
openclash_off
nft -f /var/etc/truba/truba.nft

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
check "минимальная таблица: INBOUND остаётся" sh -c "nft list chain inet truba prerouting | grep -qE 'iifname \"awg0\" meta mark set meta mark & 0xff0[0-9a-f]ffff \| 0x00040000'"
check "минимальная таблица: persist остаётся" sh -c "nft list chain inet truba persist | grep -q 0x00040000"
check "dnsmasq восстановлен" sh -c "! uci -q get dhcp.@dnsmasq[0].server | grep -q 5335"
check "бэкап dnsmasq удалён" test ! -f /etc/truba/state/dnsmasq.json
check "mosdns остановлен" sh -c "! pidof mosdns"
check "cron: блок снят" sh -c "! grep -q 'truba update-lists' /etc/crontabs/root"
check "ip rule остаются (ответы на входящие)" sh -c "ip rule show | grep -q 'lookup 77'"
inbound_checks "Маршрутизация выкл"
own_checks "Маршрутизация выкл"

echo "== Режим «Выборочный»"
uci set truba.main.routing='1'; uci set truba.main.mode='selective'; uci commit truba
/etc/init.d/truba reload; sleep 3
check "Выборочный: по умолчанию Напрямую" sh -c "nft list chain inet truba classify | tail -3 | grep -qE 'meta mark set meta mark & 0xff0[0-9a-f]ffff \| 0x00020000'"
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
no_probe() { ! probe; }
check "без Трубы ответ уходит мимо Туннеля (проба это видит)" no_probe

echo "== uninstall"
sh /usr/share/truba/uninstall.sh
check "зона truba удалена" test -z "$(uci -q get firewall.truba)"
check "аппаратное ускорение возвращено" test "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1

echo
[ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"
exit "$FAILS"
