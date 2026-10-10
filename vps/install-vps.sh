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
MODULES_FILE=/etc/modules-load.d/truba.conf

VPS_TUN=10.77.77.1
RTR_TUN=10.77.77.2
# MTU Туннеля — не больше MTU_MAX и такой, чтобы пакет Туннеля с обёрткой помещался в сеть
# VPS целиком: IPv4 20 + UDP 8 + заголовок и тег AWG 32 + S4 до 27 = 87 байт. Иначе VPS режет
# каждый полноразмерный пакет на два фрагмента: у части провайдеров сеть VPS — 1400, а не 1500.
MTU_MAX=1380
TUN_OVERHEAD=87
CONFIRM_TIMEOUT=120
BOOT_DIR=/boot
MODULES_DIR=/lib/modules

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

rand_between() { shuf -i "$1-$2" -n 1; }

# MTU Туннеля по MTU интерфейса WAN: при 1500 — 1380, при 1400 — 1313.
tunnel_mtu() {
	local nic m
	nic=$(cat "/sys/class/net/${WAN_IF:-}/mtu" 2>/dev/null) || nic=1500
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
	umask 077
	mkdir -p "$STATE_DIR"
	cat > "$STATE" <<-EOF
		WAN_IF='$WAN_IF'
		PUB_IP='$PUB_IP'
		SSH_PORT='$SSH_PORT'
		AWG_PORT='$AWG_PORT'
		AWG_PROTO='$AWG_PROTO'
		AWG_VERSION='$AWG_VERSION'
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

# ---------- проверки ----------

preflight() {
	[ "$(id -u)" -eq 0 ] || die "запустите от root"
	# shellcheck disable=SC1091
	. /etc/os-release
	if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != "24.04" ]; then
		die "нужна Ubuntu 24.04 (обнаружено: ${PRETTY_NAME:-?})"
	fi

	if systemd-detect-virt --container -q; then
		die "VPS — контейнер ($(systemd-detect-virt --container)): модуль ядра AmneziaWG в нём не загрузить. Нужна полноценная виртуальная машина (KVM и т.п.)"
	fi

	WAN_IF=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[ -n "$WAN_IF" ] || die "не найден интерфейс маршрута по умолчанию"
	local local_ip ext_ip
	local_ip=$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
	ext_ip=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)
	[ -n "$ext_ip" ] || die "не удалось узнать внешний IP"
	if [ "$local_ip" != "$ext_ip" ]; then
		die "публичный IP ($ext_ip) не назначен на $WAN_IF (там $local_ip): VPS за NAT провайдера. Схема «труба 1:1» требует IP прямо на интерфейсе"
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
		apt-cache show "$h" >/dev/null 2>&1 && echo "$h"
	done
	return 0
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
	# deb-src нужен для сборки модуля AmneziaWG через DKMS (инструкция Amnezia).
	if [ -f /etc/apt/sources.list.d/ubuntu.sources ] && ! grep -q '^Types: deb deb-src' /etc/apt/sources.list.d/ubuntu.sources; then
		sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
	fi
	apt-get update -qq
	apt-get install -y -qq software-properties-common python3-launchpadlib gnupg2 \
		"linux-headers-$(uname -r)" nftables fail2ban unattended-upgrades curl >/dev/null
	local metas
	metas=$(kernel_headers_metas)
	if [ -n "$metas" ]; then
		# shellcheck disable=SC2086 # список пакетов
		apt-get install -y -qq $metas >/dev/null
	else
		warn "не найден метапакет заголовков ядра: после обновления ядра DKMS может не собрать amneziawg — проверяйте install-vps.sh status"
	fi
	if ! grep -rqs 'amnezia/ppa' /etc/apt/sources.list.d/; then
		add-apt-repository -y ppa:amnezia/ppa >/dev/null
		apt-get update -qq
	fi
	apt-get install -y -qq amneziawg >/dev/null
	modprobe amneziawg || die "модуль amneziawg не загрузился (проверьте dkms status)"
	AWG_VERSION=$(dpkg-query -W -f='${Version}' amneziawg-dkms 2>/dev/null || dpkg-query -W -f='${Version}' amneziawg 2>/dev/null || echo unknown)

	if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
		warn "ufw включён и мешает правилам nftables Трубы — выключаю"
		ufw disable >/dev/null
	fi
}

# Какой протокол AWG поддерживает модуль: 3 — AWG 3.1 (защита заголовков, DisableCookies,
# RandomTrailers), 2 — AWG 2.0 (S3/S4, диапазоны H, I1), иначе 1.
# Проверяется тем же разбором конфига, что и у настоящего интерфейса.
awg_proto_supported() {
	local t=awgprobe$$ proto=1 f base
	f=$(mktemp)
	base=$(printf '[Interface]\nPrivateKey = %s\nS1 = 20\nS2 = 40\nS3 = 20\nS4 = 20\nH1 = 100-200\nH2 = 300-400\nH3 = 500-600\nH4 = 700-800' \
		"$(awg genkey)")
	if ip link add "$t" type amneziawg 2>/dev/null; then
		printf '%s\n' "$base" > "$f"
		if awg setconf "$t" "$f" 2>/dev/null; then
			proto=2
			printf '%s\nHeaderProtectionKey = %s\nDisableCookies = on\nRandomTrailers = off\n' "$base" "$(awg genkey)" > "$f"
			if awg setconf "$t" "$f" 2>/dev/null; then
				proto=3
			fi
		fi
		ip link del "$t" 2>/dev/null || true
	fi
	rm -f "$f"
	echo "$proto"
}

detect_awg_proto() {
	AWG_PROTO=$(awg_proto_supported)
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
		local used=" " h
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

write_awg_conf() {
	umask 077
	mkdir -p "$AWG_DIR"
	{
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
	} > "$AWG_CONF"
}

write_router_conf() {
	umask 077
	mkdir -p "$OUT_DIR"
	{
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
	} > "$ROUTER_CONF"
}

# ---------- nftables: труба 1:1 ----------

# extra_ssh — дополнительный порт SSH, остающийся за VPS на время проверки нового порта.
write_nft() {
	local extra_ssh=${1:-}
	local ssh_ports="$SSH_PORT"
	[ -n "$extra_ssh" ] && ssh_ports="{ $SSH_PORT, $extra_ssh }"
	cat > "$NFT_FILE" <<-EOF
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
	cat > "$PIPE_UNIT" <<-EOF
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
	systemctl daemon-reload
	# --now: без него служба до первой перезагрузки числится inactive, хотя правила уже загружены.
	systemctl enable --now truba-pipe.service >/dev/null 2>&1
}

# Очередь fq_codel, а не fq: fq держит на поток не больше 100 пакетов, а весь Туннель для неё —
# один поток. На пиках она отбрасывала пачки пакетов, и скачивание через Туннель вставало на
# секунды. BBR с ядра 4.13 сам задаёт темп отправки и без fq.
write_sysctl() {
	cat > "$SYSCTL_FILE" <<-EOF
		# Труба
		net.ipv4.ip_forward = 1
		net.core.default_qdisc = fq_codel
		net.ipv4.tcp_congestion_control = bbr
		net.netfilter.nf_conntrack_max = 262144
		net.ipv6.conf.all.forwarding = 0
	EOF
	# Без модуля при загрузке systemd-sysctl пропускает nf_conntrack_max, и остаётся ядерный
	# по умолчанию (7680 на 1 ГБ) — мало для full cone. modules-load идёт раньше sysctl.
	echo nf_conntrack > "$MODULES_FILE"
	modprobe nf_conntrack 2>/dev/null || true
	sysctl -q -p "$SYSCTL_FILE"
	# default_qdisc действует только на новые очереди: у WAN заменить текущую сразу, без перезагрузки.
	tc qdisc replace dev "$WAN_IF" root fq_codel 2>/dev/null || warn "не удалось заменить очередь $WAN_IF на fq_codel: заменится после перезагрузки"
}

setup_awg_service() {
	if systemctl cat "awg-quick@.service" >/dev/null 2>&1; then
		systemctl enable "awg-quick@$AWG_IF" >/dev/null 2>&1
		systemctl restart "awg-quick@$AWG_IF"
	else
		cat > /etc/systemd/system/truba-awg.service <<-EOF
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
		systemctl daemon-reload
		systemctl enable truba-awg.service >/dev/null 2>&1
		systemctl restart truba-awg.service
	fi
}

# ---------- SSH ----------

ssh_apply() {
	local ports=("$@") p
	{
		echo "# Труба: SSH самого VPS на высоком порту, вход только по ключу"
		for p in "${ports[@]}"; do echo "Port $p"; done
		echo "PasswordAuthentication no"
		echo "KbdInteractiveAuthentication no"
		echo "PermitRootLogin prohibit-password"
	} > "$SSHD_DROPIN"
	sshd -t || die "конфиг sshd не прошёл проверку"
	# В Ubuntu 24.04 SSH запускается через сокет; генератор берёт Port из sshd_config.
	systemctl daemon-reload
	if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
		systemctl restart ssh.socket
	fi
	systemctl restart ssh.service 2>/dev/null || true
}

have_key_login() {
	[ -s /root/.ssh/authorized_keys ] && grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys
}

confirm_ssh() {
	if [ "${NO_CONFIRM:-0}" = 1 ]; then
		warn "проверка нового порта SSH пропущена (--no-confirm)"
		return 0
	fi
	[ -n "${SSH_FALLBACK:-}" ] && echo "  Прежний порт $SSH_FALLBACK работает, пока вы не подтвердите новый."
	[ -r /dev/tty ] || die "нужен интерактивный терминал для проверки нового порта SSH (или --no-confirm)"
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
	warn "откат: SSH возвращается на 22, правила Трубы сняты"
	rm -f "$SSHD_DROPIN"
	systemctl daemon-reload
	systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh.service
	nft delete table ip truba_nat 2>/dev/null || true
	nft delete table inet truba_filter 2>/dev/null || true
	systemctl disable --now truba-pipe.service >/dev/null 2>&1 || true
	exit 1
}

setup_fail2ban() {
	cat > "$F2B_JAIL" <<-EOF
		# Труба
		[sshd]
		enabled = true
		port = $SSH_PORT
		backend = systemd
		banaction = nftables-multiport
	EOF
	systemctl enable fail2ban >/dev/null 2>&1
	systemctl restart fail2ban
}

setup_unattended() {
	cat > /etc/apt/apt.conf.d/20auto-upgrades <<-EOF
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
	load_state
	preflight          # WAN_IF и PUB_IP — всегда свежие, остальное из состояния

	install_packages
	if [ -z "${AWG_PROTO:-}" ]; then
		detect_awg_proto
	elif [ "$AWG_PROTO" -lt 3 ] && [ "$(awg_proto_supported)" -ge 3 ]; then
		# Повторный запуск параметры не меняет: иначе старый конфиг Роутера перестал бы подключаться.
		warn "модуль поддерживает AWG 3.1 (защита заголовков): включится после rotate-keys, затем импортируйте router.conf заново"
	fi

	choose_ssh_port
	AWG_PORT=${OPT_AWG_PORT:-${AWG_PORT:-}}
	[ -n "$AWG_PORT" ] || AWG_PORT=$(pick_port "$SSH_PORT")
	[ "$SSH_PORT" != "$AWG_PORT" ] || die "порты SSH и Туннеля совпадают"

	if [ -z "${VPS_PRIV:-}" ]; then
		say "Генерация ключей и параметров AmneziaWG (протокол ${AWG_PROTO}.x)"
		gen_keys
		gen_params
	fi
	save_state

	have_key_login || die "в /root/.ssh/authorized_keys нет ключа: после переноса SSH вход по паролю будет закрыт. Добавьте ключ и запустите снова"

	write_sysctl
	write_awg_conf
	write_router_conf

	if [ "${SSH_CONFIRMED:-0}" != 1 ]; then
		# Запасной порт на время проверки: при первой установке — 22, при смене — прежний.
		local keep=${SSH_FALLBACK:-22}
		say "SSH: временно слушает $keep и $SSH_PORT"
		ssh_apply "$keep" "$SSH_PORT"
		write_nft "$keep"
		nft -f "$NFT_FILE"
		write_pipe_unit
		confirm_ssh || rollback_ssh
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
	setup_fail2ban
	setup_unattended

	say "Готово"
	echo
	echo "  IP Трубы:        $PUB_IP"
	echo "  SSH VPS:         ssh -p $SSH_PORT root@$PUB_IP"
	echo "  Туннель:         udp/$AWG_PORT, AmneziaWG $AWG_VERSION (протокол ${AWG_PROTO}.x)"
	echo "  MTU Туннеля:     $(tunnel_mtu) (сеть VPS: $(cat "/sys/class/net/$WAN_IF/mtu"))"
	echo "  Конфиг Роутера:  $ROUTER_CONF"
	echo
	echo "  Скопировать на компьютер:  scp -P $SSH_PORT root@$PUB_IP:$ROUTER_CONF ."
	echo "  Затем: LuCI → Службы → Труба → Туннель → Импорт .conf"
	echo
	echo "  AmneziaWG на Трубе: $AWG_VERSION — модуль Роутера собирается из router/awg/SOURCES, протокол должен совпадать"
	kernel_module_check >/dev/null || true
}

cmd_show_config() {
	[ -f "$ROUTER_CONF" ] || die "нет $ROUTER_CONF — сначала install"
	cat "$ROUTER_CONF"
}

cmd_rotate_keys() {
	[ "$(id -u)" -eq 0 ] || die "запустите от root"
	load_state
	[ -n "${VPS_PRIV:-}" ] || die "Труба не установлена"
	say "Новые ключи и параметры маскировки"
	# Модуль мог обновиться: новые параметры — под то, что он умеет сейчас.
	detect_awg_proto
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
	[ "$(id -u)" -eq 0 ] || die "запустите от root"
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
	load_state
	echo "IP Трубы: ${PUB_IP:-?}   SSH: ${SSH_PORT:-?}   Туннель: udp/${AWG_PORT:-?}   AWG ${AWG_VERSION:-?} (протокол ${AWG_PROTO:-?}.x)"
	echo "MTU Туннеля: $(cat "/sys/class/net/$AWG_IF/mtu" 2>/dev/null || echo ?) (по сети VPS — не больше $(tunnel_mtu))   очередь ${WAN_IF:-?}: $(tc qdisc show dev "${WAN_IF:-}" root 2>/dev/null | awk '{print $2; exit}')"
	if [ "${AWG_PROTO:-1}" -ge 3 ]; then
		echo "Защита заголовков: $([ -n "${HPK:-}" ] && echo вкл || echo выкл)   DisableCookies: вкл   RandomTrailers: $([ "${RANDOM_TRAILERS:-0}" = 1 ] && echo вкл || echo выкл)"
	fi
	kernel_module_check || true
	echo
	awg show "$AWG_IF" 2>/dev/null || echo "Туннель не поднят"
	echo
	nft list tables 2>/dev/null | grep truba || echo "правила Трубы не загружены"
	echo
	printf 'conntrack: %s из %s\n' "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo ?)" \
		"$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo ?)"
	systemctl --no-pager --lines=0 status truba-pipe.service "awg-quick@$AWG_IF" 2>/dev/null | grep -E '●|Active:' || true
}

cmd_uninstall() {
	[ "$(id -u)" -eq 0 ] || die "запустите от root"
	load_state
	say "Остановка Туннеля и снятие правил"
	systemctl disable --now "awg-quick@$AWG_IF" >/dev/null 2>&1 || true
	systemctl disable --now truba-awg.service >/dev/null 2>&1 || true
	systemctl disable --now truba-pipe.service >/dev/null 2>&1 || true
	nft delete table ip truba_nat 2>/dev/null || true
	nft delete table inet truba_filter 2>/dev/null || true
	rm -f "$PIPE_UNIT" /etc/systemd/system/truba-awg.service "$F2B_JAIL" "$SYSCTL_FILE" "$MODULES_FILE"
	systemctl restart fail2ban >/dev/null 2>&1 || true
	say "SSH возвращается на порт 22 (текущая сессия сохранится)"
	rm -f "$SSHD_DROPIN"
	systemctl daemon-reload
	systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh.service
	if [ "${1:-}" = "--purge" ]; then
		rm -rf "$STATE_DIR" "$OUT_DIR" "$AWG_CONF"
	fi
	say "Готово. Пакеты amneziawg не удалялись"
}

main() {
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
