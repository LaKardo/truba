#!/bin/sh
# Интеграционный тест пакета truba внутри контейнера ImmortalWrt с procd (/sbin/init).
# Туннель — настоящий WireGuard (модуля amneziawg в ядре контейнера нет).
# Ожидает: /repo — корень репозитория, /dat — каталог с geoip.dat и geosite.dat.

set -u
exec 3>&1   # настоящий вывод теста: check прячет вывод команд в /dev/null
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
# wait_pid N PID — ждать до N секунд, пока процесс не завершится; неуспех — ещё работает.
wait_pid() { t=$1; while [ "$t" -gt 0 ] && kill -0 "$2" 2>/dev/null; do sleep 1; t=$((t - 1)); done; ! kill -0 "$2" 2>/dev/null; }
# bounded N cmd… — шаг не дольше N секунд. Если повис: кто чего ждёт, блокировки,
# журнал — и снять, чтобы прогон дошёл до конца, а не обрывался по тайм-ауту CI.
bounded() {
	n=$1; shift
	"$@" & bp=$!
	wait_pid "$n" "$bp" && { wait "$bp"; return; }
	{
	echo "TIMEOUT: $*"
	# Все процессы, без фильтра: шаг может ждать службу, которую заранее не угадать
	# (в CI повисли dropbear reload и logread). В контейнере их десятка три.
	for d in /proc/[0-9]*; do
		c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null); [ -n "$c" ] || continue
		echo "  ${d#/proc/} ppid=$(cut -d' ' -f4 "$d/stat") $(cut -d' ' -f3 "$d/stat") wchan=$(cat "$d/wchan" 2>/dev/null): $(echo "$c" | cut -c1-110)"
	done
	echo "  locks:"; sed 's/^/    /' /proc/locks
	# logread читает журнал через ubus: если встали procd или ubusd, он висит и сам.
	# timeout в образе нет — фоном и не дольше 5 с.
	echo "  log:"
	logread > /tmp/bounded.log 2>&1 & lp=$!
	wait_pid 5 "$lp" || { kill "$lp" 2>/dev/null; echo "    (logread не ответил за 5 с)"; }
	tail -25 /tmp/bounded.log | cut -c1-200 | sed 's/^/    /'
	} >&3 2>&3
	kill "$bp" 2>/dev/null; unstick
	return 124
}

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
# правило 999 уводит 0x162 в таблицу 354 (local default dev lo → Clash). Трафик без метки
# без OpenClash ушёл бы в «интернет» (default dev inet0).
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
}
openclash_off() {
	nft delete table inet t_openclash 2>/dev/null
	ip rule del priority 999 2>/dev/null
	ip route flush table 354 2>/dev/null
	return 0
}
own_checks() {
	check "свой UDP с меткой Туннеля → Туннель ($1)" test "$(udp_out 0x10000)" = vps
	check "свой TCP с меткой Туннеля → Туннель ($1)" tcp_out 0x10000
	# Пакеты к Трубе (сам Туннель) — только напрямую: ни петли в awg0, ни чужого прокси.
	check "output: пакеты к Трубе — «Напрямую» ($1)" sh -c "nft list chain inet truba output | grep -qE 'ip daddr 198.51.100.2 meta mark set meta mark & 0xff0[0-9a-f]ffff \| 0x00020000 return'"
	openclash_on
	# 10.77.77.1 у OpenClash в исключениях, но внешние пакеты Туннеля к Трубе — нет.
	check "Туннель при OpenClash не уходит в прокси (пинг Трубы) ($1)" ping -c 2 -W 2 10.77.77.1
	if ! grep -qE '"socket_mark": ?true' /var/run/truba/applied.json; then
		openclash_off
		echo "skip  в ядре нет nft_socket (kmod-nft-socket): свои сокеты при OpenClash не проверяются ($1)"
		check "без nft_socket нет правила socket mark ($1)" sh -c "nft list chain inet truba output && ! nft list chain inet truba output | grep -q 'socket mark'"
		return
	fi
	# Внешние пакеты Туннеля несут сокет исходного пакета с меткой «Туннель»:
	# правило для Трубы должно стоять раньше socket mark, иначе петля (живой роутер, r4).
	check "output: правило Трубы раньше socket mark ($1)" sh -c "nft list chain inet truba output | grep -A1 'ip daddr 198.51.100.2' | grep -q 'socket mark'"
	check "свой UDP с меткой Туннеля при OpenClash → Туннель ($1)" test "$(udp_out 0x10000)" = vps
	check "свой TCP с меткой Туннеля при OpenClash → Туннель ($1)" tcp_out 0x10000
	check "свой UDP без метки при OpenClash → OpenClash ($1)" test "$(udp_out)" = clash
	openclash_off
}

echo "== зависимости (ставятся в образ заранее: под procd у контейнера нет сети)"
for p in mosdns ucode-mod-socket curl ip-full wireguard-tools; do
	apk list -I "$p" 2>/dev/null | grep -q "^$p-" || { echo "нет пакета $p в образе"; exit 1; }
done

echo "== копирование файлов пакета"
cp -a /repo/router/truba/files/. /
chmod +x /usr/sbin/truba /etc/init.d/truba /etc/truba/reinstall.sh /usr/share/truba/uninstall.sh /etc/uci-defaults/90-truba
# Туннель — WireGuard, и awg из amneziawg-tools нет. «awg show» выводит то же, что «wg show»:
# без обёртки watchdog не видит handshake и не считает Туннель в порядке.
[ -x /usr/bin/awg ] || { printf '#!/bin/sh\nexec wg "$@"\n' > /usr/bin/awg; chmod +x /usr/bin/awg; }
mkdir -p /etc/truba/lists
cp /dat/geoip.dat /dat/geosite.dat /etc/truba/lists/
for f in geoip.dat geosite.dat; do sha256sum /etc/truba/lists/$f | awk '{print $1"  "FILENAME}' FILENAME=$f > /etc/truba/lists/$f.sha256sum; done

echo "== домашняя сеть и Туннель"
# netns «vps» — Труба: через неё приходят клиенты из интернета (203.0.113.77);
# netns «lanhost» — устройство в домашней сети.
# Туннель — настоящий WireGuard, а не veth: ядро шифрует пакеты и отправляет внешние
# через свой UDP-сокет, как AmneziaWG. На veth петля «Туннель в себя» была не видна.
# «Интернет» между Роутером и Трубой — veth ul0/ul1 (198.51.100.0/30).
ip netns add vps; ip netns add lanhost
ip link add ul0 type veth peer name ul1
ip link set ul1 netns vps
ip addr add 198.51.100.1/30 dev ul0; ip link set ul0 up
ip -n vps link set lo up; ip -n vps link set ul1 up
ip -n vps addr add 198.51.100.2/30 dev ul1
umask 077; wg genkey > /tmp/r.key; wg genkey > /tmp/v.key; umask 022
ip link add awg0 type wireguard
wg set awg0 private-key /tmp/r.key \
	peer "$(wg pubkey < /tmp/v.key)" endpoint 198.51.100.2:51820 allowed-ips 0.0.0.0/0 persistent-keepalive 5
ip -n vps link add wg0 type wireguard
ip netns exec vps wg set wg0 private-key /tmp/v.key listen-port 51820 \
	peer "$(wg pubkey < /tmp/r.key)" allowed-ips 10.77.77.2/32
ip -n vps addr add 10.77.77.1/30 dev wg0; ip -n vps link set wg0 up
ip -n vps addr add 203.0.113.77/32 dev lo
ip -n vps route add default via 10.77.77.2 dev wg0 src 203.0.113.77
ip link add lan0 type veth peer name lh0
ip link set lh0 netns lanhost
ip -n lanhost link set lo up; ip -n lanhost link set lh0 up
ip -n lanhost addr add 192.168.1.50/24 dev lh0
ip -n lanhost route add default via 192.168.1.1
ip link set awg0 up
# Маршрут «в интернет», как WAN на настоящем роутере. Без него нестрогий rp_filter
# (контейнер наследует его от хоста: на Ubuntu в CI all.rp_filter=2) отбрасывает
# клиентов из интернета ещё на входе. Ответы мимо Туннеля уходят сюда и теряются.
ip link add inet0 type dummy; ip link set inet0 up
ip route add default dev inet0 metric 1000
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
	set network.@amneziawg_awg0[-1].endpoint_host='198.51.100.2'
	set network.@amneziawg_awg0[-1].endpoint_port='51820'
	commit network
EOF
/etc/init.d/network reload; sleep 3

echo "== uci-defaults"
OFFLOAD_BEFORE="$(uci -q get firewall.@defaults[0].flow_offloading)"
uci set truba.lists.update_utc='04:00'; uci commit truba   # прежнее значение по умолчанию
# Прежний DNS «Напрямую» по умолчанию — один сервер.
uci -q delete truba.dns.direct_upstream; uci add_list truba.dns.direct_upstream='tls://common.dot.dns.yandex.net@77.88.8.8'; uci commit truba
sh /etc/uci-defaults/90-truba
check "время обновления списков: прежнее 04:00 → 12:00 UTC" test "$(uci -q get truba.lists.update_utc)" = 12:00
check "DNS «Напрямую»: к прежнему серверу добавлен второй" test "$(uci -q get truba.dns.direct_upstream)" = "tls://common.dot.dns.yandex.net@77.88.8.8 tls://common.dot.dns.yandex.net@77.88.8.1"
sh /etc/uci-defaults/90-truba
check "DNS «Напрямую»: повторный запуск не добавляет третий" test "$(uci -q get truba.dns.direct_upstream | wc -w)" -eq 2
# Свои серверы пользователя не трогаются.
uci -q delete truba.dns.direct_upstream; uci add_list truba.dns.direct_upstream='https://77.88.8.8/dns-query'; uci commit truba
sh /etc/uci-defaults/90-truba
check "DNS «Напрямую»: свой сервер пользователя не трогается" test "$(uci -q get truba.dns.direct_upstream)" = "https://77.88.8.8/dns-query"
uci -q delete truba.dns.direct_upstream
for u in tls://common.dot.dns.yandex.net@77.88.8.8 tls://common.dot.dns.yandex.net@77.88.8.1; do uci add_list truba.dns.direct_upstream="$u"; done
uci commit truba
check "зона truba создана" test "$(uci -q get firewall.truba.name)" = truba
check "форвардинг lan→truba" test "$(uci -q get firewall.lan_truba.dest)" = truba
check "fullcone включён" test "$(uci -q get firewall.@defaults[0].fullcone)" = 1
check "аппаратное ускорение выключено" test "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 0
check "IPv6 lan→wan REJECT" test "$(uci -q get firewall.truba_no_ipv6_inet.family)" = ipv6
check "IPv6 lan не тронут (ra)" test "$(uci -q get dhcp.lan.ra)" != disabled
check "Стартовые настройки: 8 правил" test "$(uci -q show truba | grep -c '=rule$')" -eq 8
check "программное ускорение не тронуто (было: ${OFFLOAD_BEFORE:-не задано})" test "$(uci -q get firewall.@defaults[0].flow_offloading)" = "$OFFLOAD_BEFORE"
# В ядре Docker нет nf_flow_table: с flowtable fw4 не загружается целиком (без зон).
uci set firewall.@defaults[0].flow_offloading='0'; uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1

echo "== apply (Маршрутизация вкл)"
uci set truba.watchdog.enabled='0'; uci commit truba
/etc/init.d/truba enable
check "служба запускается (не дольше 90 с)" bounded 90 /etc/init.d/truba start; sleep 4
APPLIED="$(cat /var/run/truba/applied.json 2>/dev/null)"
echo "$APPLIED" | head -c 600; echo
check "applied.json без ошибки" sh -c "! grep -q '\"error\"' /var/run/truba/applied.json"
check "таблица inet truba есть" nft list table inet truba
check "набор gi_direct4 наполнен geoip:ru" sh -c "nft list set inet truba gi_direct4 | grep -q '5\.'"
check "bypass4 содержит IP Трубы" nft get element inet truba bypass4 '{ 198.51.100.2 }'
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
# В контейнере часовой пояс UTC: 12:00 UTC и в cron — 12:00.
check "cron: 12:00 UTC" sh -c "[ \"$(date +%z)\" != +0000 ] || grep -q '^0 12 \* \* \* /usr/sbin/truba update-lists' /etc/crontabs/root"
# «Следующая проверка» на «Обзоре» — по самой строке cron, в ближайшие сутки.
NEXT="$(truba status | jsonfilter -e '@.lists.next')"
check "status: следующий запуск обновления — в ближайшие сутки" sh -c "N=$NEXT; T=\$(date +%s); [ \"\$N\" -gt \"\$T\" ] && [ \"\$N\" -le \$((T + 86400)) ]"
check "status: следующий запуск — в 12:00 UTC" sh -c "[ \"$(date +%z)\" != +0000 ] || [ \$(( $NEXT % 86400 )) -eq 43200 ]"
check "mosdns запущен" pidof mosdns
check "status: mosdns — инстанс службы truba в procd" test "$(truba status | jsonfilter -e '@.mosdns')" = true
# Контрольные суммы и предыдущие версии — только в lists: status опрашивается раз в 5 с.
truba lists > /tmp/lists.json
check "lists: контрольная сумма geoip.dat" sh -c "jsonfilter -i /tmp/lists.json -e '@.geoip.sha256' | grep -qE '^[0-9a-f]{64}$'"
check "status: без контрольных сумм и предыдущих версий" sh -c "truba status > /tmp/st0.json && [ -z \"\$(jsonfilter -i /tmp/st0.json -e '@.lists.geoip.sha256')\" ] && ! grep -q prev_geoip /tmp/st0.json"
check "mosdns слушает 5335" sh -c "netstat -lnu 2>/dev/null | grep -q ':5335' || ss -lnu | grep -q ':5335'"
# API статистики — на соседнем порту и только на 127.0.0.1: там же отладка mosdns (/debug/pprof).
check "API mosdns: счётчики кэша на 127.0.0.1:5336" sh -c "curl -s -m 2 http://127.0.0.1:5336/metrics | grep -q '^mosdns_cache_query_total'"
check "API mosdns не слушает внешние адреса" sh -c "L=\$(netstat -lnt | grep ':5336 '); [ -n \"\$L\" ] && ! echo \"\$L\" | grep -qv '127.0.0.1:5336'"
check "sets: подсети geoip «Напрямую» посчитаны при применении" sh -c "[ \"\$(truba sets | jsonfilter -e '@.geoip.direct')\" -gt 0 ]"
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
no_ping() { ! ping -c 2 -W 2 10.77.77.1; }
check "контроль: без цепочки output Туннель при OpenClash уходит в прокси" no_ping
openclash_off
nft -f /var/etc/truba/truba.nft

echo "== Проверка NAT: STUN через Туннель"
# Два STUN-сервера в netns vps отвечают IP Трубы и портом источника; .83 и .84 молчат.
# По очереди молчащие стоили бы по 4,5 с каждый, разом — одно окно повторов.
for a in 81 82; do
	ip -n vps addr add 203.0.113.$a/32 dev lo
	ip netns exec vps ucode /repo/tests/router/stun_server.uc 203.0.113.$a 3478 198.51.100.2 >/dev/null 2>&1 &
done
for a in 81 82 83 84; do uci add_list truba.main.stun="203.0.113.$a:3478"; done
uci commit truba
sleep 1
T0=$(date +%s); truba nat-test > /tmp/nat.json; T1=$(date +%s)
head -c 700 /tmp/nat.json; echo
nat() { jsonfilter -i /tmp/nat.json -e "$1"; }
check "nat-test: ответили два сервера из четырёх" test "$(nat '@.answered')" = 2
check "nat-test: внешний IP — IP Трубы, порт сохранён" sh -c "[ '$(nat '@.ip_is_vps')' = true ] && [ '$(nat '@.port_preserved')' = true ]"
check "nat-test: отображение одинаково для разных серверов" test "$(nat '@.consistent')" = true
check "nat-test: итог OK" test "$(nat '@.ok')" = true
check "nat-test: молчащий сервер — тайм-аут" test "$(nat '@.servers[3].error')" = timeout
check "nat-test: серверы опрашиваются разом (не дольше 7 с, было $((T1 - T0)) с)" test $((T1 - T0)) -le 7
check "status: итог проверки NAT для «Обзора»" test "$(truba status | jsonfilter -e '@.nat.ok')" = true

echo "== Проверка Туннеля: пакеты трёх размеров"
TUN_MTU="$(cat /sys/class/net/awg0/mtu)"
truba tunnel-test > /tmp/tt.json; head -c 500 /tmp/tt.json; echo
tt() { jsonfilter -i /tmp/tt.json -e "$1"; }
check "tunnel-test: три размера, последний — весь MTU ($TUN_MTU)" sh -c "[ \"\$(jsonfilter -i /tmp/tt.json -e '@.results[*].size' | wc -l)\" -eq 3 ] && [ \"\$(jsonfilter -i /tmp/tt.json -e '@.results[2].size')\" = '$TUN_MTU' ]"
check "tunnel-test: все размеры проходят" test "$(tt '@.ok')" = true
check "tunnel-test: задержка посчитана" sh -c "jsonfilter -i /tmp/tt.json -e '@.results[2].avg' | grep -qE '^[0-9.]+$'"
check "tunnel-test: временные файлы убраны" sh -c "! ls -d /tmp/truba-tt.* 2>/dev/null"
# Путь, который теряет крупные пакеты (так было с VPS в сети 1400): Труба отбрасывает
# пакеты Туннеля длиннее 1300 байт. Обычный ping при этом проходит.
ip netns exec vps nft add table inet bigdrop
ip netns exec vps nft add chain inet bigdrop in '{ type filter hook prerouting priority -300; }'
ip netns exec vps nft add rule inet bigdrop in iifname ul1 meta l4proto udp meta length gt 1300 drop
truba tunnel-test > /tmp/tt2.json; head -c 300 /tmp/tt2.json; echo
check "tunnel-test: путь теряет крупные пакеты — итог не OK" test "$(jsonfilter -i /tmp/tt2.json -e '@.ok')" = false
check "tunnel-test: мелкие пакеты при этом проходят" test "$(jsonfilter -i /tmp/tt2.json -e '@.results[0].ok')" = true
check "tunnel-test: пакеты во весь MTU — нет" test "$(jsonfilter -i /tmp/tt2.json -e '@.results[2].ok')" = false
ip netns exec vps nft delete table inet bigdrop

echo "== rpcd: долгие проверки идут в фоне и не держат остальные вызовы LuCI"
# rpcd обслуживает вызовы по одному: пока он ждал проверку (до ~5 с), стоял весь LuCI.
# Плагин пришёл с файлами пакета truba (ADR 0008); rpcd подхватывает его по HUP — как postinst.
# С каталога Windows файлы приходят с правами 777, а такие плагины rpcd не загружает.
chmod 0644 /usr/share/rpcd/ucode/truba-api.uc
killall -HUP rpcd
check "rpcd: объект truba (плагин из пакета truba, HUP)" wait_for 10 ubus list truba
T0=$(date +%s); ubus call truba tunnel_test > /tmp/rt.json; T1=$(date +%s)
check "rpcd: tunnel_test отвечает сразу (было $((T1 - T0)) с)" test $((T1 - T0)) -le 1
STARTED="$(jsonfilter -i /tmp/rt.json -e '@.started')"
T0=$(date +%s); ubus call luci-rpc getHostHints >/dev/null 2>&1; T1=$(date +%s)
check "rpcd: пока идёт проверка, другие вызовы не ждут (было $((T1 - T0)) с)" test $((T1 - T0)) -le 2
tt_done() { [ "$(ubus call truba tunnel_result | jsonfilter -e '@.time')" -ge "$STARTED" ] 2>/dev/null; }
check "rpcd: итог проверки Туннеля появился" wait_for 20 tt_done
check "rpcd: итог проверки Туннеля — все размеры проходят" test "$(ubus call truba tunnel_result | jsonfilter -e '@.ok')" = true
ubus call truba nat_test > /tmp/rn.json
STARTED="$(jsonfilter -i /tmp/rn.json -e '@.started')"
nat_done() { [ "$(ubus call truba nat_result | jsonfilter -e '@.time')" -ge "$STARTED" ] 2>/dev/null; }
check "rpcd: итог проверки NAT появился" wait_for 20 nat_done
check "rpcd: итог проверки NAT — OK" test "$(ubus call truba nat_result | jsonfilter -e '@.ok')" = true

echo "== учёт трафика устройств (Маршрутизация вкл)"
bytes() { nft list counter inet truba "$1" 2>/dev/null | sed -n 's/.*bytes \([0-9]*\).*/\1/p'; }
gt0() { [ "$(bytes "$1")" -gt 0 ] 2>/dev/null; }
same() { [ "$(bytes "$1")" = "$2" ]; }
lan_tcp() { ip netns exec lanhost ucode /repo/tests/router/tcp_probe.uc client 192.168.1.50 "$1" "$2"; }
probe >/dev/null 2>&1   # входящее: клиент из интернета → устройство
check "входящие: к устройству посчитано" gt0 c_inbound_down
check "входящие: от устройства посчитано" gt0 c_inbound_up
IN_DOWN="$(bytes c_inbound_down)"
# 203.0.113.0/24 входит в geoip:private («Напрямую»); 1.2.3.4 — ни в одну Категорию,
# поэтому по Режиму «Всё в туннель» идёт через Туннель на сервер в netns vps.
ip -n vps addr add 1.2.3.4/32 dev lo 2>/dev/null
check "устройство → Туннель: ответ пришёл" lan_tcp 1.2.3.4 48081
check "Туннель: от устройства посчитано" gt0 c_tunnel_up
check "Туннель: к устройству посчитано" gt0 c_tunnel_down
# Ответ из Туннеля на исходящее — это «Туннель», а не «входящие», хотя ct mark он переписывает.
check "исходящее через Туннель не считается входящим" same c_inbound_down "$IN_DOWN"
# «Интернет напрямую» в стенде — VPS по внешнему адресу через ul0; на время — в зоне wan.
uci add_list firewall.@zone[1].device='ul0'; uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1; sleep 2
TUN_UP="$(bytes c_tunnel_up)"
check "устройство → напрямую: ответ пришёл" lan_tcp 198.51.100.2 48081
check "Напрямую: от устройства посчитано" gt0 c_direct_up
check "Напрямую: к устройству посчитано" gt0 c_direct_down
check "напрямую не считается Туннелем" same c_tunnel_up "$TUN_UP"
uci del_list firewall.@zone[1].device='ul0'; uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1; sleep 2
truba status > /tmp/st.json
check "status: traffic.tunnel.up" test "$(jsonfilter -i /tmp/st.json -e '@.traffic.tunnel.up')" = "$(bytes c_tunnel_up)"
SINCE="$(jsonfilter -i /var/run/truba/applied.json -e '@.counters_since')"
TUN_UP="$(bytes c_tunnel_up)"
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "счётчики пережили применение настроек" test "$(bytes c_tunnel_up)" -ge "$TUN_UP"
check "отсчёт идёт с прежнего момента" test "$(jsonfilter -i /var/run/truba/applied.json -e '@.counters_since')" = "$SINCE"
check "status: программного ускорения нет" test "$(truba status | jsonfilter -e '@.neighbours.offload')" = false
uci set firewall.@defaults[0].flow_offloading='1'; uci commit firewall
check "status: программное ускорение замечено" test "$(truba status | jsonfilter -e '@.neighbours.offload')" = true
uci set firewall.@defaults[0].flow_offloading='0'; uci commit firewall

echo "== история скорости для «Обзора» (процесс truba stats)"
if ucode /repo/tests/router/test_stats.uc > /tmp/ts.out 2>&1; then ok "история: точки, минуты, разрывы (test_stats.uc)"
else fail "история: точки, минуты, разрывы (test_stats.uc)"; grep -v '^ok' /tmp/ts.out; fi
# Сводка файла истории или ответа rates; поля: 1 — точек, 2 — время первой, 3 — время последней,
# 4 — точек со скоростью, 5 — шаг; среди точек новее ARGV[1]: 6 — наибольшая скорость
# Туннеля от устройств, 7 — разрывов.
cat > /tmp/rates.uc <<-'EOF'
	import { readfile } from 'fs';
	let d = json(readfile(ARGV[0]) ?? '{}'), p = d.points ?? [], after = int(ARGV[1] ?? 0);
	let up = 0, gaps = 0;
	for (let x in p) {
		if (x[0] <= after)
			continue;
		if (length(x) == 1)
			gaps++;
		else if ((x[2] ?? 0) > up)
			up = x[2];
	}
	printf('%d %d %d %d %d %d %d\n', length(p), p[0]?.[0] ?? 0, p[length(p) - 1]?.[0] ?? 0,
		length(filter(p, (x) => length(x) > 1)), d.step ?? 0, up, gaps);
EOF
# rf ПОЛЕ ФАЙЛ [НОВЕЕ]
rf() { ucode /tmp/rates.uc "$2" "${3:-0}" 2>/dev/null | cut -d' ' -f"$1"; }
R=/var/run/truba/rates.json
stats_running() { ubus call service list '{"name":"truba"}' | jsonfilter -e '@.truba.instances.stats.running' | grep -q true; }
check "история: процесс stats запущен procd" stats_running
has_rates() { [ "$(rf 4 $R)" -ge 2 ] 2>/dev/null; }
check "история: точки со скоростью в /var/run (оперативная память)" wait_for 15 has_rates
check "история: точка — раз в 5 с" test "$(rf 5 $R)" = 5
T0=$(date +%s)
for i in 1 2 3; do lan_tcp 1.2.3.4 48081 >/dev/null 2>&1; done
tun_seen() { [ "$(rf 6 $R "$T0")" -gt 0 ] 2>/dev/null; }
check "история: скорость Туннеля от устройств видна без браузера" wait_for 15 tun_seen
ubus call truba rates '{"span":600}' > /tmp/r1.json
NOW="$(jsonfilter -i /tmp/r1.json -e '@.now')"
check "rpcd rates: время Роутера" test "$NOW" -ge "$T0"
check "rpcd rates: точки за 10 минут" test "$(rf 4 /tmp/r1.json)" -ge 2
ubus call truba rates '{"span":10}' > /tmp/r2.json
check "rpcd rates: ничего старше срока" test "$(rf 2 /tmp/r2.json)" -gt $((NOW - 10))
LAST="$(rf 3 /tmp/r1.json)"
ubus call truba rates "{\"span\":600,\"since\":$LAST}" > /tmp/r2.json
newer_only() { f="$(rf 2 /tmp/r2.json)"; [ "$f" = 0 ] || [ "$f" -gt "$LAST" ]; }
check "rpcd rates: since — только новые точки" newer_only
check "история: поминутные средние (до минуты)" wait_for 70 test -s /var/run/truba/rates-min.json
ubus call truba rates '{"span":86400}' > /tmp/r3.json
check "rpcd rates: сутки — поминутные средние" test "$(rf 5 /tmp/r3.json)" = 60
# Перезапуск процесса (обновление кода, сбой) продолжает историю из файла, без разрыва.
F0="$(rf 2 $R)"; L0="$(rf 3 $R)"
kill "$(pgrep -f 'truba stat[s]')"   # procd перезапустит через 5 с
newer() { [ "$(rf 3 $R)" -gt "$L0" ] 2>/dev/null; }
check "история: процесс перезапущен procd" wait_for 20 newer
check "история: перезапуск процесса не стирает историю" test "$(rf 2 $R)" = "$F0"
check "история: после перезапуска процесса без разрыва" test "$(rf 7 $R "$L0")" = 0
# Счётчики начаты заново (новый отсчёт в applied.json) — разрыв, а не скачок скорости.
cp /var/run/truba/applied.json /tmp/applied.bak
T1=$(date +%s)
sed -i 's/"counters_since": *[0-9]*/"counters_since": 1/' /var/run/truba/applied.json
gap_after() { [ "$(rf 7 $R "$T1")" -ge 1 ] 2>/dev/null; }
check "история: счётчики начаты заново — разрыв" wait_for 15 gap_after
cp /tmp/applied.bak /var/run/truba/applied.json

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
# Запросы выше прошли через кэш mosdns — «Обзор» видит их в status.
check "status: счётчики кэша DNS" sh -c "[ \"\$(truba status | jsonfilter -e '@.dns_cache.query')\" -gt 0 ] && [ \"\$(truba status | jsonfilter -e '@.dns_cache.max')\" -eq 65536 ]"

echo "== truba check"
/usr/sbin/truba check 77.88.8.8 > /tmp/chk.json; head -c 400 /tmp/chk.json; echo
check "check IP из geoip:ru → direct" grep -q '"action": "direct"' /tmp/chk.json
check "check: Категория geoip адреса — ru" test "$(jsonfilter -i /tmp/chk.json -e '@.ips[0].geoip[0]')" = ru
check "check: набор gi_direct4 выведен верно" test "$(jsonfilter -i /tmp/chk.json -e '@.ips[0].sets.gi_direct')" = true
check "check: адрес домашней сети — в bypass4 из ядра" sh -c "/usr/sbin/truba check 192.168.1.50 | jsonfilter -e '@.ips[0].reason' | grep -qx local"
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

echo "== DNS: ленивый кэш mosdns"
check "mosdns: lazy_cache_ttl 86400 по умолчанию" grep -q '"lazy_cache_ttl": 86400' /var/etc/truba/mosdns.json
# Свой DNS-сервер с TTL 2 с — для «Туннеля» и «Напрямую» сразу, чтобы не зависеть от Категории
# (.test входит в private, то есть «Напрямую»). Запись истекает, сервер выключается: ответ может
# прийти только из ленивого кэша. Сначала то же без него — иначе проверка ничего не доказывает.
# Спрашиваем mosdns напрямую: dnsmasq со stop-dns-rebind отбрасывает ответы из 192.0.2.0/24.
OLD_TUNNEL_DNS="$(uci -q get truba.dns.tunnel_upstream)"
OLD_DIRECT_DNS="$(uci -q get truba.dns.direct_upstream)"
MOSDNS_PORT="$(uci -q get truba.dns.port || echo 5335)"
lazy_ask() { nslookup -type=A -port="$MOSDNS_PORT" lazy.test 127.0.0.1 2>&1 | grep -q 192.0.2.77; }
set_upstreams() {   # set_upstreams "туннель…" "напрямую…"
	uci -q delete truba.dns.tunnel_upstream
	uci -q delete truba.dns.direct_upstream
	for u in $1; do uci add_list truba.dns.tunnel_upstream="$u"; done
	for u in $2; do uci add_list truba.dns.direct_upstream="$u"; done
}
lazy_round() {   # lazy_round TTL — ответ после истечения записи при выключенном сервере
	dnsmasq --conf-file=/dev/null --port=5399 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
		--address=/lazy.test/192.0.2.77 --local-ttl=2 --pid-file=/tmp/dm-lazy.pid
	uci set truba.dns.lazy_cache_ttl="$1"
	set_upstreams 'udp://127.0.0.1:5399' 'udp://127.0.0.1:5399'
	uci commit truba
	check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
	check "lazy_cache_ttl=$1: ответ от своего DNS-сервера" lazy_ask
	sleep 4
	kill "$(cat /tmp/dm-lazy.pid)"; sleep 1
	# Истёкший ответ тоже должен пройти через nftset: после пересборки наборов IP возвращаются сами.
	nft flush set inet truba gs_direct4
	lazy_ask
}
if lazy_round 0; then fail "без ленивого кэша истёкшая запись отдана"; else ok "без ленивого кэша истёкшая запись не отдаётся"; fi
check "mosdns: lazy_cache_ttl 0 — ленивый кэш выключен" sh -c "! grep -q lazy_cache_ttl /var/etc/truba/mosdns.json"
if lazy_round 86400; then ok "истёкшая запись отдана из ленивого кэша, пока сервер недоступен"; else fail "ленивый кэш не отдал истёкшую запись"; fi
check "IP из истёкшего ответа снова в gs_direct4" sh -c "nft list set inet truba gs_direct4 | grep -q 192.0.2.77"
check "sets: IP из DNS посчитаны" sh -c "[ \"\$(truba sets | jsonfilter -e '@.dns.direct')\" -ge 1 ]"
check "status: истёкшие ответы видны в счётчиках кэша" sh -c "[ \"\$(truba status | jsonfilter -e '@.dns_cache.lazy_hit')\" -ge 1 ]"
# Дамп кэша в оперативной памяти: смена настройки DNS перезапускает mosdns, кэш остаётся.
# Сервер по-прежнему выключен — ответ после перезапуска может прийти только из дампа.
MOSDNS_PID="$(pidof mosdns)"
OLD_TTL_MAX="$(uci -q get truba.dns.ttl_max)"
uci set truba.dns.ttl_max=299
uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "смена настройки DNS перезапустила mosdns" sh -c "pidof mosdns && [ \"\$(pidof mosdns)\" != '$MOSDNS_PID' ]"
check "дамп кэша в оперативной памяти" test -s /var/lib/truba/mosdns-cache.dump
check "после перезапуска mosdns запись взята из дампа" lazy_ask
if [ -n "$OLD_TTL_MAX" ]; then uci set truba.dns.ttl_max="$OLD_TTL_MAX"; else uci -q delete truba.dns.ttl_max; fi
set_upstreams "$OLD_TUNNEL_DNS" "$OLD_DIRECT_DNS"
uci set truba.dns.lazy_cache_ttl=86400
uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3

echo "== API mosdns: порт занят другой программой"
# Ошибка API останавливает mosdns целиком, а с ней DNS всей сети: тогда — без API.
OLD_DNS_PORT="$(uci -q get truba.dns.port)"
ucode /repo/tests/router/tcp_probe.uc server 5346 >/dev/null 2>&1 & BUSY_PID=$!
sleep 1
uci set truba.dns.port=5345; uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "занятый порт API: в конфиге mosdns нет API" sh -c "! grep -q '\"api\"' /var/etc/truba/mosdns.json"
MOSDNS_PID="$(pidof mosdns)"; sleep 7
check "занятый порт API: mosdns работает и не перезапускается" sh -c "[ -n '$MOSDNS_PID' ] && [ \"\$(pidof mosdns)\" = '$MOSDNS_PID' ]"
check "занятый порт API: mosdns слушает 5345" sh -c "netstat -lnu | grep -q '127.0.0.1:5345 '"
check "занятый порт API: предупреждение в журнале" sh -c "logread | grep -q 'порт 127.0.0.1:5346 занят'"
check "занятый порт API: счётчиков кэша нет" sh -c "[ -z \"\$(truba status | jsonfilter -e '@.dns_cache.query')\" ]"
kill "$BUSY_PID"
if [ -n "$OLD_DNS_PORT" ]; then uci set truba.dns.port="$OLD_DNS_PORT"; else uci -q delete truba.dns.port; fi
uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "порт API свободен — API снова есть" sh -c "curl -s -m 2 http://127.0.0.1:5336/metrics | grep -q '^mosdns_cache_query_total'"

echo "== Политика устройства"
uci -q batch <<-'EOF'
	add truba device
	set truba.@device[-1].name='ps5'
	set truba.@device[-1].mac='AA:BB:CC:DD:EE:FF'
	set truba.@device[-1].policy='tunnel'
	commit truba
EOF
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "MAC в dev_tunnel" sh -c "nft list set inet truba dev_tunnel | grep -qi 'aa:bb:cc:dd:ee:ff'"
if grep -q '^Name:' /tmp/ns.out; then
	check "gs_direct4 сохранён при перезагрузке правил" sh -c "nft list set inet truba gs_direct4 | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'"
else
	nft add element inet truba gs_direct4 '{ 198.51.100.7 }'
	check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
	check "gs_direct4 сохранён при перезагрузке правил" sh -c "nft list set inet truba gs_direct4 | grep -q 198.51.100.7"
fi

echo "== IP из DNS в наборах — со сроком (ADR 0007)"
# Адрес CDN, которым домен больше не пользуется, не должен направлять трафик неделями,
# до следующей смены правил или списков.
# left_le IP N — элементу IP в gs_direct4 осталось не больше N с.
left_le() { L="$(nft -j list set inet truba gs_direct4 | jsonfilter -e "@.nftables[*].set.elem[@.elem.val='$1'].elem.expires")"; [ -n "$L" ] && [ "$L" -le "$2" ]; }
check "gs_direct4: срок по умолчанию — сутки" sh -c "nft list set inet truba gs_direct4 | grep -q 'timeout 1d'"
check "IP, положенный mosdns, получает срок набора" sh -c "nft list set inet truba gs_direct4 | grep -q '192.0.2.77 expires'"
nft add element inet truba gs_direct4 '{ 198.51.100.9 expires 90s }'
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "перенос в новую таблицу не продлевает срок" left_le 198.51.100.9 90
# Срок короче оставшегося у перенесённых — ядро не приняло бы элемент длиннее срока набора.
nft add element inet truba gs_direct4 '{ 198.51.100.10 expires 80000s }'
uci set truba.dns.set_timeout=3600; uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "срок 1 ч: применено без ошибки" sh -c "! grep -q '\"error\"' /var/run/truba/applied.json && nft list set inet truba gs_direct4 | grep -q 'timeout 1h'"
check "срок 1 ч: перенесённый IP укорочен до срока набора" left_le 198.51.100.10 3600
uci set truba.dns.set_timeout=0; uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "без срока: применено без ошибки, IP перенесены" sh -c "! grep -q '\"error\"' /var/run/truba/applied.json && ! nft list set inet truba gs_direct4 | grep -q timeout && nft list set inet truba gs_direct4 | grep -q 198.51.100.10"
uci -q delete truba.dns.set_timeout; uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "срок снова сутки, перенесённые без срока получили его" sh -c "nft list set inet truba gs_direct4 | grep -q 'timeout 1d' && nft list set inet truba gs_direct4 | grep -q '198.51.100.10 expires'"

echo "== Неверные настройки пропускаются, а не ломают применение"
# Опечатки из консоли: MAC не давал загрузить таблицу nft, схема адреса DNS — запустить mosdns,
# адрес для ping делал Туннель «неработающим» навсегда.
SAVED_TUNNEL_DNS="$(uci -q get truba.dns.tunnel_upstream)"
uci -q batch <<-'EOF'
	add truba device
	set truba.@device[-1].name='typo'
	set truba.@device[-1].mac='AA:BB:CC:DD:EE'
	set truba.@device[-1].policy='tunnel'
	add_list truba.dns.tunnel_upstream='htps://1.1.1.1/dns-query'
	set truba.watchdog.probe='10.77.77.l'
	commit truba
EOF
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "неверные настройки: применено без ошибки" sh -c "! grep -q '\"error\"' /var/run/truba/applied.json"
check "неверные настройки: перечислены для «Обзора»" sh -c "[ \"\$(jsonfilter -i /var/run/truba/applied.json -e '@.invalid[*].key' | sort | xargs)\" = 'device.mac dns.tunnel_upstream watchdog.probe' ]"
check "MAC с опечаткой не попал в набор, верный остался" sh -c "nft list set inet truba dev_tunnel | grep -qi 'aa:bb:cc:dd:ee:ff' && ! nft list set inet truba dev_tunnel | grep -qiE 'aa:bb:cc:dd:ee( |,|$)'"
check "адрес DNS с опечаткой не попал в конфиг mosdns, верные остались" sh -c "! grep -q htps /var/etc/truba/mosdns.json && grep -q 'https://1.1.1.1/dns-query' /var/etc/truba/mosdns.json"
check "неверные настройки: mosdns слушает 5335" sh -c "netstat -lnu | grep -q '127.0.0.1:5335 '"
uci -q delete truba.dns.tunnel_upstream; uci add_list truba.dns.tunnel_upstream='htps://x'; uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "все адреса DNS неверные — стандартные, а не mosdns без серверов" grep -q 'https://8.8.8.8/dns-query' /var/etc/truba/mosdns.json
uci -q delete truba.@device[-1]
uci -q delete truba.dns.tunnel_upstream
for u in $SAVED_TUNNEL_DNS; do uci add_list truba.dns.tunnel_upstream="$u"; done
uci set truba.watchdog.probe=''
uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "настройки исправлены: пропущенных нет" sh -c "[ -z \"\$(jsonfilter -i /var/run/truba/applied.json -e '@.invalid[*]')\" ]"

echo "== Ошибка применения: служба и DNS сети продолжают работать (ADR 0006)"
# Обёртка nft отказывается загружать новую таблицу Трубы, пока есть /tmp/nft-fail, — как при
# ошибке в правилах или нехватке памяти ядра. Остальное, в том числе загрузку последней
# удачной копии, выполняет настоящий nft.
NFT_BIN="$(command -v nft)"
mv "$NFT_BIN" "$NFT_BIN.real"
cat > "$NFT_BIN" <<-EOF
	#!/bin/sh
	if [ -f /tmp/nft-fail ]; then
		for a in "\$@"; do
			[ "\$a" = /var/etc/truba/truba.nft ] && { echo 'Error: simulated failure' >&2; exit 1; }
		done
	fi
	exec $NFT_BIN.real "\$@"
EOF
chmod +x "$NFT_BIN"
# Шаг не дольше 90 с; код возврата самой команды не важен: проверки — после.
finished() { bounded 90 "$@"; [ $? -ne 124 ]; }
ads_blocked() { nslookup "$ADS" 127.0.0.1 2>&1 | grep -qiE 'NXDOMAIN|can.t find'; }

check "копия правил сохранена на флеше" sh -c "[ -s /etc/truba/good/truba.nft ] && [ -s /etc/truba/good/mosdns.json ] && [ -s /etc/truba/good/meta.json ]"
check "копия: без накопленных счётчиков и без IP из DNS" sh -c "! grep -q 'packets [1-9]' /etc/truba/good/truba.nft && ! grep -A3 'set gs_direct4' /etc/truba/good/truba.nft | grep -q elements"
check "копия: mosdns без API, со своими списками доменов" sh -c "! grep -q '\"api\"' /etc/truba/good/mosdns.json && grep -q '/etc/truba/good/geosite/category-ads.txt' /etc/truba/good/mosdns.json && [ -s /etc/truba/good/geosite/category-ads.txt ]"
GOOD_INODE="$(ls -i /etc/truba/good/truba.nft | awk '{print $1}')"
uci set truba.watchdog.enabled='1'; uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "копия не переписывается, пока ничего не изменилось (флеш)" test "$(ls -i /etc/truba/good/truba.nft | awk '{print $1}')" = "$GOOD_INODE"

# Сбой при работе: новая таблица (Режим «Выборочный») не загружается.
MOSDNS_PID="$(pidof mosdns)"
touch /tmp/nft-fail
uci set truba.main.mode='selective'; uci commit truba
check "reload при ошибке nft завершился" finished /etc/init.d/truba reload; sleep 3
check "ошибка nft записана для «Обзора»" sh -c "jsonfilter -i /var/run/truba/applied.json -e '@.error' | grep -q 'simulated failure'"
check "ошибка: действуют правила, загруженные до неё" test "$(jsonfilter -i /var/run/truba/applied.json -e '@.fallback')" = kept
check "ошибка: в ядре прежняя таблица (Режим «Всё в туннель»)" sh -c "nft list chain inet truba classify | tail -3 | grep -qE 'meta mark set meta mark & 0xff0[0-9a-f]ffff \| 0x00010000'"
check "ошибка: applied.json описывает действующую таблицу" test "$(jsonfilter -i /var/run/truba/applied.json -e '@.mode')" = all
check "ошибка: mosdns не остановлен и не перезапущен" test "$(pidof mosdns)" = "$MOSDNS_PID"
check "ошибка: watchdog работает" pgrep -f 'truba watchdo[g]'
check "ошибка: dnsmasq по-прежнему → mosdns" sh -c "uci -q get dhcp.@dnsmasq[0].server | grep -q '127.0.0.1#5335'"
check "ошибка: DNS сети отвечает (Блок $ADS → NXDOMAIN)" ads_blocked

# Загрузка Роутера: таблицы в ядре нет, /var пуст (tmpfs), а применить настройки не удаётся.
/etc/init.d/truba stop; sleep 1
rm -rf /var/run/truba /var/etc/truba /var/lib/truba
check "старт при ошибке nft завершился" finished /etc/init.d/truba start; sleep 4
check "загрузка: последняя удачная копия" test "$(jsonfilter -i /var/run/truba/applied.json -e '@.fallback')" = last_good
check "загрузка: таблица из копии, подсети geoip на месте" sh -c "nft list set inet truba gi_direct4 | grep -q '5\.'"
check "загрузка: mosdns с конфигом и списками копии" sh -c "pidof mosdns && grep -q '/etc/truba/good/geosite/' /var/etc/truba/mosdns.json"
check "загрузка: dnsmasq → mosdns" sh -c "uci -q get dhcp.@dnsmasq[0].server | grep -q '127.0.0.1#5335'"
check "загрузка: DNS сети отвечает (Блок $ADS → NXDOMAIN)" wait_for 10 ads_blocked
check "загрузка: правила ip и таблица Туннеля" sh -c "ip rule show | grep -q 'lookup 77' && ip route show table 77 | grep -q 'default dev awg0'"

# Загрузка без копии (её ещё ни разу не было): правил Трубы нет — и DNS идёт напрямую.
/etc/init.d/truba stop; sleep 1
rm -rf /var/run/truba /var/etc/truba /var/lib/truba /etc/truba/good
check "старт без копии при ошибке nft завершился" finished /etc/init.d/truba start; sleep 4
check "без копии: правил Трубы нет" sh -c "[ \"\$(jsonfilter -i /var/run/truba/applied.json -e '@.fallback')\" = none ] && ! nft list table inet truba"
check "без копии: DNS напрямую, dnsmasq без mosdns" sh -c "! uci -q get dhcp.@dnsmasq[0].server | grep -q 5335"
check "без копии: mosdns не запущен" sh -c "! pidof mosdns"

rm -f /tmp/nft-fail
uci set truba.main.mode='all'; uci set truba.watchdog.enabled='0'; uci commit truba
check "reload после устранения ошибки (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "после устранения: применено без ошибки" sh -c "! grep -q '\"error\"' /var/run/truba/applied.json"
check "после устранения: mosdns работает, копия снова есть" sh -c "pidof mosdns && [ -s /etc/truba/good/meta.json ]"
mv "$NFT_BIN.real" "$NFT_BIN"

echo "== Контроль Туннеля: задержка и потери для «Обзора»"
# 192.0.2.200 уходит в Туннель, но Труба его не пересылает — ответа нет.
cat > /tmp/rtt.uc <<-'EOF'
	import { ping_rtt } from 'truba.watchdog';
	print(sprintf('%J %J\n', ping_rtt('awg0', '10.77.77.1'), ping_rtt('awg0', '192.0.2.200')));
EOF
RTT="$(ucode /tmp/rtt.uc 2>&1)"; echo "ping_rtt: $RTT"
check "ping_rtt: задержка до Трубы через Туннель" sh -c "echo '$RTT' | grep -qE '^[0-9.]+ '"
check "ping_rtt: нет ответа → null" sh -c "echo '$RTT' | grep -q ' null$'"
OLD_WD_INTERVAL="$(uci -q get truba.watchdog.interval)"
uci set truba.watchdog.enabled='1'; uci set truba.watchdog.interval='10'; uci commit truba
rm -f /var/run/truba/nat.json   # как после перезагрузки: итога проверки NAT ещё нет
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload
wd_probes() { [ "$(jsonfilter -i /var/run/truba/health.json -e '@.probes[0]' 2>/dev/null | cut -d. -f1)" -ge 0 ] 2>/dev/null; }
check "watchdog: задержка и окно проверок в health.json" wait_for 15 wd_probes
# STUN-серверы из раздела «Проверка NAT» ещё отвечают.
nat_auto() { [ "$(jsonfilter -i /var/run/truba/nat.json -e '@.auto' 2>/dev/null)" = true ]; }
check "watchdog: проверка NAT запущена сама, Туннель в порядке" wait_for 20 nat_auto
check "watchdog: итог автоматической проверки NAT — OK" test "$(jsonfilter -i /var/run/truba/nat.json -e '@.ok')" = true
# Крупные пакеты — сразу после подъёма Туннеля: ping во весь MTU проходит.
big_ok() { [ "$(jsonfilter -i /var/run/truba/health.json -e '@.big.ok' 2>/dev/null)" = true ]; }
check "watchdog: крупные пакеты проходят" wait_for 20 big_ok
check "watchdog: крупные пакеты — размер во весь MTU" test "$(jsonfilter -i /var/run/truba/health.json -e '@.big.size')" = "$TUN_MTU"
check "status: health.big для вкладки «Туннель»" test "$(truba status | jsonfilter -e '@.health.big.ok')" = true
NAT_TIME="$(jsonfilter -i /var/run/truba/nat.json -e '@.time')"
sleep 12   # следующий цикл: итог свежее «в порядке с» — повтора нет
check "watchdog: без нового подъёма Туннеля NAT не перепроверяется" test "$(jsonfilter -i /var/run/truba/nat.json -e '@.time')" = "$NAT_TIME"
check "watchdog: health.json в /var/run (оперативная память)" sh -c "jsonfilter -i /var/run/truba/health.json -e '@.rtt' && [ \"\$(jsonfilter -i /var/run/truba/health.json -e '@.interval')\" = 10 ]"
check "status: health.probes для «Обзора»" sh -c "truba status | jsonfilter -e '@.health.probes[0]'"
# Обновление пакета меняет код, но не команду инстанса: reload должен перезапустить watchdog.
WD_PID="$(pgrep -f 'truba watchdo[g]')"
WD_SINCE="$(jsonfilter -i /var/run/truba/health.json -e '@.since')"
echo '// обновлено' >> /usr/share/ucode/truba/const.uc
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 2
check "новый код watchdog вступает в силу при reload" sh -c "P=\$(pgrep -f 'truba watchdo[g]'); [ -n \"\$P\" ] && [ \"\$P\" != '$WD_PID' ]"
check "перезапуск watchdog не обнуляет «в порядке с»" test "$(jsonfilter -i /var/run/truba/health.json -e '@.since')" = "$WD_SINCE"
sed -i '$d' /usr/share/ucode/truba/const.uc
# Запись после перерыва (watchdog был выключен) описывает прошлое — её «в порядке с» и окно не берутся.
echo '{"state":"healthy","since":1000,"last_check":1000,"interval":10,"probes":[1,2,3]}' > /var/run/truba/health.json
kill "$(pgrep -f 'truba watchdo[g]')"   # procd перезапустит через 5 с
wd_fresh() { [ "$(jsonfilter -i /var/run/truba/health.json -e '@.since')" != 1000 ]; }
check "устаревшая запись: «в порядке с» начинается заново" wait_for 20 wd_fresh
check "устаревшая запись: окно проверок не взято" sh -c "[ \$(jsonfilter -i /var/run/truba/health.json -e '@.probes[*]' | wc -l) -le 1 ]"
if [ -n "$OLD_WD_INTERVAL" ]; then uci set truba.watchdog.interval="$OLD_WD_INTERVAL"; else uci -q delete truba.watchdog.interval; fi
uci -q delete truba.main.stun
uci set truba.watchdog.enabled='0'; uci commit truba
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 2

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
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
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
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "Выборочный: по умолчанию Напрямую" sh -c "nft list chain inet truba classify | tail -3 | grep -qE 'meta mark set meta mark & 0xff0[0-9a-f]ffff \| 0x00020000'"
/usr/sbin/truba check 8.8.8.8 > /tmp/chk4.json
check "check 8.8.8.8 → direct (Режим)" grep -q '"reason": "mode"' /tmp/chk4.json
check "смена Режима сбрасывает gs_direct4" sh -c "! nft list set inet truba gs_direct4 | grep -q 198.51.100.7"

echo "== update-lists: скачивание в /tmp (tmpfs) и перенос на /etc"
# На роутере /tmp — tmpfs, а /etc — overlay: rename между ними не работает (EXDEV).
mount | grep -q ' on /tmp type tmpfs' && echo "/tmp — tmpfs, как на роутере" || echo "внимание: /tmp не tmpfs, перенос между ФС не проверяется"
mkdir -p /root/src
src_sum() { (cd /root/src && sha256sum "$1" > "$1.sha256sum"); }
for f in geoip.dat geosite.dat; do
	cp "/dat/$f" "/root/src/$f"
	# Другая, но правильная версия (дописана Категория): update-lists видит новый файл.
	ucode /repo/tests/router/dat_append.uc "${f%.dat}" "/root/src/$f" zztest
	src_sum "$f"
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
# Через rpcd (кнопка «Откатить»): файлы переставляются сразу, а применение идёт в фоне —
# иначе rpcd ждал бы распаковку и загрузку подсетей geoip, и стоял бы весь LuCI.
APPLIED_T="$(jsonfilter -i /var/run/truba/applied.json -e '@.time')"; sleep 1
T0=$(date +%s); ubus call truba rollback_lists > /tmp/rb2.json; T1=$(date +%s)
check "rpcd rollback_lists отвечает сразу (было $((T1 - T0)) с)" test $((T1 - T0)) -le 1
check "rpcd rollback_lists: оба набора, применение в фоне" sh -c "grep -q geosite.dat /tmp/rb2.json && [ \"\$(jsonfilter -i /tmp/rb2.json -e '@.applying')\" = true ]"
applied_after() { [ "$(jsonfilter -i /var/run/truba/applied.json -e '@.time')" -gt "$APPLIED_T" ]; }
check "rpcd rollback_lists: настройки применены в фоне" wait_for 60 applied_after
check "rpcd rollback_lists: применение завершилось" wait_idle 60
unstick
check "lists: применение не идёт" test "$(ubus call truba lists | jsonfilter -e '@.applying')" = false

echo "== update-lists -f без изменений: предыдущая версия остаётся версией для отката"
for f in geoip.dat geosite.dat; do cp "/etc/truba/lists/$f" "/root/src/$f"; src_sum "$f"; done
PREV_SHA="$(sha256sum < /etc/truba/lists/prev/geosite.dat)"
APPLIED_T="$(jsonfilter -i /var/run/truba/applied.json -e '@.time')"
sleep 1
/usr/sbin/truba update-lists -f > /tmp/ul2.json 2>&1 &
check "update-lists -f и его reload завершились" wait_idle 60
unstick
check "-f без изменений: предыдущая версия на месте" test "$(sha256sum < /etc/truba/lists/prev/geosite.dat)" = "$PREV_SHA"
check "-f без изменений: настройки применены заново" sh -c "[ \"\$(jsonfilter -i /var/run/truba/applied.json -e '@.time')\" -gt $APPLIED_T ]"

echo "== update-lists: файл, который не разбирается, не заменяет текущий"
# Контрольная сумма у источника честная: файл скачан целиком, но поврежден (или нового формата).
CUR_SHA="$(sha256sum < /etc/truba/lists/geosite.dat)"
head -c 1500000 /dat/geosite.dat > /root/src/geosite.dat; src_sum geosite.dat
/usr/sbin/truba update-lists > /tmp/ul3.json 2>&1 &
check "update-lists с нечитаемым файлом завершился" wait_idle 60
unstick
check "нечитаемый geosite не принят (parse failed)" sh -c "jsonfilter -i /etc/truba/state/lists.json -e '@.sets.geosite.errors[*]' | grep -q 'parse failed'"
check "нечитаемый geosite: текущий не заменён" test "$(sha256sum < /etc/truba/lists/geosite.dat)" = "$CUR_SHA"
check "нечитаемый geosite: mosdns работает" pidof mosdns
cp /dat/geosite.dat /root/src/geosite.dat; src_sum geosite.dat

echo "== apply: текущие списки не читаются — возвращаются предыдущие"
# Так могло остаться от версий, которые не проверяли скачанное.
head -c 1500000 /dat/geosite.dat > /tmp/broken.dat
mv /tmp/broken.dat /etc/truba/lists/geosite.dat
(cd /etc/truba/lists && sha256sum geosite.dat > geosite.dat.sha256sum)
check "reload (не дольше 90 с)" bounded 90 /etc/init.d/truba reload; sleep 3
check "нечитаемые списки: применено без ошибки" sh -c "! grep -q '\"error\"' /var/run/truba/applied.json"
check "нечитаемые списки: предупреждение для «Обзора»" grep -q lists_rolled_back /var/run/truba/applied.json
check "нечитаемые списки: текущим стал предыдущий" test "$(wc -c < /etc/truba/lists/geosite.dat)" -gt 1500000
check "нечитаемые списки: mosdns работает" pidof mosdns

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

echo "== sysupgrade: reinstall.sh возвращает DNS сети до ожидания интернета"
# После sysupgrade /etc/config/dhcp и бэкап Трубы (/etc/truba в keep.d) сохраняются, а пакетов
# нет: dnsmasq шлёт запросы в mosdns, которого нет, и reinstall.sh ждал бы интернета вечно.
# Имитация: служба снята без teardown (procd убивает mosdns, настройки dnsmasq остаются);
# «исходный» DNS сети в бэкапе — свой сервер на 5399, который знает up.trubatest (не .test:
# эту зону dnsmasq OpenWrt отвечает сам, rfc6761.conf). truba в этом контейнере стоит
# не из apk, поэтому reinstall.sh идёт дальше проверки «уже установлена».
cp /etc/truba/state/dnsmasq.json /tmp/dnsmasq.orig.json
DM_SID="$(jsonfilter -i /tmp/dnsmasq.orig.json -e '@.sid')"
printf '{"sid":"%s","noresolv":"1","server":["127.0.0.1#5399"]}' "$DM_SID" > /etc/truba/state/dnsmasq.json
dnsmasq --conf-file=/dev/null --port=5399 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
	--address=/up.trubatest/5.6.7.8 --pid-file=/tmp/dm-up.pid
ubus call service delete '{"name":"truba"}'; sleep 2
up_ok() { nslookup up.trubatest 127.0.0.1 2>&1 | grep -q 5.6.7.8; }
check "sysupgrade: mosdns нет — DNS сети не отвечает" sh -c "! pidof mosdns && ! nslookup up.trubatest 127.0.0.1 2>&1 | grep -q 5.6.7.8"
sh /etc/truba/reinstall.sh >/dev/null 2>&1 & RI_PID=$!
check "reinstall: DNS сети отвечает, не дожидаясь интернета" wait_for 20 up_ok
check "reinstall: dnsmasq вернулся к серверам из бэкапа" test "$(uci -q get dhcp.@dnsmasq[0].server)" = "127.0.0.1#5399"
check "reinstall: бэкап dnsmasq использован и удалён" test ! -f /etc/truba/state/dnsmasq.json
check "reinstall: запись в журнале" sh -c "logread | grep -q 'truba-reinstall.*DNS сети возвращён'"
check "reinstall: дальше ждёт интернет (ещё работает)" kill -0 "$RI_PID"
kill "$RI_PID" 2>/dev/null; for p in $(pgrep -f 'truba/reinstall[.]sh'); do kill "$p" 2>/dev/null; done
kill "$(cat /tmp/dm-up.pid)" 2>/dev/null
# Как было до имитации: исходный бэкап, dnsmasq → mosdns, служба снова работает.
cp /tmp/dnsmasq.orig.json /etc/truba/state/dnsmasq.json
uci -q batch <<-'EOF'
	delete dhcp.@dnsmasq[0].server
	add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
	set dhcp.@dnsmasq[0].noresolv='1'
	set dhcp.@dnsmasq[0].cachesize='0'
	commit dhcp
EOF
check "служба снова запускается (не дольше 90 с)" bounded 90 /etc/init.d/truba start; sleep 3
check "после имитации: mosdns работает" pidof mosdns

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
check "последняя удачная копия правил удалена" test ! -e /etc/truba/good

echo
[ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"
exit "$FAILS"
