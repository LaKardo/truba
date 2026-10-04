#!/usr/bin/env bash
# Проверки install-vps.sh без настоящего VPS: shellcheck, генерация параметров AWG,
# правила nftables (nft -c). Запуск в контейнере ubuntu:24.04 с --cap-add NET_ADMIN.
set -uo pipefail

FAILS=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }

SCRIPT=${1:-/repo/vps/install-vps.sh}

export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
apt-get update -qq >/dev/null && apt-get install -y -qq shellcheck nftables >/dev/null

if shellcheck -s bash "$SCRIPT"; then ok "shellcheck"; else fail "shellcheck"; fi
if bash -n "$SCRIPT"; then ok "bash -n"; else fail "bash -n"; fi

# shellcheck disable=SC1090
source "$SCRIPT"
set +e

STATE_DIR=$(mktemp -d)
NFT_FILE="$STATE_DIR/pipe.nft"

# Параметры AWG 2.x
AWG_PROTO=2
for i in $(seq 50); do
	gen_params
	[ $((S1 + 56)) -ne "$S2" ] || { fail "S1+56 == S2 ($S1, $S2)"; break; }
	for v in S1 S2; do [ "${!v}" -ge 15 ] && [ "${!v}" -le 150 ] || fail "$v вне 15..150: ${!v}"; done
	[ "$S3" -ge 8 ] && [ "$S3" -le 55 ] || fail "S3 вне 8..55: $S3"
	[ "$S4" -ge 4 ] && [ "$S4" -le 27 ] || fail "S4 вне 4..27: $S4"
	[ "$JMIN" -lt "$JMAX" ] && [ "$JMAX" -le 1280 ] || fail "Jmin/Jmax: $JMIN/$JMAX"
	# Диапазоны H не пересекаются.
	ranges=$(printf '%s\n' "$H1" "$H2" "$H3" "$H4" | tr '-' ' ' | sort -n)
	prev_hi=0
	while read -r lo hi; do
		[ "$lo" -gt "$prev_hi" ] && [ "$hi" -gt "$lo" ] && [ "$hi" -le 2147483647 ] || fail "H пересекаются: $H1 $H2 $H3 $H4"
		prev_hi=$hi
	done <<< "$ranges"
done
ok "50 наборов параметров AWG 2.x в допустимых пределах"

AWG_PROTO=1
gen_params
[ -z "$S3" ] && [ -z "$I1" ] && [[ "$H1" =~ ^[0-9]+$ ]] && ok "параметры AWG 1.x без S3/S4/I1" || fail "параметры AWG 1.x"

# Правила nftables
WAN_IF=eth0; PUB_IP=203.0.113.10; SSH_PORT=52222; AWG_PORT=51820
if write_nft 22; then ok "nft -c: переходный режим (SSH 22 и $SSH_PORT)"; else fail "nft переходный режим"; fi
grep -q 'tcp dport != { 52222, 22 } dnat' "$NFT_FILE" && ok "переходный режим: 22 остаётся за VPS" || fail "переходный режим: 22"
if write_nft; then ok "nft -c: итоговый режим"; else fail "nft итоговый режим"; fi
grep -q 'tcp dport != 52222 dnat to $RTR' "$NFT_FILE" && ok "итоговый режим: 22 уходит на Роутер" || fail "итоговый режим"
grep -q 'snat to $PUB' "$NFT_FILE" && ok "SNAT от IP VPS" || fail "SNAT"
grep -q 'udp dport 68 return' "$NFT_FILE" && ok "DHCP-клиент VPS не уходит на Роутер" || fail "DHCP"

# Загрузка правил в ядро и проверка, что они реально стоят.
if nft -f "$NFT_FILE"; then
	nft list chain ip truba_nat prerouting > "$STATE_DIR/chain.txt"
	grep -q 'dnat to 10.77.77.2' "$STATE_DIR/chain.txt" && ok "правила загружены в ядро" || fail "правила в ядре"
	nft delete table ip truba_nat; nft delete table inet truba_filter
else
	fail "nft -f"
fi

# Конфиги AWG
AWG_PROTO=2; gen_params
VPS_PRIV=vpriv; VPS_PUB=vpub; RTR_PRIV=rpriv; RTR_PUB=rpub; PSK=psk
AWG_DIR="$STATE_DIR/awg"; AWG_CONF="$AWG_DIR/awg0.conf"; OUT_DIR="$STATE_DIR/out"; ROUTER_CONF="$OUT_DIR/router.conf"
write_awg_conf; write_router_conf
grep -q "^AllowedIPs = 10.77.77.2/32" "$AWG_CONF" && ok "VPS: пир — только Роутер" || fail "VPS AllowedIPs"
grep -q "^Endpoint = 203.0.113.10:51820" "$ROUTER_CONF" && ok "Роутер: Endpoint" || fail "Роутер Endpoint"
grep -q "^PersistentKeepalive = 25" "$ROUTER_CONF" && ok "Роутер: keepalive 25" || fail "keepalive"
grep -q "^MTU = 1380" "$ROUTER_CONF" && ok "Роутер: MTU 1380" || fail "MTU"
[ "$(grep -c '^S[1-4] = ' "$ROUTER_CONF")" -eq 4 ] && ok "Роутер: S1–S4" || fail "S1-S4"
diff <(grep -E '^(S[1-4]|H[1-4]) = ' "$AWG_CONF") <(grep -E '^(S[1-4]|H[1-4]) = ' "$ROUTER_CONF") >/dev/null \
	&& ok "S1–S4 и H1–H4 совпадают у сторон" || fail "S/H различаются"
[ "$(stat -c %a "$ROUTER_CONF")" = 600 ] && ok "router.conf доступен только root" || fail "права router.conf"

echo
[ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"
exit "$FAILS"
