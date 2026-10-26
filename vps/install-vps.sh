#!/usr/bin/env bash
# Труба — настройка VPS (Ubuntu 24.04) как «прозрачной трубы» для Роутера.
# Все порты публичного IP, кроме SSH и порта Туннеля, уходят на Роутер (DNAT 1:1),
# исходящий трафик Роутера выходит от IP VPS с сохранением порта (SNAT).
#
#   install-vps.sh install [--ssh-port N] [--awg-port N] [--mtu N|auto] [--no-confirm]
#   install-vps.sh show-config
#   install-vps.sh rotate-keys
#   install-vps.sh random-trailers on|off
#   install-vps.sh status
#   install-vps.sh mtu-check
#   install-vps.sh diag [секунд]
#   install-vps.sh repair-module
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
SSHD_CONFIG=/etc/ssh/sshd_config
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-truba.conf
F2B_JAIL=/etc/fail2ban/jail.d/truba.local
PIPE_UNIT=/etc/systemd/system/truba-pipe.service
AWG_DROPIN=/etc/systemd/system/awg-quick@$AWG_IF.service.d/10-truba.conf
SYSCTL_FILE=/etc/sysctl.d/90-truba.conf
# Каталоги sysctl.d по старшинству: из файлов с одинаковым именем systemd-sysctl берёт первый.
SYSCTL_DIRS="/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d"
MODULES_FILE=/etc/modules-load.d/truba.conf
UNBOUND_CONF=/etc/unbound/unbound.conf.d/truba.conf
UNATTENDED_CONF=/etc/apt/apt.conf.d/52truba
JOURNAL_CONF=/etc/systemd/journald.conf.d/90-truba.conf
LOCK_FILE=/run/lock/truba-installer.lock
# Что установщик застал и поменял в системе (UFW, unbound) — для uninstall. Хранится отдельно от
# pipe.env: откат установки возвращает pipe.env, а эти отметки должны остаться.
OWNED="$STATE_DIR/owned.env"
# Снимок файлов на время установки или rotate-keys.
TXN_DIR="$STATE_DIR/txn"
# Отдельный таймер systemd откатывает SSH и правила, если новый порт не подтвердили, даже когда
# сам установщик убит вместе с оборвавшейся сессией SSH.
ROLLBACK_UNIT=truba-rollback

VPS_TUN=10.77.77.1
RTR_TUN=10.77.77.2
# MTU Туннеля — не больше MTU_MAX и такой, чтобы пакет Туннеля с обёрткой помещался в сеть
# VPS целиком: IPv4 20 + UDP 8 + заголовок и тег AWG 32 + S4 до 27 + добавка AWG 3.1 до 15 = 102
# байта. Иначе VPS режет полноразмерные пакеты на два фрагмента: у части провайдеров сеть VPS —
# 1400, а не 1500. Добавка ограничена окном, которое модуль узнаёт и по принятым пакетам, поэтому
# на неё тоже оставлен запас.
MTU_MAX=1380
# Меньше — слишком мелкие пакеты: пути уже 1280 + 102 байт почти не встречаются.
MTU_MIN=1280
TUN_OVERHEAD=102
# AWG 3.1. Добавка к пакетам данных — случайная, вместо дополнения до кратного 16: иначе длины
# всех пакетов Туннеля дают один и тот же остаток от деления на 16. В среднем это те же ~7,5 байта.
AWG_PADDING=0-15
# Keepalive Роутера держит открытым NAT его провайдера. Период случайный, чтобы у простаивающего
# Туннеля не было ровного ритма; верхняя граница — прежние 25 с, так что NAT не закроется раньше.
AWG_KEEPALIVE=15-25
# Таймеры AWG 3.1 — случайные из диапазона, чтобы рукопожатия не шли ровно раз в 120 с. Дольше
# всего Туннель живёт без рукопожатия так: RekeyAfterTime до 125 + keepalive Роутера до 25 +
# одна повторная попытка 5 = 155 с, меньше порога контроля Туннеля на Роутере (handshake_max,
# 180 с). RejectAfterTime от 170 — позже этого: старая сессия не закрывается раньше смены ключей.
AWG_REKEY_AFTER=95-125
AWG_REKEY_TIMEOUT=5
AWG_REJECT_AFTER=170-190
AWG_KEEPALIVE_TIMEOUT=8-14
AWG_HANDSHAKE_ATTEMPTS=16-20
# Имена для пакета-приманки I1 (DNS): популярные российские сайты из белых списков мобильных
# операторов, у которых в ответе нет CNAME. Поля: имя, адрес A и адрес AAAA (- если записи нет)
# на случай, если при установке имя не разрешится. Обычно адреса берутся настоящие, через DNS.
I1_DOMAINS="ya.ru 77.88.55.242 2a02:6b8::2:242
yandex.ru 77.88.55.88 2a02:6b8:a::a
mail.yandex.ru 77.88.21.37 2a02:6b8::a4
browser.yandex.ru 93.158.134.121 2a02:6b8::3f7
yastatic.net 37.9.64.225 2a02:6b8:23::225
api-maps.yandex.ru 87.250.251.134 2a02:6b8::274
dzen.ru 95.163.218.220 2a00:b4c0:9100:b000::1:b0
www.kinopoisk.ru 213.180.199.9 2a02:6b8::473
vk.com 87.240.132.67 -
vk.ru 87.240.132.78 -
api.vk.ru 87.240.137.206 -
id.vk.ru 93.186.237.1 -
m.vk.ru 87.240.132.72 -
ok.ru 217.20.157.145 -
m.ok.ru 217.20.157.145 -
st.okcdn.ru 217.20.152.226 -
mail.ru 89.221.239.1 2a00:b4c0:9100:b000::1
www.mail.ru 90.156.232.41 -
cloud.mail.ru 95.163.48.30 -
max.ru 155.212.204.74 -
web.max.ru 155.212.204.193 -
gosuslugi.ru 213.59.253.7 -
online.sberbank.ru 84.252.149.51 -
id.sber.ru 84.252.149.147 -
id.tbank.ru 178.130.128.26 -
alfa-mobile.alfabank.ru 217.12.98.151 -
www.ozon.ru 185.73.194.82 -
ozon.ru 185.73.194.82 -
st.ozone.ru 185.73.195.117 -
wildberries.ru 185.62.202.2 2a03:720::173:2
www.avito.ru 176.114.124.24 -
m.avito.ru 176.114.120.16 -
api.avito.ru 176.114.122.2 -
2gis.ru 95.129.232.210 -
api.2gis.ru 91.236.51.50 -
auto.ru 51.250.126.110 -
rutube.ru 178.248.233.148 -
lenta.ru 81.19.72.32 -
ria.ru 194.190.139.47 -
rambler.ru 81.19.82.2 -
gazeta.ru 81.19.72.2 -
mts.ru 178.248.238.27 -
megafon.ru 178.177.13.149 -"
CONFIRM_TIMEOUT=120
# Таймер отката срабатывает позже окна подтверждения: сначала откатывает сам установщик.
ROLLBACK_DELAY=$((CONFIRM_TIMEOUT + 60))
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

# MTU Туннеля по MTU интерфейса WAN: при 1500 — 1380, при 1400 — 1298.
auto_mtu() {
	local nic m
	nic=$(cat "$SYS_NET/${WAN_IF:-}/mtu" 2>/dev/null) || nic=1500
	m=$((nic - TUN_OVERHEAD))
	[ "$m" -le "$MTU_MAX" ] || m=$MTU_MAX
	echo "$m"
}

# Заданный вручную (--mtu, TUN_MTU в pipe.env) — например, если путь до дома уже сети VPS
# (PPPoE, мобильная связь): его показывает mtu-check.
tunnel_mtu() {
	if [ -n "${TUN_MTU:-}" ]; then echo "$TUN_MTU"; else auto_mtu; fi
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

STATE_KEYS="WAN_IF PUB_IP SSH_PORT AWG_PORT AWG_PROTO VPS_PRIV VPS_PUB RTR_PRIV RTR_PUB PSK JC JMIN JMAX
S1 S2 S3 S4 H1 H2 H3 H4 I1 I1_SRV HPK RANDOM_TRAILERS SSH_CONFIRMED SSH_FALLBACK TUN_MTU DNS_CF DNS_GOOGLE
UFW_DISABLED UNBOUND_PREEXISTING RESOLVCONF_ENABLED"

# Допустимо ли значение поля pipe.env. Пустое — у полей, которых может ещё не быть.
state_value_ok() {
	local k=$1 v=$2
	[ -n "$v" ] || return 0
	case $k in
		WAN_IF) [[ $v =~ ^[A-Za-z0-9_.@:-]{1,15}$ ]] ;;
		PUB_IP) [[ $v =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ;;
		SSH_PORT|AWG_PORT|SSH_FALLBACK) [[ $v =~ ^[0-9]{1,5}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] ;;
		AWG_PROTO) [[ $v =~ ^[123]$ ]] ;;
		VPS_PRIV|VPS_PUB|RTR_PRIV|RTR_PUB|PSK|HPK) [[ $v =~ ^[A-Za-z0-9+/=]+$ ]] ;;
		JC|JMIN|JMAX|S1|S2|S3|S4) [[ $v =~ ^[0-9]{1,5}$ ]] ;;
		TUN_MTU) [[ $v =~ ^[0-9]{4}$ ]] && [ "$v" -ge "$MTU_MIN" ] && [ "$v" -le "$MTU_MAX" ] ;;
		H1|H2|H3|H4) [[ $v =~ ^[0-9]{1,10}(-[0-9]{1,10})?$ ]] ;;
		I1|I1_SRV) [[ $v =~ ^[A-Za-z0-9\<\>\ ]+$ ]] ;;
		DNS_CF) [[ " $DNS_CF_PAIR " == *" $v "* ]] ;;
		DNS_GOOGLE) [[ " $DNS_GOOGLE_PAIR " == *" $v "* ]] ;;
		RANDOM_TRAILERS|SSH_CONFIRMED|UFW_DISABLED|UNBOUND_PREEXISTING|RESOLVCONF_ENABLED) [[ $v =~ ^[01]$ ]] ;;
		*) return 0 ;;
	esac
}

# pipe.env и owned.env читаются как данные, а не исполняются: только строки KEY='значение' из
# известных полей с проверенным значением. Поля прежних версий (например, AWG_VERSION) пропускаются.
load_env() {
	local f=$1 meta line k v
	[ -e "$f" ] || return 0
	if [ ! -f "$f" ] || [ -L "$f" ]; then die "$f: не обычный файл"; fi
	meta=$(stat -c '%u %a' "$f")
	if [ "${meta% *}" != 0 ] || (( (8#${meta#* } & 8#022) != 0 )); then
		die "$f: владелец должен быть root, запись — только у владельца (chown root; chmod 600)"
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		[[ -z $line || $line == \#* ]] && continue
		[[ $line =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'$ ]] || die "$f: неверная строка «${line%%=*}=…»"
		k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
		[[ " ${STATE_KEYS//$'\n'/ } " == *" $k "* ]] || continue
		state_value_ok "$k" "$v" || die "$f: недопустимое значение $k"
		printf -v "$k" '%s' "$v"
	done < "$f"
	return 0
}

load_state() { load_env "$STATE"; }

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
		I1_SRV='${I1_SRV:-}'
		HPK='${HPK:-}'
		RANDOM_TRAILERS='${RANDOM_TRAILERS:-0}'
		SSH_CONFIRMED='${SSH_CONFIRMED:-0}'
		SSH_FALLBACK='${SSH_FALLBACK:-}'
		TUN_MTU='${TUN_MTU:-}'
		DNS_CF='${DNS_CF:-}'
		DNS_GOOGLE='${DNS_GOOGLE:-}'
	EOF
}

# Что было в системе до первой установки. Пустое значение — неизвестно (установка прежней версии).
save_owned() {
	install -d -m 700 "$STATE_DIR"
	put_file 600 "$OWNED" <<-EOF
		UFW_DISABLED='${UFW_DISABLED:-}'
		UNBOUND_PREEXISTING='${UNBOUND_PREEXISTING:-}'
		RESOLVCONF_ENABLED='${RESOLVCONF_ENABLED:-}'
	EOF
}

# Записывается один раз, до установки пакетов. У Трубы прежней версии исходное состояние уже не
# узнать: поля остаются пустыми, и uninstall ведёт себя как раньше. Отметка ufw ставится позже,
# когда ufw действительно выключен (txn_commit).
record_owned() {
	if [ -f "$OWNED" ]; then load_env "$OWNED"; return 0; fi
	UFW_DISABLED='' UNBOUND_PREEXISTING='' RESOLVCONF_ENABLED=''
	# Трубы ещё нет: система в исходном состоянии.
	if [ -z "${VPS_PRIV:-}" ] && [ ! -e "$PIPE_UNIT" ]; then
		UFW_DISABLED=0
		UNBOUND_PREEXISTING=0
		if systemctl is-enabled -q unbound 2>/dev/null; then UNBOUND_PREEXISTING=1; fi
		RESOLVCONF_ENABLED=0
		if systemctl is-enabled -q unbound-resolvconf.service 2>/dev/null; then RESOLVCONF_ENABLED=1; fi
	fi
	save_owned
}

# ---------- apt ----------

apt_get() { apt-get -o DPkg::Lock::Timeout="$APT_WAIT" "$@"; }

# DPkg::Lock::Timeout на блокировку списков пакетов не действует: apt-get update ждём сами.
apt_update() {
	# В одном запуске индексы достаточно обновить один раз до изменения источников.
	[ "${APT_UPDATED:-0}" = 0 ] || return 0
	local err i
	for ((i = 0; i < APT_WAIT; i += 10)); do
		if err=$(LC_ALL=C apt-get update -qq 2>&1 >/dev/null); then
			[ -z "$err" ] || printf '%s\n' "$err" >&2
			APT_UPDATED=1
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
	# ssh-keygen понимает опции authorized_keys и проверяет сам ключ, а не только его префикс.
	local file=${1:-/root/.ssh/authorized_keys}
	[ -s "$file" ] && ssh-keygen -l -f "$file" >/dev/null 2>&1
}

valid_ipv4() {
	local a b c d x
	[[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	IFS=. read -r a b c d <<< "$1"
	for x in "$a" "$b" "$c" "$d"; do
		[ "$((10#$x))" -le 255 ] || return 1
	done
}

external_ipv4() {
	local url addr
	for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
		addr=$(curl -4 -fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null) || continue
		# Убираем только обрамляющие пробелы, не склеивая некорректный ответ.
		addr=$(printf '%s' "$addr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		if valid_ipv4 "$addr"; then printf '%s\n' "$addr"; return 0; fi
	done
	return 1
}

# TCP и UDP — разные пространства портов; свой работающий порт разрешён при повторной установке.
check_port_available() {
	local proto=$1 port=$2 previous=${3:-}
	[ "$port" != "$previous" ] || return 0
	if ss -Hln"$proto" "( sport = :$port )" | grep -q .; then
		die "порт $proto/$port уже занят другой службой"
	fi
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

	have_key_login /root/.ssh/authorized_keys || die "в /root/.ssh/authorized_keys нет ключа: после переноса SSH вход по паролю будет закрыт. Добавьте ключ и запустите снова"

	WAN_IF=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[ -n "$WAN_IF" ] || die "не найден интерфейс маршрута по умолчанию"
	# Внешний IP сообщают сервисы в интернете; в минимальном образе curl может не быть.
	if ! command -v curl >/dev/null; then
		apt_update
		apt_get install -y -qq curl >/dev/null
	fi
	local ext_ip local_ips
	ext_ip=$(external_ipv4) || die "не удалось узнать корректный внешний IPv4"
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

# Ядра, у которых нет модуля amneziawg. Проверяются все установленные: какое загрузится
# следующим, решает GRUB, и это не обязательно самое новое.
kernels_without_module() {
	local k
	find "$BOOT_DIR" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V \
		| while IFS= read -r k; do
			find "$MODULES_DIR/$k" -name 'amneziawg.ko*' 2>/dev/null | grep -q . || echo "$k"
		done
}

# Строка для status; если у какого-то ядра модуля нет — предупреждение и код 1.
kernel_module_check() {
	local missing k
	find "$BOOT_DIR" -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | grep -q . || return 0
	missing=$(kernels_without_module | xargs)
	if [ -z "$missing" ]; then
		echo "Модуль amneziawg: есть у всех установленных ядер"
		return 0
	fi
	for k in $missing; do
		if [ "$k" = "$(uname -r)" ]; then
			warn "модуля amneziawg нет для работающего ядра $k: install-vps.sh repair-module"
		else
			warn "модуля amneziawg нет для ядра $k: если VPS загрузится с ним, Туннель не поднимется. Выполните install-vps.sh repair-module"
		fi
	done
	return 1
}

# Сборка модуля для ядер без него: заголовки (если есть в архиве), DKMS, depmod, проверка.
repair_kernel() {
	local k=$1 log
	if [ ! -e "$MODULES_DIR/$k/build" ]; then
		if pkg_available "linux-headers-$k"; then
			say "$k: ставлю заголовки ядра"
			apt_get install -y -qq "linux-headers-$k" >/dev/null || { warn "$k: заголовки не поставились"; return 1; }
		else
			warn "$k: заголовков нет в архиве Ubuntu — модуль не собрать. Удалите это ядро или перейдите на новое (apt-get full-upgrade)"
			return 1
		fi
	fi
	say "$k: сборка модуля amneziawg (DKMS)"
	if ! log=$(dkms autoinstall -k "$k" 2>&1); then
		printf '%s\n' "$log" | tail -20 >&2
		warn "$k: DKMS не собрал модуль — журнал сборки: /var/lib/dkms/amneziawg/*/build/make.log"
		return 1
	fi
	depmod -a "$k"
	find "$MODULES_DIR/$k" -name 'amneziawg.ko*' 2>/dev/null | grep -q . || { warn "$k: модуль так и не появился"; return 1; }
	say "$k: модуль собран"
}

cmd_repair_module() {
	need_root
	load_state
	local k fails=0 running list
	running=$(uname -r)
	command -v dkms >/dev/null || die "нет dkms: сначала install"
	export DEBIAN_FRONTEND=noninteractive
	list=$(kernels_without_module)
	if [ -z "$list" ]; then
		say "Модуль amneziawg есть у всех установленных ядер"
	else
		apt_update
		while IFS= read -r k; do
			repair_kernel "$k" || fails=$((fails + 1))
		done <<< "$list"
	fi
	# Работающее ядро: модуль загружается, а остановившийся Туннель поднимается.
	if find "$MODULES_DIR/$running" -name 'amneziawg.ko*' 2>/dev/null | grep -q .; then
		modprobe amneziawg || { warn "модуль amneziawg не загрузился: dmesg | tail"; fails=$((fails + 1)); }
		if [ -n "${VPS_PRIV:-}" ] && [ ! -d "$SYS_NET/$AWG_IF" ]; then
			if systemctl restart "$(awg_unit)"; then
				say "Туннель поднят"
			else
				warn "Туннель не поднялся: journalctl -u $(awg_unit)"
				fails=$((fails + 1))
			fi
		fi
	fi
	[ "$fails" -eq 0 ] || die "не всё удалось исправить (ошибок: $fails)"
}

# Ключ PPA add-apt-repository берёт с Launchpad и встраивает в Signed-By файла источника.
# Сверяем полный отпечаток с закреплённым: подменённый ключ дал бы чужой модуль ядра.
PPA_FPR=75C9DD72C799870E310542E24166F2C257290828
PPA_SOURCES_DIR=/etc/apt/sources.list.d

# Отпечатки основных ключей в Signed-By файла .sources (встроенный ключ или путь к нему).
ppa_key_fprs() {
	local f=$1 signed
	signed=$(awk '/^Signed-By:/ { sub(/^Signed-By:[[:space:]]*/, ""); print; exit }' "$f")
	if [ -n "$signed" ] && [ -f "$signed" ]; then
		gpg --show-keys --with-colons "$signed" 2>/dev/null
	else
		awk '/^Signed-By:/ { on = 1; next } on && /^[^ ]/ { exit } on' "$f" \
			| sed 's/^ //; s/^\.$//' | gpg --show-keys --with-colons 2>/dev/null
	fi | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }'
}

ppa_key_check() {
	local f fprs n=0
	command -v gpg >/dev/null || { warn "нет gpg: ключ PPA amnezia не проверен"; return 0; }
	for f in "$PPA_SOURCES_DIR"/*.sources "$PPA_SOURCES_DIR"/*.list; do
		if [ ! -f "$f" ] || ! grep -qs 'amnezia/ppa' "$f"; then continue; fi
		n=$((n + 1))
		case $f in
			*.list) warn "$f: старый формат источника, ключ PPA не проверен"; continue ;;
		esac
		fprs=$(ppa_key_fprs "$f")
		[ "$fprs" = "$PPA_FPR" ] \
			|| die "$f: ключ PPA amnezia не тот (${fprs:-нет ключа}), ожидается $PPA_FPR. Удалите файл и запустите install снова"
	done
	[ "$n" -gt 0 ] || die "источник PPA amnezia не подключён"
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
		APT_UPDATED=0
	fi
	ppa_key_check
	apt_update
	local hdr metas
	if ! hdr=$(running_headers); then
		die "заголовков ядра $(uname -r) нет в архиве Ubuntu: модуль AmneziaWG под это ядро не собрать. Обновите ядро (apt-get full-upgrade), перезагрузите VPS и запустите install снова"
	fi
	metas=$(kernel_headers_metas)
	[ -n "$metas" ] || warn "не найден метапакет заголовков ядра: после обновления ядра DKMS может не собрать amneziawg — проверяйте install-vps.sh status"
	# Конфиг unbound — до пакета: служба сразу стартует с ним, а не на 127.0.0.1.
	pick_forwarders
	write_unbound_conf
	# shellcheck disable=SC2086 # списки пакетов
	apt_get install -y -qq nftables fail2ban unattended-upgrades curl unbound $hdr $metas >/dev/null
	# Заголовки этого ядра больше не нужны, когда VPS перейдёт на новое: метапакет приносит
	# заголовки новых ядер, а эти пусть убирает apt autoremove (работающее ядро apt не трогает).
	if [ -n "$hdr" ] && [ -n "$metas" ]; then apt-mark auto "$hdr" >/dev/null; fi
	# Модуль собирается DKMS по одним заголовкам ядра: исходники ядра (deb-src) ему не нужны.
	apt_get install -y -qq amneziawg >/dev/null
	modprobe amneziawg || die "модуль amneziawg не загрузился (проверьте dkms status)"
}

# ufw мешает правилам nftables Трубы. Выключается внутри транзакции, прямо перед загрузкой правил:
# откат включит его снова, а uninstall — по отметке в owned.env.
ufw_off() {
	if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
		warn "ufw включён и мешает правилам nftables Трубы — выключаю (uninstall включит его снова)"
		ufw disable >/dev/null
		if [ -d "$TXN_DIR" ]; then touch "$TXN_DIR/ufw-off"; fi
	fi
	return 0
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
# RandomTrailers, ContentPaddingAddition, диапазоны PersistentKeepalive и таймеров), 2 — AWG 2.0 (S3/S4,
# диапазоны H, I1), иначе 1.
# Проверяется тем же разбором конфига, что и у настоящего интерфейса. Код 1 — интерфейс
# AmneziaWG не создаётся: модуля нет (например, DKMS не собрал его под новое ядро).
awg_proto_supported() {
	local t=awgprobe$$ proto=1 f base key
	ip link add "$t" type amneziawg 2>/dev/null || return 1
	f=$(mktemp)
	base=$(printf '[Interface]\nPrivateKey = %s\nS1 = 20\nS2 = 40\nS3 = 20\nS4 = 20\nH1 = 100-200\nH2 = 300-400\nH3 = 500-600\nH4 = 700-800' \
		"$(awg genkey)")
	printf '%s\n' "$base" > "$f"
	if awg setconf "$t" "$f" 2>/dev/null; then
		proto=2
		# Пир без Endpoint: интерфейс выключен, и пробный keepalive никуда не уходит.
		key=$(awg genkey)
		printf '%s\nHeaderProtectionKey = %s\nDisableCookies = off\nRandomTrailers = off\nContentPaddingAddition = %s\nRekeyAfterTime = %s\nRekeyTimeout = %s\nRejectAfterTime = %s\nKeepaliveTimeout = %s\nMaxHandshakeAttempts = %s\n\n[Peer]\nPublicKey = %s\nPersistentKeepalive = %s\n' \
			"$base" "$key" "$AWG_PADDING" "$AWG_REKEY_AFTER" "$AWG_REKEY_TIMEOUT" "$AWG_REJECT_AFTER" \
			"$AWG_KEEPALIVE_TIMEOUT" "$AWG_HANDSHAKE_ATTEMPTS" "$key" "$AWG_KEEPALIVE" > "$f"
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

# Адрес в шестнадцатеричном виде, как в записи DNS: IPv4 — 4 байта, IPv6 — 16.
ipv4_hex() {
	local a b c d
	valid_ipv4 "$1" || return 1
	IFS=. read -r a b c d <<< "$1"
	printf '%02x%02x%02x%02x' "$((10#$a))" "$((10#$b))" "$((10#$c))" "$((10#$d))"
}

ipv6_hex() {
	local a=$1 head tail g n=0 out=''
	local -a h=() t=()
	[[ $a =~ ^[0-9a-fA-F:]{2,39}$ ]] || return 1
	if [[ $a == *::* ]]; then
		head=${a%%::*}; tail=${a#*::}
		[[ $tail != *::* ]] || return 1
	else
		head=$a; tail=''
	fi
	[ -z "$head" ] || IFS=: read -ra h <<< "$head"
	[ -z "$tail" ] || IFS=: read -ra t <<< "$tail"
	if [[ $a == *::* ]]; then
		n=$((8 - ${#h[@]} - ${#t[@]}))
		[ "$n" -ge 1 ] || return 1
	else
		[ "${#h[@]}" -eq 8 ] || return 1
	fi
	for g in "${h[@]}"; do [[ $g =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1; out+=$(printf '%04x' "$((16#$g))"); done
	for ((; n > 0; n--)); do out+=0000; done
	for g in "${t[@]}"; do [[ $g =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1; out+=$(printf '%04x' "$((16#$g))"); done
	printf '%s' "$out"
}

# Имя в виде вопроса DNS: метки с длиной и нулевой байт в конце.
dns_name_hex() {
	local label out=''
	local -a labels=()
	IFS=. read -ra labels <<< "$1"
	for label in "${labels[@]}"; do
		out+=$(printf '%02x' "${#label}")$(printf '%s' "$label" | od -An -tx1 | tr -d ' \n')
	done
	printf '%s00' "$out"
}

# Настоящие адреса имени (4 — A, 6 — AAAA) через DNS VPS, не больше восьми, по одному в строке.
# Без ответа — пусто.
i1_resolve() {
	local fam=ahostsv4 out addr n=0 seen=' '
	[ "$2" = 6 ] && fam=ahostsv6
	out=$(timeout 5 getent "$fam" "$1" 2>/dev/null) || out=''
	while read -r addr _; do
		[ -n "$addr" ] || continue
		if [ "$2" = 4 ]; then
			valid_ipv4 "$addr" || continue
		elif [[ $addr == ::ffff:* ]] || ! ipv6_hex "$addr" >/dev/null; then
			continue
		fi
		[[ $seen != *" $addr "* ]] || continue
		seen+="$addr "
		echo "$addr"
		n=$((n + 1)); [ "$n" -lt 8 ] || break
	done <<< "$out"
	return 0
}

# Пакеты-приманки I1 в форме DNS (I1 не обязан совпадать у сторон). Роутер (I1) шлёт запрос
# о популярном российском сайте, Труба (I1_SRV) — ответ на тот же вопрос с настоящими адресами
# сайта. Имя, тип, флаги, EDNS и TTL выбираются при установке, поэтому у каждой Трубы свои
# пакеты; ID транзакции и DNS Cookie — случайные при каждом рукопожатии.
gen_i1() {
	local line name a4 a6 qtype=0001 rdlen=0004 q flags udp dobit cookie ttl ans='' n=0 addr
	local -a addrs=()
	line=$(printf '%s\n' "$I1_DOMAINS" | shuf -n 1)
	read -r name a4 a6 <<< "$line"
	# AAAA — только у имён, у которых эта запись есть: иначе ответ выдал бы подделку.
	if [ "$a6" != - ] && [ "$(rand_between 0 2)" = 0 ]; then qtype=001c; rdlen=0010; fi
	q="$(dns_name_hex "$name")${qtype}0001"
	flags=$(shuf -n 1 -e 0100 0120)       # RD или RD+AD (как у dig)
	udp=$(shuf -n 1 -e 04d0 1000)          # размер EDNS: 1232 или 4096
	dobit=$(shuf -n 1 -e 0000 8000)        # бит DO
	cookie=$(rand_between 0 1)

	# Запрос: заголовок (qdcount 1, arcount 1 — запись OPT), вопрос, OPT.
	if [ "$cookie" = 1 ]; then
		I1="<r 2><b 0x${flags}0001000000000001${q}000029${udp}0000${dobit}000c000a0008><r 8>"
	else
		I1="<r 2><b 0x${flags}0001000000000001${q}000029${udp}0000${dobit}0000>"
	fi

	if [ "$qtype" = 001c ]; then
		mapfile -t addrs < <(i1_resolve "$name" 6)
		[ "${#addrs[@]}" -gt 0 ] || addrs=("$a6")
	else
		mapfile -t addrs < <(i1_resolve "$name" 4)
		[ "${#addrs[@]}" -gt 0 ] || addrs=("$a4")
	fi
	ttl=$(printf '%08x' "$(rand_between 60 600)")
	for addr in "${addrs[@]}"; do
		if [ "$qtype" = 001c ]; then addr=$(ipv6_hex "$addr"); else addr=$(ipv4_hex "$addr"); fi
		ans+="c00c${qtype}0001${ttl}${rdlen}${addr}"
		n=$((n + 1))
	done
	# Ответ: RD+RA без AA (так отвечает резолвер), те же вопрос и OPT; Cookie — клиента и сервера.
	if [ "$cookie" = 1 ]; then
		I1_SRV="<r 2><b 0x81800001$(printf '%04x' "$n")00000001${q}${ans}00002904d00000${dobit}0014000a0010><r 16>"
	else
		I1_SRV="<r 2><b 0x81800001$(printf '%04x' "$n")00000001${q}${ans}00002904d00000${dobit}0000>"
	fi
}

# Повторный install: у установок прежних версий I1 — один и тот же DNS-ответ о google.com у всех
# Труб, а ответа для Трубы нет. Ключи, S и H не меняются; I1 не обязан совпадать у сторон, поэтому
# прежний router.conf продолжит подключаться, пока его не импортируют заново.
refresh_i1() {
	[ "${AWG_PROTO:-1}" -ge 2 ] && [ -z "${I1_SRV:-}" ] || return 0
	say "Новые пакеты-приманки I1: DNS-запрос Роутера и ответ Трубы"
	gen_i1
}

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
		# Ответ cookie (64 + S3) не должен совпадать по длине с ответом рукопожатия (92 + S2).
		while [ "$S3" -eq $((S2 + 28)) ]; do S3=$(rand_between "$s3min" 55); done
		# S4 удлиняет каждый пакет данных: tunnel_mtu оставляет под него до 27 байт.
		S4=$(rand_between "$s4min" 27)
		local hs=() i lo w
		if [ "$AWG_PROTO" -ge 3 ]; then
			# HeaderProtectionKey шифрует заголовок целиком вместе с типом пакета, поэтому другие H
			# ничего не прячут, а диапазоны лишь замедляют разбор пакетов. 1–4 — штатные значения
			# Amnezia VPN на 3.x; без ключа они ушли бы открыто (проверяет awg_check_h).
			hs=(1 2 3 4)
		else
			# Четыре непересекающихся диапазона: по одному в каждой четверти пространства.
			local q=$((2147483647 / 4))
			for i in 0 1 2 3; do
				w=$(rand_between 100000 5000000)
				lo=$(( i * q + 5 + $(rand_between 0 $((q - w - 10))) ))
				hs+=("$lo-$((lo + w))")
			done
			mapfile -t hs < <(printf '%s\n' "${hs[@]}" | shuf)
		fi
		H1=${hs[0]}; H2=${hs[1]}; H3=${hs[2]}; H4=${hs[3]}
		gen_i1
	else
		S3=''; S4=''; I1=''; I1_SRV=''
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
	local side=$1
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
	# Роутер шлёт DNS-запрос, Труба — ответ на него. Без ответа (установка прежней версии) — запрос.
	if [ "$side" = vps ] && [ -n "${I1_SRV:-}" ]; then
		echo "I1 = $I1_SRV"
	elif [ -n "${I1:-}" ]; then
		echo "I1 = $I1"
	fi
	if [ "${AWG_PROTO:-1}" -ge 3 ]; then
		[ -n "${HPK:-}" ] && echo "HeaderProtectionKey = $HPK"
		# Оставляем защиту AWG от нагрузки рукопожатиями включённой. Это не влияет на RTT данных.
		echo "DisableCookies = off"
		# Запас на случай DPI по размерам пакетов: дорого по трафику, включается отдельной командой.
		# Добавку модуль берёт вместо RandomTrailers, поэтому с ним её нет.
		if [ "${RANDOM_TRAILERS:-0}" = 1 ]; then
			echo "RandomTrailers = on"
		else
			echo "ContentPaddingAddition = $AWG_PADDING"
		fi
		echo "RekeyAfterTime = $AWG_REKEY_AFTER"
		echo "RekeyTimeout = $AWG_REKEY_TIMEOUT"
		echo "RejectAfterTime = $AWG_REJECT_AFTER"
		echo "KeepaliveTimeout = $AWG_KEEPALIVE_TIMEOUT"
		echo "MaxHandshakeAttempts = $AWG_HANDSHAKE_ATTEMPTS"
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
	awg_params_block vps
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
	awg_params_block router
	echo
	echo "[Peer]"
	echo "PublicKey = $VPS_PUB"
	echo "PresharedKey = $PSK"
	echo "Endpoint = $PUB_IP:$AWG_PORT"
	echo "AllowedIPs = 0.0.0.0/0"
	if [ "${AWG_PROTO:-1}" -ge 3 ]; then
		echo "PersistentKeepalive = $AWG_KEEPALIVE"
	else
		echo "PersistentKeepalive = 25"
	fi
}

# H1–H4 = 1/2/3/4 — настоящие типы сообщений WireGuard: без защиты заголовков их видно снаружи.
awg_check_h() {
	if [ "$H1 $H2 $H3 $H4" = "1 2 3 4" ] && { [ "${AWG_PROTO:-1}" -lt 3 ] || [ -z "${HPK:-}" ]; }; then
		die "H1–H4 = 1/2/3/4 без HeaderProtectionKey выдают WireGuard: выполните rotate-keys"
	fi
	return 0
}

# На AWG 3.x диапазоны H остались от прежних версий: повторный install их не меняет, иначе
# прежний router.conf перестал бы подключаться.
h_ranges_on_awg3() {
	[ "${AWG_PROTO:-1}" -ge 3 ] && [[ "$H1$H2$H3$H4" == *-* ]]
}

warn_h_ranges() {
	h_ranges_on_awg3 || return 0
	warn "H1–H4 заданы диапазонами: на AWG 3.1 они ничего не прячут (заголовок шифрует HeaderProtectionKey) и могут снижать скорость. Чтобы перейти на 1/2/3/4: install-vps.sh rotate-keys, затем импортируйте router.conf заново"
}

# AWG_CONF_CHANGED=1 — конфиг Туннеля стал другим, и Туннель надо перезапустить.
write_awg_conf() {
	awg_check_h
	install -d -m 700 "$AWG_DIR"
	put_file 600 "$AWG_CONF" < <(awg_conf)
	AWG_CONF_CHANGED=$FILE_CHANGED
}

# ROUTER_CONF_NEW=1 — прежний router.conf стал другим (адрес, порт, MTU, параметры AWG): Роутеру нужен новый.
write_router_conf() {
	local existed=0
	[ -f "$ROUTER_CONF" ] && existed=1
	awg_check_h
	install -d -m 700 "$OUT_DIR"
	put_file 600 "$ROUTER_CONF" < <(router_conf)
	ROUTER_CONF_NEW=0
	if [ "$existed" = 1 ] && [ "$FILE_CHANGED" = 1 ]; then ROUTER_CONF_NEW=1; fi
}

# ---------- nftables: труба 1:1 ----------

# Порты SNAT для соединений Роутера с исходным портом Туннеля — бо́льшая часть 1024–65535 без него.
# Оболочка Туннеля идёт мимо conntrack (raw_pre, raw_out), и SNAT не видит, что порт занят: оставил бы
# его соединению Роутера, и ответы на него ушли бы в AmneziaWG.
snat_ports_off_awg() {
	if [ "$AWG_PORT" -lt 1024 ]; then
		echo 1024-65535
	elif [ $((AWG_PORT - 1024)) -ge $((65535 - AWG_PORT)) ]; then
		echo "1024-$((AWG_PORT - 1))"
	else
		echo "$((AWG_PORT + 1))-65535"
	fi
}

# extra_ssh — дополнительные порты SSH через пробел, остающиеся за VPS на время проверки нового.
write_nft() {
	local extra_ssh=${1:-}
	local ssh_ports="$SSH_PORT" snat_off
	snat_off=$(snat_ports_off_awg)
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
				oifname \$WAN ip saddr \$RTR udp sport $AWG_PORT snat to \$PUB:$snat_off comment "порт Туннеля занят его оболочкой"
				oifname \$WAN ip saddr \$RTR snat to \$PUB
			}
		}

		table inet truba_filter
		delete table inet truba_filter
		table inet truba_filter {
			# Только внешняя оболочка Туннеля. Внутреннему IPv4 нужен conntrack для NAT.
			chain raw_pre {
				type filter hook prerouting priority raw; policy accept;
				iifname \$WAN ip daddr \$PUB udp dport $AWG_PORT notrack
			}
			chain raw_out {
				type filter hook output priority raw; policy accept;
				oifname \$WAN ip saddr \$PUB udp sport $AWG_PORT notrack
			}
			chain input {
				type filter hook input priority filter; policy drop;
				iif lo accept
				iifname \$WAN ip daddr \$PUB udp dport $AWG_PORT accept
				ct state established,related accept
				ct state invalid drop
				meta l4proto ipv6-icmp accept
				iifname \$WAN tcp dport $ssh_ports accept
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
				tcp flags syn / syn,rst tcp option maxseg size set rt mtu
			}
			# DSCP пакетов Туннеля — 0: модуль ставит рукопожатию AF41, как WireGuard, а мусорным
			# пакетам — случайный, и по этому их узнают. ECN не трогается.
			chain dscp {
				type filter hook output priority mangle; policy accept;
				udp sport $AWG_PORT ip dscp != cs0 ip dscp set cs0
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
		net.ipv4.tcp_syncookies = 1
		net.ipv4.conf.all.accept_redirects = 0
		net.ipv4.conf.default.accept_redirects = 0
		net.ipv4.conf.all.send_redirects = 0
		net.ipv4.conf.default.send_redirects = 0
		net.ipv6.conf.all.accept_redirects = 0
		net.ipv6.conf.default.accept_redirects = 0
		net.core.default_qdisc = fq_codel
		# Верхние пределы, а не выделенная память и не размер буфера AWG.
		net.core.rmem_max = 16777216
		net.core.wmem_max = 16777216
		net.core.netdev_max_backlog = 16384
		net.core.optmem_max = 65536
		net.ipv4.tcp_congestion_control = bbr
		net.netfilter.nf_conntrack_max = 262144
		net.netfilter.nf_conntrack_buckets = 262144
		net.netfilter.nf_conntrack_udp_timeout = 60
		net.netfilter.nf_conntrack_udp_timeout_stream = 180
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
			Requires=truba-pipe.service
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
	else
		# Пакетный юнит: без правил Трубы Туннель не поднимается (иначе без фильтра).
		put_file 644 "$AWG_DROPIN" <<-EOF
			[Unit]
			After=truba-pipe.service
			Requires=truba-pipe.service
		EOF
		[ "$FILE_CHANGED" = 0 ] || systemctl daemon-reload
	fi
	systemctl enable "$unit" >/dev/null 2>&1
	if [ "${AWG_CONF_CHANGED:-1}" = 1 ] || ! systemctl is-active -q "$unit"; then
		systemctl restart "$unit"
	fi
}

# ---------- DNS для Роутера ----------

# У Cloudflare и Google по два anycast-адреса, и с одного VPS они могут вести в разные точки
# присутствия: на Трубе 2026-10-26 до 8.8.8.8 было 22 мс, до 8.8.4.4 — 0,6 мс. Новое соединение DoT
# стоит три поездки, поэтому у каждого поставщика берётся ближний адрес пары (ADR 0013). Прежний
# выбор остаётся, пока другой адрес не ближе на DNS_SWITCH_MS: иначе повторный install из-за
# разброса менял бы конфиг и перезапускал unbound, сбрасывая его кэш. Без ответа на ping (ICMP
# закрыт) выбор не меняется.
DNS_CF_PAIR="1.1.1.1 1.0.0.1"
DNS_GOOGLE_PAIR="8.8.8.8 8.8.4.4"
DNS_SWITCH_MS=5

# Наименьший RTT ping в мс или пусто, если ответа нет.
rtt_min() {
	{ ping -n -q -c 5 -i 0.2 -W 1 "$1" 2>/dev/null || true; } | awk '/^(rtt|round-trip)/ { split($4, r, "/"); print r[1] }'
}

# pick_near прежний a b → «адрес RTT_a RTT_b» (RTT — «-», если ответа нет). Без прежнего — a.
pick_near() {
	local cur=${1:-$2} other rc ro new
	if [ "$cur" = "$2" ]; then other=$3; else other=$2; fi
	rc=$(rtt_min "$cur"); ro=$(rtt_min "$other")
	new=$cur
	if [ -n "$rc" ] && [ -n "$ro" ] && awk -v c="$rc" -v o="$ro" -v d="$DNS_SWITCH_MS" 'BEGIN { exit !(o + d <= c) }'; then
		new=$other
	fi
	if [ "$cur" = "$2" ]; then echo "$new ${rc:--} ${ro:--}"; else echo "$new ${ro:--} ${rc:--}"; fi
}

pick_forwarders() {
	local a b ca cb ga gb
	read -r a b <<< "$DNS_CF_PAIR"; read -r DNS_CF ca cb <<< "$(pick_near "${DNS_CF:-}" "$a" "$b")"
	read -r a b <<< "$DNS_GOOGLE_PAIR"; read -r DNS_GOOGLE ga gb <<< "$(pick_near "${DNS_GOOGLE:-}" "$a" "$b")"
	say "DNS для Роутера: пересылка на $DNS_CF и $DNS_GOOGLE (ping, мс: ${DNS_CF_PAIR% *} $ca, ${DNS_CF_PAIR#* } $cb, ${DNS_GOOGLE_PAIR% *} $ga, ${DNS_GOOGLE_PAIR#* } $gb)"
}

# unbound на адресе Трубы в Туннеле (ADR 0013). Роутер шлёт ему обычные запросы внутри Туннеля
# (Туннель и так шифрован), а TLS до Cloudflare и Google держит VPS — в 3–4 мс от них. Новое
# соединение стоит тогда 13–30 мс, а не две поездки через Туннель, как у DoH с Роутера.
# Выбор самого быстрого адреса (fast-server-permil) не включается: unbound сравнивает адреса по
# времени ответа с поправкой на разброс и залипает на Google. У Cloudflare ответ то 5 мс по открытому
# соединению, то 19 мс и больше с новым (простаивающий DoT он закрывает через 10 с): разброс большой,
# он проигрывает и дальше получает только редкие запросы на остывшее соединение (ADR 0013).
# Адресов пересылки два, по одному у Cloudflare и Google: промахи делятся на меньшее число
# соединений, и каждое реже простаивает дольше 10 с. С четырьмя адресами медленных (дольше 65 мс)
# ответов было вдвое больше. Если один адрес недоступен, unbound уходит на другого поставщика.
# Адрес каждого поставщика — ближний по ping из его пары (pick_forwarders).
write_unbound_conf() {
	put_file 644 "$UNBOUND_CONF" <<-EOF
		# Труба: DNS для Роутера. Сгенерировано install-vps.sh
		server:
		    num-threads: 1
		    minimal-responses: yes
		    outgoing-num-tcp: 64
		    incoming-num-tcp: 32
		    msg-cache-slabs: 1
		    rrset-cache-slabs: 1
		    infra-cache-slabs: 1
		    key-cache-slabs: 1
		    # Просроченный ответ — только после ожидания 1800 мс; mosdns имеет свой резерв.
		    serve-expired: yes
		    serve-expired-ttl: 86400
		    serve-expired-client-timeout: 1800
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
		    # По одному адресу у каждого: соединение с ним реже остывает (ADR 0013).
		    forward-addr: ${DNS_CF:-1.1.1.1}@853#cloudflare-dns.com
		    forward-addr: ${DNS_GOOGLE:-8.8.8.8}@853#dns.google
	EOF
	UNBOUND_CONF_CHANGED=$FILE_CHANGED
}

# Конфиг пишет install_packages до установки пакета; здесь unbound перезапускается, только если
# конфиг изменился или служба не работает (перезапуск сбрасывает её кэш).
setup_unbound() {
	unbound-checkconf "$UNBOUND_CONF" || die "конфиг unbound не прошёл проверку"
	# Пакет может прописать unbound DNS-сервером самого VPS (resolvconf). VPS резолвит как прежде:
	# этот unbound отвечает только Роутеру.
	systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
	systemctl enable unbound >/dev/null 2>&1
	if [ "${UNBOUND_CONF_CHANGED:-1}" = 1 ] || ! systemctl is-active -q unbound; then
		systemctl restart unbound
	fi
	systemctl is-active -q unbound || die "unbound не запустился: journalctl -u unbound"
}

# Строки status про unbound. Если он не отвечает, Роутер молча уходит на запасной DoH, поэтому видно
# это только здесь: запросы, SERVFAIL, доля ответов из кэша unbound (обычно единицы процентов —
# повторы отвечает кэш Роутера), медиана ответа серверов на промахи и среднее время ответа каждого
# адреса пересылки по замерам unbound.
unbound_status() {
	local stats servers
	stats=$(unbound-control stats_noreset 2>/dev/null) || return 0
	awk -F= '
		$1 == "total.num.queries" { q = $2 } $1 == "total.num.cachehits" { h = $2 }
		$1 == "total.recursion.time.median" { m = $2 } $1 == "num.answer.rcode.SERVFAIL" { s = $2 }
		END {
			if (q == "") exit
			printf "DNS для Роутера (unbound на %s): запросов %d, из кэша %d %%, ответ серверов — медиана %.0f мс, SERVFAIL %d\n",
				ip, q, (q ? 100 * h / q : 0), 1000 * m, s
		}' ip="$VPS_TUN" <<< "$stats"
	# Строка dump_infra: «1.1.1.1@853 . ttl 786 ping 14 var 38 rtt 178 …», ping — сглаженное время, мс.
	servers=$({ unbound-control dump_infra 2>/dev/null || true; } | awk '
		$1 ~ /@853$/ && $2 == "." { for (i = 3; i < NF; i++) if ($i == "ping") { sub(/@853$/, "", $1); print $(i + 1), $1 } }' \
		| sort -n | awk '{ printf "%s%s — %d мс", sep, $2, $1; sep = ", " }')
	[ -z "$servers" ] || echo "Серверы пересылки (замер unbound): $servers"
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
	if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
		# Только socket activation использует генератор портов из sshd_config.
		systemctl daemon-reload
		systemctl restart ssh.socket
	fi
	if systemctl is-enabled ssh.service >/dev/null 2>&1 || ! systemctl is-enabled ssh.socket >/dev/null 2>&1; then
		systemctl restart ssh.service || die "не удалось перезапустить ssh.service"
	fi
}

# Файлы конфигурации sshd, где задан параметр key, через пробел. sshd берёт первое значение,
# поэтому файл в sshd_config.d раньше Трубы по имени перекрывает её настройку.
sshd_option_files() {
	local f out=''
	for f in "$SSHD_CONFIG" "${SSHD_DROPIN%/*}"/*.conf; do
		[ -f "$f" ] || continue
		grep -qiE "^[[:space:]]*$1[[:space:]]" "$f" && out+="${out:+ }$f"
	done
	echo "${out:-?}"
}

# Значение key в выводе sshd -T должно подходить под шаблон want, иначе — выход с итоговым
# значением и файлами, где параметр задан.
sshd_expect() {
	local effective=$1 key=$2 want=$3 name=$4 got
	got=$(awk -v k="${key,,}" '$1 == k { print $2; exit }' <<< "$effective")
	[[ $got =~ ^($want)$ ]] && return 0
	die "sshd: итоговое $name ${got:-не задано} вместо нужного Трубе — задано в: $(sshd_option_files "$name"). Уберите строку из файла раньше $SSHD_DROPIN или переименуйте его"
}

ssh_validate_effective() {
	local effective
	effective=$(sshd -T) || die "не удалось прочитать эффективную конфигурацию sshd"
	sshd_expect "$effective" passwordauthentication no PasswordAuthentication
	sshd_expect "$effective" kbdinteractiveauthentication no KbdInteractiveAuthentication
	# OpenSSH до 9.8 (Ubuntu 24.04 — 9.6) выводит prohibit-password старым именем without-password.
	sshd_expect "$effective" permitrootlogin 'prohibit-password|without-password' PermitRootLogin
}

ssh_apply() {
	local p
	put_file 644 "$SSHD_DROPIN" < <(
		echo "# Труба: SSH самого VPS на высоком порту, вход только по ключу"
		for p in "$@"; do echo "Port $p"; done
		echo "PasswordAuthentication no"
		echo "KbdInteractiveAuthentication no"
		echo "PermitRootLogin prohibit-password"
		echo "MaxAuthTries 3"
		echo "LoginGraceTime 20"
		echo "X11Forwarding no"
	)
	sshd -t || die "конфиг sshd не прошёл проверку"
	ssh_validate_effective
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
	rollback_timer_stop
	txn_restore
	warn "откат: SSH и правила Трубы — как до запуска, SSH слушает: $(sshd_ports)"
	exit 1
}

# ---------- транзакция: снимок файлов и откат ----------

# Файлы, которые install и rotate-keys меняют вместе: при откате возвращаются все сразу.
txn_files() {
	printf '%s\n' "$STATE" "$AWG_CONF" "$ROUTER_CONF" "$SSHD_DROPIN" "$NFT_FILE" "$PIPE_UNIT" "$AWG_DROPIN" \
		/etc/systemd/system/truba-awg.service
}

awg_unit() {
	if systemctl cat "awg-quick@.service" >/dev/null 2>&1; then echo "awg-quick@$AWG_IF"; else echo truba-awg.service; fi
}

# Снимок до изменений: копии файлов (отсутствующие — только в списке), какие службы работали.
# Список с путями пишется последним: без него снимок неполный и при откате просто удаляется.
txn_begin() {
	rm -rf "$TXN_DIR"
	install -d -m 700 "$STATE_DIR" "$TXN_DIR"
	local i=0 f unit
	: > "$TXN_DIR/manifest.tmp"
	while IFS= read -r f; do
		i=$((i + 1))
		if [ -e "$f" ]; then cp -a "$f" "$TXN_DIR/$i"; fi
		printf '%s\t%s\n' "$i" "$f" >> "$TXN_DIR/manifest.tmp"
	done < <(txn_files)
	if systemctl is-active -q truba-pipe.service 2>/dev/null; then touch "$TXN_DIR/pipe-active"; fi
	if systemctl is-enabled -q truba-pipe.service 2>/dev/null; then touch "$TXN_DIR/pipe-enabled"; fi
	unit=$(awg_unit)
	echo "$unit" > "$TXN_DIR/awg-unit"
	if systemctl is-active -q "$unit" 2>/dev/null; then touch "$TXN_DIR/awg-active"; fi
	if systemctl is-enabled -q "$unit" 2>/dev/null; then touch "$TXN_DIR/awg-enabled"; fi
	mv "$TXN_DIR/manifest.tmp" "$TXN_DIR/manifest"
	TXN_ACTIVE=1
}

# Возврат к снимку. Без die: откат доводится до конца, даже если отдельный шаг не удался.
txn_restore() {
	local i f unit awg_changed=0
	if [ ! -f "$TXN_DIR/manifest" ]; then
		rm -rf "$TXN_DIR"
		TXN_ACTIVE=0
		return 0
	fi
	unit=$(cat "$TXN_DIR/awg-unit" 2>/dev/null) || unit="awg-quick@$AWG_IF"
	# Службы, которых до запуска не было, выключаются, пока их юниты ещё на месте:
	# truba-pipe при остановке сам снимает правила.
	if [ ! -e "$TXN_DIR/awg-enabled" ]; then systemctl disable "$unit" >/dev/null 2>&1 || true; fi
	if [ ! -e "$TXN_DIR/awg-active" ]; then systemctl stop "$unit" >/dev/null 2>&1 || true; fi
	if [ ! -e "$TXN_DIR/pipe-enabled" ]; then systemctl disable truba-pipe.service >/dev/null 2>&1 || true; fi
	if [ ! -e "$TXN_DIR/pipe-active" ]; then systemctl stop truba-pipe.service >/dev/null 2>&1 || true; fi
	while IFS=$'\t' read -r i f; do
		if [ -e "$TXN_DIR/$i" ]; then
			cmp -s "$TXN_DIR/$i" "$f" && continue
			mkdir -p "${f%/*}"
			cp -a "$TXN_DIR/$i" "$f" || warn "откат: не удалось вернуть $f"
		elif [ -e "$f" ]; then
			rm -f "$f"
		else
			continue
		fi
		[ "$f" != "$AWG_CONF" ] || awg_changed=1
	done < "$TXN_DIR/manifest"
	systemctl daemon-reload >/dev/null 2>&1 || true
	( ssh_restart ) || warn "откат: sshd не перезапустился"
	if [ -e "$TXN_DIR/pipe-active" ] && [ -f "$NFT_FILE" ]; then
		nft -f "$NFT_FILE" || warn "откат: прежние правила nftables не загрузились"
	else
		nft delete table ip truba_nat 2>/dev/null || true
		nft delete table inet truba_filter 2>/dev/null || true
	fi
	if [ -e "$TXN_DIR/awg-active" ] && [ "$awg_changed" = 1 ]; then
		systemctl restart "$unit" || warn "откат: Туннель не перезапустился"
	fi
	if [ -e "$TXN_DIR/ufw-off" ]; then
		ufw --force enable >/dev/null || warn "откат: ufw не включился"
	fi
	rm -rf "$TXN_DIR"
	TXN_ACTIVE=0
}

# Снимок прошлой операции остался (VPS перезагрузился до таймера отката): сначала вернуть его.
txn_recover() {
	warn "прошлая операция не завершилась — возвращаю настройки, какими они были до неё"
	rollback_timer_stop
	txn_restore
}

txn_commit() {
	rollback_timer_stop
	if [ -e "$TXN_DIR/ufw-off" ]; then
		load_env "$OWNED"
		UFW_DISABLED=1
		save_owned
	fi
	rm -rf "$TXN_DIR"
	TXN_ACTIVE=0
}

# Выход по ошибке или сигналу (оборвалась сессия SSH) посреди транзакции — откат сразу, не дожидаясь
# таймера. Вывод может уже не дойти до терминала, поэтому ошибки печати не прерывают откат.
txn_on_exit() {
	[ "${TXN_ACTIVE:-0}" = 1 ] || return 0
	[ "$BASHPID" = "$$" ] || return 0
	set +e
	trap '' PIPE HUP INT TERM
	warn "изменения не завершены — возвращаю прежние настройки" 2>/dev/null
	rollback_timer_stop
	txn_restore 2>/dev/null
}

# Таймер в отдельном юните systemd: он сработает, даже если установщик убит вместе с сессией SSH.
# Запускает копию скрипта из снимка — исходный файл могут удалить или заменить.
rollback_timer_start() {
	local self
	self=$(readlink -f "${BASH_SOURCE[0]}")
	[ -f "$self" ] || die "таймеру отката нужен файл скрипта: скачайте install-vps.sh и запустите bash install-vps.sh install"
	rollback_timer_stop
	cp "$self" "$TXN_DIR/install-vps.sh"
	systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_DELAY}s" --timer-property=AccuracySec=1s \
		/bin/bash "$TXN_DIR/install-vps.sh" txn-rollback >/dev/null \
		|| die "не удалось запустить таймер отката (systemd-run)"
}

rollback_timer_stop() {
	systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
	systemctl reset-failed "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
}

# Чужой awg0.conf (другой туннель на этом VPS) первая установка не перезаписывает.
check_foreign_awg_conf() {
	[ -z "${VPS_PRIV:-}" ] || return 0
	[ -f "$AWG_CONF" ] || return 0
	head -1 "$AWG_CONF" | grep -q '^# Труба:' \
		|| die "$AWG_CONF уже есть и создан не Трубой: перенесите его или задайте другой интерфейс"
}

setup_fail2ban() {
	put_file 644 "$F2B_JAIL" <<-EOF
		# Труба
		[sshd]
		enabled = true
		port = $SSH_PORT
		backend = systemd
		banaction = nftables-multiport
		maxretry = 3
		findtime = 10m
		bantime = 24h
		bantime.increment = true
	EOF
	systemctl enable fail2ban >/dev/null 2>&1
	if [ "$FILE_CHANGED" = 1 ] || ! systemctl is-active -q fail2ban; then
		systemctl restart fail2ban
	fi
}

setup_unattended() {
	# Отдельный файл: не перезаписываем настройки владельца в 20auto-upgrades.
	put_file 644 "$UNATTENDED_CONF" <<-EOF
		APT::Periodic::Update-Package-Lists "1";
		APT::Periodic::Unattended-Upgrade "1";
		Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
		Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
		Unattended-Upgrade::Automatic-Reboot "false";
	EOF
}

setup_journal() {
	put_file 644 "$JOURNAL_CONF" <<-EOF
		[Journal]
		SystemMaxUse=100M
		RuntimeMaxUse=50M
	EOF
	[ "$FILE_CHANGED" = 0 ] || systemctl restart systemd-journald
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
	# Порт SSH и терминал для его проверки — до любых изменений (preflight может поставить curl).
	local previous_awg=${AWG_PORT:-} previous_ssh=${SSH_PORT:-}
	choose_ssh_port
	if [ "${NO_CONFIRM:-0}" != 1 ] && [ "${SSH_CONFIRMED:-0}" != 1 ]; then
		{ : </dev/tty; } 2>/dev/null || die "нужен интерактивный терминал для проверки нового порта SSH (или --no-confirm)"
		# Таймер отката запускает копию скрипта, поэтому нужен сам файл, а не bash <(curl …).
		[ -f "$(readlink -f "${BASH_SOURCE[0]}")" ] \
			|| die "скачайте install-vps.sh в файл и запустите: bash install-vps.sh install"
	fi
	preflight          # WAN_IF и PUB_IP — всегда свежие, остальное из состояния

	# Порты — до пакетов: ошибка видна сразу, а не после нескольких минут установки.
	AWG_PORT=${OPT_AWG_PORT:-${AWG_PORT:-}}
	[ -n "$AWG_PORT" ] || AWG_PORT=$(pick_port "$SSH_PORT")
	[ "$SSH_PORT" != "$AWG_PORT" ] || die "порты SSH и Туннеля совпадают"
	# Уже слушающий порт sshd допустим и при первой установке с --ssh-port.
	if [[ " $(sshd_ports) " != *" $SSH_PORT "* ]]; then
		check_port_available t "$SSH_PORT" "$previous_ssh"
	fi
	check_port_available u "$AWG_PORT" "$previous_awg"
	case ${OPT_MTU:-} in
		'') ;;
		auto) TUN_MTU='' ;;
		*) TUN_MTU=$OPT_MTU ;;
	esac
	check_foreign_awg_conf
	record_owned

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
	else
		# H1–H4 есть только у прежней установки.
		warn_h_ranges
		refresh_i1
	fi
	write_sysctl

	# Отсюда SSH, правила и конфиги Туннеля меняются вместе: при ошибке, обрыве сессии или без
	# подтверждения нового порта всё возвращается к снимку.
	txn_begin
	save_state
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
			if [ "${NO_CONFIRM:-0}" != 1 ]; then rollback_timer_start; fi
			say "SSH: временно слушает ${keep// /, } и $SSH_PORT"
			ssh_apply "${keep_ports[@]}" "$SSH_PORT"
			write_nft "$keep"
			ufw_off
			nft -f "$NFT_FILE"
			write_pipe_unit
			confirm_ssh "$keep" || rollback_ssh
			# Новый порт работает: дальше откат нужен только при ошибке, его сделает сам скрипт.
			rollback_timer_stop
		fi
		SSH_CONFIRMED=1
		SSH_FALLBACK=''
		save_state
	fi

	say "SSH: только порт $SSH_PORT; порт 22 и все остальные уходят на Роутер"
	ssh_apply "$SSH_PORT"
	write_nft
	ufw_off
	nft -f "$NFT_FILE"
	write_pipe_unit
	setup_awg_service
	txn_commit
	setup_unbound
	setup_fail2ban
	setup_unattended
	setup_journal

	local ver
	ver=$(awg_version)
	say "Готово"
	echo
	echo "  IP Трубы:        $PUB_IP"
	echo "  SSH VPS:         ssh -p $SSH_PORT root@$PUB_IP"
	echo "  Туннель:         udp/$AWG_PORT, протокол AmneziaWG ${AWG_PROTO}.x"
	echo "  MTU Туннеля:     $(tunnel_mtu)${TUN_MTU:+ (задан вручную)} (сеть VPS: $(cat "$SYS_NET/$WAN_IF/mtu")); проверка пути до Роутера — mtu-check"
	echo "  DNS для Роутера: udp://$VPS_TUN — сервер «Туннеля» на вкладке «DNS»"
	echo "  Конфиг Роутера:  $ROUTER_CONF"
	echo
	echo "  Скопировать на компьютер:  scp -P $SSH_PORT root@$PUB_IP:$ROUTER_CONF ."
	echo "  Или вывести текст для импорта: bash install-vps.sh show-config"
	echo "  Затем: LuCI → Службы → Труба → Туннель → Импорт .conf"
	echo
	echo "  AmneziaWG на Трубе: $ver — модуль Роутера собирается из router/awg/SOURCES, протокол должен совпадать"
	if [ "${ROUTER_CONF_NEW:-0}" = 1 ]; then
		warn "router.conf изменился (адрес, порт, MTU или параметры Туннеля) — импортируйте его в Роутер заново"
	fi
	kernel_module_check >/dev/null || true
}

cmd_show_config() {
	need_root
	[ -f "$ROUTER_CONF" ] || die "нет $ROUTER_CONF — сначала install"
	cat "$ROUTER_CONF"
}

# Путь до Роутера по ping с запретом фрагментации до его внешнего адреса (Endpoint у awg0):
# самый большой пакет, который проходит целиком, — MTU пути. Меряется путь VPS → дом; ответы
# идут обратно тем же путём. Роутер за CGNAT провайдера на ping может не отвечать.
path_mtu() {
	local ip=$1 lo=$2 hi=$3 mid
	ping_df "$ip" "$lo" || return 1
	while [ $((hi - lo)) -gt 1 ]; do
		mid=$(((lo + hi) / 2))
		if ping_df "$ip" "$mid"; then lo=$mid; else hi=$mid; fi
	done
	ping_df "$ip" "$hi" && lo=$hi
	echo "$lo"
}

# Пакет целиком (IPv4 20 + ICMP 8 + данные) размером size доходит без фрагментации. Три попытки:
# потеря одного пакета не должна занижать MTU.
ping_df() { ping -n -q -c 3 -i 0.2 -W 1 -M 'do' -s $(($2 - 28)) "$1" >/dev/null 2>&1; }

# Счётчики фрагментации IPv4 из /proc/net/snmp: FragCreates — фрагментов нарезано при отправке,
# ReasmReqds — пришло фрагментов на сборку. Внешние пакеты Туннеля идут без запрета фрагментации,
# поэтому слишком большой пакет не теряется, а режется — и виден здесь.
ip_frag_counters() {
	awk '$1 == "Ip:" { if (!n++) { for (i = 2; i <= NF; i++) k[i] = $i } else for (i = 2; i <= NF; i++)
		if (k[i] ~ /^(FragCreates|ReasmReqds|ReasmFails)$/) print "ip." k[i], $i }' "$PROC/net/snmp" 2>/dev/null || true
}

# Замер без ping: Роутер за CGNAT или с закрытым ping не отвечает, но фрагменты видны по счётчикам.
# Счётчики общие для всего VPS: в них попадает и проброшенный на Роутер трафик.
mtu_passive() {
	local secs=$1 a b
	a=$(ip_frag_counters); sleep "$secs"; b=$(ip_frag_counters)
	diag_delta <(echo "$a") <(echo "$b") | awk -v secs="$secs" -v mtu="$2" -v auto="$3" '
		{ v[$1] = $2 }
		END {
			printf "  за %d с: VPS нарезал при отправке %d фрагментов, пришло на сборку %d\n", secs, v["ip.FragCreates"], v["ip.ReasmReqds"]
			if (v["ip.FragCreates"] > 0 && mtu > auto)
				print "!! пакеты к дому не помещаются в сеть VPS: MTU Туннеля " mtu " больше " auto ". Выполните install-vps.sh install и импортируйте router.conf в Роутер заново"
			else if (v["ip.FragCreates"] > 0)
				print "!! VPS режет исходящие пакеты, хотя MTU Туннеля в сеть VPS помещается: режется проброшенный на Роутер трафик или MTU интерфейса Туннеля другой (ip link show awg0)"
			if (v["ip.ReasmReqds"] > 0)
				print "!! пакеты от дома приходят фрагментами: путь уже MTU Туннеля. Уменьшайте --mtu шагами по 20 (install-vps.sh install --mtu N) и повторяйте mtu-check под нагрузкой"
			if (v["ip.FragCreates"] + v["ip.ReasmReqds"] == 0)
				print "==> фрагментов нет: при трафике через Туннель пакеты помещаются в путь целиком"
		}'
}

cmd_mtu_check() {
	need_root
	load_state
	[ -n "${VPS_PRIV:-}" ] || die "Труба не установлена"
	local ep ip nic p rec cur
	ep=$(timeout 5 awg show "$AWG_IF" endpoints 2>/dev/null | awk 'NR == 1 { print $2 }') || ep=''
	ip=${ep%:*}
	valid_ipv4 "$ip" || die "адрес Роутера неизвестен: Туннель не поднят или Роутер ещё не подключался"
	nic=$(cat "$SYS_NET/$WAN_IF/mtu" 2>/dev/null) || nic=1500
	cur=$(cat "$SYS_NET/$AWG_IF/mtu" 2>/dev/null) || cur=$(tunnel_mtu)
	say "Проверка пути до Роутера ($ip): ping без фрагментации, до $nic байт"
	if ! p=$(path_mtu "$ip" 1028 "$nic"); then
		warn "Роутер ($ip) не отвечает на ping (CGNAT провайдера или ping с WAN закрыт) — смотрю фрагменты по счётчикам ядра"
		say "Замер 30 с. Запустите дома скачивание и отправку (например, тест скорости) через Туннель"
		mtu_passive 30 "$cur" "$(auto_mtu)"
		return 0
	fi
	rec=$((p - TUN_OVERHEAD))
	[ "$rec" -le "$MTU_MAX" ] || rec=$MTU_MAX
	echo "  MTU пути VPS → Роутер: $p   MTU Туннеля сейчас: $cur${TUN_MTU:+ (задан вручную)}   по пути — не больше $rec"
	if [ "$rec" -lt "$MTU_MIN" ]; then
		warn "путь уже $((MTU_MIN + TUN_OVERHEAD)) байт: Туннель будет работать с фрагментацией"
	elif [ "$cur" -gt "$rec" ]; then
		warn "полноразмерные пакеты Туннеля режутся на фрагменты. Уменьшите MTU: install-vps.sh install --mtu $rec, затем импортируйте router.conf в Роутер"
	else
		say "MTU Туннеля помещается в путь целиком"
	fi
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
	# Ключи меняются целиком: при ошибке остаются прежние pipe.env, awg0.conf и router.conf.
	txn_begin
	save_state
	write_awg_conf
	write_router_conf
	setup_awg_service
	txn_commit
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
	# Добавка к пакетам данных у модуля главнее RandomTrailers: с ним её нет, без него — снова есть.
	local pad=0
	[ "$RANDOM_TRAILERS" = 1 ] || pad=$AWG_PADDING
	awg set "$AWG_IF" random-trailers "$1" content-padding-addition "$pad" \
		|| warn "Туннель не поднят: настройка применится при его запуске"
	say "RandomTrailers $1 на Трубе. Сразу импортируйте заново $ROUTER_CONF в Роутер:"
	echo "  LuCI → Службы → Труба → Туннель → Импорт .conf"
	echo "  (с RandomTrailers меняется и добавка к пакетам, поэтому одного флага у $AWG_IF мало)"
}

# awg show без секретов: ключ защиты заголовков awg выводит открытым, а по выводу status
# просят помощи. Строки с ключами скрываются, как приватный ключ у самого awg.
awg_show_masked() {
	local out
	out=$(timeout 5 awg show "$AWG_IF" 2>/dev/null) || return 1
	printf '%s\n' "$out" | sed -E 's/^([[:space:]]*(private key|preshared key|header protection key):).*/\1 (hidden)/'
}

cmd_status() {
	need_root
	load_state
	if [ -f "$TXN_DIR/manifest" ]; then
		warn "прошлая установка или rotate-keys не завершились: следующая изменяющая команда сначала вернёт прежние настройки"
	fi
	echo "IP Трубы: ${PUB_IP:-?}   SSH: ${SSH_PORT:-?}   Туннель: udp/${AWG_PORT:-?}   AmneziaWG $(awg_version), протокол ${AWG_PROTO:-?}.x"
	echo "MTU Туннеля: $(cat "$SYS_NET/$AWG_IF/mtu" 2>/dev/null || echo ?) ($([ -n "${TUN_MTU:-}" ] && echo "задан вручную; по сети VPS — до $(auto_mtu)" || echo "по сети VPS — не больше $(auto_mtu)"))   очередь ${WAN_IF:-?}: $(wan_qdisc_show)"
	if [ "${AWG_PROTO:-1}" -ge 3 ]; then
		local rt="выкл   добавка к пакетам: $AWG_PADDING байт" dc cookies
		[ "${RANDOM_TRAILERS:-0}" = 1 ] && rt=вкл
		# Фактическое состояние интерфейса, а не записанное в конфиг.
		if [ -d "$SYS_NET/$AWG_IF" ]; then
			dc=$(timeout 5 awg show "$AWG_IF" disable-cookies 2>/dev/null) || dc=''
			case $dc in
				off) cookies=вкл ;;
				on) cookies='ВЫКЛ (DisableCookies = on)' ;;
				*) cookies='не удалось проверить' ;;
			esac
			rt="$rt (у интерфейса: $(timeout 5 awg show "$AWG_IF" random-trailers 2>/dev/null || echo ?))"
		else
			cookies='Туннель не поднят'
		fi
		echo "Защита заголовков: $([ -n "${HPK:-}" ] && echo вкл || echo выкл)   Cookie-защита: $cookies   RandomTrailers: $rt"
		warn_h_ranges
	fi
	kernel_module_check || true
	local over
	over=$(sysctl_overrides)
	[ -z "$over" ] || printf 'sysctl: при загрузке VPS настройки Трубы перебьют строки (уберите их):\n%s\n' "$over"
	echo
	awg_show_masked || echo "Туннель не поднят"
	echo
	nft list tables 2>/dev/null | grep truba || echo "правила Трубы не загружены"
	echo
	printf 'conntrack: %s из %s\n' "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo ?)" \
		"$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo ?)"
	unbound_status
	systemctl --no-pager --lines=0 status truba-pipe.service "awg-quick@$AWG_IF" unbound 2>/dev/null | grep -E '●|Active:' || true
}

# ---------- diag: замер потерь и упоров за интервал ----------

PROC=/proc
# Внешний адрес для сравнения: задержку самого VPS отделить от задержки пути до дома.
DIAG_REF_IP=1.1.1.1

# Счётчики «имя значение». Снимаются дважды, отчёт — по разнице.
diag_snapshot() {
	local d f hdr row i v
	for d in "$WAN_IF" "$AWG_IF"; do
		[ -d "$SYS_NET/$d/statistics" ] || continue
		for f in rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors; do
			printf '%s.%s %s\n' "$d" "$f" "$(cat "$SYS_NET/$d/statistics/$f" 2>/dev/null || echo 0)"
		done
	done
	# Отброшенное очередью WAN — по корню (mq суммирует дочерние), переполнение fq_codel — по всем.
	{ tc -s qdisc show dev "$WAN_IF" 2>/dev/null || true; } | awk '
		$1 == "qdisc" { root = ($4 == "root"); next }
		root && $1 == "Sent" { gsub(/[(),]/, " "); for (i = 1; i < NF; i++) if ($i == "dropped") d = $(i + 1) }
		{ for (i = 1; i < NF; i++) if ($i == "drop_overlimit") o += $(i + 1) }
		END { print "qdisc.dropped", d + 0; print "qdisc.overlimit", o + 0 }'
	awk '$1 == "Udp:" { if (!n++) { for (i = 2; i <= NF; i++) k[i] = $i } else for (i = 2; i <= NF; i++)
		if (k[i] ~ /^(InErrors|RcvbufErrors|SndbufErrors)$/) print "udp." k[i], $i }' "$PROC/net/snmp" 2>/dev/null || true
	ip_frag_counters
	# softnet_stat: по строке на CPU, второй столбец — отброшено из очереди приёма, третий — ядру не
	# хватило бюджета на разбор (time_squeeze). Числа шестнадцатеричные.
	local drop=0 squeeze=0 a b c
	while read -r a b c _; do
		: "$a"
		drop=$((drop + 16#$b)); squeeze=$((squeeze + 16#$c))
	done < "$PROC/net/softnet_stat"
	echo "softnet.dropped $drop"; echo "softnet.squeeze $squeeze"
	# cpu — сумма, cpuN — каждое ядро: всего, простой (idle + iowait), softirq, steal.
	awk '/^cpu/ { t = 0; for (i = 2; i <= 9; i++) t += $i
		print $1 ".total", t; print $1 ".idle", $5 + $6; print $1 ".softirq", $8; print $1 ".steal", $9 }' "$PROC/stat"
	# Столбцы conntrack по заголовку: набор столбцов зависит от версии ядра.
	if [ -r "$PROC/net/stat/nf_conntrack" ]; then
		{
			read -ra hdr
			local -A sum=()
			while read -ra row; do
				for i in "${!hdr[@]}"; do
					case ${hdr[i]} in insert_failed|drop|early_drop) v=${row[i]:-0}; sum[${hdr[i]}]=$(( ${sum[${hdr[i]}]:-0} + 16#$v )) ;; esac
				done
			done
			for i in insert_failed drop early_drop; do echo "conntrack.$i ${sum[$i]:-0}"; done
		} < "$PROC/net/stat/nf_conntrack"
	fi
}

# Разница двух снимков.
diag_delta() { awk 'NR == FNR { a[$1] = $2; next } { print $1, $2 - (($1 in a) ? a[$1] : 0) }' "$1" "$2"; }

# Итог ping: «потери% min avg max» или пусто.
ping_summary() {
	awk '/packet loss/ { for (i = 1; i <= NF; i++) if ($i ~ /%$/) l = $i }
		/^(rtt|round-trip)/ { split($4, r, "/"); s = r[1] " " r[2] " " r[3] }
		END { if (l != "") print l, (s == "" ? "- - -" : s) }' "$1"
}

# Отчёт по разнице счётчиков (stdin) за secs секунд. Только наблюдения и подсказки, ничего не меняет.
diag_report() {
	local secs=$1 tun_ping=$2 ref_ping=$3
	awk -v secs="$secs" -v wan="$WAN_IF" -v awg="$AWG_IF" -v tp="$tun_ping" -v rp="$ref_ping" -v ref="$DIAG_REF_IP" '
		{ v[$1] = $2 }
		function pct(a, b) { return b > 0 ? 100 * a / b : 0 }
		function nic(d,   s) {
			if (!((d ".rx_packets") in v)) return
			printf "  %-6s принято %d пак/с, отправлено %d пак/с; отброшено: приём %d, отправка %d; ошибки: %d/%d\n", d,
				v[d ".rx_packets"] / secs, v[d ".tx_packets"] / secs, v[d ".rx_dropped"], v[d ".tx_dropped"], v[d ".rx_errors"], v[d ".tx_errors"]
		}
		function rtt(name, s, tunnel,   f) {
			if (s == "") { printf "  %s: ping не запускался\n", name; return }
			split(s, f, " ")
			# Вход на Роутер из зоны Туннеля закрыт: на ping от VPS он не отвечает, и это не потери.
			if (f[2] == "-" && tunnel) printf "  %s: Роутер не отвечает на ping из Туннеля (вход закрыт) — замер на Роутере: truba tunnel-test\n", name
			else if (f[2] == "-") printf "  %s: нет ответа (потери %s)\n", name, f[1]
			else printf "  %s: %s / %s / %s мс (мин / сред / макс), потери %s\n", name, f[2], f[3], f[4], f[1]
		}
		END {
			printf "За %d с:\n", secs
			nic(wan); nic(awg)
			printf "  очередь WAN: отброшено %d (из них при переполнении %d)\n", v["qdisc.dropped"], v["qdisc.overlimit"]
			printf "  UDP: ошибки приёма %d, мал буфер приёма %d, мал буфер отправки %d\n", v["udp.InErrors"], v["udp.RcvbufErrors"], v["udp.SndbufErrors"]
			printf "  фрагменты IPv4: VPS нарезал при отправке %d, пришло на сборку %d (не собралось %d)\n", v["ip.FragCreates"], v["ip.ReasmReqds"], v["ip.ReasmFails"]
			printf "  разбор входящих: отброшено %d, не хватило бюджета %d раз\n", v["softnet.dropped"], v["softnet.squeeze"]
			if ("conntrack.drop" in v)
				printf "  conntrack: отброшено %d, не вставлено %d, вытеснено %d\n", v["conntrack.drop"], v["conntrack.insert_failed"], v["conntrack.early_drop"]
			steal = pct(v["cpu.steal"], v["cpu.total"]); si = pct(v["cpu.softirq"], v["cpu.total"])
			for (k in v) if (k ~ /^cpu[0-9]+\.total$/) {
				c = k; sub(/\.total$/, "", c)
				b = pct(v[c ".total"] - v[c ".idle"], v[c ".total"]); if (b > busy) { busy = b; bc = c }
				s = pct(v[c ".softirq"], v[c ".total"]); if (s > msi) msi = s
			}
			printf "  CPU: steal %.1f %%, softirq %.1f %% (на самом занятом ядре — %.1f %%), самое занятое ядро %s — %.0f %%\n", steal, si, msi, bc, busy
			rtt("RTT Туннеля (до Роутера)", tp, 1)
			rtt("RTT VPS → " ref, rp, 0)
			print ""
			n = 0
			# Steal сам по себе не вред: важно, растёт ли при нём задержка. До 10 % — только к сведению.
			if (steal >= 10) { n++; print "! steal " sprintf("%.1f", steal) " %: хост VPS делит процессор с соседями, задержка Туннеля скачет. Настройкой не лечится — только другой тариф или провайдер" }
			else if (steal >= 5) print "  steal " sprintf("%.1f", steal) " %: соседи по хосту иногда забирают процессор; это заметно, только если под нагрузкой растёт RTT"
			if (busy >= 90) { n++; print "! ядро " bc " занято на " sprintf("%.0f", busy) " %: упор в процессор (шифрование Туннеля идёт в основном на одном ядре)" }
			if (v["softnet.dropped"] > 0) {
				n++; print "! ядро отбрасывает входящие пакеты, не успевая их разобрать: кандидат — net.core.netdev_max_backlog"
				if (v["softnet.squeeze"] > secs) print "  разбор прерывался по лимиту (" v["softnet.squeeze"] " раз): кандидат — и net.core.netdev_budget"
			} else if (v["softnet.squeeze"] > 0)
				# Без потерь это не упор: остаток пакетов ядро разбирает на следующем проходе. В ВМ чаще всего
				# срабатывает лимит времени 2 мс, когда гипервизор забирает vCPU, — бюджет в пакетах не поможет.
				print "  разбор прерывался по лимиту без потерь — остаток разбирается следующим проходом, настройка не нужна"
			if (v["udp.RcvbufErrors"] + v["udp.SndbufErrors"] > 0) { n++; print "! UDP теряет пакеты из-за буфера сокета: кандидат — net.core.rmem_max/wmem_max" }
			if (v["qdisc.overlimit"] > 0) { n++; print "! очередь WAN переполняется (drop_overlimit): пакетов больше, чем она держит" }
			if (v["ip.FragCreates"] > 0) { n++; print "! VPS режет исходящие пакеты на фрагменты: пакет Туннеля не помещается в сеть VPS — install-vps.sh mtu-check" }
			if (v["ip.ReasmReqds"] > 0) { n++; print "! входящие пакеты приходят фрагментами: путь от дома уже MTU Туннеля — install-vps.sh mtu-check" }
			else if (v["qdisc.dropped"] > 0) print "  очередь WAN отбрасывала пакеты при перегрузке — так fq_codel держит задержку низкой, это нормально"
			if (v["conntrack.drop"] + v["conntrack.insert_failed"] + v["conntrack.early_drop"] > 0) { n++; print "! conntrack отбрасывает соединения: таблица переполнена" }
			if (v[wan ".rx_errors"] + v[wan ".tx_errors"] + v[awg ".tx_errors"] > 0) { n++; print "! ошибки интерфейсов: dmesg | tail, ip -s link" }
			if (v[wan ".rx_dropped"] > 0) print "  " wan ": отброшенные при приёме — часто это пакеты неизвестных протоколов, сами по себе не потери"
			if (!n) print "Потерь и упоров не найдено."
		}'
}

# Замер на работающей Трубе. Запускать дважды: в простое и под нагрузкой (скачивание дома через
# Туннель) — по разнице видно, где растёт задержка и теряются пакеты.
cmd_diag() {
	need_root
	load_state
	[ -n "${WAN_IF:-}" ] || die "Труба не установлена"
	local secs=${1:-30} dir
	if ! [[ $secs =~ ^[0-9]+$ ]] || [ "$secs" -lt 5 ] || [ "$secs" -gt 600 ]; then die "diag: длительность — от 5 до 600 секунд"; fi
	local mem cpu
	mem=$(awk '/^MemTotal:/ { printf "%.1f ГБ", $2 / 1048576 }' "$PROC/meminfo")
	cpu=$(awk -F': ' '/^model name/ { print $2; exit }' "$PROC/cpuinfo")
	echo "VPS: $(nproc) vCPU (${cpu:-?}), память $mem, ядро $(uname -r), виртуализация $(systemd-detect-virt 2>/dev/null || echo ?)"
	echo "WAN $WAN_IF: драйвер $(basename "$(readlink "$SYS_NET/$WAN_IF/device/driver" 2>/dev/null)" 2>/dev/null || echo ?), очередей приёма $(find "$SYS_NET/$WAN_IF/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l), очередь: $(wan_qdisc_show)"
	dir=$(mktemp -d)
	say "Замер ${secs} с. Для замера под нагрузкой запустите дома скачивание через Туннель"
	diag_snapshot > "$dir/a"
	ping -n -q -c "$secs" -i 1 -W 2 "$RTR_TUN" > "$dir/tun" 2>&1 &
	ping -n -q -c "$secs" -i 1 -W 2 "$DIAG_REF_IP" > "$dir/ref" 2>&1 &
	sleep "$secs"
	wait || true
	diag_snapshot > "$dir/b"
	diag_delta "$dir/a" "$dir/b" | diag_report "$secs" "$(ping_summary "$dir/tun")" "$(ping_summary "$dir/ref")"
	rm -rf "$dir"
}

cmd_uninstall() {
	need_root
	load_state
	load_env "$OWNED"
	rollback_timer_stop
	rm -rf "$TXN_DIR"
	say "Остановка Туннеля и снятие правил"
	systemctl disable --now "awg-quick@$AWG_IF" >/dev/null 2>&1 || true
	systemctl disable --now truba-awg.service >/dev/null 2>&1 || true
	systemctl disable --now truba-pipe.service >/dev/null 2>&1 || true
	nft delete table ip truba_nat 2>/dev/null || true
	nft delete table inet truba_filter 2>/dev/null || true
	rm -f "$PIPE_UNIT" /etc/systemd/system/truba-awg.service "$AWG_DROPIN" "$F2B_JAIL" "$SYSCTL_FILE" "$MODULES_FILE" "$UNBOUND_CONF"
	rm -f "$UNATTENDED_CONF" "$JOURNAL_CONF"
	rmdir "${AWG_DROPIN%/*}" 2>/dev/null || true
	systemctl restart systemd-journald
	systemctl daemon-reload
	systemctl restart fail2ban >/dev/null 2>&1 || true
	# unbound, стоявший до Трубы, остаётся работать со своими настройками; поставленный ею — выключается.
	if [ "${UNBOUND_PREEXISTING:-}" = 1 ]; then
		systemctl try-restart unbound >/dev/null 2>&1 || true
	else
		systemctl disable --now unbound >/dev/null 2>&1 || true
	fi
	if [ "${RESOLVCONF_ENABLED:-}" = 1 ]; then
		systemctl enable --now unbound-resolvconf.service >/dev/null 2>&1 || true
	fi
	rm -f "$SSHD_DROPIN"
	ssh_restart
	say "SSH вернулся к прежним настройкам, порт: $(sshd_ports) (текущая сессия сохранится)"
	if [ "${UFW_DISABLED:-}" = 1 ] && command -v ufw >/dev/null; then
		say "Включаю ufw снова: его выключила установка Трубы"
		ufw --force enable >/dev/null || warn "ufw не включился: ufw enable"
	fi
	# Исходное состояние unbound и resolvconf остаётся для новой установки. ufw возвращён — его отметка снимается.
	if [ -f "$OWNED" ]; then UFW_DISABLED=0; save_owned; fi
	if [ "${1:-}" = "--purge" ]; then
		rm -rf "$STATE_DIR" "$OUT_DIR" "$AWG_CONF"
	fi
	say "Готово. Пакеты amneziawg и unbound не удалялись"
}

# Вызывает таймер отката (systemd-run), если новый порт SSH так и не подтвердили.
cmd_txn_rollback() {
	need_root
	[ -f "$TXN_DIR/manifest" ] || exit 0
	warn "вход по новому порту SSH не подтверждён — возвращаю прежние SSH и правила"
	txn_restore
}

main() {
	trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
	# Обрыв сессии SSH (HUP) и Ctrl+C тоже ведут к выходу, а значит — к откату незавершённых изменений.
	trap 'txn_on_exit' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	local cmd=${1:-} arg=''
	shift || true
	if [ "$cmd" = random-trailers ] || { [ "$cmd" = diag ] && [[ ${1:-} =~ ^[0-9]+$ ]]; }; then
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
			--mtu)
				[ $# -ge 2 ] || die "--mtu: укажите число или auto"
				if [ "$2" != auto ] && ! state_value_ok TUN_MTU "$2"; then
					die "--mtu: число от $MTU_MIN до $MTU_MAX или auto"
				fi
				OPT_MTU=$2
				shift 2 ;;
			--purge) PURGE=1; shift ;;
			*) die "неизвестный параметр: $1" ;;
		esac
	done
	case "$cmd" in
		install|rotate-keys|random-trailers|uninstall|repair-module|txn-rollback)
			need_root
			install -d -m 755 "${LOCK_FILE%/*}"
			exec 9>"$LOCK_FILE"
			if [ "$cmd" = txn-rollback ]; then
				# Установщик мог ещё не выйти: он откатывает сам. Если он завис, вход важнее — откат всё равно.
				flock -w 60 9 || warn "установщик не отпускает блокировку — откатываю без неё"
			else
				flock -n 9 || die "другая изменяющая команда уже выполняется"
			fi
			case "$cmd" in
				txn-rollback) ;;
				# Снимок прошлой операции (VPS перезагрузился до таймера отката) — до чтения pipe.env.
				*) if [ -e "$TXN_DIR" ]; then txn_recover; fi ;;
			esac
			case "$cmd" in
				install) cmd_install ;;
				rotate-keys) cmd_rotate_keys ;;
				random-trailers) cmd_random_trailers "$arg" ;;
				uninstall) cmd_uninstall ${PURGE:+--purge} ;;
				repair-module) cmd_repair_module ;;
				txn-rollback) cmd_txn_rollback ;;
			esac ;;
		show-config) cmd_show_config ;;
		status) cmd_status ;;
		mtu-check) cmd_mtu_check ;;
		diag) cmd_diag ${arg:+"$arg"} ;;
		*) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
	esac
}

# При подключении через source (тесты) main не запускается.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
