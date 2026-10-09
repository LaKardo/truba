#!/bin/sh
# Живой стенд LuCI для проверки интерфейса (внутри контейнера ImmortalWrt с procd).
# Туннель — dummy-интерфейс, Наборы правил — из /dat. Не для продакшена.
set -e

cp -a /repo/router/truba/files/. /
cp -a /repo/router/luci-app-truba/htdocs/. /www/
cp -a /repo/router/luci-app-truba/root/. /
chmod +x /usr/sbin/truba /etc/init.d/truba /etc/truba/reinstall.sh /usr/share/truba/uninstall.sh
# С примонтированного каталога Windows файлы приходят с правами 777; rpcd такие скрипты игнорирует.
chmod 0644 /usr/share/rpcd/ucode/truba-api.uc /usr/share/rpcd/acl.d/luci-app-truba.json

mkdir -p /etc/truba/lists
for f in geoip.dat geosite.dat; do
	cp "/dat/$f" /etc/truba/lists/
	sha256sum "/etc/truba/lists/$f" | awk -v f="$f" '{print $1"  "f}' > "/etc/truba/lists/$f.sha256sum"
done

ip link add lan0 type dummy 2>/dev/null || true
ip link add awg0 type dummy 2>/dev/null || true
ip link set awg0 up

# Адрес, по которому браузер ходит на стенд (сеть Docker). wan стенда — eth0 с DHCP: netifd
# снимает адрес Docker уже при загрузке, а межсетевой экран закрывает wan. Тот же адрес —
# статикой в wan, и порт 80 из wan открыт (только стенд). Адрес и шлюз передаёт tests/run.sh
# из docker inspect (STAND_ADDR=172.17.0.2/16, STAND_GW=172.17.0.1); без них — что на eth0 сейчас.
ETH0="${STAND_ADDR:-$(ip -4 -o addr show dev eth0 | awk '{print $4; exit}')}"
GW="${STAND_GW:-$(ip -4 route show default | awk '{print $3; exit}')}"
if [ -n "$ETH0" ]; then
	uci -q batch <<-EOF
		set network.wan.proto='static'
		set network.wan.ipaddr='$ETH0'
		set network.wan.gateway='$GW'
		delete network.wan6
		set firewall.truba_test_http=rule
		set firewall.truba_test_http.name='Test stand: LuCI from Docker'
		set firewall.truba_test_http.src='wan'
		set firewall.truba_test_http.proto='tcp'
		set firewall.truba_test_http.dest_port='80'
		set firewall.truba_test_http.target='ACCEPT'
		# В ядре Docker нет nf_flow_table: с flowtable fw4 не перезагружается, и правило выше не встало бы.
		set firewall.@defaults[0].flow_offloading='0'
		commit firewall
	EOF
fi

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
	set network.@amneziawg_awg0[-1].endpoint_host='203.0.113.10'
	set network.@amneziawg_awg0[-1].endpoint_port='51820'
	set network.@amneziawg_awg0[-1].public_key='demo'
	commit network
EOF
/etc/init.d/network reload
sleep 3

sh /etc/uci-defaults/90-truba
sh /etc/uci-defaults/luci-truba
uci set truba.watchdog.enabled='0'; uci commit truba
/etc/init.d/firewall reload >/dev/null 2>&1 || true
/etc/init.d/rpcd restart
/etc/init.d/truba enable
/etc/init.d/truba start
sleep 3
ubus list truba && echo "rpcd: объект truba на месте"
