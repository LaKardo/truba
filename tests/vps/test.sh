#!/usr/bin/env bash
# Проверки install-vps.sh без настоящего VPS: shellcheck, генерация параметров AWG,
# правила nftables (nft -c). Запуск в контейнере ubuntu:24.04 с --cap-add NET_ADMIN.
set -uo pipefail

FAILS=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }

SCRIPT=${1:-/repo/vps/install-vps.sh}

export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
apt-get update -qq >/dev/null && apt-get install -y -qq shellcheck nftables iproute2 >/dev/null

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

# AWG 3.1: защите заголовков нужны S1–S4 не меньше 12.
AWG_PROTO=3
bad=0
for i in $(seq 50); do
	gen_params
	for v in S1 S2 S3 S4; do [ "${!v}" -ge 12 ] || { fail "AWG 3: $v < 12 (${!v})"; bad=1; }; done
	[ $((S1 + 56)) -ne "$S2" ] || { fail "AWG 3: S1+56 == S2"; bad=1; }
	[ "$S4" -le 27 ] || { fail "AWG 3: S4 > 27"; bad=1; }
done
[ "$bad" -eq 0 ] && ok "50 наборов параметров AWG 3.1: S1–S4 ≥ 12"

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

# sysctl: без загрузки nf_conntrack при старте systemd-sysctl пропускает nf_conntrack_max.
SYSCTL_FILE="$STATE_DIR/90-truba.conf"; MODULES_FILE="$STATE_DIR/modules-load-truba.conf"
modprobe() { :; }; sysctl() { :; }; tc() { echo "$*" > "$STATE_DIR/tc.txt"; }
write_sysctl
unset -f modprobe sysctl tc
grep -q 'nf_conntrack_max = 262144' "$SYSCTL_FILE" && ok "sysctl: nf_conntrack_max" || fail "sysctl nf_conntrack_max"
grep -qx 'nf_conntrack' "$MODULES_FILE" && ok "nf_conntrack загружается при старте" || fail "modules-load nf_conntrack"
# fq держит на поток 100 пакетов, а Туннель для неё — один поток: на пиках скачивание вставало.
grep -q 'default_qdisc = fq_codel$' "$SYSCTL_FILE" && ok "sysctl: очередь fq_codel, не fq" || fail "sysctl: default_qdisc"
grep -qx 'qdisc replace dev eth0 root fq_codel' "$STATE_DIR/tc.txt" && ok "очередь WAN заменяется сразу, без перезагрузки" || fail "tc: очередь WAN"

# Заголовки ядра: метапакеты под метапакеты ядра — иначе DKMS не соберёт amneziawg для ядра,
# которое поставит unattended-upgrades, и после перезагрузки VPS Туннель не поднимется.
dpkg-query() { printf '%s\n' 'ii  linux-image-6.8.0-45-generic' 'ii  linux-image-generic-hwe-24.04' \
	'ii  linux-image-virtual' 'rc  linux-image-azure' 'ii  linux-image-extra-virtual' 'ii  linux-image-unsigned-6.8.0-45-generic'; }
apt-cache() { case "$2" in linux-headers-generic-hwe-24.04|linux-headers-virtual|linux-headers-azure) return 0 ;; *) return 1 ;; esac; }
got=$(kernel_headers_metas | xargs)
unset -f dpkg-query apt-cache
[ "$got" = "linux-headers-generic-hwe-24.04 linux-headers-virtual" ] && ok "заголовки: метапакеты под установленные метапакеты ядра" || fail "заголовки: «$got»"

# Модуль для ядра, которое VPS загрузит после перезагрузки (самое новое в /boot).
BOOT_DIR="$STATE_DIR/boot"; MODULES_DIR="$STATE_DIR/modules"
mkdir -p "$BOOT_DIR" "$MODULES_DIR/6.8.0-45-generic/updates/dkms" "$MODULES_DIR/6.8.0-100-generic"
touch "$BOOT_DIR/vmlinuz-6.8.0-45-generic" "$BOOT_DIR/vmlinuz-6.8.0-100-generic" "$MODULES_DIR/6.8.0-45-generic/updates/dkms/amneziawg.ko.zst"
out=$(kernel_module_check 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'нет для ядра 6.8.0-100-generic' <<< "$out" && ok "новое ядро без модуля — предупреждение" || fail "новое ядро без модуля: $rc $out"
mkdir -p "$MODULES_DIR/6.8.0-100-generic/updates/dkms"; touch "$MODULES_DIR/6.8.0-100-generic/updates/dkms/amneziawg.ko.zst"
kernel_module_check >/dev/null 2>&1 && ok "новое ядро с модулем — без предупреждения" || fail "новое ядро с модулем"

# Конфиги AWG
AWG_PROTO=2; gen_params
VPS_PRIV=vpriv; VPS_PUB=vpub; RTR_PRIV=rpriv; RTR_PUB=rpub; PSK=psk
AWG_DIR="$STATE_DIR/awg"; AWG_CONF="$AWG_DIR/awg0.conf"; OUT_DIR="$STATE_DIR/out"; ROUTER_CONF="$OUT_DIR/router.conf"
write_awg_conf; write_router_conf
grep -q "^AllowedIPs = 10.77.77.2/32" "$AWG_CONF" && ok "VPS: пир — только Роутер" || fail "VPS AllowedIPs"
grep -q "^Endpoint = 203.0.113.10:51820" "$ROUTER_CONF" && ok "Роутер: Endpoint" || fail "Роутер Endpoint"
grep -q "^PersistentKeepalive = 25" "$ROUTER_CONF" && ok "Роутер: keepalive 25" || fail "keepalive"
grep -q "^MTU = 1380" "$ROUTER_CONF" && ok "Роутер: MTU 1380 при сети VPS 1500" || fail "MTU"
# MTU Туннеля — от сети VPS: пакет Туннеля с обёрткой (до 87 байт) помещается в неё целиком.
mtu_both() { grep -qx "MTU = $1" "$AWG_CONF" && grep -qx "MTU = $1" "$ROUTER_CONF"; }
if ip link add trubamtu0 type dummy 2>/dev/null; then
	WAN_IF=trubamtu0
	ip link set trubamtu0 mtu 1400; write_awg_conf; write_router_conf
	mtu_both 1313 && ok "сеть VPS 1400: MTU 1313 у обеих сторон" || fail "сеть 1400: $(grep '^MTU' "$ROUTER_CONF")"
	ip link set trubamtu0 mtu 9000; write_awg_conf; write_router_conf
	mtu_both 1380 && ok "сеть VPS 9000: MTU не больше 1380" || fail "сеть 9000: $(grep '^MTU' "$ROUTER_CONF")"
	ip link del trubamtu0
else
	# С одним NET_ADMIN модуль dummy не загрузить; в tests/run.sh all его загружает тест роутера.
	echo "skip  MTU по сети VPS: нет модуля dummy на хосте"
fi
WAN_IF=nonexistent0; write_router_conf
grep -qx "MTU = 1380" "$ROUTER_CONF" && ok "интерфейса нет: MTU 1380" || fail "нет интерфейса: $(grep '^MTU' "$ROUTER_CONF")"
WAN_IF=eth0; write_awg_conf; write_router_conf
[ "$(grep -c '^S[1-4] = ' "$ROUTER_CONF")" -eq 4 ] && ok "Роутер: S1–S4" || fail "S1-S4"
diff <(grep -E '^(S[1-4]|H[1-4]) = ' "$AWG_CONF") <(grep -E '^(S[1-4]|H[1-4]) = ' "$ROUTER_CONF") >/dev/null \
	&& ok "S1–S4 и H1–H4 совпадают у сторон" || fail "S/H различаются"
[ "$(stat -c %a "$ROUTER_CONF")" = 600 ] && ok "router.conf доступен только root" || fail "права router.conf"
! grep -qE '^(HeaderProtectionKey|DisableCookies|RandomTrailers)' "$AWG_CONF" "$ROUTER_CONF" \
	&& ok "AWG 2.0: без параметров 3.1" || fail "AWG 2.0: лишние параметры 3.1"

# Конфиги AWG 3.1: ключ защиты заголовков одинаковый, DisableCookies у обеих сторон,
# RandomTrailers — только по команде random-trailers.
AWG_PROTO=3; gen_params; HPK='aHBrLXRlc3Qta2V5LTMyLWJ5dGVzLWxvbmctLS0tLS0='; RANDOM_TRAILERS=0
write_awg_conf; write_router_conf
bad=0
for f in "$AWG_CONF" "$ROUTER_CONF"; do
	grep -qx "HeaderProtectionKey = $HPK" "$f" && grep -qx 'DisableCookies = on' "$f" && ! grep -q '^RandomTrailers' "$f" \
		|| { fail "AWG 3.1: $(basename "$f")"; bad=1; }
done
[ "$bad" -eq 0 ] && ok "AWG 3.1: HeaderProtectionKey и DisableCookies у обеих сторон, RandomTrailers выкл"
RANDOM_TRAILERS=1; write_awg_conf; write_router_conf
grep -qx 'RandomTrailers = on' "$AWG_CONF" && grep -qx 'RandomTrailers = on' "$ROUTER_CONF" \
	&& ok "AWG 3.1: RandomTrailers у обеих сторон" || fail "AWG 3.1: RandomTrailers"
STATE="$STATE_DIR/pipe.env"; AWG_VERSION=test; save_state
( unset HPK RANDOM_TRAILERS; load_state; [ "$HPK" = 'aHBrLXRlc3Qta2V5LTMyLWJ5dGVzLWxvbmctLS0tLS0=' ] && [ "$RANDOM_TRAILERS" = 1 ] ) \
	&& ok "pipe.env хранит HeaderProtectionKey и RandomTrailers" || fail "pipe.env: HPK/RandomTrailers"

# Порт SSH. Смена порта у подтверждённой установки снова идёт через окно с подтверждением,
# прежний порт — запасной: иначе закрытый у провайдера новый порт оставил бы VPS без входа.
ssh_case() {   # ssh_case SSH_PORT SSH_CONFIRMED SSH_FALLBACK OPT_SSH_PORT → «порт подтверждён запасной»
	SSH_PORT=$1 SSH_CONFIRMED=$2 SSH_FALLBACK=$3 OPT_SSH_PORT=$4
	choose_ssh_port
	echo "$SSH_PORT $SSH_CONFIRMED ${SSH_FALLBACK:--}"
}
[ "$(ssh_case 50022 1 '' 51022)" = "51022 0 50022" ] && ok "SSH: смена порта — снова окно с подтверждением, прежний запасной" \
	|| fail "SSH: смена порта: $(ssh_case 50022 1 '' 51022)"
[ "$(ssh_case 50022 1 '' '')" = "50022 1 -" ] && ok "SSH: повторный install без смены порта — без окна" \
	|| fail "SSH: повторный install: $(ssh_case 50022 1 '' '')"
[ "$(ssh_case 50022 1 '' 50022)" = "50022 1 -" ] && ok "SSH: тот же порт явно — без окна" \
	|| fail "SSH: тот же порт: $(ssh_case 50022 1 '' 50022)"
# Прерванная смена: в pipe.env уже новый порт, не подтверждён, запасной — прежний.
[ "$(ssh_case 51022 0 50022 '')" = "51022 0 50022" ] && ok "SSH: прерванная смена порта — окно с прежним запасным" \
	|| fail "SSH: прерванная смена: $(ssh_case 51022 0 50022 '')"
read -r p c f <<< "$(ssh_case '' 0 '' '')"
[ "$p" -ge 40000 ] && [ "$p" -le 59999 ] && [ "$c" = 0 ] && [ "$f" = - ] && ok "SSH: первая установка — случайный порт, запасной 22" \
	|| fail "SSH: первая установка: $p $c $f"
SSH_PORT=51022 SSH_CONFIRMED=0 SSH_FALLBACK=50022; save_state
( unset SSH_FALLBACK; load_state; [ "$SSH_FALLBACK" = 50022 ] ) && ok "pipe.env хранит запасной порт SSH" || fail "pipe.env: SSH_FALLBACK"
unset OPT_SSH_PORT

echo
[ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"
exit "$FAILS"
