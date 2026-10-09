#!/bin/sh
# Откат всего, что пакет truba поменял в системе (вызывается при удалении пакета).

/etc/init.d/truba stop >/dev/null 2>&1
/etc/init.d/truba disable >/dev/null 2>&1

ORIG=/etc/truba/state/firewall.orig
if [ -f "$ORIG" ]; then
	while IFS='=' read -r k v; do
		case "$k" in
		fullcone|flow_offloading_hw)
			if [ -n "$v" ]; then
				uci -q set "firewall.@defaults[0].$k=$v"
			else
				uci -q delete "firewall.@defaults[0].$k"
			fi
			;;
		esac
	done < "$ORIG"
	rm -f "$ORIG"
fi

uci -q delete firewall.truba
uci -q delete firewall.lan_truba
uci -q delete firewall.truba_no_ipv6_inet
uci -q commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1

[ -f /etc/rc.local ] && sed -i '\#/etc/truba/reinstall.sh#d' /etc/rc.local

# Последняя удачная копия правил (ADR 0006) — производная от настроек, без пакета не нужна.
rm -rf /etc/truba/good

exit 0
