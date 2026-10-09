#!/bin/sh
# Стенд Роутера для частей tests/router/*.sh — контейнер ImmortalWrt под настоящим procd/netifd/fw4.
# Подключается первой строкой части: . /repo/tests/router/stand.sh
#   /repo — корень репозитория, /dat — geoip.dat и geosite.dat.
# Сеть стенда:
#   netns «vps»     — Труба: Туннель — настоящий WireGuard (модуля amneziawg в ядре контейнера нет):
#                     ядро шифрует пакеты и шлёт внешние своим UDP-сокетом, как AmneziaWG;
#                     клиенты из интернета приходят с 203.0.113.77;
#   ul0 ↔ ul1       — «интернет» между Роутером и Трубой (198.51.100.0/30, Труба — .2);
#   netns «lanhost» — устройство домашней сети 192.168.1.50 за br-lan.
# После стенда служба truba запущена, контроль Туннеля выключен.

. /repo/tests/lib/check.sh

section "стенд"
for p in mosdns ucode-mod-socket curl ip-full wireguard-tools; do
	apk list -I "$p" 2>/dev/null | grep -q "^$p-" || { echo "нет пакета $p в образе"; exit 1; }
done

# Файлы пакета. С каталога Windows они приходят с правами 777, а такие плагины rpcd не загружает.
cp -a /repo/router/truba/files/. /
chmod 0755 /usr/sbin/truba /etc/init.d/truba /etc/truba/reinstall.sh /usr/share/truba/uninstall.sh /etc/uci-defaults/90-truba
chmod 0644 /usr/share/rpcd/ucode/truba-api.uc /usr/share/ucode/truba/*.uc
# «awg show» выводит то же, что «wg show»: без обёртки watchdog не видит handshake.
printf '#!/bin/sh\nexec wg "$@"\n' > /usr/bin/awg; chmod +x /usr/bin/awg
mkdir -p /etc/truba/lists
for f in geoip.dat geosite.dat; do
	cp "/dat/$f" /etc/truba/lists/
	(cd /etc/truba/lists && sha256sum "$f" > "$f.sha256sum")
done

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
# (контейнер наследует его от хоста) отбрасывает клиентов из интернета ещё на входе.
# Ответы мимо Туннеля уходят сюда и теряются.
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
section "стенд: сеть"
/etc/init.d/network reload
iface_up() { [ "$(ubus call network.interface."$1" status 2>/dev/null | jsonfilter -e '@.up')" = true ]; }
if ! { wait_for 20 iface_up lan && wait_for 20 iface_up awg0; }; then fail "стенд: lan и awg0 не поднялись"; finish; fi

# Программное ускорение до и после установки: пакет его не трогает (проверяет часть net).
uci -q get firewall.@defaults[0].flow_offloading > /tmp/offload.before || true
sh /etc/uci-defaults/90-truba
uci -q get firewall.@defaults[0].flow_offloading > /tmp/offload.after || true
# В ядре Docker нет nf_flow_table: с flowtable fw4 не загружается целиком (без зон).
uci set firewall.@defaults[0].flow_offloading='0'; uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1

section "стенд: служба"
uci set truba.watchdog.enabled='0'; uci commit truba
/etc/init.d/truba enable
check "стенд: служба запустилась" bounded 90 /etc/init.d/truba start
wait_for 15 mosdns_up || fail "стенд: mosdns не слушает $(dns_port)"
# ubus-API пришёл с файлами пакета; rpcd подхватывает его по HUP — как postinst.
killall -HUP rpcd
wait_for 10 ubus list truba || fail "стенд: нет объекта truba в ubus"
[ "$FAILS" -eq 0 ] || finish
