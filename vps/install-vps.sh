#!/usr/bin/env bash
# Труба — настройка VPS (Ubuntu 24.04) как «прозрачной трубы» для Роутера.
# Все порты публичного IP, кроме SSH и порта Туннеля, уходят на Роутер (DNAT 1:1),
# исходящий трафик Роутера выходит от IP VPS с сохранением порта (SNAT).
#
#   install-vps.sh install [--ssh-port N] [--awg-port N] [--no-confirm]
#   install-vps.sh show-config
#   install-vps.sh rotate-keys
#   install-vps.sh random-trailers on|off
#   install-vps.sh status
#   install-vps.sh uninstall [--purge]
#
# Повторный запуск install безопасен: ключи и порты берутся из /etc/truba/pipe.env.

set -Eeuo pipefail

STATE_DIR=/etc/truba
STATE="$STATE_DIR/pipe.env"
NFT_FILE="$STATE_DIR/pipe.nft"
AWG_DIR=/etc/amnezia/amneziawg
AWG_IF=awg0
AWG_CONF="$AWG_DIR/$AWG_IF.conf"
OUT_DIR=/root/truba
ROUTER_CONF="$OUT_DIR/router.conf"
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-truba.conf
F2B_JAIL=/etc/fail2ban/jail.d/truba.local
PIPE_UNIT=/etc/systemd/system/truba-pipe.service
SYSCTL_FILE=/etc/sysctl.d/90-truba.conf
# Каталоги sysctl.d по старшинству: из файлов с одинаковым именем systemd-sysctl берёт первый.
SYSCTL_DIRS="/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d"
MODULES_FILE=/etc/modules-load.d/truba.conf
UNBOUND_CONF=/etc/unbound/unbound.conf.d/truba.conf

VPS_TUN=10.77.77.1
RTR_TUN=10.77.77.2
# MTU Туннеля — не больше MTU_MAX и такой, чтобы пакет Туннеля с обёрткой помещался в сеть
# VPS целиком: IPv4 20 + UDP 8 + заголовок и тег AWG 32 + S4 до 27 = 87 байт. Иначе VPS режет
# каждый полноразмерный пакет на два фрагмента: у части провайдеров сеть VPS — 1400, а не 1500.
MTU_MAX=1380
TUN_OVERHEAD=87
CONFIRM_TIMEOUT=120
# Сколько ждать apt, занятый другим процессом (на свежем VPS — cloud-init и автообновления), с.
APT_WAIT=600
BOOT_DIR=/boot
MODULES_DIR=/lib/modules
SYS_NET=/sys/class/net

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

# Место ошибки, если команда упала без своего сообщения (set -e). Только в основном процессе:
# из подоболочки код ошибки и так вернётся вызывающему, и сообщение вышло бы дважды.
on_err() {
	[ "$BASHPID" = "$$" ] || return 0
	printf '\033[1;31mОшибка:\033[0m строка %s: %s (код %s)\n' "$2" "$3" "$1" >&2
}

need_root() { [ "$(id -u)" -eq 0 ] || die "запустите от root"; }

rand_between() { shuf -i "$1-$2" -n 1; }

# Файл целиком из stdin с правами mode — и у нового файла, и у прежнего. Пишется рядом во
# временный файл и подменяет прежний разом. FILE_CHANGED=1, если содержимое стало другим.
# Каталог создаётся, если его нет; каталоги для ключей заранее создаются с правами 700.
put_file() {
	local mode=$1 f=$2 tmp
	mkdir -p "${f%/*}"
	tmp=$(mktemp "${f%/*}/.${f##*/}.XXXXXX")
	cat > "$tmp"
	chmod "$mode" "$tmp"
	if cmp -s "$tmp" "$f"; then
		rm -f "$tmp"
		chmod "$mode" "$f"
		FILE_CHANGED=0
	else
		mv -f "$tmp" "$f"
		FILE_CHANGED=1
	fi
}

# MTU Туннеля по MTU интерфейса WAN: при 1500 — 1380, при 1400 — 1313.
tunnel_mtu() {
	local nic m
	nic=$(cat "$SYS_NET/${WAN_IF:-}/mtu" 2>/dev/null) || nic=1500
	m=$((nic - TUN_OVERHEAD))
	[ "$m" -le "$MTU_MAX" ] || m=$MTU_MAX
	echo "$m"
}

port_busy() { ss -Hlntu "( sport = :$1 )" 2>/dev/null | grep -q .; }

pick_port() {
	local p
	for _ in $(seq 50); do
		p=$(rand_between 40000 59999)
		if ! port_busy "$p" && [ "$p" != "${1:-}" ]; then
			echo "$p"
			return
		fi
	done
	die "не удалось подобрать свободный порт"
}

load_state() {
	# shellcheck disable=SC1090
	[ -f "$STATE" ] && . "$STATE"
	return 0
}

save_state() {
	install -d -m 700 "$STATE_DIR"
	put_file 600 "$STATE" <<-EOF
		WAN_IF='$WAN_IF'
		PUB_IP='$PUB_IP'
		SSH_PORT='$SSH_PORT'
		AWG_PORT='$AWG_PORT'
		AWG_PROTO='$AWG_PROTO'
		VPS_PRIV='$VPS_PRIV'
		VPS_PUB='$VPS_PUB'
		RTR_PRIV='$RTR_PRIV'
		RTR_PUB='$RTR_PUB'
		PSK='$PSK'
		JC='$JC'
		JMIN='$JMIN'
		JMAX='$JMAX'
		S1='$S1'
		S2='$S2'
		S3='$S3'
		S4='$S4'
		H1='$H1'
		H2='$H2'
		H3='$H3'
		H4='$H4'
		I1='$I1'
		HPK='${HPK:-}'
		RANDOM_TRAILERS='${RANDOM_TRAILERS:-0}'
		SSH_CONFIRMED='${SSH_CONFIRMED:-0}'
		SSH_FALLBACK='${SSH_FALLBACK:-}'
	EOF
}

# ---------- apt ----------

apt_get() { apt-get -o DPkg::Lock::Timeout="$APT_WAIT" "$@"; }

# DPkg::Lock::Timeout на блокировку списков пакетов не действует: apt-get update ждём сами.
apt_update() {
	local err i
	for ((i = 0; i < APT_WAIT; i += 10)); do
		if err=$(LC_ALL=C apt-get update -qq 2>&1 >/dev/null); then
			[ -z "$err" ] || printf '%s\n' "$err" >&2
			return 0
		fi
		case $err in
			*"Could not get lock"*)
				[ "$i" -gt 0 ] || say "apt занят другим процессом (cloud-init, автообновления) — жду до $((APT_WAIT / 60)) мин" ;;
			*)
				printf '%s\n' "$err" >&2
				die "apt-get update не прошёл" ;;
		esac
		sleep 10
	done
	die "apt занят дольше $((APT_WAIT / 60)) мин: запустите install позже"
}

# Есть ли пакет в архиве: у чисто виртуального имени кандидата на установку нет.
pkg_available() {
	apt-cache policy "$1" 2>/dev/null | awk '$1 == "Candidate:" { c = $2 } END { exit !(c != "" && c != "(none)") }'
}

pkg_installed() { [ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" = "ii " ]; }

# ---------- проверки ----------

have_key_login() {
	[ -s /root/.ssh/authorized_keys ] && grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys
}

wan_ips() { ip -4 -o addr show dev "$WAN_IF" scope global | awk '{ sub(/\/.*/, "", $4); print $4 }'; }

preflight() {
	# shellcheck disable=SC1091
	. /etc/os-release
	if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != "24.04" ]; then
		die "нужна Ubuntu 24.04 (обнаружено: ${PRETTY_NAME:-?})"
	fi

	if systemd-detect-virt --container -q; then
		die "VPS — контейнер ($(systemd-detect-virt --container)): модуль ядра AmneziaWG в нём не загрузить. Нужна полноценная виртуальная машина (KVM и т.п.)"
	fi

	have_key_login || die "в /root/.ssh/authorized_keys нет ключа: после переноса SSH вход по паролю будет закрыт. Добавьте ключ и запустите снова"

	WAN_IF=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[ -n "$WAN_IF" ] || die "не найден интерфейс маршрута по умолчанию"
	# Внешний IP сообщают сервисы в интернете; в минимальном образе curl может не быть.
	if ! command -v curl >/dev/null; then
		apt_update
		apt_get install -y -qq curl >/dev/null
	fi
	local ext_ip local_ips
	ext_ip=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)
	[ -n "$ext_ip" ] || die "не удалось узнать внешний IP"
	local_ips=$(wan_ips | xargs)
	if [[ " $local_ips " != *" $ext_ip "* ]]; then
		die "публичный IP ($ext_ip) не назначен на $WAN_IF (там: ${local_ips:-нет IPv4}): VPS за NAT провайдера. Схема «труба 1:1» требует IP прямо на интерфейсе"
	fi
	PUB_IP=$ext_ip
}

# ---------- пакеты ----------

# Метапакеты заголовков под метапакеты ядра, что стоят в системе: linux-image-generic →
# linux-headers-generic, linux-image-generic-hwe-24.04 → linux-headers-generic-hwe-24.04 и т.п.
# Одних заголовков текущего ядра (linux-headers-$(uname -r)) мало: unattended-upgrades ставит
# новое ядро, DKMS без его заголовков не собирает amneziawg, и после перезагрузки VPS Туннель
# не поднимается. С метапакетом заголовки нового ядра приходят вместе с ним.
kernel_headers_metas() {
	local p h
	for p in $(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 2>/dev/null \
			| awk '$1 == "ii" && $2 !~ /^linux-image-(unsigned-)?[0-9]/ {print $2}'); do
		h="linux-headers-${p#linux-image-}"
		if pkg_available "$h"; then echo "$h"; fi
	done
}

# Заголовки работающего ядра: по ним DKMS собирает модуль, без которого Туннель не поднять.
# Печатает пакет, если его надо поставить. Код 1 — его нет в архиве: Ubuntu хранит заголовки
# не всех сборок ядра, и у образа на промежуточной сборке их уже не скачать.
running_headers() {
	local h
	h="linux-headers-$(uname -r)"
	pkg_installed "$h" && return 0
	pkg_available "$h" || return 1
	echo "$h"
}

# Есть ли модуль amneziawg у самого нового установленного ядра — его VPS загрузит после
# перезагрузки. Печатает строку для status; без модуля — предупреждение.
kernel_module_check() {
	local k
	k=$(find "$BOOT_DIR" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -1) || true
	[ -n "$k" ] || return 0
	if find "$MODULES_DIR/$k" -name 'amneziawg.ko*' 2>/dev/null | grep -q .; then
		echo "Модуль amneziawg для ядра после перезагрузки ($k): есть"
	else
		warn "модуля amneziawg нет для ядра $k: после перезагрузки VPS Туннель не поднимется. Поставьте linux-headers-$k и выполните dkms autoinstall -k $k"
		return 1
	fi
}

install_packages() {
	say "Установка пакетов"
	export DEBIAN_FRONTEND=noninteractive
	# PPA — до apt-get update, чтобы списки пакетов обновились один раз. add-apt-repository
	# есть почти в любом образе Ubuntu; где его нет, он ставится первым.
	if ! grep -rqs 'amnezia/ppa' /etc/apt/sources.list.d/; then
		if ! command -v add-apt-repository >/dev/null; then
			apt_update
			apt_get install -y -qq software-properties-common >/dev/null
		fi
		add-apt-repository -y -n ppa:amnezia/ppa >/dev/null
	fi
	apt_update
	local hdr metas
	if ! hdr=$(running_headers); then
		die "заголовков ядра $(uname -r) нет в архиве Ubuntu: модуль AmneziaWG под это ядро не собрать. Обновите ядро (apt-get full-upgrade), перезагрузите VPS и запустите install снова"
	fi
	metas=$(kernel_headers_metas)
	[ -n "$metas" ] || warn "не найден метапакет заголовков ядра: после обновления ядра DKMS может не собрать amneziawg — проверяйте install-vps.sh status"
	# Конфиг unbound — до пакета: служба сразу стартует с ним, а не на 127.0.0.1.
	write_unbound_conf
	# shellcheck disable=SC2086 # списки пакетов
	apt_get install -y -qq nftables fail2ban unattended-upgrades curl unbound $hdr $metas >/dev/null
	# Заголовки этого ядра больше не нужны, когда VPS перейдёт на новое: метапакет приносит
	# заголовки новых ядер, а эти пусть убирает apt autoremove (работающее ядро apt не трогает).
	if [ -n "$hdr" ] && [ -n "$metas" ]; then apt-mark auto "$hdr" >/dev/null; fi
	# Модуль собирается DKMS по одним заголовкам ядра: исходники ядра (deb-src) ему не нужны.
	apt_get install -y -qq amneziawg >/dev/null
	modprobe amneziawg || die "модуль amneziawg не загрузился (проверьте dkms status)"

	if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
		warn "ufw включён и мешает правилам nftables Трубы — выключаю"
		ufw disable >/dev/null
	fi
}

# Версия AmneziaWG на Трубе для сверки с router/awg/SOURCES: что сообщает о себе модуль
# (загруженный, иначе установленный) и из какой сборки PPA он пришёл — дата и коммит.
awg_version() {
	# Версия пакета в PPA: 1.0.0-0~<дата и время сборки>+<коммит>~ubuntu24.04.1.
	local mod pkg re='~([0-9]{8})[0-9]*\+([0-9a-f]+)'
	mod=$(cat /sys/module/amneziawg/version 2>/dev/null || modinfo -F version amneziawg 2>/dev/null || true)
	pkg=$(dpkg-query -W -f='${Version}' amneziawg-dkms 2>/dev/null || true)
	if [[ $pkg =~ $re ]]; then
		pkg="сборка PPA ${BASH_REMATCH[1]}, ${BASH_REMATCH[2]}"
	fi
	echo "${mod:-?}${pkg:+ ($pkg)}"
}

# Какой протокол AWG поддерживает модуль: 3 — AWG 3.1 (защита заголовков, DisableCookies,
# RandomTrailers), 2 — AWG 2.0 (S3/S4, диапазоны H, I1), иначе 1.
# Проверяется тем же разбором конфига, что и у настоящего интерфейса. Код 1 — интерфейс
# AmneziaWG не создаётся: модуля нет (например, DKMS не собрал его под новое ядро).
awg_proto_supported() {
	local t=awgprobe$$ proto=1 f base
	ip link add "$t" type amneziawg 2>/dev/null || return 1
	f=$(mktemp)
	base=$(printf '[Interface]\nPrivateKey = %s\nS1 = 20\nS2 = 40\nS3 = 20\nS4 = 20\nH1 = 100-200\nH2 = 300-400\nH3 = 500-600\nH4 = 700-800' \
		"$(awg genkey)")
	printf '%s\n' "$base" > "$f"
	if awg setconf "$t" "$f" 2>/dev/null; then
		proto=2
		printf '%s\nHeaderProtectionKey = %s\nDisableCookies = on\nRandomTrailers = off\n' "$base" "$(awg genkey)" > "$f"
		if awg setconf "$t" "$f" 2>/dev/null; then
			proto=3
		fi
	fi
	ip link del "$t" 2>/dev/null || true
	rm -f "$f"
	echo "$proto"
}

# AWG_PROTO_NOW — протокол, который модуль поддерживает сейчас. Без модуля — выход до любых
# изменений: иначе параметры молча сгенерировались бы под AWG 1.x, а Роутер ждёт 2.0 или 3.1.
detect_awg_proto() {
	AWG_PROTO_NOW=$(awg_proto_supported) \
		|| die "интерфейс AmneziaWG не создаётся: модуля amneziawg нет у ядра $(uname -r). Проверьте dkms status и install-vps.sh status"
}

# ---------- ключи и параметры маскировки ----------

gen_params() {
	JC=$(rand_between 4 8)
	JMIN=$(rand_between 40 80)
	JMAX=$(rand_between 300 900)
	S1=$(rand_between 15 150)
	while :; do S2=$(rand_between 15 150); [ $((S1 + 56)) -ne "$S2" ] && break; done
	if [ "$AWG_PROTO" -ge 2 ]; then
		# Защите заголовков (AWG 3) нужны S1–S4 не меньше 12; S1 и S2 и так от 15.
		local s3min=8 s4min=4
		if [ "$AWG_PROTO" -ge 3 ]; then s3min=12; s4min=12; fi
		S3=$(rand_between "$s3min" 55)
		# S4 удлиняет каждый пакет данных: tunnel_mtu оставляет под него до 27 байт.
		S4=$(rand_between "$s4min" 27)
		# Четыре непересекающихся диапазона: по одному в каждой четверти пространства.
		local q=$((2147483647 / 4)) i lo w
		local hs=()
		for i in 0 1 2 3; do
			w=$(rand_between 100000 5000000)
			lo=$(( i * q + 5 + $(rand_between 0 $((q - w - 10))) ))
			hs+=("$lo-$((lo + w))")
		done
		mapfile -t hs < <(printf '%s\n' "${hs[@]}" | shuf)
		H1=${hs[0]}; H2=${hs[1]}; H3=${hs[2]}; H4=${hs[3]}
		# Пакет-приманка в форме DNS-ответа (I1 не обязан совпадать у сторон).
		I1='<r 2><b 0x858000010001000000000377777706676f6f676c6503636f6d0000010001c00c000100010000012c0004><r 4>'
	else
		S3=''; S4=''; I1=''
		local used=" " h v
		for v in H1 H2 H3 H4; do
			while :; do h=$(rand_between 5 2147483647); [[ "$used" != *" $h "* ]] && break; done
			used+="$h "
			printf -v "$v" '%s' "$h"
		done
	fi
}

gen_keys() {
	VPS_PRIV=$(awg genkey); VPS_PUB=$(printf '%s' "$VPS_PRIV" | awg pubkey)
	RTR_PRIV=$(awg genkey); RTR_PUB=$(printf '%s' "$RTR_PRIV" | awg pubkey)
	PSK=$(awg genpsk)
	# Ключ защиты заголовков (AWG 3): одинаковый у Трубы и Роутера.
	HPK=''
	if [ "$AWG_PROTO" -ge 3 ]; then HPK=$(awg genkey); fi
}

awg_params_block() {
	echo "Jc = $JC"
	echo "Jmin = $JMIN"
	echo "Jmax = $JMAX"
	echo "S1 = $S1"
	echo "S2 = $S2"
	[ -n "${S3:-}" ] && echo "S3 = $S3"
	[ -n "${S4:-}" ] && echo "S4 = $S4"
	echo "H1 = $H1"
	echo "H2 = $H2"
	echo "H3 = $H3"
	echo "H4 = $H4"
	[ -n "${I1:-}" ] && echo "I1 = $I1"
	if [ "${AWG_PROTO:-1}" -ge 3 ]; then
		[ -n "${HPK:-}" ] && echo "HeaderProtectionKey = $HPK"
		# Ответы cookie шлются только под нагрузкой; с одним пиром они не нужны, а их размер узнаваем.
		echo "DisableCookies = on"
		# Запас на случай DPI по размерам пакетов: дорого по трафику, включается отдельной командой.
		[ "${RANDOM_TRAILERS:-0}" = 1 ] && echo "RandomTrailers = on"
	fi
	return 0
}

awg_conf() {
	echo "# Труба: Туннель к Роутеру. Сгенерировано install-vps.sh"
	echo "[Interface]"
	echo "PrivateKey = $VPS_PRIV"
	echo "Address = $VPS_TUN/30"
	echo "ListenPort = $AWG_PORT"
	echo "MTU = $(tunnel_mtu)"
	awg_params_block
	echo
	echo "[Peer]"
	echo "# Роутер — единственный пир"
	echo "PublicKey = $RTR_PUB"
	echo "PresharedKey = $PSK"
	echo "AllowedIPs = $RTR_TUN/32"
}

router_conf() {
	echo "# Труба: конфиг для импорта в Роутер (Службы → Труба → Туннель → Импорт)"
	echo "[Interface]"
	echo "PrivateKey = $RTR_PRIV"
	echo "Address = $RTR_TUN/30"
	echo "MTU = $(tunnel_mtu)"
	awg_params_block
	echo
	echo "[Peer]"
	echo "PublicKey = $VPS_PUB"
	echo "PresharedKey = $PSK"
	echo "Endpoint = $PUB_IP:$AWG_PORT"
	echo "AllowedIPs = 0.0.0.0/0"
	echo "PersistentKeepalive = 25"
}

# AWG_CONF_CHANGED=1 — конфиг Туннеля стал другим, и Туннель надо перезапустить.
write_awg_conf() {
	install -d -m 700 "$AWG_DIR"
	put_file 600 "$AWG_CONF" < <(awg_conf)
	AWG_CONF_CHANGED=$FILE_CHANGED
}

# ROUTER_CONF_NEW=1 — прежний router.conf стал другим (адрес, порт, MTU): Роутеру нужен новый.
write_router_conf() {
	local existed=0
	[ -f "$ROUTER_CONF" ] && existed=1
	install -d -m 700 "$OUT_DIR"
	put_file 600 "$ROUTER_CONF" < <(router_conf)
	ROUTER_CONF_NEW=0
	if [ "$existed" = 1 ] && [ "$FILE_CHANGED" = 1 ]; then ROUTER_CONF_NEW=1; fi
}

# ---------- nftables: труба 1:1 ----------

# extra_ssh — дополнительные порты SSH через пробел, остающиеся за VPS на время проверки нового.
write_nft() {
	local extra_ssh=${1:-}
	local ssh_ports="$SSH_PORT"
	[ -n "$extra_ssh" ] && ssh_ports="{ $SSH_PORT, ${extra_ssh// /, } }"
	put_file 644 "$NFT_FILE" <<-EOF
		#!/usr/sbin/nft -f
		# Труба: всё, кроме служебных портов, — на Роутер. Сгенерировано install-vps.sh
		define WAN = "$WAN_IF"
		define AWG = "$AWG_IF"
		define PUB = $PUB_IP
		define RTR = $RTR_TUN

		table ip truba_nat
		delete table ip truba_nat
		table ip truba_nat {
			chain prerouting {
				type nat hook prerouting priority dstnat; policy accept;
				iifname \$WAN udp dport 68 return comment "DHCP-клиент самого VPS"
				iifname \$WAN ip daddr \$PUB tcp dport != $ssh_ports dnat to \$RTR
				iifname \$WAN ip daddr \$PUB udp dport != $AWG_PORT dnat to \$RTR
				iifname \$WAN ip daddr \$PUB meta l4proto != { tcp, udp } dnat to \$RTR
			}
			chain postrouting {
				type nat hook postrouting priority srcnat; policy accept;
				oifname \$WAN ip saddr \$RTR snat to \$PUB
			}
		}

		table inet truba_filter
		delete table inet truba_filter
		table inet truba_filter {
			chain input {
				type filter hook input priority filter; policy drop;
				iif lo accept
				ct state established,related accept
				ct state invalid drop
				meta l4proto ipv6-icmp accept
				iifname \$WAN tcp dport $ssh_ports accept
				iifname \$WAN udp dport $AWG_PORT accept
				iifname \$WAN udp sport 67 udp dport 68 accept
				iifname \$WAN udp sport 547 udp dport 546 accept comment "DHCPv6-клиент самого VPS"
				iifname \$AWG ip saddr \$RTR accept
			}
			chain forward {
				type filter hook forward priority filter; policy drop;
				ct state established,related accept
				ct state invalid drop
				iifname \$WAN oifname \$AWG ct status dnat accept
				iifname \$AWG oifname \$WAN ip saddr \$RTR accept
			}
			chain mss {
				type filter hook forward priority mangle; policy accept;
				tcp flags syn tcp option maxseg size set rt mtu
			}
		}
	EOF
	nft -c -f "$NFT_FILE" || die "правила nftables не прошли проверку"
}

write_pipe_unit() {
	put_file 644 "$PIPE_UNIT" <<-EOF
		[Unit]
		Description=Труба: проброс публичного IP на Роутер (nftables)
		After=network-online.target nftables.service
		Wants=network-online.target
		Before=awg-quick@$AWG_IF.service

		[Service]
		Type=oneshot
		RemainAfterExit=yes
		ExecStart=/usr/sbin/nft -f $NFT_FILE
		ExecStop=-/usr/sbin/nft delete table ip truba_nat
		ExecStop=-/usr/sbin/nft delete table inet truba_filter

		[Install]
		WantedBy=multi-user.target
	EOF
	[ "$FILE_CHANGED" = 0 ] || systemctl daemon-reload
	# --now: без него служба до первой перезагрузки числится inactive, хотя правила уже загружены.
	systemctl enable --now truba-pipe.service >/dev/null 2>&1
}

# ---------- sysctl и очередь ----------

# Файлы sysctl.d в том порядке, в каком systemd-sysctl применяет их при загрузке: по имени, а из
# файлов с одинаковым именем — из старшего каталога. Ссылки раскрыты (99-sysctl.conf → sysctl.conf).
sysctl_files() {
	local d f
	# shellcheck disable=SC2086 # список каталогов
	for d in $SYSCTL_DIRS; do
		for f in "$d"/*.conf; do
			if [ -e "$f" ]; then printf '%s\t%s\n' "${f##*/}" "$f"; fi
		done
	done | awk -F '\t' '!seen[$1]++' | LC_ALL=C sort -t "$(printf '\t')" -k1,1 | cut -f2 \
		| while IFS= read -r f; do readlink -f "$f"; done
}

# Строки, которыми файлы, применяемые при загрузке позже нашего, ставят ключам Трубы другие
# значения: «файл: ключ = значение». Обычно это /etc/sysctl.conf (99-sysctl.conf идёт после
# 90-truba.conf), куда гайды по BBR пишут net.core.default_qdisc = fq.
sysctl_overrides() {
	local me later=()
	[ -f "$SYSCTL_FILE" ] || return 0
	me=$(readlink -f "$SYSCTL_FILE")
	mapfile -t later < <(sysctl_files | awk -v me="$me" 'after; $0 == me { after = 1 }')
	[ "${#later[@]}" -gt 0 ] || return 0
	awk '
		/^[ \t]*([#;]|$)/ || !index($0, "=") { next }
		{
			i = index($0, "="); k = substr($0, 1, i - 1); v = substr($0, i + 1)
			sub(/^[ \t]*-?[ \t]*/, "", k); sub(/[ \t]+$/, "", k); gsub(/\//, ".", k)
			gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/[ \t]+/, " ", v)
			if (FILENAME == ARGV[1]) { mine[k] = v; next }
			if (k in mine) { val[k] = v; src[k] = FILENAME }
		}
		END { for (k in val) if (val[k] != mine[k]) printf "%s: %s = %s\n", src[k], k, val[k] }
	' "$SYSCTL_FILE" "${later[@]}"
}

# default_qdisc действует только на новые очереди: у WAN текущие заменяются сразу. У карты с
# несколькими очередями корень — mq с очередью на каждую; новый mq берёт их по default_qdisc.
# Свой корень, поставленный раньше, сначала снимается: mq поверх mq ядро не пересоздаёт, а
# корень, созданный самим ядром, снять нельзя — его новый mq просто заменяет.
wan_qdisc() {
	if [ "$(find "$SYS_NET/$WAN_IF/queues/" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)" -gt 1 ]; then
		tc qdisc del dev "$WAN_IF" root 2>/dev/null || true
		tc qdisc replace dev "$WAN_IF" root mq
	else
		tc qdisc replace dev "$WAN_IF" root fq_codel
	fi
}

# Очереди WAN для status: корень и дочерние, например «mq + fq_codel ×2».
wan_qdisc_show() {
	tc qdisc show dev "${WAN_IF:-}" 2>/dev/null | awk '
		$1 == "qdisc" && $2 != "ingress" && $2 != "clsact" { if ($4 == "root") r = $2; else n[$2]++ }
		END { s = r; for (k in n) s = s " + " k " ×" n[k]; print (s == "" ? "?" : s) }'
}

# Очередь fq_codel, а не fq: fq держит на поток не больше 100 пакетов, а весь Туннель для неё —
# один поток. На пиках она отбрасывала пачки пакетов, и скачивание через Туннель вставало на
# секунды. BBR с ядра 4.13 сам задаёт темп отправки и без fq.
# Корзин хэш-таблицы conntrack столько же, сколько записей, — так ядро само делает на машинах от
# 4 ГБ. На 1 ГБ их по умолчанию около 7680, и при полной таблице поиск идёт по цепочкам в десятки
# записей. Цена — 2 МБ памяти.
write_sysctl() {
	put_file 644 "$SYSCTL_FILE" <<-EOF
		# Труба
		net.ipv4.ip_forward = 1
		net.core.default_qdisc = fq_codel
		net.ipv4.tcp_congestion_control = bbr
		net.netfilter.nf_conntrack_max = 262144
		net.netfilter.nf_conntrack_buckets = 262144
		net.ipv6.conf.all.forwarding = 0
	EOF
	# Без модуля при загрузке systemd-sysctl пропускает ключи nf_conntrack, и остаются ядерные
	# по умолчанию (7680 записей на 1 ГБ) — мало для full cone. modules-load идёт раньше sysctl.
	put_file 644 "$MODULES_FILE" <<< nf_conntrack
	modprobe nf_conntrack 2>/dev/null || true
	sysctl -q -p "$SYSCTL_FILE"
	local over
	over=$(sysctl_overrides)
	[ -z "$over" ] || warn "при загрузке VPS эти строки перебьют настройки Трубы из $SYSCTL_FILE — уберите их:"$'\n'"$over"
	wan_qdisc 2>/dev/null || warn "не удалось заменить очередь $WAN_IF на fq_codel: заменится после перезагрузки"
}

# Туннель перезапускается, только если его конфиг изменился или он не работает: после
# перезапуска Труба не знает адреса Роутера, и Туннель стоит, пока Роутер не сделает новое
# рукопожатие сам (до ~15 с).
setup_awg_service() {
	local unit="awg-quick@$AWG_IF"
	if ! systemctl cat "awg-quick@.service" >/dev/null 2>&1; then
		unit=truba-awg.service
		put_file 644 "/etc/systemd/system/$unit" <<-EOF
			[Unit]
			Description=Труба: Туннель AmneziaWG
			After=network-online.target truba-pipe.service
			Wants=network-online.target

			[Service]
			Type=oneshot
			RemainAfterExit=yes
			ExecStart=/usr/bin/awg-quick up $AWG_IF
			ExecStop=/usr/bin/awg-quick down $AWG_IF

			[Install]
			WantedBy=multi-user.target
		EOF
		[ "$FILE_CHANGED" = 0 ] || systemctl daemon-reload
	fi
	systemctl enable "$unit" >/dev/null 2>&1
	if [ "${AWG_CONF_CHANGED:-1}" = 1 ] || ! systemctl is-active -q "$unit"; then
		systemctl restart "$unit"
	fi
}

# ---------- DNS для Роутера ----------

# unbound на адресе Трубы в Туннеле (ADR 0013). Роутер шлёт ему обычные запросы внутри Туннеля
# (Туннель и так шифрован), а TLS до Cloudflare и Google держит VPS — в миллисекундах от них.
# Новое соединение стоит тогда миллисекунды, а не две поездки через Туннель, как у DoH с Роутера.
write_unbound_conf() {
	put_file 644 "$UNBOUND_CONF" <<-EOF
		# Труба: DNS для Роутера. Сгенерировано install-vps.sh
		server:
		    interface: $VPS_TUN
		    # Адрес появляется вместе с $AWG_IF, а unbound стартует раньше.
		    ip-freebind: yes
		    access-control: $RTR_TUN/32 allow
		    do-ip6: no
		    # DNSSEC проверяют сами Cloudflare и Google: своя проверка — лишние запросы на промахах.
		    module-config: "iterator"
		    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt
		    hide-identity: yes
		    hide-version: yes
		    # Счётчики ответов по кодам (SERVFAIL) — для install-vps.sh status.
		    extended-statistics: yes

		forward-zone:
		    name: "."
		    forward-tls-upstream: yes
		    forward-addr: 1.1.1.1@853#cloudflare-dns.com
		    forward-addr: 1.0.0.1@853#cloudflare-dns.com
		    forward-addr: 8.8.8.8@853#dns.google
		    forward-addr: 8.8.4.4@853#dns.google
	EOF
	UNBOUND_CONF_CHANGED=$FILE_CHANGED
}

# Конфиг пишет install_packages до установки пакета; здесь unbound перезапускается, только если
# конфиг изменился или служба не работает (перезапуск сбрасывает её кэш).
setup_unbound() {
	# Пакет может прописать unbound DNS-сервером самого VPS (resolvconf). VPS резолвит как прежде:
	# этот unbound отвечает только Роутеру.
	systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
	systemctl enable unbound >/dev/null 2>&1
	if [ "${UNBOUND_CONF_CHANGED:-1}" = 1 ] || ! systemctl is-active -q unbound; then
		systemctl restart unbound
	fi
	systemctl is-active -q unbound || die "unbound не запустился: journalctl -u unbound"
}

# ---------- SSH ----------

# Порты из настроек sshd (через пробел), кроме skip. Если sshd -T не ответил — 22, порт
# по умолчанию.
sshd_ports() {
	{ sshd -T 2>/dev/null || true; } | awk -v skip="${1:-}" '
		$1 == "port" { n++; if ($2 != skip && !seen[$2]++) { printf "%s%s", sep, $2; sep = " " } }
		END { if (!n && skip != "22") printf "22"; print "" }'
}

# В Ubuntu 24.04 SSH слушает сокет systemd, его порты генератор берёт из sshd_config. Если
# сокет выключен (sshd запущен как служба), его не трогаем: restart запустил бы и выключенный.
ssh_restart() {
	systemctl daemon-reload
	if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
		systemctl restart ssh.socket
	fi
	systemctl restart ssh.service 2>/dev/null || true
}

ssh_apply() {
	local p
	put_file 644 "$SSHD_DROPIN" < <(
		echo "# Труба: SSH самого VPS на высоком порту, вход только по ключу"
		for p in "$@"; do echo "Port $p"; done
		echo "PasswordAuthentication no"
		echo "KbdInteractiveAuthentication no"
		echo "PermitRootLogin prohibit-password"
	)
	sshd -t || die "конфиг sshd не прошёл проверку"
	[ "$FILE_CHANGED" = 0 ] || ssh_restart
}

# keep — порты через пробел, которые работают, пока новый не подтверждён.
confirm_ssh() {
	local keep=${1:-}
	if [ "${NO_CONFIRM:-0}" = 1 ]; then
		warn "проверка нового порта SSH пропущена (--no-confirm)"
		return 0
	fi
	# Право чтения у /dev/tty есть всегда; без терминала у процесса он не открывается.
	{ : </dev/tty; } 2>/dev/null || die "нужен интерактивный терминал для проверки нового порта SSH (или --no-confirm)"
	echo "  Прежний порт ${keep// /, } работает, пока вы не подтвердите новый."
	echo
	echo "  Откройте НОВОЕ окно терминала и войдите по новому порту:"
	echo
	echo "      ssh -p $SSH_PORT root@$PUB_IP"
	echo
	echo "  Если вход удался — вернитесь сюда и введите yes."
	echo "  Без подтверждения через $CONFIRM_TIMEOUT с изменения SSH и правил будут откачены."
	echo
	local ans=''
	read -r -t "$CONFIRM_TIMEOUT" -p "  Вход по новому порту работает? [yes/NO] " ans </dev/tty || true
	[ "$ans" = yes ]
}

rollback_ssh() {
	if [ -n "${SSH_FALLBACK:-}" ]; then
		# Смена порта у работающей Трубы: SSH и правила возвращаются к прежнему порту.
		warn "откат: SSH остаётся на прежнем порту $SSH_FALLBACK"
		SSH_PORT=$SSH_FALLBACK
		SSH_FALLBACK=''
		SSH_CONFIRMED=1
		save_state
		ssh_apply "$SSH_PORT"
		write_nft
		nft -f "$NFT_FILE"
		exit 1
	fi
	rm -f "$SSHD_DROPIN"
	ssh_restart
	nft delete table ip truba_nat 2>/dev/null || true
	nft delete table inet truba_filter 2>/dev/null || true
	systemctl disable --now truba-pipe.service >/dev/null 2>&1 || true
	warn "откат: правила Трубы сняты, SSH снова слушает прежние порты: $(sshd_ports)"
	exit 1
}

setup_fail2ban() {
	put_file 644 "$F2B_JAIL" <<-EOF
		# Труба
		[sshd]
		enabled = true
		port = $SSH_PORT
		backend = systemd
		banaction = nftables-multiport
	EOF
	systemctl enable fail2ban >/dev/null 2>&1
	if [ "$FILE_CHANGED" = 1 ] || ! systemctl is-active -q fail2ban; then
		systemctl restart fail2ban
	fi
}

setup_unattended() {
	put_file 644 /etc/apt/apt.conf.d/20auto-upgrades <<-EOF
		APT::Periodic::Update-Package-Lists "1";
		APT::Periodic::Unattended-Upgrade "1";
	EOF
}

# ---------- команды ----------

# Порт SSH этого запуска: --ssh-port, сохранённый или новый случайный. Новый порт ещё никто
# не проверял, поэтому, даже если прежний был подтверждён, переход снова идёт через окно
# «прежний + новый» с подтверждением, а прежний порт (SSH_FALLBACK) остаётся для отката.
# Без этого sshd сразу слушал бы только новый порт, а прежний ушёл бы на Роутер: закрытый
# у провайдера новый порт оставил бы VPS без входа.
choose_ssh_port() {
	local saved=${SSH_PORT:-}
	SSH_PORT=${OPT_SSH_PORT:-$saved}
	[ -n "$SSH_PORT" ] || SSH_PORT=$(pick_port)
	if [ -n "$saved" ] && [ "$SSH_PORT" != "$saved" ] && [ "${SSH_CONFIRMED:-0}" = 1 ]; then
		SSH_CONFIRMED=0
		SSH_FALLBACK=$saved
	fi
	return 0
}

cmd_install() {
	need_root
	load_state
	preflight          # WAN_IF и PUB_IP — всегда свежие, остальное из состояния

	# Порты — до пакетов: ошибка видна сразу, а не после нескольких минут установки.
	choose_ssh_port
	AWG_PORT=${OPT_AWG_PORT:-${AWG_PORT:-}}
	[ -n "$AWG_PORT" ] || AWG_PORT=$(pick_port "$SSH_PORT")
	[ "$SSH_PORT" != "$AWG_PORT" ] || die "порты SSH и Туннеля совпадают"

	install_packages
	detect_awg_proto
	if [ -z "${AWG_PROTO:-}" ]; then
		AWG_PROTO=$AWG_PROTO_NOW
	elif [ "$AWG_PROTO" -lt 3 ] && [ "$AWG_PROTO_NOW" -ge 3 ]; then
		# Повторный запуск параметры не меняет: иначе старый конфиг Роутера перестал бы подключаться.
		warn "модуль поддерживает AWG 3.1 (защита заголовков): включится после rotate-keys, затем импортируйте router.conf заново"
	fi

	if [ -z "${VPS_PRIV:-}" ]; then
		say "Генерация ключей и параметров AmneziaWG (протокол ${AWG_PROTO}.x)"
		gen_keys
		gen_params
	fi
	save_state

	write_sysctl
	write_awg_conf
	write_router_conf

	if [ "${SSH_CONFIRMED:-0}" != 1 ]; then
		# Запасные порты на время проверки: при смене — прежний, при первой установке — те, что
		# sshd слушает сейчас (обычно 22). Если sshd уже слушает только новый порт, вход по нему
		# работает, и проверять нечего.
		local keep=${SSH_FALLBACK:-} keep_ports=()
		[ -n "$keep" ] || keep=$(sshd_ports "$SSH_PORT")
		if [ -n "$keep" ]; then
			read -ra keep_ports <<< "$keep"
			say "SSH: временно слушает ${keep// /, } и $SSH_PORT"
			ssh_apply "${keep_ports[@]}" "$SSH_PORT"
			write_nft "$keep"
			nft -f "$NFT_FILE"
			write_pipe_unit
			confirm_ssh "$keep" || rollback_ssh
		fi
		SSH_CONFIRMED=1
		SSH_FALLBACK=''
		save_state
	fi

	say "SSH: только порт $SSH_PORT; порт 22 и все остальные уходят на Роутер"
	ssh_apply "$SSH_PORT"
	write_nft
	nft -f "$NFT_FILE"
	write_pipe_unit
	setup_awg_service
	setup_unbound
	setup_fail2ban
	setup_unattended

	local ver
	ver=$(awg_version)
	say "Готово"
	echo
	echo "  IP Трубы:        $PUB_IP"
	echo "  SSH VPS:         ssh -p $SSH_PORT root@$PUB_IP"
	echo "  Туннель:         udp/$AWG_PORT, протокол AmneziaWG ${AWG_PROTO}.x"
	echo "  MTU Туннеля:     $(tunnel_mtu) (сеть VPS: $(cat "$SYS_NET/$WAN_IF/mtu"))"
	echo "  DNS для Роутера: udp://$VPS_TUN — первый сервер «Туннеля» на вкладке «DNS и списки»"
	echo "  Конфиг Роутера:  $ROUTER_CONF"
	echo
	echo "  Скопировать на компьютер:  scp -P $SSH_PORT root@$PUB_IP:$ROUTER_CONF ."
	echo "  Затем: LuCI → Службы → Труба → Туннель → Импорт .conf"
	echo
	echo "  AmneziaWG на Трубе: $ver — модуль Роутера собирается из router/awg/SOURCES, протокол должен совпадать"
	if [ "${ROUTER_CONF_NEW:-0}" = 1 ]; then
		warn "router.conf изменился (адрес, порт или MTU Туннеля) — импортируйте его в Роутер заново"
	fi
	kernel_module_check >/dev/null || true
}

cmd_show_config() {
	need_root
	[ -f "$ROUTER_CONF" ] || die "нет $ROUTER_CONF — сначала install"
	cat "$ROUTER_CONF"
}

cmd_rotate_keys() {
	need_root
	load_state
	[ -n "${VPS_PRIV:-}" ] || die "Труба не установлена"
	# Модуль мог обновиться: новые параметры — под то, что он умеет сейчас.
	detect_awg_proto
	AWG_PROTO=$AWG_PROTO_NOW
	say "Новые ключи и параметры маскировки"
	gen_keys
	gen_params
	save_state
	write_awg_conf
	write_router_conf
	setup_awg_service
	say "Готово. Импортируйте заново $ROUTER_CONF в Роутер — старый конфиг больше не подключится"
}

# RandomTrailers должен совпадать у сторон: пока он разный, рукопожатие не проходит,
# а текущее соединение держится до перевыпуска ключей (около 2–3 минут).
cmd_random_trailers() {
	need_root
	load_state
	[ -n "${VPS_PRIV:-}" ] || die "Труба не установлена"
	[ "${AWG_PROTO:-1}" -ge 3 ] || die "RandomTrailers есть только в AWG 3.1: сначала rotate-keys"
	case "${1:-}" in
		on) RANDOM_TRAILERS=1 ;;
		off) RANDOM_TRAILERS=0 ;;
		*) die "укажите on или off" ;;
	esac
	save_state
	write_awg_conf
	write_router_conf
	awg set "$AWG_IF" random-trailers "$1" || warn "Туннель не поднят: настройка применится при его запуске"
	say "RandomTrailers $1 на Трубе. Сразу переключите так же на Роутере:"
	echo "  LuCI → Сеть → Интерфейсы → $AWG_IF → AmneziaWG → Random Trailers → Сохранить и применить"
	echo "  (или импортируйте заново $ROUTER_CONF)"
}

cmd_status() {
	need_root
	load_state
	echo "IP Трубы: ${PUB_IP:-?}   SSH: ${SSH_PORT:-?}   Туннель: udp/${AWG_PORT:-?}   AmneziaWG $(awg_version), протокол ${AWG_PROTO:-?}.x"
	echo "MTU Туннеля: $(cat "$SYS_NET/$AWG_IF/mtu" 2>/dev/null || echo ?) (по сети VPS — не больше $(tunnel_mtu))   очередь ${WAN_IF:-?}: $(wan_qdisc_show)"
	if [ "${AWG_PROTO:-1}" -ge 3 ]; then
		echo "Защита заголовков: $([ -n "${HPK:-}" ] && echo вкл || echo выкл)   DisableCookies: вкл   RandomTrailers: $([ "${RANDOM_TRAILERS:-0}" = 1 ] && echo вкл || echo выкл)"
	fi
	kernel_module_check || true
	local over
	over=$(sysctl_overrides)
	[ -z "$over" ] || printf 'sysctl: при загрузке VPS настройки Трубы перебьют строки (уберите их):\n%s\n' "$over"
	echo
	awg show "$AWG_IF" 2>/dev/null || echo "Туннель не поднят"
	echo
	nft list tables 2>/dev/null | grep truba || echo "правила Трубы не загружены"
	echo
	printf 'conntrack: %s из %s\n' "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo ?)" \
		"$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo ?)"
	# Запросы Роутера и ошибки пересылки: если unbound не отвечает, Роутер молча уходит на запасной DoH.
	unbound-control stats_noreset 2>/dev/null | awk -F= '
		$1 == "total.num.queries" { q = $2 } $1 == "num.answer.rcode.SERVFAIL" { s = $2 }
		END { if (q != "") printf "DNS для Роутера (unbound на %s): запросов %d, SERVFAIL %d\n", ip, q, s }' ip="$VPS_TUN" || true
	systemctl --no-pager --lines=0 status truba-pipe.service "awg-quick@$AWG_IF" unbound 2>/dev/null | grep -E '●|Active:' || true
}

cmd_uninstall() {
	need_root
	load_state
	say "Остановка Туннеля и снятие правил"
	systemctl disable --now "awg-quick@$AWG_IF" >/dev/null 2>&1 || true
	systemctl disable --now truba-awg.service >/dev/null 2>&1 || true
	systemctl disable --now truba-pipe.service >/dev/null 2>&1 || true
	systemctl disable --now unbound >/dev/null 2>&1 || true
	nft delete table ip truba_nat 2>/dev/null || true
	nft delete table inet truba_filter 2>/dev/null || true
	rm -f "$PIPE_UNIT" /etc/systemd/system/truba-awg.service "$F2B_JAIL" "$SYSCTL_FILE" "$MODULES_FILE" "$UNBOUND_CONF"
	systemctl restart fail2ban >/dev/null 2>&1 || true
	rm -f "$SSHD_DROPIN"
	ssh_restart
	say "SSH вернулся к прежним настройкам, порт: $(sshd_ports) (текущая сессия сохранится)"
	if [ "${1:-}" = "--purge" ]; then
		rm -rf "$STATE_DIR" "$OUT_DIR" "$AWG_CONF"
	fi
	say "Готово. Пакеты amneziawg и unbound не удалялись"
}

main() {
	trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
	local cmd=${1:-} arg=''
	shift || true
	if [ "$cmd" = random-trailers ]; then
		arg=${1:-}
		shift || true
	fi
	while [ $# -gt 0 ]; do
		case "$1" in
			--ssh-port|--awg-port)
				[ $# -ge 2 ] || die "$1: укажите номер порта"
				if ! [[ $2 =~ ^[0-9]{1,5}$ ]] || [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
					die "$1: неверный номер порта «$2»"
				fi
				if [ "$1" = --ssh-port ]; then OPT_SSH_PORT=$2; else OPT_AWG_PORT=$2; fi
				shift 2 ;;
			--no-confirm) NO_CONFIRM=1; shift ;;
			--purge) PURGE=1; shift ;;
			*) die "неизвестный параметр: $1" ;;
		esac
	done
	case "$cmd" in
		install) cmd_install ;;
		show-config) cmd_show_config ;;
		rotate-keys) cmd_rotate_keys ;;
		random-trailers) cmd_random_trailers "$arg" ;;
		status) cmd_status ;;
		uninstall) cmd_uninstall ${PURGE:+--purge} ;;
		*) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
	esac
}

# При подключении через source (тесты) main не запускается.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
