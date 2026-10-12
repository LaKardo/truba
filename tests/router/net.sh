#!/bin/sh
# Путь пакетов: что ставит установка, правила и маршруты после применения, входящие через
# Туннель, свои сокеты Роутера, чужие цепочки nftables и mesh-VPN (ADR 0011), mesh-VPN как зона Маршрутизации:
# перенаправление в truba и DNS (ADR 0014), закрытый IPv6-интернет зон (ADR 0016), DSCP Туннеля, учёт трафика, Политика
# устройства, Аварийная блокировка, Маршрутизация выкл, Режим «Выборочный», teardown, uninstall.
. /repo/tests/router/stand.sh

# Правило зоны, закрывающее IPv6-интернет (ADR 0016), — в цепочке зоны у fw4: отказ всем адресам, кроме локальных.
no6_chain() { nft list chain inet fw4 "forward_$1" 2>/dev/null | grep -q 'ip6 daddr != { fc00::/7, fe80::/10, ff00::/8 } .*jump handle_reject'; }

section "установка (uci-defaults)"
check "зона truba (установка) и перенаправление lan → truba (применение)" eval '[ "$(uci -q get firewall.truba.name)" = truba ] && [ "$(uci -q get firewall.lan_truba.dest)" = truba ]'
check "fullcone включён, аппаратное ускорение выключено" eval '[ "$(uci -q get firewall.@defaults[0].fullcone)" = 1 ] && [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 0 ]'
check "программное ускорение не тронуто" cmp -s /tmp/offload.before /tmp/offload.after
check "IPv6-интернет зоне lan закрыт (применение), IPv6 сети не тронут" eval 'no6_chain lan && [ "$(uci -q get dhcp.lan.ra)" != disabled ]'
check "Стартовые настройки: 8 правил" test "$(uci -q show truba | grep -c '=rule$')" -eq 8
# rc.local стенда — маркер готовности (tests/run.sh): здесь — как на Роутере, с «exit 0», и uci-defaults дважды.
printf '# Put your custom commands here\n\nexit 0\n' > /etc/rc.local
sh /etc/uci-defaults/90-truba; sh /etc/uci-defaults/90-truba
check "rc.local: переустановка после sysupgrade — одной строкой перед exit 0" eval \
	'[ "$(grep -cF /etc/truba/reinstall.sh /etc/rc.local)" = 1 ] && grep -B1 "^exit 0" /etc/rc.local | grep -qxF "[ -x /etc/truba/reinstall.sh ] && /etc/truba/reinstall.sh &"'

section "применение (Маршрутизация вкл)"
check "без ошибки" no_error
check "ubus truba.schema через rpcd: умолчание iface" eval '[ "$(ubus call truba schema | jsonfilter -e @.sections.main.iface.def)" = awg0 ]'
check "подсети geoip:ru — в gi_direct4, их число — для «DNS и списки»" eval 'in_set gi_direct4 "[[:space:]{,]5\.[0-9]" && [ "$(truba sets | jsonfilter -e "@.geoip.direct")" -gt 0 ]'
check "bypass4: IP Трубы и подсеть Туннеля" eval 'nft get element inet truba bypass4 "{ 198.51.100.2 }" && in_set bypass4 10.77.77.0/30'
check "lan_if = br-lan" in_set lan_if br-lan
check "ip rule: метка Туннеля и oif awg0 → 77" eval 'ip rule show | grep -q "fwmark 0x1000000/0xf000000 lookup 77" && ip rule show | grep -q "oif awg0 lookup 77"'
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
	check "свой UDP с меткой Туннеля → через Туннель ($1)" test "$(udp_out 0x1000000)" = vps
	foreign_on
	check "чужие цепочки: ответ на входящее всё равно в Туннель ($1)" probe
	# Внешние пакеты Туннеля к Трубе — только напрямую, иначе Туннель ушёл бы в чужую таблицу.
	check "чужие цепочки: Туннель жив, ping Трубы ($1)" ping -c 2 -W 2 10.77.77.1
	if [ "$SOCKET_MARK" = true ]; then
		check "чужие цепочки: свой UDP с меткой Туннеля всё равно через Туннель ($1)" test "$(udp_out 0x1000000)" = vps
	else
		echo "skip  в ядре нет nft_socket (kmod-nft-socket): метка своих сокетов при чужой цепочке ($1)"
	fi
	foreign_off
}
foreign_checks "Маршрутизация вкл"

section "соседняя mesh-VPN"
# Служба mesh-VPN занимает байт 0x00ff0000 целиком. Своим сокетам она ставит 0x80000 (правило 5210 →
# main), пакетам со своего интерфейса в forward — 0x40000 и маскарадинг по этой метке, а в mangle
# prerouting и output копирует байт между ct mark и meta mark; restore перезаписывает meta mark
# целиком. Узлы сети — в её таблице 52 (правило 5270); узел 100.64.0.2 — netns meshhost за ms0.
ip netns add meshhost
ip link add ms0 type veth peer name ms1
ip link set ms1 netns meshhost
ip addr add 100.64.0.1/32 dev ms0; ip link set ms0 up
ip -n meshhost link set lo up; ip -n meshhost link set ms1 up
ip -n meshhost addr add 100.64.0.2/32 dev ms1
ip -n meshhost route add 100.64.0.1 dev ms1
ip -n meshhost route add default via 100.64.0.1 dev ms1
ip route add 100.64.0.2 dev ms0 table 52
ip rule add fwmark 0x80000/0xff0000 lookup main priority 5210
ip rule add lookup 52 priority 5270
ip netns exec meshhost ucode /repo/tests/lib/tcp_probe.uc server 48082 >/dev/null 2>&1 &
# Зона сети, как её создают сами такие службы; «интернет напрямую» стенда — ul0 в зоне wan.
uci -q batch <<-'EOF'
	set firewall.mesh=zone
	set firewall.mesh.name='mesh'
	add_list firewall.mesh.device='ms0'
	set firewall.mesh.input='ACCEPT'
	set firewall.mesh.output='ACCEPT'
	set firewall.mesh.forward='ACCEPT'
	set firewall.mesh_wan=forwarding
	set firewall.mesh_wan.src='mesh'
	set firewall.mesh_wan.dest='wan'
	set firewall.lan_mesh=forwarding
	set firewall.lan_mesh.src='lan'
	set firewall.lan_mesh.dest='mesh'
	add_list firewall.@zone[1].device='ul0'
	commit firewall
EOF
/etc/init.d/firewall reload >/dev/null 2>&1
# mesh_on МАСКА МЕТКА [УСЛОВИЕ] — цепочки службы: МЕТКА в байте МАСКИ ставится пакетам со своего
# интерфейса в forward и по ней маскарадинг; restore копирует байт из ct mark в meta mark, перезаписывая
# её целиком, — с УСЛОВИЕМ или (сборка с ошибкой порядка байтов: маска 0x0000ff00) без него, то есть
# у каждого установленного пакета.
mesh_on() {
	keep=$(printf '0x%08x' $(( ~$1 & 0xffffffff )))
	nft -f - <<-EOF
		table ip t_mesh {
			counter via_tunnel { }
			chain pre {
				type filter hook prerouting priority mangle; policy accept;
				ct state established,related ${3:-} meta mark set ct mark and $1
			}
			chain out {
				type filter hook output priority mangle; policy accept;
				ct state new meta mark and $1 != 0 ct mark set meta mark and $1
			}
			chain mark_fwd {
				type filter hook forward priority filter; policy accept;
				iifname "ms0" meta mark set meta mark and $keep xor $2
			}
			chain count_fwd {
				type filter hook forward priority mangle; policy accept;
				iifname "ms0" oifname "awg0" counter name via_tunnel
				iifname "awg0" oifname "ms0" counter name via_tunnel
			}
			chain post {
				type nat hook postrouting priority srcnat; policy accept;
				meta mark and $1 == $2 masquerade
			}
		}
	EOF
}
mesh_fixed() { mesh_on 0x00ff0000 0x00040000 'ct mark and 0x00ff0000 != 0'; }
mesh_buggy() { mesh_on 0x0000ff00 0x00000400; }
# Узел сети выходит в интернет через Роутер (выходной узел); устройство домашней сети — к узлу.
mesh_exit() { ip netns exec meshhost ucode /repo/tests/lib/tcp_probe.uc client 100.64.0.2 198.51.100.2 48081; }
via_tunnel() { nft list counter ip t_mesh via_tunnel | awk '/packets/ { print $2 }'; }
mesh_checks() {
	check "узел сети → интернет напрямую ($1)" mesh_exit
	check "узел сети: ни одного пакета через Туннель ($1)" test "$(via_tunnel)" = 0
	check "устройство → узел сети ($1)" lan_tcp 100.64.0.2 48082
	check "устройство → Туннель: соединение живо после первого пакета ($1)" lan_tcp 1.2.3.5 48081
	check "ответ на входящее через Туннель — в Туннель ($1)" probe
}
# Из цепочек с одним приоритетом первой идёт загруженная позже: Труба пересоздаёт таблицу при
# каждом применении, служба — при своём запуске. Проверяются оба порядка для обоих вариантов.
ip -n vps addr add 1.2.3.5/32 dev lo
for v in fixed buggy; do
	if [ "$v" = fixed ]; then variant="исправная"; else variant="restore без условия"; fi
	"mesh_$v"
	reload "служба mesh-VPN ($variant) уже работает"
	mesh_checks "$variant, Труба загружена позже"
	nft delete table ip t_mesh; "mesh_$v"
	mesh_checks "$variant, служба загружена позже"
	nft delete table ip t_mesh
done
check "свои сокеты службы (0x80000) — мимо Туннеля" eval 'ip route get 203.0.113.77 mark 0x80000 | grep -q "dev inet0"'

section "mesh-VPN — зона Маршрутизации (ADR 0014)"
# Зона mesh выбрана в «Маршрутизация → Зоны»: перенаправление mesh → truba заводит сама Труба, узлы
# сети идут по Категориям, как домашняя сеть. Адрес ms0 — /32: для dnsmasq с --local-service узлы
# чужие, и он им не отвечает; перехват Трубы подменяет им источник на адрес Роутера.
mesh_tunnel() { ip netns exec meshhost ucode /repo/tests/lib/tcp_probe.uc client 100.64.0.2 1.2.3.5 48081; }
# DNS-ответ на localhost — из /etc/hosts Роутера: ответил dnsmasq, куда бы ни был адресован запрос.
dns_from() { ip netns exec "$1" ucode /repo/tests/lib/dns_ttl.uc 53 localhost "$2" | grep -q '^127\.0\.0\.1 '; }
# Подменённый источник conntrack отмечает флагом snat: его видно на input после nat (srcnat).
# dns_seen ms0|lan — запросы DNS с ms0 или br-lan, dns_snat ms0|lan — из них с подменённым источником.
nft -f - <<-'EOF'
	table inet t_snat {
		counter dns_ms0 { }
		counter snat_ms0 { }
		counter dns_lan { }
		counter snat_lan { }
		chain in {
			type filter hook input priority srcnat + 10; policy accept;
			udp dport 53 iifname "ms0" counter name dns_ms0
			udp dport 53 iifname "ms0" ct status snat counter name snat_ms0
			udp dport 53 iifname "br-lan" counter name dns_lan
			udp dport 53 iifname "br-lan" ct status snat counter name snat_lan
		}
	}
EOF
pk() { nft list counter inet t_snat "$1" | awk '/packets/ { print $2 }'; }
dns_seen() { [ "$(pk "dns_$1")" -gt 0 ]; }
dns_snat() { [ "$(pk "snat_$1")" -gt 0 ]; }
check "до: dnsmasq узлу сети не отвечает" eval '! dns_from meshhost 100.64.0.1'
# IPv6 стенда: у узла сети ULA за ms0; за ul0 (зона wan) — «интернет» 2001:db8:100::2 и ULA fd66::2.
sysctl -qw net.ipv6.conf.all.forwarding=1
ip addr add fd64::1/64 dev ms0 nodad
ip -n meshhost addr add fd64::2/64 dev ms1 nodad; ip -n meshhost -6 route add default via fd64::1
ip addr add 2001:db8:100::1/64 dev ul0 nodad; ip addr add fd66::1/64 dev ul0 nodad
ip -n vps addr add 2001:db8:100::2/64 dev ul1 nodad; ip -n vps addr add fd66::2/64 dev ul1 nodad
ip -n vps -6 route add fd64::/64 via fd66::1
v6_mesh() { ip netns exec meshhost ping -6 -c 2 -w 3 "$1" >/dev/null 2>&1; }
check "до: узел сети выходит в IPv6-интернет" v6_mesh 2001:db8:100::2
uci add_list truba.main.zone='mesh'; uci commit truba
reload "зона mesh выбрана"
check "перенаправление mesh → truba заведено, ms0 — в lan_if" eval '[ "$(uci -q get firewall.mesh_truba.src)" = mesh ] && [ "$(uci -q get firewall.mesh_truba.dest)" = truba ] && in_set lan_if ms0'
check "IPv6-интернет зоне mesh закрыт, lan — по-прежнему" eval 'no6_chain mesh && no6_chain lan'
check "узел сети: IPv6 в интернет — отказ, к ULA за той же зоной wan — проходит" eval '! v6_mesh 2001:db8:100::2 && v6_mesh fd66::2'
check "узел сети → Туннель (по Режиму)" mesh_tunnel
uci delete firewall.mesh_truba; uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1
check "без перенаправления fw4 отбрасывает трафик узла в Туннель" eval '! mesh_tunnel'
reload "перенаправление удалено вручную"
check "применение заводит перенаправление снова" eval '[ "$(uci -q get firewall.mesh_truba.dest)" = truba ] && mesh_tunnel'
check "узел сети: DNS к чужому серверу перехвачен, источник подменён — dnsmasq ответил" eval 'dns_from meshhost 8.8.8.8 && dns_snat ms0'
check "узел сети: DNS к адресу Роутера — тоже" dns_from meshhost 100.64.0.1
check "устройство домашней сети: DNS перехвачен, источник не подменён" eval 'in_set local4 192.168.1.0/24 && dns_from lanhost 8.8.8.8 && dns_seen lan && ! dns_snat lan'
nft delete table inet t_snat
ip addr add 10.99.0.1/24 dev ms0
ACTION=ifupdate INTERFACE=lan sh /etc/hotplug.d/iface/50-truba
check "новая подсеть Роутера — в local4 после события интерфейса (hotplug)" in_set local4 10.99.0.0/24
ip addr del 10.99.0.1/24 dev ms0
uci del_list truba.main.zone='mesh'; uci commit truba
reload "зона mesh убрана"
check "своё перенаправление mesh → truba убрано, lan → truba на месте" eval '[ -z "$(uci -q get firewall.mesh_truba)" ] && [ "$(uci -q get firewall.lan_truba.dest)" = truba ]'
check "правило IPv6 зоны mesh убрано — узел сети снова выходит в IPv6-интернет, lan закрыт" eval \
	'[ -z "$(uci -q get firewall.mesh_truba_no_ipv6)" ] && ! no6_chain mesh && v6_mesh 2001:db8:100::2 && no6_chain lan'
# Перенаправление, которое владелец завёл сам: засчитывается, второе не заводится, без зоны остаётся.
uci -q batch <<-'EOF'
	set firewall.my_mesh=forwarding
	set firewall.my_mesh.src='mesh'
	set firewall.my_mesh.dest='truba'
	commit firewall
	add_list truba.main.zone='mesh'
	commit truba
EOF
/etc/init.d/firewall reload >/dev/null 2>&1
reload "зона mesh и перенаправление владельца"
check "перенаправление владельца засчитано — своего Труба не заводит" eval '[ -z "$(uci -q get firewall.mesh_truba)" ] && mesh_tunnel'
uci del_list truba.main.zone='mesh'; uci commit truba
reload "зона mesh убрана снова"
check "перенаправление владельца не тронуто" test "$(uci -q get firewall.my_mesh.dest)" = truba
uci delete firewall.my_mesh; uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1
ip -n vps addr del 1.2.3.5/32 dev lo
ip addr del 2001:db8:100::1/64 dev ul0; ip addr del fd66::1/64 dev ul0
ip -n vps addr del 2001:db8:100::2/64 dev ul1; ip -n vps addr del fd66::2/64 dev ul1
for p in $(ip netns pids meshhost); do kill "$p"; done
ip netns del meshhost
ip rule del priority 5210; ip rule del priority 5270; ip route flush table 52
uci -q batch <<-'EOF'
	delete firewall.mesh
	delete firewall.mesh_wan
	delete firewall.lan_mesh
	del_list firewall.@zone[1].device='ul0'
	commit firewall
EOF
/etc/init.d/firewall reload >/dev/null 2>&1

section "события интерфейсов (hotplug)"
hotplug() { ACTION="$1" INTERFACE="$2" DEVICE="${3:-}" sh /etc/hotplug.d/iface/50-truba; }
rp() { sysctl -n net.ipv4.conf.awg0.rp_filter; }
sysctl -qw net.ipv4.conf.awg0.rp_filter=1
hotplug ifup awg0 awg0
check "подъём Туннеля: rp_filter его устройства — 0" test "$(rp)" = 0
sysctl -qw net.ipv4.conf.awg0.rp_filter=1
T77="$(ip route show table 77)"
check "падение Туннеля: код 0, rp_filter не тронут, таблица Туннеля пересчитана как была" \
	eval 'hotplug ifdown awg0 && [ "$(rp)" = 1 ] && [ "$(ip route show table 77)" = "$T77" ]'
sysctl -qw net.ipv4.conf.awg0.rp_filter=0
ip link add hp0 type dummy; ip link set hp0 up; ip addr add 10.98.0.1/24 dev hp0
mv /var/run/truba/applied.json /tmp/applied.json
check "служба остановлена (нет applied.json): событие — код 0, наборы не тронуты" eval 'hotplug ifupdate lan && ! in_set local4 10.98.0.0/24'
mv /tmp/applied.json /var/run/truba/applied.json
ip link del hp0

section "DSCP пакетов Туннеля"
# Ядро ставит рукопожатию AF41 — по нему WireGuard и AmneziaWG узнают. Труба обнуляет DSCP всего,
# что Роутер шлёт на IP Трубы: до её цепочки output рукопожатие (148 байт, udp length 156) ещё
# с AF41, у Трубы (netns vps) — уже с 0. Новое рукопожатие — снятием и возвратом пира.
nft -f - <<-'EOF'
	table inet t_dscp {
		counter hs_af41 { }
		chain out {
			type filter hook output priority mangle - 10; policy accept;
			ip daddr 198.51.100.2 udp length 156 ip dscp af41 counter name hs_af41
		}
	}
EOF
ip netns exec vps nft -f - <<-'EOF'
	table inet t_dscp {
		counter hs_zero { }
		counter not_zero { }
		chain in {
			type filter hook prerouting priority raw; policy accept;
			udp dport 51820 udp length 156 ip dscp cs0 counter name hs_zero
			udp dport 51820 ip dscp != cs0 counter name not_zero
		}
	}
EOF
# cnt [vps] СЧЁТЧИК — пакеты счётчика проверочной таблицы на Роутере или у Трубы.
cnt() {
	if [ "$1" = vps ]; then ip netns exec vps nft list counter inet t_dscp "$2"; else nft list counter inet t_dscp "$1"; fi \
		| awk '/packets/ { print $2 }'
}
hs_at_vps() { [ "$(cnt vps hs_zero)" -gt 0 ]; }
VPUB="$(wg show awg0 peers)"
wg set awg0 peer "$VPUB" remove
wg set awg0 peer "$VPUB" endpoint 198.51.100.2:51820 allowed-ips 0.0.0.0/0 persistent-keepalive 5
check "рукопожатие: от ядра — AF41, у Трубы — DSCP 0" eval 'wait_for 10 hs_at_vps && [ "$(cnt hs_af41)" -gt 0 ]'
check "у Трубы ни одного пакета Туннеля с DSCP" test "$(cnt vps not_zero)" = 0
check "Туннель жив после нового рукопожатия" ping -c 2 -W 2 10.77.77.1
nft delete table inet t_dscp; ip netns exec vps nft delete table inet t_dscp

section "учёт трафика устройств"
probe >/dev/null 2>&1
check "входящие: посчитаны в обе стороны" eval 'gt0 c_inbound_down && gt0 c_inbound_up'
check "входящие: устройство — в dv_inbound_down и dv_inbound_up" eval 'in_set dv_inbound_down 192.168.1.50 && in_set dv_inbound_up 192.168.1.50'
IN_DOWN="$(bytes c_inbound_down)"
# 1.2.3.4 нет ни в одной Категории: по Режиму «Всё в туннель» — через Туннель на сервер в netns vps.
ip -n vps addr add 1.2.3.4/32 dev lo
check "устройство → Туннель: ответ пришёл, посчитан в обе стороны" eval 'lan_tcp 1.2.3.4 48081 && gt0 c_tunnel_up && gt0 c_tunnel_down'
check "устройство — в dv_tunnel_up и dv_tunnel_down" eval 'in_set dv_tunnel_up 192.168.1.50 && in_set dv_tunnel_down 192.168.1.50'
# Ответ из Туннеля на исходящее — «Туннель», хотя ct mark он переписывает на «входящее».
check "исходящее через Туннель не считается входящим" test "$(bytes c_inbound_down)" = "$IN_DOWN"
# «Интернет напрямую» стенда — Труба по внешнему адресу через ul0; на время — в зоне wan.
uci add_list firewall.@zone[1].device='ul0'; uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1
TUN_UP="$(bytes c_tunnel_up)"
check "устройство → напрямую: ответ пришёл, посчитан в обе стороны" eval 'lan_tcp 198.51.100.2 48081 && gt0 c_direct_up && gt0 c_direct_down'
check "устройство — в dv_direct_up и dv_direct_down" eval 'in_set dv_direct_up 192.168.1.50 && in_set dv_direct_down 192.168.1.50'
check "напрямую не считается Туннелем" test "$(bytes c_tunnel_up)" = "$TUN_UP"
uci del_list firewall.@zone[1].device='ul0'; uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1
check "status: трафик Туннеля — из счётчика" test "$(truba status | jsonfilter -e '@.traffic.tunnel.up')" = "$(bytes c_tunnel_up)"

section "набор устройств полон"
# 1024 чужих адреса: новый элемент в набор не помещается, и update прерывает правило (ADR 0018).
# Счётчик Действия стоит раньше update, а правила взаимоисключающие: учёт не врёт.
nft flush set inet truba dv_tunnel_up
nft add element inet truba dv_tunnel_up "{ $(seq 0 1023 | awk '{ printf "%s10.200.%d.%d", (NR > 1 ? "," : ""), int($1 / 256), $1 % 256 }') }"
TU="$(bytes c_tunnel_up)"; IU="$(bytes c_inbound_up)"
lan_tcp 1.2.3.4 48081 >/dev/null 2>&1
check "набор полон: устройства в нём нет, Туннель посчитан, входящие — нет" \
	eval '! in_set dv_tunnel_up 192.168.1.50 && [ "$(bytes c_tunnel_up)" -gt "$TU" ] && [ "$(bytes c_inbound_up)" = "$IU" ]'
nft flush set inet truba dv_tunnel_up
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
check "минимальная таблица: без classify, INBOUND на месте" eval '! nft list chain inet truba classify && nft list chain inet truba prerouting | grep -q 0x04000000'
check "dnsmasq восстановлен, бэкап удалён, mosdns остановлен, cron снят" eval '! uci -q get dhcp.@dnsmasq[0].server | grep -q 5335 && [ ! -f /etc/truba/state/dnsmasq.json ] && ! pidof mosdns && ! grep -q "truba update-lists" /etc/crontabs/root'
check "ip rule остаются (ответы на входящие)" eval 'ip rule show | grep -q "lookup 77"'
check "ответ на входящее уходит обратно в Туннель (Маршрутизация выкл)" probe
foreign_checks "Маршрутизация выкл"

section "Режим «Выборочный»"
uci set truba.main.routing='1'; uci commit truba; reload "Маршрутизация вкл"
nft add element inet truba gs_direct4 '{ 198.51.100.7 }'
uci set truba.main.mode='selective'; uci commit truba; reload "Режим «Выборочный»"
check "смена Режима сбрасывает IP из DNS" eval '! in_set gs_direct4 198.51.100.7'
check "«Выборочный»: по умолчанию — Напрямую" test "$(mode_mark)" = 0x02000000
check "truba check 8.8.8.8 → Напрямую по Режиму" eval 'truba check 8.8.8.8 | grep -q "\"reason\": \"mode\""'

section "teardown"
/etc/init.d/truba stop
check "таблица, ip rule и table 77 сняты" eval '! nft list table inet truba && ! ip rule show | grep -q "lookup 77" && [ -z "$(ip route show table 77)" ]'
check "без Трубы ответ на входящее уходит мимо Туннеля" eval '! probe'
check "остановка службы правило IPv6 зоны lan не снимает" no6_chain lan

section "uninstall"
# Перенаправление в truba, которое владелец завёл сам (секция без имени), удаляется вместе с зоной.
uci -q batch >/dev/null <<-'EOF'
	add firewall forwarding
	set firewall.@forwarding[-1].src='wan'
	set firewall.@forwarding[-1].dest='truba'
	commit firewall
EOF
sh /usr/share/truba/uninstall.sh
check "зона truba и перенаправления в неё удалены, аппаратное ускорение возвращено" eval '[ -z "$(uci -q get firewall.truba)" ] && ! uci -q show firewall | grep -q "dest=.truba.$" && [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1 ]'
check "правила IPv6 зон удалены" eval '! uci -q show firewall | grep -q "_truba_no_ipv6=" && ! no6_chain lan'
check "данные службы удалены: Наборы правил, копия правил, распакованные списки" eval '[ ! -e /etc/truba/lists ] && [ ! -e /etc/truba/state ] && [ ! -e /etc/truba/good ] && [ ! -e /var/lib/truba ]'
check "rc.local: строки переустановки нет, exit 0 на месте" eval '! grep -qF /etc/truba/reinstall.sh /etc/rc.local && grep -qx "exit 0" /etc/rc.local'

finish
