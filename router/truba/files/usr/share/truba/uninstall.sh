#!/bin/sh
# Откат всего, что пакет truba поменял в системе (вызывается при удалении пакета).

# Пути и имя зоны — у службы (ADR 0015); пакет ещё на месте. Без них откатывать вслепую нельзя.
eval "$(/usr/sbin/truba env)"
[ -n "$TRUBA_FW_ZONE" ] && [ -n "$TRUBA_REINSTALL" ] || exit 1
ZONE="$TRUBA_FW_ZONE"

"$TRUBA_INIT" stop >/dev/null 2>&1
"$TRUBA_INIT" disable >/dev/null 2>&1

ORIG="$TRUBA_STATE_DIR/firewall.orig"
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

uci -q delete "firewall.$ZONE"
# Перенаправления в зону Туннеля — и свои (<зона>_truba), и заведённые владельцем: зоны больше нет.
# -X — настоящие имена секций: номера @forwarding[N] сдвигаются после каждого удаления.
for s in $(uci -q -X show firewall | sed -n "s/^firewall\.\([^.]*\)\.dest='$ZONE'\$/\1/p"); do
	[ "$(uci -q get "firewall.$s")" = forwarding ] && uci -q delete "firewall.$s"
done
uci -q delete firewall.truba_no_ipv6_inet
uci -q commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1

if [ -f /etc/rc.local ]; then
	grep -vF "$TRUBA_REINSTALL" /etc/rc.local > /tmp/rc.local.truba && cat /tmp/rc.local.truba > /etc/rc.local
	rm -f /tmp/rc.local.truba
fi

# Данные службы: Наборы правил с предыдущими версиями и последняя удачная копия правил на
# флеше, распакованные списки и итоги проверок в памяти.
rm -rf "$TRUBA_LISTS_DIR" "$TRUBA_STATE_DIR" "$TRUBA_GOOD_DIR" \
	"$TRUBA_DATA_DIR" "$TRUBA_RUN_DIR" "$TRUBA_ETC_DIR" "$TRUBA_DL_DIR"

exit 0
