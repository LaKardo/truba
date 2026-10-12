#!/bin/sh
# Живой стенд LuCI для части ui: пакеты truba и luci-app-truba в контейнере ImmortalWrt под procd.
# Туннель — dummy-интерфейс, Наборы правил — из /dat.
set -e
. /repo/tests/lib/check.sh

# Без -a: в CI файлы репозитория принадлежат пользователю раннера, а rpcd выполняет «rc init» только
# для скрипта root:root. cp -R даёт копиям владельца root и не меняет владельца /etc и других каталогов.
cp -R /repo/router/truba/files/. /
cp -R /repo/router/luci-app-truba/htdocs/. /www/
cp -R /repo/router/luci-app-truba/root/. /
chmod 0755 /usr/sbin/truba /etc/init.d/truba /etc/truba/reinstall.sh /usr/share/truba/uninstall.sh
# С каталога Windows файлы приходят с правами 777; rpcd такие плагины и ACL не загружает.
chmod 0644 /usr/share/rpcd/ucode/truba-api.uc /usr/share/rpcd/acl.d/luci-app-truba.json

mkdir -p /etc/truba/lists
for f in geoip.dat geosite.dat; do
	cp "/dat/$f" /etc/truba/lists/
	(cd /etc/truba/lists && sha256sum "$f" > "$f.sha256sum")
done

ip link add lan0 type dummy
ip link add awg0 type dummy
ip link set awg0 up

# Адрес, по которому браузер ходит на стенд (сеть Docker). wan стенда — eth0 с DHCP: netifd снимает
# адрес Docker уже при загрузке, а межсетевой экран закрывает wan. Тот же адрес — статикой в wan,
# и порт 80 из wan открыт (только стенд). Адрес и шлюз передаёт tests/run.sh из docker inspect.
uci -q batch <<-EOF
	set network.wan.proto='static'
	set network.wan.ipaddr='$STAND_ADDR'
	set network.wan.gateway='$STAND_GW'
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
wan_up() { [ "$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.up')" = true ]; }
wait_for 20 wan_up

sh /etc/uci-defaults/90-truba
sh /etc/uci-defaults/luci-truba
uci set truba.watchdog.enabled='0'; uci commit truba
# Argon в образе стенда — для снимков в другой теме; при установке он делает себя темой по умолчанию.
# Проверки идут в Bootstrap, другие темы browser.js включает сам.
uci set luci.main.mediaurlbase='/luci-static/bootstrap'; uci commit luci
/etc/init.d/firewall reload >/dev/null 2>&1 || true
/etc/init.d/rpcd restart
/etc/init.d/truba enable
/etc/init.d/truba start
wait_for 15 ubus call truba status
# Устройства для вкладки «Устройства» (ADR 0018). Клиентов в домашней сети стенда нет, поэтому
# элементы наборов с трафиком добавляются вручную: процесс stats видит новые элементы и пишет их
# в историю. 192.168.1.50 — сосед с MAC (на нём сценарий Политики), 100.64.0.9 — узел mesh-VPN без MAC.
ip neigh replace 192.168.1.50 lladdr 02:11:22:33:44:55 dev br-lan nud permanent
D=/var/run/truba/devices.json
inject() { nft delete element inet truba "$1" "{ $2 }" 2>/dev/null || true; nft add element inet truba "$1" "{ $2 counter packets 10 bytes $3 }"; }
inject dv_tunnel_down 192.168.1.50 600000
inject dv_direct_down 100.64.0.9 300000
dev_seen() { grep -q '"192.168.1.50"' $D && grep -q '"100.64.0.9"' $D; }
wait_for 15 dev_seen
# Первый снимок с элементом мог стать точкой отсчёта (прошлый снимок — до загрузки таблицы): ещё
# порция байт — уже трафик, с ним у устройств есть скорость, сутки и время трафика.
inject dv_tunnel_down 192.168.1.50 1200000
inject dv_direct_down 100.64.0.9 600000
dev_last() { [ -n "$(jsonfilter -i $D -e "@.devices['192.168.1.50'].last")" ] && [ -n "$(jsonfilter -i $D -e "@.devices['100.64.0.9'].last")" ]; }
wait_for 20 dev_last
echo "стенд LuCI готов: $STAND_ADDR"
