#!/bin/sh
# Путь пакетов: что ставит установка, правила и маршруты после применения, входящие через
# Туннель, свои сокеты Роутера, чужие цепочки nftables (ADR 0011), учёт трафика, Политика
# устройства, Аварийная блокировка, Маршрутизация выкл, Режим «Выборочный», teardown, uninstall.
. /repo/tests/router/stand.sh

section "установка (uci-defaults)"
check "зона truba и форвардинг lan → truba" eval '[ "$(uci -q get firewall.truba.name)" = truba ] && [ "$(uci -q get firewall.lan_truba.dest)" = truba ]'
check "fullcone включён, аппаратное ускорение выключено" eval '[ "$(uci -q get firewall.@defaults[0].fullcone)" = 1 ] && [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 0 ]'
check "программное ускорение не тронуто" cmp -s /tmp/offload.before /tmp/offload.after
check "IPv6 из lan в интернет — REJECT, IPv6 сети не тронут" eval '[ "$(uci -q get firewall.truba_no_ipv6_inet.family)" = ipv6 ] && [ "$(uci -q get dhcp.lan.ra)" != disabled ]'
check "Стартовые настройки: 8 правил" test "$(uci -q show truba | grep -c '=rule$')" -eq 8

section "применение (Маршрутизация вкл)"
check "без ошибки" no_error
check "подсети geoip:ru — в gi_direct4, их число — для «DNS и списки»" eval 'in_set gi_direct4 "[[:space:]{,]5\.[0-9]" && [ "$(truba sets | jsonfilter -e "@.geoip.direct")" -gt 0 ]'
check "bypass4: IP Трубы и подсеть Туннеля" eval 'nft get element inet truba bypass4 "{ 198.51.100.2 }" && in_set bypass4 10.77.77.0/30'
check "lan_if = br-lan" in_set lan_if br-lan
check "ip rule: метка Туннеля и oif awg0 → 77" eval 'ip rule show | grep -q "fwmark 0x10000/0xff0000 lookup 77" && ip rule show | grep -q "oif awg0 lookup 77"'
check "table 77: default и подсеть Туннеля через awg0" eval 'ip route show table 77 | grep -q "default dev awg0" && ip route show table 77 | grep -q "10.77.77.0/30 dev awg0"'
check "dnsmasq → mosdns без кэша, исходные значения сохранены" eval 'uci -q get dhcp.@dnsmasq[0].server | grep -q "127.0.0.1#5335" && [ "$(uci -q get dhcp.@dnsmasq[0].cachesize)" = 0 ] && [ -f /etc/truba/state/dnsmasq.json ]'
check "status: mosdns — инстанс службы truba" test "$(truba status | jsonfilter -e '@.mosdns')" = true
check "API mosdns: счётчики кэша только на 127.0.0.1:5336" eval 'curl -s -m 2 http://127.0.0.1:5336/metrics | grep -q "^mosdns_cache_query_total" && ! netstat -lnt | grep ":5336 " | grep -qv "127.0.0.1:5336"'
# Время обновления хранится в UTC, а cron работает по местному времени Роутера (в образе — +0800).
NEXT="$(truba status | jsonfilter -e '@.lists.next')"; NOW="$(date +%s)"
H="$(date -d "@$NEXT" +%H | sed "s/^0//")"; M="$(date -d "@$NEXT" +%M | sed "s/^0//")"
check "cron: 12:00 UTC по местному времени, следующий запуск — в ближайшие сутки" eval 'grep -q "^$M $H \* \* \* /usr/sbin/truba update-lists" /etc/crontabs/root && [ $((NEXT % 86400)) -eq 43200 ] && [ "$NEXT" -gt "$NOW" ] && [ "$NEXT" -le $((NOW + 86400)) ]'
check "geosite: узкие Категории раньше широких (category-cdn-ru раньше category-ru)" eval 'applied "@.geosite_order[*]" | xargs | grep -q "category-cdn-ru=direct.* category-ru=direct"'
check "lists: контрольные суммы есть, а в status их нет (опрос раз в 5 с)" eval 'truba lists | jsonfilter -e "@.geoip.sha256" | grep -qE "^[0-9a-f]{64}$" && [ -z "$(truba status | jsonfilter -e "@.lists.geoip.sha256")" ]'

section "входящие через Туннель"
# Обычный проброс порта из зоны truba, как его создаёт вкладка «Входящие».
uci -q batch <<-'EOF'
	set firewall.t_in=redirect
	set firewall.t_in.src='truba'
	set firewall.t_in.src_dport='48080'
	set firewall.t_in.dest='lan'
	set firewall.t_in.dest_ip='192.168.1.50'
	set firewall.t_in.dest_port='8080'
	set firewall.t_in.proto='tcp'
	set firewall.t_in.target='DNAT'
	commit firewall
EOF
/etc/init.d/firewall reload >/dev/null 2>&1
ip netns exec lanhost ucode /repo/tests/lib/tcp_probe.uc server 8080 >/dev/null 2>&1 &
ip netns exec vps ucode /repo/tests/lib/udp_probe.uc server 203.0.113.77 40001 vps >/dev/null 2>&1 &
ip netns exec vps ucode /repo/tests/lib/tcp_probe.uc server 48081 >/dev/null 2>&1 &
ucode /repo/tests/lib/udp_probe.uc server 0.0.0.0 40001 local >/dev/null 2>&1 &
wait_for 10 probe
check "ответ на входящее уходит обратно в Туннель" probe

# Чужие цепочки (ADR 0011): в postrouting перезаписывают ct mark целиком; в output ставят свою
# meta mark всему исходящему Роутера, и правило 999 уводит его в свою таблицу — здесь к
# процессу на самом Роутере: ответ «local» вместо «vps».
foreign_on() {
	nft -f - <<-'EOF'
		table inet t_foreign {
			chain post {
				type filter hook postrouting priority filter; policy accept;
				ct mark set ip dscp | 0x80
			}
			chain out {
				type route hook output priority mangle; policy accept;
				ip daddr { 10.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16 } return
				meta mark set 0x162
			}
		}
	EOF
	ip rule add fwmark 0x162 lookup 354 priority 999
	ip route add local default dev lo table 354
}
foreign_off() { nft delete table inet t_foreign 2>/dev/null; ip rule del priority 999 2>/dev/null; ip route flush table 354 2>/dev/null; return 0; }
SOCKET_MARK="$(applied '@.socket_mark')"
foreign_checks() {
	check "свой UDP с меткой Туннеля → через Туннель ($1)" test "$(udp_out 0x10000)" = vps
	foreign_on
	check "чужие цепочки: ответ на входящее всё равно в Туннель ($1)" probe
	# Внешние пакеты Туннеля к Трубе — только напрямую, иначе Туннель ушёл бы в чужую таблицу.
	check "чужие цепочки: Туннель жив, ping Трубы ($1)" ping -c 2 -W 2 10.77.77.1
	if [ "$SOCKET_MARK" = true ]; then
		check "чужие цепочки: свой UDP с меткой Туннеля всё равно через Туннель ($1)" test "$(udp_out 0x10000)" = vps
	else
		echo "skip  в ядре нет nft_socket (kmod-nft-socket): метка своих сокетов при чужой цепочке ($1)"
	fi
	foreign_off
}
foreign_checks "Маршрутизация вкл"

section "учёт трафика устройств"
probe >/dev/null 2>&1
check "входящие: посчитаны в обе стороны" eval 'gt0 c_inbound_down && gt0 c_inbound_up'
IN_DOWN="$(bytes c_inbound_down)"
# 1.2.3.4 нет ни в одной Категории: по Режиму «Всё в туннель» — через Туннель на сервер в netns vps.
ip -n vps addr add 1.2.3.4/32 dev lo
check "устройство → Туннель: ответ пришёл, посчитан в обе стороны" eval 'lan_tcp 1.2.3.4 48081 && gt0 c_tunnel_up && gt0 c_tunnel_down'
# Ответ из Туннеля на исходящее — «Туннель», хотя ct mark он переписывает на «входящее».
check "исходящее через Туннель не считается входящим" test "$(bytes c_inbound_down)" = "$IN_DOWN"
# «Интернет напрямую» стенда — Труба по внешнему адресу через ul0; на время — в зоне wan.
uci add_list firewall.@zone[1].device='ul0'; uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1
TUN_UP="$(bytes c_tunnel_up)"
check "устройство → напрямую: ответ пришёл, посчитан в обе стороны" eval 'lan_tcp 198.51.100.2 48081 && gt0 c_direct_up && gt0 c_direct_down'
check "напрямую не считается Туннелем" test "$(bytes c_tunnel_up)" = "$TUN_UP"
uci del_list firewall.@zone[1].device='ul0'; uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1
check "status: трафик Туннеля — из счётчика" test "$(truba status | jsonfilter -e '@.traffic.tunnel.up')" = "$(bytes c_tunnel_up)"
SINCE="$(applied '@.counters_since')"; TUN_UP="$(bytes c_tunnel_up)"

section "Политика устройства"
uci -q batch >/dev/null <<-'EOF'
	add truba device
	set truba.@device[-1].name='ps5'
	set truba.@device[-1].mac='AA:BB:CC:DD:EE:FF'
	set truba.@device[-1].policy='tunnel'
	commit truba
EOF
reload "Политика устройства"
check "MAC — в dev_tunnel" in_set dev_tunnel aa:bb:cc:dd:ee:ff
check "счётчики и отсчёт пережили применение" eval '[ "$(bytes c_tunnel_up)" -ge "$TUN_UP" ] && [ "$(applied "@.counters_since")" = "$SINCE" ]'
offload() { uci set firewall.@defaults[0].flow_offloading="$1"; uci commit firewall; truba status | jsonfilter -e '@.neighbours.offload'; }
check "status: программное ускорение замечено" eval '[ "$(offload 0)" = false ] && [ "$(offload 1)" = true ]'
offload 0 >/dev/null

section "Аварийная блокировка"
uci set truba.watchdog.enabled='1'; uci commit truba
echo '{"state":"down"}' > /var/run/truba/health.json
truba routes >/dev/null
check "Туннель упал, блокировка вкл → blackhole" eval 'ip route show table 77 | grep -q "blackhole default"'
uci set truba.main.killswitch='0'; uci commit truba; truba routes >/dev/null
check "Туннель упал, блокировка выкл → без default" eval '! ip route show table 77 | grep -q default'
echo '{"state":"healthy"}' > /var/run/truba/health.json
uci set truba.main.killswitch='1'; uci set truba.watchdog.enabled='0'; uci commit truba; truba routes >/dev/null
check "Туннель в порядке → default dev awg0" eval 'ip route show table 77 | grep -q "default dev awg0"'

section "Маршрутизация выкл"
uci set truba.main.routing='0'; uci commit truba
reload "Маршрутизация выкл"
check "минимальная таблица: без classify, INBOUND на месте" eval '! nft list chain inet truba classify && nft list chain inet truba prerouting | grep -q 0x00040000'
check "dnsmasq восстановлен, бэкап удалён, mosdns остановлен, cron снят" eval '! uci -q get dhcp.@dnsmasq[0].server | grep -q 5335 && [ ! -f /etc/truba/state/dnsmasq.json ] && ! pidof mosdns && ! grep -q "truba update-lists" /etc/crontabs/root'
check "ip rule остаются (ответы на входящие)" eval 'ip rule show | grep -q "lookup 77"'
check "ответ на входящее уходит обратно в Туннель (Маршрутизация выкл)" probe
foreign_checks "Маршрутизация выкл"

section "Режим «Выборочный»"
uci set truba.main.routing='1'; uci commit truba; reload "Маршрутизация вкл"
nft add element inet truba gs_direct4 '{ 198.51.100.7 }'
uci set truba.main.mode='selective'; uci commit truba; reload "Режим «Выборочный»"
check "смена Режима сбрасывает IP из DNS" eval '! in_set gs_direct4 198.51.100.7'
check "«Выборочный»: по умолчанию — Напрямую" test "$(mode_mark)" = 0x00020000
check "truba check 8.8.8.8 → Напрямую по Режиму" eval 'truba check 8.8.8.8 | grep -q "\"reason\": \"mode\""'

section "teardown"
/etc/init.d/truba stop
check "таблица, ip rule и table 77 сняты" eval '! nft list table inet truba && ! ip rule show | grep -q "lookup 77" && [ -z "$(ip route show table 77)" ]'
check "без Трубы ответ на входящее уходит мимо Туннеля" eval '! probe'

section "uninstall"
sh /usr/share/truba/uninstall.sh
check "зона truba удалена, аппаратное ускорение возвращено" eval '[ -z "$(uci -q get firewall.truba)" ] && [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1 ]'
check "данные службы удалены: Наборы правил, копия правил, распакованные списки" eval '[ ! -e /etc/truba/lists ] && [ ! -e /etc/truba/state ] && [ ! -e /etc/truba/good ] && [ ! -e /var/lib/truba ]'

finish
