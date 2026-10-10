#!/usr/bin/env bash
# install-vps.sh без настоящего VPS: shellcheck, запись файлов, apt, заголовки ядра, протокол AWG,
# параметры AWG 1.x/2.x/3.1, конфиги обеих сторон и их перезапуск, правила nftables с загрузкой
# в ядро, sysctl, очередь WAN, MTU по сети VPS, DNS для Роутера (unbound), порт SSH.
# Контейнер ubuntu:24.04 с --cap-add NET_ADMIN (tests/run.sh vps).
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
T=$(mktemp -d)   # файлы самих проверок

# Запись файлов: права явные и у нового файла, и у прежнего; глобальный umask не меняется.
umask 022
f="$STATE_DIR/pf.conf"
put_file 600 "$f" <<< a
[ "$FILE_CHANGED" = 1 ] && [ "$(stat -c %a "$f")" = 600 ] && ok "put_file: новый файл с заданными правами" || fail "put_file: новый файл: $FILE_CHANGED $(stat -c %a "$f")"
chmod 644 "$f"; put_file 600 "$f" <<< a
[ "$FILE_CHANGED" = 0 ] && [ "$(stat -c %a "$f")" = 600 ] && ok "put_file: то же содержимое — без изменений, права выправлены" || fail "put_file: то же содержимое: $FILE_CHANGED $(stat -c %a "$f")"
put_file 644 "$f" <<< b
[ "$FILE_CHANGED" = 1 ] && [ "$(cat "$f")" = b ] && [ "$(stat -c %a "$f")" = 644 ] && ok "put_file: новое содержимое" || fail "put_file: новое содержимое"
[ -z "$(find "$STATE_DIR" -name '.pf.conf.*')" ] && ok "put_file: временных файлов не остаётся" || fail "put_file: временные файлы"
[ "$(umask)" = 0022 ] && ok "put_file: umask вызывающего не меняется" || fail "put_file: umask $(umask)"

# apt: занятый apt (cloud-init, автообновления на свежем VPS) ждём, а не падаем.
apt-get() { echo "$*" >> "$T/apt"; }
apt_get install -y x
grep -q -- '-o DPkg::Lock::Timeout=600 install -y x' "$T/apt" && ok "apt_get: ждёт блокировку dpkg" || fail "apt_get: $(cat "$T/apt")"
: > "$T/apt"
apt-get() {
	echo "$*" >> "$T/apt"
	[ "$(wc -l < "$T/apt")" -ge 3 ] && return 0
	echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1 (apt-get)" >&2; return 100
}
sleep() { :; }
out=$(apt_update 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l < "$T/apt")" -eq 3 ] && [ "$(grep -c 'apt занят' <<< "$out")" -eq 1 ] \
	&& ok "apt_update: при занятых списках повторяет и дожидается" || fail "apt_update: rc=$rc вызовов $(wc -l < "$T/apt"): $out"
: > "$T/apt"
apt-get() { echo "$*" >> "$T/apt"; echo "E: The repository 'x' does not have a Release file." >&2; return 100; }
out=$( (apt_update) 2>&1 )
[ "$(wc -l < "$T/apt")" -eq 1 ] && grep -q 'Release file' <<< "$out" && grep -q 'apt-get update не прошёл' <<< "$out" \
	&& ok "apt_update: другая ошибка — сразу выход с текстом apt" || fail "apt_update: другая ошибка: $out"
apt-get() { echo "E: Could not get lock /var/lib/apt/lists/lock." >&2; return 100; }
out=$( (APT_WAIT=30; apt_update) 2>&1 )
grep -q 'apt занят дольше' <<< "$out" && ok "apt_update: ожидание ограничено" || fail "apt_update: без предела: $out"
unset -f apt-get sleep

# Пакеты в архиве: у чисто виртуального имени и у отсутствующего пакета кандидата нет.
apt-cache() { case "$2" in real) printf 'real:\n  Installed: (none)\n  Candidate: 1.0\n' ;; virt) printf 'virt:\n  Installed: (none)\n  Candidate: (none)\n' ;; esac; }
pkg_available real && ! pkg_available virt && ! pkg_available missing && ok "pkg_available: по кандидату apt-cache policy" || fail "pkg_available"
unset -f apt-cache

# Заголовки ядра: метапакеты под метапакеты ядра — иначе DKMS не соберёт amneziawg для ядра,
# которое поставит unattended-upgrades, и после перезагрузки VPS Туннель не поднимется.
dpkg-query() { printf '%s\n' 'ii  linux-image-6.8.0-45-generic' 'ii  linux-image-generic-hwe-24.04' \
	'ii  linux-image-virtual' 'rc  linux-image-azure' 'ii  linux-image-extra-virtual' 'ii  linux-image-unsigned-6.8.0-45-generic'; }
apt-cache() {
	case "$2" in
		linux-headers-generic-hwe-24.04|linux-headers-virtual|linux-headers-azure) printf '%s:\n  Candidate: 1.0\n' "$2" ;;
		*) printf '%s:\n  Candidate: (none)\n' "$2" ;;
	esac
}
got=$(kernel_headers_metas | xargs)
unset -f dpkg-query apt-cache
[ "$got" = "linux-headers-generic-hwe-24.04 linux-headers-virtual" ] && ok "заголовки: метапакеты под установленные метапакеты ядра" || fail "заголовки: «$got»"

# Заголовки работающего ядра: Ubuntu хранит в архиве не все сборки ядра.
uname() { echo 6.8.0-45-generic; }
dpkg-query() { return 1; }
apt-cache() { printf '%s:\n  Candidate: (none)\n' "$2"; }
running_headers >/dev/null; [ $? -eq 1 ] && ok "заголовки ядра: нет в архиве — код 1" || fail "заголовки ядра: нет в архиве"
apt-cache() { printf '%s:\n  Candidate: 6.8.0-45.45\n' "$2"; }
[ "$(running_headers)" = linux-headers-6.8.0-45-generic ] && ok "заголовки ядра: есть в архиве — ставятся" || fail "заголовки ядра: $(running_headers)"
dpkg-query() { printf 'ii '; }
out=$(running_headers); [ $? -eq 0 ] && [ -z "$out" ] && ok "заголовки ядра: уже стоят — ничего не ставится" || fail "заголовки ядра: уже стоят: $out"
unset -f uname dpkg-query apt-cache

# Установка пакетов: PPA до единственного apt-get update, без deb-src, заголовки работающего
# ядра без пометки «вручную»; без заголовков в архиве — выход до установки.
LOG="$T/install"
apt-get() { echo "apt-get $*" >> "$LOG"; }
apt-mark() { echo "apt-mark $*" >> "$LOG"; }
add-apt-repository() { echo "add-apt-repository $*" >> "$LOG"; }
modprobe() { :; }
uname() { echo 6.8.0-146-generic; }
dpkg-query() { case "$*" in *linux-image-*) echo 'ii  linux-image-generic' ;; *) return 1 ;; esac; }
apt-cache() { printf '%s:\n  Candidate: 1\n' "$2"; }
UNBOUND_CONF="$T/unbound/truba.conf"
sources_before=$(cat /etc/apt/sources.list.d/ubuntu.sources)
out=$( (install_packages) 2>&1 ); rc=$?
want="add-apt-repository -y -n ppa:amnezia/ppa
apt-get update -qq
apt-get -o DPkg::Lock::Timeout=600 install -y -qq nftables fail2ban unattended-upgrades curl unbound linux-headers-6.8.0-146-generic linux-headers-generic
apt-mark auto linux-headers-6.8.0-146-generic
apt-get -o DPkg::Lock::Timeout=600 install -y -qq amneziawg"
[ "$rc" -eq 0 ] && [ "$(cat "$LOG")" = "$want" ] && ok "пакеты: PPA, один apt-get update, заголовки ядра и метапакеты, apt-mark auto" \
	|| fail "пакеты: rc=$rc $out"$'\n'"$(cat "$LOG")"
[ "$(cat /etc/apt/sources.list.d/ubuntu.sources)" = "$sources_before" ] && ok "пакеты: источники Ubuntu не меняются (deb-src не нужен)" || fail "пакеты: ubuntu.sources изменён"
[ -f "$UNBOUND_CONF" ] && ok "пакеты: конфиг unbound — до установки пакета" || fail "пакеты: конфиг unbound"
: > "$LOG"
apt-cache() { case "$2" in linux-headers-6.8.0-*) printf '%s:\n  Candidate: (none)\n' "$2" ;; *) printf '%s:\n  Candidate: 1\n' "$2" ;; esac; }
out=$( (install_packages) 2>&1 )
grep -q 'заголовков ядра 6.8.0-146-generic нет в архиве' <<< "$out" && ! grep -q install "$LOG" \
	&& ok "пакеты: заголовков ядра нет в архиве — понятный выход до установки" || fail "пакеты: без заголовков: $out"$'\n'"$(cat "$LOG")"
unset -f apt-get apt-mark add-apt-repository modprobe uname dpkg-query apt-cache

# Протокол AWG по пробному интерфейсу; без модуля — выход, а не молчаливый AWG 1.x.
ip() { [ "$1 $2" != "link add" ]; }
awg_proto_supported >/dev/null; [ $? -ne 0 ] && ok "протокол AWG: интерфейс не создаётся — код ошибки" || fail "протокол AWG: без модуля"
out=$( (detect_awg_proto; echo "дальше: $AWG_PROTO_NOW") 2>&1 )
grep -q 'интерфейс AmneziaWG не создаётся' <<< "$out" && ! grep -q 'дальше' <<< "$out" \
	&& ok "протокол AWG: без модуля — выход до изменений" || fail "протокол AWG: без модуля: $out"
ip() { :; }
awg() { case $1 in genkey) echo a2V5 ;; setconf) return 0 ;; esac; }
p3=$(awg_proto_supported)
awg() { case $1 in genkey) echo a2V5 ;; setconf) ! grep -q HeaderProtectionKey "$3" ;; esac; }
p2=$(awg_proto_supported)
awg() { case $1 in genkey) echo a2V5 ;; setconf) return 1 ;; esac; }
p1=$(awg_proto_supported)
[ "$p3 $p2 $p1" = "3 2 1" ] && ok "протокол AWG: 3.1, 2.0 и 1.x по разбору пробного конфига" || fail "протокол AWG: $p3 $p2 $p1"
unset -f ip awg

# Версия AWG для сверки с router/awg/SOURCES: модуль и сборка PPA.
modinfo() { echo 3.1.20260812; }
dpkg-query() { echo '1.0.0-0~202609061402+4569c4c~ubuntu24.04.1'; }
[ "$(awg_version)" = "3.1.20260812 (сборка PPA 20260906, 4569c4c)" ] && ok "версия AWG: модуль и сборка PPA" || fail "версия AWG: $(awg_version)"
unset -f modinfo dpkg-query

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
if write_nft "22 2222"; then
	grep -q 'tcp dport != { 52222, 22, 2222 } dnat' "$NFT_FILE" && grep -q 'tcp dport { 52222, 22, 2222 } accept' "$NFT_FILE" \
		&& ok "переходный режим: все прежние порты SSH остаются за VPS" || fail "переходный режим: несколько прежних портов"
else
	fail "nft -c: несколько прежних портов"
fi
if write_nft; then ok "nft -c: итоговый режим"; else fail "nft итоговый режим"; fi
grep -q 'tcp dport != 52222 dnat to $RTR' "$NFT_FILE" && ok "итоговый режим: 22 уходит на Роутер" || fail "итоговый режим"
grep -q 'snat to $PUB' "$NFT_FILE" && ok "SNAT от IP VPS" || fail "SNAT"
grep -q 'udp dport 68 return' "$NFT_FILE" && ok "DHCP-клиент VPS не уходит на Роутер" || fail "DHCP"
grep -q 'udp sport 547 udp dport 546 accept' "$NFT_FILE" && ok "ответы DHCPv6 доходят до VPS" || fail "DHCPv6"

# Загрузка правил в ядро и проверка, что они реально стоят.
if nft -f "$NFT_FILE"; then
	nft list chain ip truba_nat prerouting > "$STATE_DIR/chain.txt"
	grep -q 'dnat to 10.77.77.2' "$STATE_DIR/chain.txt" && ok "правила загружены в ядро" || fail "правила в ядре"
	nft delete table ip truba_nat; nft delete table inet truba_filter
else
	fail "nft -f"
fi

# sysctl: без загрузки nf_conntrack при старте systemd-sysctl пропускает ключи conntrack.
SD="$T/sysctl"; mkdir -p "$SD/etc" "$SD/lib"
SYSCTL_DIRS="$SD/etc $SD/lib"; SYSCTL_FILE="$SD/etc/90-truba.conf"; MODULES_FILE="$STATE_DIR/modules-load-truba.conf"
SYS_NET="$T/sys"; mkdir -p "$SYS_NET/eth0/queues/tx-0" "$SYS_NET/eth0/queues/rx-0"
modprobe() { :; }; sysctl() { :; }; tc() { echo "$*" >> "$STATE_DIR/tc.txt"; }
out=$(write_sysctl 2>&1)
grep -q 'nf_conntrack_max = 262144' "$SYSCTL_FILE" && ok "sysctl: nf_conntrack_max" || fail "sysctl nf_conntrack_max"
grep -q 'nf_conntrack_buckets = 262144' "$SYSCTL_FILE" && ok "sysctl: корзин conntrack столько же, сколько записей" || fail "sysctl nf_conntrack_buckets"
grep -qx 'nf_conntrack' "$MODULES_FILE" && ok "nf_conntrack загружается при старте" || fail "modules-load nf_conntrack"
# fq держит на поток 100 пакетов, а Туннель для неё — один поток: на пиках скачивание вставало.
grep -q 'default_qdisc = fq_codel$' "$SYSCTL_FILE" && ok "sysctl: очередь fq_codel, не fq" || fail "sysctl: default_qdisc"
[ "$(cat "$STATE_DIR/tc.txt")" = 'qdisc replace dev eth0 root fq_codel' ] && ok "очередь WAN заменяется сразу, без перезагрузки" || fail "tc: очередь WAN: $(cat "$STATE_DIR/tc.txt")"
[ "$(stat -c %a "$SYSCTL_FILE") $(stat -c %a "$MODULES_FILE")" = "644 644" ] && ok "sysctl и modules-load читаемы всеми" || fail "права sysctl"
[ -z "$out" ] && ok "sysctl: без чужих ключей — без предупреждения" || fail "sysctl: лишнее предупреждение: $out"
# /etc/sysctl.conf (99-sysctl.conf) применяется при загрузке позже 90-truba.conf.
printf '# BBR\nnet.core.default_qdisc=fq\nnet.ipv4.ip_forward=1\n' > "$SD/sysctl.conf"
ln -s ../sysctl.conf "$SD/etc/99-sysctl.conf"
out=$(write_sysctl 2>&1)
grep -q 'перебьют настройки Трубы' <<< "$out" && grep -q "$SD/sysctl.conf: net.core.default_qdisc = fq" <<< "$out" \
	&& ok "sysctl: install предупреждает, что /etc/sysctl.conf перебьёт очередь" || fail "sysctl: предупреждение: $out"
# Карта с несколькими очередями: mq с очередью на каждую, а не один fq_codel на всех.
mkdir -p "$SYS_NET/eth0/queues/tx-1" "$SYS_NET/eth0/queues/tx-2" "$SYS_NET/eth0/queues/tx-3"
: > "$STATE_DIR/tc.txt"; wan_qdisc
[ "$(cat "$STATE_DIR/tc.txt")" = $'qdisc del dev eth0 root\nqdisc replace dev eth0 root mq' ] && ok "очередь WAN: несколько очередей — mq" || fail "очередь WAN mq: $(cat "$STATE_DIR/tc.txt")"
tc() { printf '%s\n' 'qdisc mq 0: root' 'qdisc fq_codel 0: parent :2 limit 10240p' 'qdisc fq_codel 0: parent :1 limit 10240p' 'qdisc ingress ffff: parent ffff:fff1 ----'; }
[ "$(wan_qdisc_show)" = "mq + fq_codel ×2" ] && ok "status: очередь WAN с дочерними" || fail "status очередь: $(wan_qdisc_show)"
unset -f modprobe sysctl tc
SYS_NET=/sys/class/net

# Ключи sysctl, перебиваемые при загрузке: только файлы после нашего, файл с тем же именем —
# из старшего каталога, последнее значение ключа.
printf 'net.core.default_qdisc=fq\n' > "$SD/etc/10-early.conf"                      # раньше нашего
printf 'net/ipv4/tcp_congestion_control = cubic\n' > "$SD/lib/95-x.conf"
printf 'net.netfilter.nf_conntrack_max = 1000\n' > "$SD/lib/97-a.conf"
printf 'net.netfilter.nf_conntrack_max = 262144\n' > "$SD/lib/98-b.conf"           # вернули наше
printf 'net.ipv4.ip_forward = 0\n' > "$SD/lib/99-sysctl.conf"                       # перекрыт /etc
got=$(sysctl_overrides | sort)
want=$(printf '%s\n' "$SD/lib/95-x.conf: net.ipv4.tcp_congestion_control = cubic" "$SD/sysctl.conf: net.core.default_qdisc = fq" | sort)
[ "$got" = "$want" ] && ok "sysctl: перебивающие ключи — по порядку загрузки" || fail "sysctl_overrides:"$'\n'"$got"

# Очередь WAN на настоящем ядре: прежний корень fq_codel (так ставили раньше) и повторный
# запуск дают mq с очередью на каждую из 4.
if ip link add trubaq0 numtxqueues 4 type veth peer name trubaq1 2>/dev/null; then
	ip link set trubaq0 up; ip link set trubaq1 up
	tc qdisc replace dev trubaq0 root fq_codel
	WAN_IF=trubaq0; wan_qdisc; wan_qdisc
	got=$(tc qdisc show dev trubaq0)
	[ "$(awk '$4 == "root" {print $2}' <<< "$got")" = mq ] && [ "$(grep -c parent <<< "$got")" -eq 4 ] \
		&& ok "очередь WAN в ядре: mq и 4 дочерние, повторно — так же" || fail "очередь WAN в ядре:"$'\n'"$got"
	ip link del trubaq0; WAN_IF=eth0
else
	fail "veth с 4 очередями"
fi

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
	# С одним NET_ADMIN модуль dummy не загрузить; его загружают стенды Роутера (tests/run.sh).
	echo "skip  MTU по сети VPS: нет модуля dummy на хосте"
fi
WAN_IF=nonexistent0; write_router_conf
grep -qx "MTU = 1380" "$ROUTER_CONF" && ok "интерфейса нет: MTU 1380" || fail "нет интерфейса: $(grep '^MTU' "$ROUTER_CONF")"
WAN_IF=eth0; write_awg_conf; write_router_conf
[ "$(grep -c '^S[1-4] = ' "$ROUTER_CONF")" -eq 4 ] && ok "Роутер: S1–S4" || fail "S1-S4"
diff <(grep -E '^(S[1-4]|H[1-4]) = ' "$AWG_CONF") <(grep -E '^(S[1-4]|H[1-4]) = ' "$ROUTER_CONF") >/dev/null \
	&& ok "S1–S4 и H1–H4 совпадают у сторон" || fail "S/H различаются"
[ "$(stat -c %a "$ROUTER_CONF") $(stat -c %a "$AWG_CONF") $(stat -c %a "$AWG_DIR") $(stat -c %a "$OUT_DIR")" = "600 600 700 700" ] \
	&& ok "router.conf, awg0.conf и их каталоги доступны только root" || fail "права конфигов AWG"
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
STATE="$STATE_DIR/pipe.env"; save_state
( unset HPK RANDOM_TRAILERS; load_state; [ "$HPK" = 'aHBrLXRlc3Qta2V5LTMyLWJ5dGVzLWxvbmctLS0tLS0=' ] && [ "$RANDOM_TRAILERS" = 1 ] ) \
	&& ok "pipe.env хранит HeaderProtectionKey и RandomTrailers" || fail "pipe.env: HPK/RandomTrailers"
[ "$(stat -c %a "$STATE") $(stat -c %a "$STATE_DIR")" = "600 700" ] && ok "pipe.env и его каталог доступны только root" || fail "права pipe.env"
[ "$(umask)" = 0022 ] && ok "запись ключей не меняет umask: юниты и конфиги остаются читаемыми" || fail "umask после записи ключей: $(umask)"

# Повторный install: Туннель перезапускается, только если его конфиг изменился, а о новом
# router.conf (адрес, порт, MTU) install предупреждает.
write_awg_conf; write_router_conf
[ "$AWG_CONF_CHANGED $ROUTER_CONF_NEW" = "0 0" ] && ok "повторная запись конфигов AWG без изменений" || fail "повторная запись: $AWG_CONF_CHANGED $ROUTER_CONF_NEW"
AWG_PORT=51821; write_awg_conf; write_router_conf
[ "$AWG_CONF_CHANGED $ROUTER_CONF_NEW" = "1 1" ] && ok "смена порта Туннеля: конфиг изменился, router.conf — заново" || fail "смена порта: $AWG_CONF_CHANGED $ROUTER_CONF_NEW"
rm -f "$ROUTER_CONF"; write_router_conf
[ "$ROUTER_CONF_NEW" = 0 ] && ok "первый router.conf — без предупреждения о новом" || fail "первый router.conf: $ROUTER_CONF_NEW"
AWG_PORT=51820
systemctl() { echo "$*" >> "$T/sysd"; case $1 in is-active) [ "${ACTIVE:-1}" = 1 ] ;; *) return 0 ;; esac; }
: > "$T/sysd"; AWG_CONF_CHANGED=0; setup_awg_service
! grep -q '^restart' "$T/sysd" && ok "Туннель: конфиг тот же — без перезапуска" || fail "Туннель перезапущен зря: $(cat "$T/sysd")"
: > "$T/sysd"; AWG_CONF_CHANGED=1; setup_awg_service
grep -qx 'restart awg-quick@awg0' "$T/sysd" && ok "Туннель: конфиг изменился — перезапуск" || fail "Туннель: без перезапуска: $(cat "$T/sysd")"
: > "$T/sysd"; AWG_CONF_CHANGED=0; ACTIVE=0 setup_awg_service
grep -qx 'restart awg-quick@awg0' "$T/sysd" && ok "Туннель: не работает — перезапуск" || fail "Туннель не поднят: $(cat "$T/sysd")"
# Юнит пишется с правами 644, даже если прежний был 600.
PIPE_UNIT="$STATE_DIR/truba-pipe.service"; touch "$PIPE_UNIT"; chmod 600 "$PIPE_UNIT"
write_pipe_unit; [ "$(stat -c %a "$PIPE_UNIT")" = 644 ] && ok "юнит truba-pipe читаем всеми" || fail "права юнита: $(stat -c %a "$PIPE_UNIT")"
# SSH: сокет systemd перезапускается, только если он включён.
: > "$T/sysd"
systemctl() { echo "$*" >> "$T/sysd"; [ "$1" != is-enabled ]; }
ssh_restart
! grep -q 'restart ssh.socket' "$T/sysd" && grep -q 'restart ssh.service' "$T/sysd" && ok "SSH: выключенный сокет не запускается" || fail "SSH: сокет: $(cat "$T/sysd")"
: > "$T/sysd"
systemctl() { echo "$*" >> "$T/sysd"; }
ssh_restart
grep -q 'restart ssh.socket' "$T/sysd" && ok "SSH: включённый сокет перезапускается" || fail "SSH: включённый сокет: $(cat "$T/sysd")"
unset -f systemctl

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
[ "$p" -ge 40000 ] && [ "$p" -le 59999 ] && [ "$c" = 0 ] && [ "$f" = - ] && ok "SSH: первая установка — случайный порт" \
	|| fail "SSH: первая установка: $p $c $f"
SSH_PORT=51022 SSH_CONFIRMED=0 SSH_FALLBACK=50022; save_state
( unset SSH_FALLBACK; load_state; [ "$SSH_FALLBACK" = 50022 ] ) && ok "pipe.env хранит запасной порт SSH" || fail "pipe.env: SSH_FALLBACK"
unset OPT_SSH_PORT
# Запасные порты при первой установке — те, что sshd слушает сейчас, а не всегда 22.
sshd() { printf '%s\n' 'port 2222' 'port 52222' 'port 2222' 'addressfamily any'; }
[ "$(sshd_ports 52222)" = 2222 ] && [ "$(sshd_ports)" = "2222 52222" ] && ok "SSH: запасные — текущие порты sshd без нового" || fail "SSH: порты sshd: «$(sshd_ports 52222)»"
sshd() { echo 'port 52222'; }
[ -z "$(sshd_ports 52222)" ] && ok "SSH: sshd уже слушает только новый порт — запасных нет" || fail "SSH: только новый: «$(sshd_ports 52222)»"
sshd() { return 255; }
[ "$(sshd_ports)" = 22 ] && [ -z "$(sshd_ports 22)" ] && ok "SSH: sshd -T не ответил — запасной 22" || fail "SSH: без sshd -T: «$(sshd_ports)»"
unset -f sshd
# Без терминала — понятная ошибка, а не мгновенный откат: право чтения у /dev/tty есть всегда.
out=$( (NO_CONFIRM=0 SSH_PORT=52222 PUB_IP=203.0.113.10 confirm_ssh 22) 2>&1 </dev/null )
grep -q 'нужен интерактивный терминал' <<< "$out" && ok "SSH: без терминала — ошибка до вопроса" || fail "SSH: без терминала: $out"

# Ключ root проверяется до установки пакетов: без него install выходит сразу.
out=$( (
	STATE="$T/none.env"
	systemd-detect-virt() { return 1; }
	have_key_login() { return 1; }
	install_packages() { echo "ПАКЕТЫ"; }
	cmd_install
) 2>&1 )
grep -q 'нет ключа' <<< "$out" && ! grep -q 'ПАКЕТЫ' <<< "$out" && ok "install: ключ root — до пакетов" || fail "install: ключ root: $out"

# Команды требуют root с понятным сообщением, в том числе status и show-config.
for c in cmd_status cmd_show_config cmd_rotate_keys cmd_uninstall; do
	out=$( (id() { echo 1000; }; "$c") 2>&1 )
	grep -q 'запустите от root' <<< "$out" || fail "$c без root: $out"
done
ok "команды без root — «запустите от root»"

# Упавшая команда без своего сообщения: строка и команда — один раз, и из подоболочки тоже.
cat > "$T/err.sh" <<'EOF'
source "$1"
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
f() { local x; x=$(false); }
f
echo "после ошибки"
EOF
out=$(bash "$T/err.sh" "$SCRIPT" 2>&1)
[ "$(grep -c 'Ошибка' <<< "$out")" -eq 1 ] && grep -q 'строка [0-9]*: x=$(false) (код 1)' <<< "$out" && ! grep -q 'после ошибки' <<< "$out" \
	&& ok "ошибка без сообщения: строка и команда, один раз" || fail "ошибка без сообщения: $out"

# DNS для Роутера (ADR 0013): unbound на адресе Трубы в Туннеле отвечает только Роутеру,
# стартует раньше Туннеля и наружу не слушает. Конфиг — в каталоге пакета, вместе с его
# собственными файлами; пересылка по TLS проверяется по конфигу: интернет проверкам не нужен.
if apt-get install -y -qq unbound bind9-dnsutils ca-certificates >/dev/null 2>&1; then
	UNBOUND_CONF=/etc/unbound/unbound.conf.d/truba.conf
	write_unbound_conf
	# Ключ корневой зоны пакет кладёт при запуске службы (ExecStartPre) — так же и здесь.
	/usr/libexec/unbound-helper root_trust_anchor_update >/dev/null 2>&1
	if out=$(unbound-checkconf 2>&1); then ok "unbound: конфиг вместе с файлами пакета проходит проверку"; else fail "unbound-checkconf: $out"; fi
	[ "$(stat -c %a "$UNBOUND_CONF")" = 644 ] && ok "unbound: конфиг читаем службой" || fail "unbound: права конфига"
	grep -qx '    forward-tls-upstream: yes' "$UNBOUND_CONF" && [ "$(grep -cE '^    forward-addr: [0-9.]+@853#(cloudflare-dns\.com|dns\.google)$' "$UNBOUND_CONF")" -eq 4 ] \
		&& ok "unbound: к Cloudflare и Google — только по TLS, с проверкой имени сервера" || fail "unbound: пересылка по TLS"
	# Адреса Туннеля ещё нет: awg0 поднимается позже, а unbound всё равно стартует.
	unbound -d >"$STATE_DIR/unbound.log" 2>&1 & UB=$!
	listening() { ss -Hlnu '( sport = :53 )' | grep -q '10.77.77.1:53'; }
	for _ in $(seq 20); do listening && break; sleep 0.5; done
	kill -0 "$UB" 2>/dev/null && listening && ok "unbound: стартует до Туннеля (ip-freebind)" || fail "unbound: старт без адреса Туннеля: $(tail -3 "$STATE_DIR/unbound.log")"
	[ "$(ss -Hlnu '( sport = :53 )' | grep -v '127.0.0.5[34]' | awk '{print $4}' | xargs)" = 10.77.77.1:53 ] \
		&& ok "unbound: слушает только адрес Трубы в Туннеле" || fail "unbound слушает: $(ss -Hlnu '( sport = :53 )' | awk '{print $4}' | xargs)"
	ip addr add 10.77.77.1/32 dev lo; ip addr add 10.77.77.2/32 dev lo; ip addr add 10.77.77.3/32 dev lo
	ask() { dig +time=2 +tries=1 @10.77.77.1 -b "$1" localhost A; }
	ask 10.77.77.2 | grep -qE '^localhost\.[[:space:]].*A[[:space:]]+127\.0\.0\.1$' && ok "unbound: отвечает Роутеру" || fail "unbound: Роутеру: $(ask 10.77.77.2 | grep -E 'status|^localhost')"
	# Сам VPS (127.0.0.0/8) unbound обслуживает по умолчанию; из сети Туннеля — только Роутер.
	ask 10.77.77.3 | grep -q 'status: REFUSED' && ok "unbound: другим адресам — отказ" || fail "unbound: другим адресам: $(ask 10.77.77.3 | grep status)"
	kill "$UB" 2>/dev/null; for a in 1 2 3; do ip addr del 10.77.77.$a/32 dev lo; done
else
	fail "apt-get install unbound"
fi

# Параметры: порт без значения или не число — понятная ошибка до любых изменений, а не
# «unbound variable» и не отказ nftables посреди установки.
arg_err() { ( main install "$@" ) 2>&1 >/dev/null; }
case "$(arg_err --ssh-port)" in *"укажите номер порта"*) ok "параметры: порт без значения";; *) fail "параметры: порт без значения: $(arg_err --ssh-port)";; esac
case "$(arg_err --awg-port 70000)" in *"неверный номер порта"*) ok "параметры: порт вне 1–65535";; *) fail "параметры: порт вне 1–65535: $(arg_err --awg-port 70000)";; esac
case "$(arg_err --ssh-port 22x)" in *"неверный номер порта"*) ok "параметры: порт не число";; *) fail "параметры: порт не число: $(arg_err --ssh-port 22x)";; esac

echo
[ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"
exit "$FAILS"
