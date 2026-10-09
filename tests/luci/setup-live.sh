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
