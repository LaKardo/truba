#!/usr/bin/env bash
# install-vps.sh без настоящего VPS: shellcheck, запись файлов, apt, заголовки ядра, протокол AWG,
# параметры AWG 1.x/2.x/3.1, конфиги обеих сторон и их перезапуск, правила nftables (и DSCP Туннеля) с загрузкой
# в ядро, sysctl, очередь WAN, MTU по сети VPS, DNS для Роутера (unbound), порт SSH.
# Контейнер ubuntu:24.04 с --cap-add NET_ADMIN (tests/run.sh vps).
set -uo pipefail

FAILS=0
ok()   { echo "ok    $*"; }
# Проверки в подоболочках тоже должны попасть в итог: счётчик ещё и в файле.
fail() { echo "FAIL  $*"; if [ -n "${T:-}" ]; then echo x >> "$T/fails"; else FAILS=$((FAILS + 1)); fi; }

SCRIPT=${1:-/repo/vps/install-vps.sh}

export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
apt-get update -qq >/dev/null && apt-get install -y -qq shellcheck nftables iproute2 openssh-client >/dev/null

if shellcheck -s bash "$SCRIPT"; then ok "shellcheck"; else fail "shellcheck"; fi
if bash -n "$SCRIPT"; then ok "bash -n"; else fail "bash -n"; fi

# shellcheck disable=SC1090
source "$SCRIPT"
set +e

STATE_DIR=$(mktemp -d)
NFT_FILE="$STATE_DIR/pipe.nft"
T=$(mktemp -d)   # файлы самих проверок

# Ключи с опциями тоже разрешают вход; одного похожего префикса недостаточно.
ssh-keygen -q -t ed25519 -N '' -f "$T/login"
printf '  no-agent-forwarding %s\n' "$(cat "$T/login.pub")" > "$T/authorized_keys"
have_key_login "$T/authorized_keys" && ok "SSH: ключ с опциями и пробелами" || fail "SSH: ключ с опциями"
echo 'ssh-ed25519 not-a-key' > "$T/authorized_keys"
! have_key_login "$T/authorized_keys" && ok "SSH: повреждённый ключ не принимается" || fail "SSH: повреждённый ключ"
valid_ipv4 203.0.113.10 && ! valid_ipv4 256.1.2.3 && ! valid_ipv4 '1.2.3.4 text' && ! valid_ipv4 $'1.2.3.4\n5.6.7.8' \
	&& ok "IPv4: проверка октетов и лишнего текста" || fail "IPv4: проверка"
curl() { case "${*: -1}" in *ipify*) echo '<html>error</html>' ;; *) echo ' 203.0.113.10 ' ;; esac; }
[ "$(external_ipv4)" = 203.0.113.10 ] && ok "IPv4: неверный ответ — следующий сервис" || fail "IPv4: резервный сервис"
unset -f curl
ss() { echo 'LISTEN'; }
out=$( (check_port_available t 55555) 2>&1 )
grep -q 'уже занят' <<< "$out" && ok "порты: занятый TCP отклонён" || fail "порты: занятый TCP"
check_port_available u 51820 51820 && ok "порты: свой UDP при повторном запуске" || fail "порты: свой UDP"
unset -f ss

# Служебные конфиги пишутся отдельно от пользовательских и без лишних перезапусков.
UNATTENDED_CONF="$T/52truba"; JOURNAL_CONF="$T/journal.conf"
setup_unattended
grep -q 'Remove-Unused-Kernel-Packages "true"' "$UNATTENDED_CONF" && grep -q 'Automatic-Reboot "false"' "$UNATTENDED_CONF" \
	&& ok "обновления: очистка ядер без автоперезагрузки" || fail "обновления: настройки"
systemctl() { echo "$*" >> "$T/journal-restarts"; }
setup_journal; setup_journal
[ "$(wc -l < "$T/journal-restarts")" -eq 1 ] && grep -qx 'SystemMaxUse=100M' "$JOURNAL_CONF" \
	&& ok "журнал: ограничен, повторно без перезапуска" || fail "журнал: настройки"
unset -f systemctl

# Проверяем реальные строки конфигурации SSH и fail2ban без перезапуска служб хоста.
SSHD_DROPIN="$T/sshd.conf"; F2B_JAIL="$T/fail2ban.local"
saved_ssh_restart=$(declare -f ssh_restart)
sshd() {
	case "$1" in
		-T) printf '%s\n' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin prohibit-password' ;;
		*) return 0 ;;
	esac
}; ssh_restart() { :; }; systemctl() { :; }
ssh_apply 52222
grep -qx 'MaxAuthTries 3' "$SSHD_DROPIN" && grep -qx 'LoginGraceTime 20' "$SSHD_DROPIN" && grep -qx 'X11Forwarding no' "$SSHD_DROPIN" \
	&& ok "SSH: лимиты авторизации и запрет X11" || fail "SSH: защитные параметры"
SSH_PORT=52222; setup_fail2ban
grep -qx 'bantime.increment = true' "$F2B_JAIL" && grep -qx 'maxretry = 3' "$F2B_JAIL" \
	&& ok "fail2ban: усиленные лимиты" || fail "fail2ban: лимиты"
# OpenSSH до 9.8 выводит prohibit-password старым именем; перекрытая настройка — ошибка с файлом.
sshd() { [ "$1" = -T ] && printf '%s\n' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin without-password'; return 0; }
( ssh_validate_effective ) && ok "SSH: PermitRootLogin without-password (OpenSSH 9.6) принят" || fail "SSH: without-password отклонён"
mkdir -p "$T/sshd.d"; SSHD_CONFIG="$T/sshd_config"; : > "$SSHD_CONFIG"
printf 'PermitRootLogin yes\n' > "$T/sshd.d/05-hoster.conf"
sshd() { [ "$1" = -T ] && printf '%s\n' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitrootlogin yes'; return 0; }
out=$( (SSHD_DROPIN="$T/sshd.d/10-truba.conf"; ssh_validate_effective) 2>&1 )
grep -q "итоговое PermitRootLogin yes" <<< "$out" && grep -q "05-hoster.conf" <<< "$out" \
	&& ok "SSH: перекрытый PermitRootLogin — ошибка с файлом" || fail "SSH: перекрытый PermitRootLogin: $out"
sshd() { [ "$1" = -T ] && printf '%s\n' 'passwordauthentication yes' 'kbdinteractiveauthentication no' 'permitrootlogin prohibit-password'; return 0; }
out=$( (ssh_validate_effective) 2>&1 )
grep -q "итоговое PasswordAuthentication yes" <<< "$out" && ok "SSH: вход по паролю — ошибка" || fail "SSH: пароль: $out"
SSHD_CONFIG=/etc/ssh/sshd_config
unset -f sshd ssh_restart systemctl
# Возвращаем функцию скрипта после подмены.
eval "$saved_ssh_restart"
# Настоящий sshd: наш файл применяется, и его итог проходит проверку (контейнер одноразовый).
apt-get install -y -qq openssh-server >/dev/null 2>&1
(
	ssh-keygen -A >/dev/null 2>&1; mkdir -p /run/sshd
	SSHD_DROPIN=/etc/ssh/sshd_config.d/10-truba.conf
	ssh_restart() { :; }
	ssh_apply 52222 && ok "SSH: настоящий sshd $(sshd -V 2>&1 | head -1 | cut -d, -f1) принимает настройки Трубы"
) || fail "SSH: настоящий sshd: $(sshd -T 2>&1 | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractive)')"
rm -f /etc/ssh/sshd_config.d/10-truba.conf

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
ppa_key_check() { :; }
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
unset -f apt-get apt-mark add-apt-repository modprobe uname dpkg-query apt-cache ppa_key_check
eval "$(sed -n '/^ppa_key_check()/,/^}/p' "$SCRIPT")"
apt-get install -y -qq gnupg iputils-ping >/dev/null 2>&1
# Ключ PPA: полный отпечаток встроенного в Signed-By ключа сверяется с закреплённым.
apt-get install -y -qq gnupg >/dev/null 2>&1
(
	PPA_SOURCES_DIR="$T/sources"; mkdir -p "$PPA_SOURCES_DIR"; export GNUPGHOME="$T/gnupg"; mkdir -m 700 -p "$GNUPGHOME"
	gpg --batch --quiet --passphrase '' --quick-gen-key 'truba-test <t@example.invalid>' ed25519 sign never 2>/dev/null
	fpr=$(gpg --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')
	src() { { printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/\nSuites: noble\nComponents: main\nSigned-By:\n'
		gpg --armor --export "$fpr" | sed 's/^$/./; s/^/ /'; } > "$PPA_SOURCES_DIR/amnezia-ubuntu-ppa-noble.sources"; }
	src
	PPA_FPR=$fpr; ( ppa_key_check ) && ok "ключ PPA: отпечаток совпадает — продолжение" || fail "ключ PPA: свой ключ отклонён"
	PPA_FPR=75C9DD72C799870E310542E24166F2C257290828
	out=$( (ppa_key_check) 2>&1 ); grep -q 'ключ PPA amnezia не тот' <<< "$out" && ok "ключ PPA: чужой ключ — отказ до установки" || fail "ключ PPA: чужой: $out"
	gpg --export "$fpr" > "$T/ppa.gpg"
	printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/\nSuites: noble\nSigned-By: %s\n' "$T/ppa.gpg" > "$PPA_SOURCES_DIR/amnezia-ubuntu-ppa-noble.sources"
	PPA_FPR=$fpr; ( ppa_key_check ) && ok "ключ PPA: Signed-By с путём к файлу" || fail "ключ PPA: путь"
	rm -f "$PPA_SOURCES_DIR"/*
	out=$( (ppa_key_check) 2>&1 ); grep -q 'не подключён' <<< "$out" && ok "ключ PPA: источника нет — отказ" || fail "ключ PPA: без источника: $out"
)
# Протокол AWG по пробному интерфейсу; без модуля — выход, а не молчаливый AWG 1.x.
ip() { [ "$1 $2" != "link add" ]; }
awg_proto_supported >/dev/null; [ $? -ne 0 ] && ok "протокол AWG: интерфейс не создаётся — код ошибки" || fail "протокол AWG: без модуля"
out=$( (detect_awg_proto; echo "дальше: $AWG_PROTO_NOW") 2>&1 )
grep -q 'интерфейс AmneziaWG не создаётся' <<< "$out" && ! grep -q 'дальше' <<< "$out" \
	&& ok "протокол AWG: без модуля — выход до изменений" || fail "протокол AWG: без модуля: $out"
ip() { :; }
awg() { case $1 in genkey) echo a2V5 ;; setconf) cp "$3" "$T/probe" ;; esac; }
p3=$(awg_proto_supported)
awg() { case $1 in genkey) echo a2V5 ;; setconf) ! grep -q HeaderProtectionKey "$3" ;; esac; }
p2=$(awg_proto_supported)
awg() { case $1 in genkey) echo a2V5 ;; setconf) return 1 ;; esac; }
p1=$(awg_proto_supported)
[ "$p3 $p2 $p1" = "3 2 1" ] && ok "протокол AWG: 3.1, 2.0 и 1.x по разбору пробного конфига" || fail "протокол AWG: $p3 $p2 $p1"
# AWG 3.1 — только если модуль принимает всё, что Труба пишет для него: и добавку к пакетам,
# и диапазон keepalive у пира.
grep -qx 'ContentPaddingAddition = 0-15' "$T/probe" && grep -qx 'PersistentKeepalive = 15-25' "$T/probe" \
	&& ok "протокол AWG 3.1: проба с добавкой к пакетам и диапазоном keepalive" || fail "проба AWG 3.1:"$'\n'"$(cat "$T/probe")"
awg() { case $1 in genkey) echo a2V5 ;; setconf) ! grep -q ContentPaddingAddition "$3" ;; esac; }
[ "$(awg_proto_supported)" = 2 ] && ok "протокол AWG: без добавки к пакетам — 2.0" || fail "протокол AWG без ContentPaddingAddition"
unset -f ip awg

# Версия AWG для сверки с router/awg/SOURCES: модуль и сборка PPA.
modinfo() { echo 3.1.20260812; }
dpkg-query() { echo '1.0.0-0~202609061402+4569c4c~ubuntu24.04.1'; }
[ "$(awg_version)" = "3.1.20260812 (сборка PPA 20260906, 4569c4c)" ] && ok "версия AWG: модуль и сборка PPA" || fail "версия AWG: $(awg_version)"
unset -f modinfo dpkg-query

# Параметры AWG 2.x. DNS на VPS для I1 не спрашивается: опорные адреса из списка.
timeout() { shift; "$@"; }
getent() { return 2; }
AWG_PROTO=2
for i in $(seq 50); do
	gen_params
	[ $((S1 + 56)) -ne "$S2" ] || { fail "S1+56 == S2 ($S1, $S2)"; break; }
	for v in S1 S2; do [ "${!v}" -ge 15 ] && [ "${!v}" -le 150 ] || fail "$v вне 15..150: ${!v}"; done
	[ "$S3" -ge 8 ] && [ "$S3" -le 55 ] && [ "$S3" -ne $((S2 + 28)) ] || fail "S3 вне 8..55 или S2+28: $S3"
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
	[ $((S2 + 28)) -ne "$S3" ] || { fail "AWG 3: S2+28 == S3"; bad=1; }
	[ "$S4" -le 27 ] || { fail "AWG 3: S4 > 27"; bad=1; }
	for v in H1 H2 H3 H4; do [[ ${!v} =~ ^[0-9]+$ ]] && [ "${!v}" -ge 5 ] || { fail "AWG 3: $v не одно число: ${!v}"; bad=1; }; done
	[ "$(printf '%s\n' "$H1" "$H2" "$H3" "$H4" | sort -u | wc -l)" -eq 4 ] || { fail "AWG 3: H совпадают"; bad=1; }
done
[ "$bad" -eq 0 ] && ok "50 наборов параметров AWG 3.1: S1–S4 ≥ 12, S3 ≠ S2+28, H1–H4 — разные числа"

AWG_PROTO=1
gen_params
[ -z "$S3" ] && [ -z "$I1" ] && [ -z "$I1_SRV" ] && [[ "$H1" =~ ^[0-9]+$ ]] && ok "параметры AWG 1.x без S3/S4/I1" || fail "параметры AWG 1.x"

# I1 — пакет DNS: <r N> заменяется N нулевыми байтами, и пакет разбирается как настоящий.
# Вывод: «флаги qd an ns ar имя тип класс | адреса | udp do длина-опций», иначе ошибка разбора.
dns_parse() {
	perl -e '
		my $s = shift; my $hex = "";
		while ($s =~ /<(\w+)(?:\s+([^>]*))?>/g) {
			my ($t, $a) = ($1, $2);
			if ($t eq "b") { $a =~ s/^0x//; $hex .= $a } elsif ($t eq "r") { $hex .= "00" x $a } else { die "тег $t\n" }
		}
		die "нечётный hex\n" if length($hex) % 2 || $hex =~ /[^0-9a-f]/;
		my $p = pack("H*", $hex); my $o = 0;
		my $need = sub { die "короткий пакет\n" if $o + $_[0] > length $p };
		my $u16 = sub { $need->(2); my $v = unpack("n", substr($p, $o, 2)); $o += 2; $v };
		my $u32 = sub { $need->(4); my $v = unpack("N", substr($p, $o, 4)); $o += 4; $v };
		my $name = sub {
			my @l;
			while (1) {
				$need->(1); my $n = ord substr($p, $o, 1);
				if ($n == 0) { $o++; last }
				if (($n & 0xc0) == 0xc0) { $need->(2); die "указатель не на вопрос\n" if $u16->() != 0xc00c; return "*" }
				die "метка $n\n" if $n > 63; $o++; $need->($n); push @l, substr($p, $o, $n); $o += $n;
			}
			join ".", @l;
		};
		$u16->(); my $fl = $u16->(); my ($qd, $an, $ns, $ar) = map { $u16->() } 1..4;
		die "qdcount $qd\n" if $qd != 1;
		my $qn = $name->(); my $qt = $u16->(); my $qc = $u16->();
		my @addr;
		for (1..$an) {
			die "имя ответа\n" if $name->() ne "*";
			my ($t, $c) = ($u16->(), $u16->()); my $ttl = $u32->(); my $len = $u16->();
			die "тип ответа\n" if $t != $qt || $c != 1 || $len != ($t == 1 ? 4 : 16);
			die "TTL $ttl\n" if $ttl < 60 || $ttl > 600;
			$need->($len); my $raw = substr($p, $o, $len); $o += $len;
			push @addr, $len == 4 ? join(".", unpack("C4", $raw)) : join(":", map { sprintf "%x", $_ } unpack("n8", $raw));
		}
		die "arcount $ar\n" if $ar != 1;
		die "OPT: имя\n" if $name->() ne "";
		die "OPT: тип\n" if $u16->() != 41;
		my $udp = $u16->(); $u16->(); my $do = $u16->() >> 15; my $rdl = $u16->();
		$need->($rdl); my $end = $o + $rdl;
		while ($o < $end) { my ($c, $l) = ($u16->(), $u16->()); die "опция $c\n" if $c != 10; $o += $l }
		die "длина OPT\n" if $o != $end;
		die "лишние байты\n" if $o != length $p;
		printf "%04x %d %d %d %d %s %d %d | %s | %d %d %d\n", $fl, $qd, $an, $ns, $ar, $qn, $qt, $qc, join(" ", @addr), $udp, $do, $rdl;
	' "$1"
}
# Опорные адреса имён лежат в сетях их владельцев (проверено по RIPEstat при подборе списка).
in_owner_net() {
	case $1 in
		77.88.*|5.255.255.*|93.158.1[2-8][0-9].*|87.250.2[2-5][0-9].*|213.180.199.*|37.9.64.*|2a02:6b8:*) return 0 ;;
		87.240.1[2-9][0-9].*|93.186.2[2-3][0-9].*|95.213.*) return 0 ;;
		95.163.*|217.20.1[4-5][0-9].*|89.221.23[6-9].*|90.156.23[2-9].*|155.212.*|2a00:b4c0:*) return 0 ;;
		213.59.25[2-5].*|84.252.149.*|178.130.128.*|217.12.98.*|185.73.19[2-5].*|185.62.202.*|2a03:720:*) return 0 ;;
		176.114.12[0-4].*|95.129.232.*|91.236.51.*|51.250.126.*|178.248.23[2-9].*|81.19.*|194.190.139.*|178.177.*) return 0 ;;
	esac
	return 1
}
# Опорные адреса из списка.
AWG_PROTO=3
bad=0; seen=" "
for i in $(seq 50); do
	gen_params
	q=$(dns_parse "$I1" 2>&1) || { fail "I1 не разбирается: $q — $I1"; bad=1; continue; }
	r=$(dns_parse "$I1_SRV" 2>&1) || { fail "I1 Трубы не разбирается: $r — $I1_SRV"; bad=1; continue; }
	read -r qfl _ qan _ _ qname qtype _ _ _ _ qdo _ <<< "$q"
	[[ $qfl =~ ^01[02]0$ ]] && [ "$qan" = 0 ] || { fail "I1: не запрос: $q"; bad=1; }
	[[ $I1 == '<r 2><b 0x'* ]] || { fail "I1: не с ID транзакции <r 2>: $I1"; bad=1; }
	line=$(grep "^$qname " <<< "$I1_DOMAINS") || { fail "I1: имя не из списка: $qname"; bad=1; continue; }
	read -r _ a4 a6 <<< "$line"
	[ "$qtype" = 1 ] || { [ "$qtype" = 28 ] && [ "$a6" != - ]; } || { fail "I1: AAAA у $qname без такой записи"; bad=1; }
	# Ответ Трубы — на тот же вопрос, с тем же битом DO, адреса — опорные.
	read -r rfl _ ran _ _ rname rtype _ raddr _ rdo _ <<< "${r//|/ }"
	[ "$rfl $rname $rtype $rdo" = "8180 $qname $qtype $qdo" ] && [ "$ran" = 1 ] || { fail "I1 Трубы: не ответ на вопрос: $q / $r"; bad=1; }
	if [ "$qtype" = 1 ]; then [ "$raddr" = "$a4" ]; else [ "$(ipv6_hex "$raddr")" = "$(ipv6_hex "$a6")" ]; fi \
		|| { fail "I1 Трубы: адрес $raddr, а у $qname $a4 $a6"; bad=1; }
	in_owner_net "$raddr" || { fail "I1 Трубы: $raddr не в сети владельца $qname"; bad=1; }
	seen+="$I1"$'\n'
done
[ "$bad" -eq 0 ] && ok "I1: 50 пар — корректный DNS-запрос Роутера и ответ Трубы на тот же вопрос"
[ "$(sort -u <<< "$seen" | wc -l)" -ge 25 ] && ok "I1: у разных установок разные пакеты" || fail "I1: мало разных: $(sort -u <<< "$seen" | wc -l)"
bad=0
while read -r name a4 a6; do
	in_owner_net "$a4" && { [ "$a6" = - ] || in_owner_net "$a6"; } && ipv4_hex "$a4" >/dev/null \
		&& { [ "$a6" = - ] || ipv6_hex "$a6" >/dev/null; } || { fail "список I1: $name $a4 $a6"; bad=1; }
	[[ $name =~ ^[a-z0-9-]+(\.[a-z0-9-]+)*\.(ru|net|com)$ ]] || { fail "список I1: имя $name"; bad=1; }
done <<< "$I1_DOMAINS"
[ "$bad" -eq 0 ] && ok "список I1: $(wc -l <<< "$I1_DOMAINS") российских имён, опорные адреса в сетях владельцев"
# DNS на VPS отвечает — в ответе Трубы все настоящие адреса (не больше восьми, без повторов).
getent() { case $1 in ahostsv4) printf '77.88.44.55 STREAM yandex.ru\n77.88.44.55 DGRAM\n5.255.255.77 STREAM\n77.88.55.88 STREAM\n' ;;
	ahostsv6) printf '2a02:6b8:a::a STREAM yandex.ru\n::ffff:1.2.3.4 STREAM\n' ;; esac; }
I1_DOMAINS='yandex.ru 77.88.55.88 2a02:6b8:a::a' gen_i1
r=$(dns_parse "$I1_SRV") || fail "I1 Трубы с адресами из DNS: $I1_SRV"
case "$(dns_parse "$I1")" in
	*" yandex.ru 1 "*) [[ $r == *"| 77.88.44.55 5.255.255.77 77.88.55.88 |"* ]] && [[ $r == "8180 1 3 0 1 "* ]] ;;
	*) [[ $r == *"| 2a02:6b8:a:0:0:0:0:a |"* ]] ;;
esac && ok "I1 Трубы: настоящие адреса имени из DNS VPS" || fail "I1 Трубы с DNS: $r"
[ "$(ipv6_hex 2a02:6b8::2:242)" = 2a0206b8000000000000000000020242 ] && [ "$(ipv4_hex 5.255.255.77)" = 05ffff4d ] \
	&& ! ipv6_hex 1::2::3 >/dev/null && [ "$(dns_name_hex ya.ru)" = 02796102727500 ] \
	&& ok "I1: адреса и имя в формате DNS" || fail "I1: формат адресов/имени"
# Повторный install: прежний I1 (DNS-ответ о google.com) заменяется, ключи и S/H — нет.
AWG_PROTO=3; gen_params; s_before="$S1 $S2 $S3 $S4 $H1 $H2 $H3 $H4"
I1='<r 2><b 0x858000010001000000000377777706676f6f676c6503636f6d0000010001c00c000100010000012c0004><r 4>'; I1_SRV=''
refresh_i1 >/dev/null
[ -n "$I1_SRV" ] && [[ $I1 != *676f6f676c65* ]] && [ "$s_before" = "$S1 $S2 $S3 $S4 $H1 $H2 $H3 $H4" ] \
	&& ok "повторный install: старый I1 заменяется, S и H прежние" || fail "повторный install: I1 $I1"
i1_before=$I1; refresh_i1 >/dev/null
[ "$I1" = "$i1_before" ] && ok "повторный install: новый I1 больше не меняется" || fail "повторный install: I1 сменился ещё раз"
AWG_PROTO=1; I1=''; I1_SRV=''; refresh_i1 >/dev/null
[ -z "$I1$I1_SRV" ] && ok "повторный install: у AWG 1.x I1 нет" || fail "повторный install: I1 у AWG 1.x"
getent() { return 2; }
# Таймеры: самая долгая пауза без рукопожатия меньше порога контроля Туннеля на Роутере (180 с),
# а старая сессия закрывается позже смены ключей.
hi() { echo "${1#*-}"; }
lo() { echo "${1%-*}"; }
[ $(( $(hi "$AWG_REKEY_AFTER") + $(hi "$AWG_KEEPALIVE") + $(hi "$AWG_REKEY_TIMEOUT") )) -lt 180 ] \
	&& [ "$(lo "$AWG_REJECT_AFTER")" -gt $(( $(hi "$AWG_REKEY_AFTER") + $(hi "$AWG_KEEPALIVE") + $(hi "$AWG_REKEY_TIMEOUT") )) ] \
	&& ok "таймеры AWG 3.1: рукопожатие чаще 180 с, RejectAfterTime позже смены ключей" || fail "таймеры AWG 3.1: пределы"

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
grep -q 'udp sport 51820 ip dscp != cs0 ip dscp set cs0' "$NFT_FILE" && ok "DSCP пакетов Туннеля обнуляется" || fail "DSCP Туннеля"
grep -q 'tcp flags syn / syn,rst' "$NFT_FILE" && ok "MSS: SYN и SYN-ACK без RST" || fail "MSS: флаги"

# udp_tos SPORT TOS — UDP-пакет на 127.0.0.1:9 с порта SPORT и байтом TOS (IP_TOS, hex).
# TOS — числом: строку setsockopt передал бы как байты.
udp_tos() {
	perl -MSocket -e 'socket(my $s, PF_INET, SOCK_DGRAM, 0) or die; setsockopt($s, 0, 1, hex($ARGV[1])) or die;
		bind($s, sockaddr_in($ARGV[0], INADDR_ANY)) or die; send($s, "x", 0, sockaddr_in(9, inet_aton("127.0.0.1"))) or die' "$1" "$2"
}
# packets ИМЯ — пакеты счётчика из проверочной таблицы t_dscp.
packets() { nft list counter inet t_dscp "$1" | awk '/packets/ { print $2 }'; }

# Загрузка правил в ядро и проверка, что они реально стоят.
if nft -f "$NFT_FILE"; then
	nft list chain ip truba_nat prerouting > "$STATE_DIR/chain.txt"
	grep -q 'dnat to 10.77.77.2' "$STATE_DIR/chain.txt" && ok "правила загружены в ядро" || fail "правила в ядре"
	# Что уходит после цепочки dscp: AF41 с ECT(0) с порта Туннеля — DSCP 0, ECN тот же;
	# с другого порта — как было.
	nft -f - <<-'EOF'
		table inet t_dscp {
			counter tun_clean { }
			counter tun_other { }
			counter other_af41 { }
			chain post {
				type filter hook postrouting priority filter; policy accept;
				udp sport 51820 ip dscp cs0 ip ecn ect0 counter name tun_clean
				udp sport 51820 ip dscp != cs0 counter name tun_other
				udp sport 51821 ip dscp af41 counter name other_af41
			}
		}
	EOF
	udp_tos 51820 0x8a; udp_tos 51821 0x88
	[ "$(packets tun_clean) $(packets tun_other) $(packets other_af41)" = "1 0 1" ] \
		&& ok "DSCP в ядре: у пакетов Туннеля 0, ECN не тронут, у остальных как был" \
		|| fail "DSCP в ядре: $(packets tun_clean) $(packets tun_other) $(packets other_af41)"
	nft delete table inet t_dscp
	nft delete table ip truba_nat; nft delete table inet truba_filter
else
	fail "nft -f"
fi

# Внешняя оболочка без conntrack, соседний порт по-прежнему отслеживается для DNAT.
ip addr add 203.0.113.10/32 dev lo
ip addr add 203.0.113.20/32 dev lo
ip link add truba-raw0 type veth peer name truba-raw1
ip link set truba-raw0 up; ip link set truba-raw1 up
WAN_IF=truba-raw0
write_nft && nft -f "$NFT_FILE"
nft -f - <<-'EOF'
	table inet raw_test {
		counter outer_in { }
		counter outer_out { }
		counter inner_nat { }
		chain pre {
			type filter hook prerouting priority -150; policy accept;
			iifname "truba-raw0" udp dport 51820 ct state untracked counter name outer_in
			iifname "lo" udp dport 51821 ct state new counter name inner_nat
		}
		chain out {
			type filter hook output priority -150; policy accept;
			oifname "lo" udp sport 51820 ct state untracked counter name outer_out
		}
	}
EOF
perl -MSocket -e '
	open(my $f, "<", "/sys/class/net/truba-raw1/ifindex") or die "$!"; my $i = <$f>; close($f);
	sub htons { unpack("S", pack("n", $_[0])) }
	socket(my $s, 17, SOCK_RAW, htons(0x0800)) or die "$!";
	my $ip = pack("CCnnnCCna4a4", 0x45, 0, 29, 1, 0, 64, 17, 0, inet_aton("203.0.113.20"), inet_aton("203.0.113.10"));
	my $sum = 0; $sum += $_ for unpack("n*", $ip); $sum = ($sum & 65535) + ($sum >> 16); $sum = ($sum & 65535) + ($sum >> 16);
	substr($ip, 10, 2) = pack("n", (~$sum) & 65535);
	my $frame = pack("H*", "ffffffffffff0200000000010800") . $ip . pack("nnnn", 40000, 51820, 9, 0) . "x";
	send($s, $frame, 0, pack("S! S! i! S! C C a8", 17, htons(0x0800), $i, 1, 0, 6, "\xff" x 6)) or die "$!";
'
for _ in $(seq 20); do
	nft list counter inet raw_test outer_in | grep -q 'packets 1 ' && break
	sleep 0.1
done
WAN_IF=lo
write_nft && nft -f "$NFT_FILE"
for p in 51820 51821; do
	perl -MSocket -e 'socket(my $s, PF_INET, SOCK_DGRAM, 0) or die; send($s, "x", 0, sockaddr_in($ARGV[0], inet_aton("203.0.113.10"))) or die' "$p"
done
perl -MSocket -e 'socket(my $s, PF_INET, SOCK_DGRAM, 0) or die; bind($s, sockaddr_in(51820, inet_aton("203.0.113.10"))) or die; send($s, "x", 0, sockaddr_in(9, inet_aton("203.0.113.20"))) or die'
raw_count() { nft list counter inet raw_test "$1" | awk '/packets/ {print $2}'; }
[ "$(raw_count outer_in) $(raw_count outer_out) $(raw_count inner_nat)" = "1 1 1" ] \
	&& ok "notrack: оболочка в обе стороны, соседний порт сохраняет conntrack" || fail "notrack: $(raw_count outer_in) $(raw_count outer_out) $(raw_count inner_nat)"
nft delete table inet raw_test
nft delete table ip truba_nat; nft delete table inet truba_filter
ip addr del 203.0.113.10/32 dev lo
ip addr del 203.0.113.20/32 dev lo
ip link del truba-raw0
WAN_IF=eth0

# sysctl: без загрузки nf_conntrack при старте systemd-sysctl пропускает ключи conntrack.
SD="$T/sysctl"; mkdir -p "$SD/etc" "$SD/lib"
SYSCTL_DIRS="$SD/etc $SD/lib"; SYSCTL_FILE="$SD/etc/90-truba.conf"; MODULES_FILE="$STATE_DIR/modules-load-truba.conf"
SYS_NET="$T/sys"; mkdir -p "$SYS_NET/eth0/queues/tx-0" "$SYS_NET/eth0/queues/rx-0"
modprobe() { :; }; sysctl() { :; }; tc() { echo "$*" >> "$STATE_DIR/tc.txt"; }
out=$(write_sysctl 2>&1)
grep -q 'nf_conntrack_max = 262144' "$SYSCTL_FILE" && ok "sysctl: nf_conntrack_max" || fail "sysctl nf_conntrack_max"
for setting in 'rmem_max = 16777216' 'wmem_max = 16777216' 'netdev_max_backlog = 16384' 'optmem_max = 65536' \
	'nf_conntrack_udp_timeout = 60' 'nf_conntrack_udp_timeout_stream = 180'; do
	grep -qF "$setting" "$SYSCTL_FILE" && ok "sysctl: $setting" || fail "sysctl: $setting"
done
grep -q 'net.ipv4.conf.all.send_redirects = 0' "$SYSCTL_FILE" && grep -q 'net.ipv6.conf.default.accept_redirects = 0' "$SYSCTL_FILE" \
	&& ok "sysctl: ICMP redirects отключены" || fail "sysctl: redirects"
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
# Следующим GRUB может загрузить и старое ядро: модуль нужен всем установленным.
rm "$MODULES_DIR/6.8.0-45-generic/updates/dkms/amneziawg.ko.zst"
out=$(kernel_module_check 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'нет для ядра 6.8.0-45-generic' <<< "$out" && grep -q repair-module <<< "$out" \
	&& ok "старое ядро без модуля — тоже предупреждение" || fail "старое ядро без модуля: $rc $out"
# repair-module: заголовки, DKMS, depmod — только для ядер без модуля.
(
	LOG="$T/repair"; : > "$LOG"
	pkg_available() { echo "avail $1" >> "$LOG"; return 0; }
	apt_get() { echo "apt-get $*" >> "$LOG"; }
	apt_update() { :; }
	dkms() { echo "dkms $*" >> "$LOG"; mkdir -p "$MODULES_DIR/$3/updates/dkms"; touch "$MODULES_DIR/$3/updates/dkms/amneziawg.ko.zst"; }
	depmod() { echo "depmod $*" >> "$LOG"; }
	modprobe() { :; }; uname() { echo 6.8.0-100-generic; }
	STATE="$T/none.env"
	out=$(cmd_repair_module 2>&1); rc=$?
	[ "$rc" -eq 0 ] && grep -qx 'apt-get install -y -qq linux-headers-6.8.0-45-generic' "$LOG" \
		&& grep -qx 'dkms autoinstall -k 6.8.0-45-generic' "$LOG" && grep -qx 'depmod -a 6.8.0-45-generic' "$LOG" \
		&& ! grep -q 6.8.0-100 "$LOG" && ok "repair-module: заголовки, DKMS и depmod только для ядра без модуля" \
		|| fail "repair-module: $rc $out"$'\n'"$(cat "$LOG")"
	rm "$MODULES_DIR/6.8.0-45-generic/updates/dkms/amneziawg.ko.zst"
	pkg_available() { return 1; }
	out=$(cmd_repair_module 2>&1); rc=$?
	[ "$rc" -ne 0 ] && grep -q 'заголовков нет в архиве' <<< "$out" && ok "repair-module: заголовков нет — понятная ошибка" || fail "repair-module без заголовков: $out"
)
touch "$MODULES_DIR/6.8.0-45-generic/updates/dkms/amneziawg.ko.zst"

# Конфиги AWG
AWG_PROTO=2; gen_params
VPS_PRIV=vpriv; VPS_PUB=vpub; RTR_PRIV=rpriv; RTR_PUB=rpub; PSK=psk
AWG_DIR="$STATE_DIR/awg"; AWG_CONF="$AWG_DIR/awg0.conf"; OUT_DIR="$STATE_DIR/out"; ROUTER_CONF="$OUT_DIR/router.conf"
write_awg_conf; write_router_conf
grep -q "^AllowedIPs = 10.77.77.2/32" "$AWG_CONF" && ok "VPS: пир — только Роутер" || fail "VPS AllowedIPs"
grep -q "^Endpoint = 203.0.113.10:51820" "$ROUTER_CONF" && ok "Роутер: Endpoint" || fail "Роутер Endpoint"
grep -q "^PersistentKeepalive = 25" "$ROUTER_CONF" && ok "Роутер: keepalive 25" || fail "keepalive"
grep -q "^MTU = 1380" "$ROUTER_CONF" && ok "Роутер: MTU 1380 при сети VPS 1500" || fail "MTU"
# MTU Туннеля — от сети VPS: пакет Туннеля с обёрткой (до 102 байт) помещается в неё целиком.
mtu_both() { grep -qx "MTU = $1" "$AWG_CONF" && grep -qx "MTU = $1" "$ROUTER_CONF"; }
if ip link add trubamtu0 type dummy 2>/dev/null; then
	WAN_IF=trubamtu0
	ip link set trubamtu0 mtu 1400; write_awg_conf; write_router_conf
	mtu_both 1298 && ok "сеть VPS 1400: MTU 1298 у обеих сторон (запас на S4 и добавку)" || fail "сеть 1400: $(grep '^MTU' "$ROUTER_CONF")"
	ip link set trubamtu0 mtu 9000; write_awg_conf; write_router_conf
	mtu_both 1380 && ok "сеть VPS 9000: MTU не больше 1380" || fail "сеть 9000: $(grep '^MTU' "$ROUTER_CONF")"
	ip link del trubamtu0
else
	# С одним NET_ADMIN модуль dummy не загрузить; его загружают стенды Роутера (tests/run.sh).
	echo "skip  MTU по сети VPS: нет модуля dummy на хосте"
fi
WAN_IF=nonexistent0; write_router_conf
grep -qx "MTU = 1380" "$ROUTER_CONF" && ok "интерфейса нет: MTU 1380" || fail "нет интерфейса: $(grep '^MTU' "$ROUTER_CONF")"
TUN_MTU=1320; write_awg_conf; write_router_conf
mtu_both 1320 && ok "MTU, заданный вручную, — у обеих сторон" || fail "ручной MTU: $(grep '^MTU' "$ROUTER_CONF")"
TUN_MTU=''
state_value_ok TUN_MTU 1300 && ! state_value_ok TUN_MTU 1400 && ! state_value_ok TUN_MTU 1200 && ! state_value_ok TUN_MTU 13a0 \
	&& ok "MTU вручную: только $MTU_MIN–$MTU_MAX" || fail "MTU вручную: пределы"
case "$( (main install --mtu 1500) 2>&1 )" in *"--mtu: число"*) ok "параметры: --mtu вне пределов";; *) fail "параметры: --mtu 1500";; esac
# MTU пути: самый большой пакет без фрагментации — двоичным поиском, потеря не занижает.
(
	ping_df() { [ "$2" -le 1452 ]; }
	[ "$(path_mtu 192.0.2.1 1028 1500)" = 1452 ] && ok "MTU пути: двоичный поиск (PPPoE 1452)" || fail "MTU пути: $(path_mtu 192.0.2.1 1028 1500)"
	ping_df() { [ "$2" -le 1500 ]; }
	[ "$(path_mtu 192.0.2.1 1028 1500)" = 1500 ] && ok "MTU пути: путь не уже сети VPS" || fail "MTU пути 1500"
	ping_df() { return 1; }
	! path_mtu 192.0.2.1 1028 1500 >/dev/null && ok "MTU пути: Роутер не отвечает — ошибка, а не 0" || fail "MTU пути без ответа"
	# Пакет ping_df — целиком: данных на 28 байт меньше.
	unset -f ping_df; eval "$(grep '^ping_df()' "$SCRIPT")"
	ping() { echo "$*" > "$T/ping"; }
	ping_df 192.0.2.1 1452; grep -q -- '-M do -s 1424 192.0.2.1' "$T/ping" && ok "MTU пути: ping без фрагментации, данные = размер − 28" || fail "ping: $(cat "$T/ping")"
	# Роутер не отвечает на ping — фрагменты по счётчикам ядра за интервал.
	PROC="$T/fproc"; mkdir -p "$PROC/net"
	fsnmp() { printf 'Ip: Forwarding ReasmReqds ReasmFails FragCreates\nIp: 1 %s 0 %s\n' "$1" "$2" > "$PROC/net/snmp"; }
	sleep() { fsnmp 0 400; }; fsnmp 0 100
	out=$(mtu_passive 30 1313 1298)
	grep -q 'нарезал при отправке 300' <<< "$out" && grep -q '1313 больше 1298' <<< "$out" \
		&& ok "MTU без ping: VPS режет пакеты — MTU Туннеля больше сети VPS" || fail "mtu_passive режет: $out"
	sleep() { fsnmp 50 100; }; fsnmp 0 100
	out=$(mtu_passive 30 1298 1298)
	grep -q 'приходят фрагментами' <<< "$out" && ! grep -q 'нарезал при отправке [1-9]' <<< "$out" \
		&& ok "MTU без ping: фрагменты от дома — путь уже MTU" || fail "mtu_passive от дома: $out"
	sleep() { :; }
	out=$(mtu_passive 30 1298 1298); grep -q 'фрагментов нет' <<< "$out" && ok "MTU без ping: фрагментов нет" || fail "mtu_passive чисто: $out"
)
WAN_IF=eth0; write_awg_conf; write_router_conf
[ "$(grep -c '^S[1-4] = ' "$ROUTER_CONF")" -eq 4 ] && ok "Роутер: S1–S4" || fail "S1-S4"
diff <(grep -E '^(S[1-4]|H[1-4]) = ' "$AWG_CONF") <(grep -E '^(S[1-4]|H[1-4]) = ' "$ROUTER_CONF") >/dev/null \
	&& ok "S1–S4 и H1–H4 совпадают у сторон" || fail "S/H различаются"
[ "$(stat -c %a "$ROUTER_CONF") $(stat -c %a "$AWG_CONF") $(stat -c %a "$AWG_DIR") $(stat -c %a "$OUT_DIR")" = "600 600 700 700" ] \
	&& ok "router.conf, awg0.conf и их каталоги доступны только root" || fail "права конфигов AWG"
! grep -qE '^(HeaderProtectionKey|DisableCookies|RandomTrailers|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts)' "$AWG_CONF" "$ROUTER_CONF" \
	&& ok "AWG 2.0: без параметров 3.1" || fail "AWG 2.0: лишние параметры 3.1"
grep -qxF "I1 = $I1_SRV" "$AWG_CONF" && grep -qxF "I1 = $I1" "$ROUTER_CONF" && [ "$I1" != "$I1_SRV" ] \
	&& ok "I1: у Роутера DNS-запрос, у Трубы — ответ" || fail "I1 в конфигах: $(grep -h '^I1' "$AWG_CONF" "$ROUTER_CONF")"
( I1_SRV=''; awg_conf | grep -qxF "I1 = $I1" ) && ok "I1: без ответа (прежняя установка) у Трубы — запрос" || fail "I1 без I1_SRV"

# Конфиги AWG 3.1: ключ защиты заголовков одинаковый, cookie-защита включена у обеих сторон,
# RandomTrailers — только по команде random-trailers.
AWG_PROTO=3; gen_params; HPK='aHBrLXRlc3Qta2V5LTMyLWJ5dGVzLWxvbmctLS0tLS0='; RANDOM_TRAILERS=0
write_awg_conf; write_router_conf
bad=0
for f in "$AWG_CONF" "$ROUTER_CONF"; do
	grep -qx "HeaderProtectionKey = $HPK" "$f" && grep -qx 'DisableCookies = off' "$f" && ! grep -q '^RandomTrailers' "$f" \
		|| { fail "AWG 3.1: $(basename "$f")"; bad=1; }
done
[ "$bad" -eq 0 ] && ok "AWG 3.1: HeaderProtectionKey и cookie-защита у обеих сторон, RandomTrailers выкл"
grep -qx 'ContentPaddingAddition = 0-15' "$AWG_CONF" && grep -qx 'ContentPaddingAddition = 0-15' "$ROUTER_CONF" \
	&& ok "AWG 3.1: добавка к пакетам 0–15 у обеих сторон" || fail "AWG 3.1: ContentPaddingAddition"
grep -qx 'PersistentKeepalive = 15-25' "$ROUTER_CONF" && ! grep -q '^PersistentKeepalive' "$AWG_CONF" \
	&& ok "AWG 3.1: keepalive Роутера — случайный 15–25 с, у Трубы его нет" || fail "AWG 3.1: keepalive: $(grep -h '^PersistentKeepalive' "$AWG_CONF" "$ROUTER_CONF")"
timers=$'RekeyAfterTime = 95-125\nRekeyTimeout = 5\nRejectAfterTime = 170-190\nKeepaliveTimeout = 8-14\nMaxHandshakeAttempts = 16-20'
[ "$(grep -E '^(Rekey|Reject|KeepaliveTimeout|MaxHandshake)' "$AWG_CONF")" = "$timers" ] \
	&& [ "$(grep -E '^(Rekey|Reject|KeepaliveTimeout|MaxHandshake)' "$ROUTER_CONF")" = "$timers" ] \
	&& ok "AWG 3.1: случайные таймеры у обеих сторон" || fail "AWG 3.1: таймеры: $(grep -hE '^(Rekey|Reject|Keepalive|Max)' "$AWG_CONF" "$ROUTER_CONF")"
grep -qx 'RekeyAfterTime = 95-125' "$T/probe" && grep -qx 'MaxHandshakeAttempts = 16-20' "$T/probe" \
	&& ok "протокол AWG 3.1: проба и с таймерами" || fail "проба AWG 3.1 без таймеров"
# Добавку модуль берёт вместо RandomTrailers: с ним её нет ни у одной стороны.
RANDOM_TRAILERS=1; write_awg_conf; write_router_conf
grep -qx 'RandomTrailers = on' "$AWG_CONF" && grep -qx 'RandomTrailers = on' "$ROUTER_CONF" \
	&& ! grep -q '^ContentPaddingAddition' "$AWG_CONF" "$ROUTER_CONF" \
	&& ok "AWG 3.1: RandomTrailers у обеих сторон, без добавки к пакетам" || fail "AWG 3.1: RandomTrailers"
STATE="$STATE_DIR/pipe.env"; save_state
( i1=$I1_SRV; unset I1_SRV; load_state; [ "$I1_SRV" = "$i1" ] ) && ok "pipe.env хранит I1 Трубы" || fail "pipe.env: I1_SRV"
( unset HPK RANDOM_TRAILERS; load_state; [ "$HPK" = 'aHBrLXRlc3Qta2V5LTMyLWJ5dGVzLWxvbmctLS0tLS0=' ] && [ "$RANDOM_TRAILERS" = 1 ] ) \
	&& ok "pipe.env хранит HeaderProtectionKey и RandomTrailers" || fail "pipe.env: HPK/RandomTrailers"
[ "$(stat -c %a "$STATE") $(stat -c %a "$STATE_DIR")" = "600 700" ] && ok "pipe.env и его каталог доступны только root" || fail "права pipe.env"
# pipe.env — данные: код в нём не исполняется, неизвестные поля пропускаются, плохие значения — отказ.
cp "$STATE" "$T/state.bak"
printf "AWG_VERSION='1.0'\n" >> "$STATE"
( load_state ) >/dev/null 2>&1 && ok "pipe.env: поле прежней версии пропускается" || fail "pipe.env: AWG_VERSION"
printf "SSH_PORT='\$(touch %s/pwned)'\n" "$T" >> "$STATE"
! ( load_state ) >/dev/null 2>&1 && [ ! -e "$T/pwned" ] && ok "pipe.env: подстановка команд не исполняется" || fail "pipe.env: исполнение кода"
cp "$T/state.bak" "$STATE"; echo "touch $T/pwned" >> "$STATE"
! ( load_state ) >/dev/null 2>&1 && [ ! -e "$T/pwned" ] && ok "pipe.env: строка-команда — отказ" || fail "pipe.env: команда"
cp "$T/state.bak" "$STATE"; chmod 666 "$STATE"
! ( load_state ) >/dev/null 2>&1 && ok "pipe.env: запись всем — отказ" || fail "pipe.env: права 666"
cp "$T/state.bak" "$STATE"; chmod 600 "$STATE"
# status не выводит ключи: awg show печатает ключ защиты заголовков открытым.
awg() { printf 'interface: awg0\n  private key: (hidden)\n  header protection key: aHBrLXNlY3JldA==\n\npeer: cHVi\n  preshared key: (hidden)\n'; }
timeout() { shift; "$@"; }
out=$(awg_show_masked)
! grep -q 'aHBrLXNlY3JldA' <<< "$out" && grep -q 'header protection key: (hidden)' <<< "$out" && grep -q 'peer: cHVi' <<< "$out" \
	&& ok "status: ключ защиты заголовков скрыт" || fail "status: $out"
unset -f awg timeout
[ "$(umask)" = 0022 ] && ok "запись ключей не меняет umask: юниты и конфиги остаются читаемыми" || fail "umask после записи ключей: $(umask)"
# random-trailers переключает на ходу и RandomTrailers, и добавку к пакетам: модуль берёт её вместо них.
awg() { echo "$*" >> "$T/awgset"; }
: > "$T/awgset"
out=$( (cmd_random_trailers off; cmd_random_trailers on) 2>&1 )
[ "$(cat "$T/awgset")" = $'set awg0 random-trailers off content-padding-addition 0-15\nset awg0 random-trailers on content-padding-addition 0' ] \
	&& grep -q 'Импорт .conf' <<< "$out" \
	&& ok "random-trailers: на ходу вместе с добавкой к пакетам, на Роутере — импорт router.conf" || fail "random-trailers: $(cat "$T/awgset") $out"
unset -f awg

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
AWG_DROPIN="$T/awg-dropin/10-truba.conf"
: > "$T/sysd"; AWG_CONF_CHANGED=0; setup_awg_service
grep -qx 'Requires=truba-pipe.service' "$AWG_DROPIN" && ok "Туннель (пакетный юнит): не поднимается без правил Трубы" || fail "drop-in awg-quick"
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
sshd() {
	case "$1" in
		-T) printf '%s\n' 'port 2222' 'port 52222' 'port 2222' 'addressfamily any' ;;
		-T\ *) printf '%s\n' 'port 2222' ;;
		*) printf '%s\n' 'port 2222' 'port 52222' 'port 2222' 'addressfamily any' ;;
	esac
}
[ "$(sshd_ports 52222)" = 2222 ] && [ "$(sshd_ports)" = "2222 52222" ] && ok "SSH: запасные — текущие порты sshd без нового" || fail "SSH: порты sshd: «$(sshd_ports 52222)»"
sshd() { case "$1" in -T) echo 'port 52222' ;; *) echo 'port 52222' ;; esac; }
[ -z "$(sshd_ports 52222)" ] && ok "SSH: sshd уже слушает только новый порт — запасных нет" || fail "SSH: только новый: «$(sshd_ports 52222)»"
sshd() { return 255; }
[ "$(sshd_ports)" = 22 ] && [ -z "$(sshd_ports 22)" ] && ok "SSH: sshd -T не ответил — запасной 22" || fail "SSH: без sshd -T: «$(sshd_ports)»"
unset -f sshd
# Без терминала — отказ до любых изменений установки.
out=$( (NO_CONFIRM=0 SSH_PORT=52222 PUB_IP=203.0.113.10 confirm_ssh 22) 2>&1 </dev/null )
grep -q 'нужен интерактивный терминал' <<< "$out" && ok "SSH: без терминала — ошибка до вопроса" || fail "SSH: без терминала: $out"

# Ключ root проверяется до установки пакетов: без него install выходит сразу.
out=$( (
	STATE="$T/none.env"
	systemd-detect-virt() { return 1; }
	have_key_login() { return 1; }
	install_packages() { echo "ПАКЕТЫ"; }
	NO_CONFIRM=1 cmd_install
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
	[ "$(unbound-checkconf -o num-threads)" = 1 ] && [ "$(unbound-checkconf -o minimal-responses)" = yes ] \
		&& ok "unbound: один поток и минимальные ответы" || fail "unbound: поток и ответы"
	for pair in outgoing-num-tcp:64 incoming-num-tcp:32 msg-cache-slabs:1 rrset-cache-slabs:1 infra-cache-slabs:1 key-cache-slabs:1 \
		serve-expired:yes serve-expired-ttl:86400 serve-expired-client-timeout:1800; do
		[ "$(unbound-checkconf -o "${pair%:*}")" = "${pair#*:}" ] && ok "unbound: $pair" || fail "unbound: $pair"
	done
	[ "$(stat -c %a "$UNBOUND_CONF")" = 644 ] && ok "unbound: конфиг читаем службой" || fail "unbound: права конфига"
	grep -qx '    forward-tls-upstream: yes' "$UNBOUND_CONF" \
		&& [ "$(grep -E '^    forward-addr:' "$UNBOUND_CONF" | xargs)" = "forward-addr: 1.1.1.1@853#cloudflare-dns.com forward-addr: 8.8.8.8@853#dns.google" ] \
		&& ok "unbound: к Cloudflare и Google — только по TLS, с проверкой имени сервера, по одному адресу" || fail "unbound: пересылка по TLS: $(grep forward-addr "$UNBOUND_CONF" | xargs)"
	# Выбор самого быстрого адреса залипает на Google (ADR 0013): промахи делятся между всеми адресами.
	[ "$(unbound-checkconf -o fast-server-permil)" = 0 ] \
		&& ok "unbound: промахи — всем адресам, без выбора самого быстрого" || fail "unbound: fast-server-permil $(unbound-checkconf -o fast-server-permil)"
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

# status: строки про unbound — из его счётчиков и замеров (вывод снят с настоящей Трубы). Без unbound
# или без замеров status не падает и под set -e: он печатает и всё остальное.
unbound-control() {
	case $1 in
		stats_noreset) printf '%s\n' total.num.queries=9316 total.num.cachehits=522 total.recursion.time.avg=0.036148 \
			total.recursion.time.median=0.0159878 num.answer.rcode.NOERROR=8020 num.answer.rcode.SERVFAIL=3 ;;
		dump_infra) printf '%s\n' '1.0.0.1@853 . ttl 786 ping 26 var 38 rtt 178 rto 178 tA 0 tAAAA 0 tother 0' \
			'8.8.8.8@853 . ttl 770 ping 11 var 7 rtt 50 rto 50 tA 0 tAAAA 0 tother 0' \
			'1.1.1.1@853 . ttl 871 ping 14 var 79 rtt 330 rto 330 tA 0 tAAAA 0 tother 0' ;;
	esac
}
out=$(set -Eeuo pipefail; unbound_status; echo конец)
[ "$out" = "DNS для Роутера (unbound на 10.77.77.1): запросов 9316, из кэша 5 %, ответ серверов — медиана 16 мс, SERVFAIL 3
Серверы пересылки (замер unbound): 8.8.8.8 — 11 мс, 1.1.1.1 — 14 мс, 1.0.0.1 — 26 мс
конец" ] && ok "status: unbound — запросы, кэш, медиана, серверы по замеру" || fail "status unbound: $out"
unbound-control() { [ "$1" = stats_noreset ] && printf '%s\n' total.num.queries=0; [ "$1" = stats_noreset ]; }
out=$(set -Eeuo pipefail; unbound_status; echo конец)
[ "$out" = "DNS для Роутера (unbound на 10.77.77.1): запросов 0, из кэша 0 %, ответ серверов — медиана 0 мс, SERVFAIL 0
конец" ] && ok "status: unbound без замеров серверов" || fail "status unbound без замеров: $out"
unbound-control() { return 1; }
out=$(set -Eeuo pipefail; unbound_status; echo конец)
[ "$out" = конец ] && ok "status: unbound не отвечает — строк нет, status идёт дальше" || fail "status без unbound: $out"
unset -f unbound-control

# diag: разница счётчиков за интервал, подсказки только по наблюдениям.
(
	PROC="$T/proc"; SYS_NET="$T/dsys"; WAN_IF=eth9; AWG_IF=awg9
	mkdir -p "$PROC/net/stat" "$SYS_NET/eth9/statistics" "$SYS_NET/awg9/statistics"
	snap() {   # snap rx_drop softnet_drop steal user idle udp_rcvbuf — накопленные значения, как в ядре
		for d in eth9 awg9; do for f in rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors; do echo 0 > "$SYS_NET/$d/statistics/$f"; done; done
		echo 3000 > "$SYS_NET/eth9/statistics/rx_packets"; echo "$1" > "$SYS_NET/eth9/statistics/rx_dropped"
		printf 'Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors\nUdp: 10 0 0 10 %s 0\n' "$6" > "$PROC/net/snmp"
		printf '00000010 %08x 00000000 0\n00000010 00000000 00000000 0\n' "$2" > "$PROC/net/softnet_stat"
		# cpu: user nice system idle iowait irq softirq steal
		printf 'cpu  %d 0 0 %d 0 0 10 %d\ncpu0 %d 0 0 %d 0 0 10 %d\ncpu1 0 0 0 1000 0 0 0 0\n' "$4" "$5" "$3" "$4" "$5" "$3" > "$PROC/stat"
		printf 'entries searched found new invalid ignore delete delete_list insert insert_failed drop early_drop\n' > "$PROC/net/stat/nf_conntrack"
		printf '00000001 0 0 0 0 0 0 0 0 00000000 00000000 00000000\n' >> "$PROC/net/stat/nf_conntrack"
	}
	tc() { printf 'qdisc mq 0: root\n Sent 1 bytes 1 pkt (dropped 0, overlimits 0 requeues 0)\nqdisc fq_codel 0: parent :1\n  maxpacket 1 drop_overlimit 0 new_flow_count 1\n'; }
	snap 0 0 0 100 900 0; diag_snapshot > "$T/da"
	snap 0 0 0 200 1800 0; diag_snapshot > "$T/db"
	out=$(diag_delta "$T/da" "$T/db" | diag_report 10 '0% 30.1 31.0 35.2' '0% 1.1 1.2 1.5')
	grep -q 'Потерь и упоров не найдено' <<< "$out" && grep -q 'RTT Туннеля (до Роутера): 30.1 / 31.0 / 35.2' <<< "$out" \
		&& ok "diag: без потерь — без подсказок, RTT Туннеля и VPS" || fail "diag спокойный: $out"
	snap 0 0 0 0 1000 0; diag_snapshot > "$T/da"
	snap 5 7 150 900 1020 3; diag_snapshot > "$T/db"
	out=$(diag_delta "$T/da" "$T/db" | diag_report 10 '' '100% - - -')
	grep -q 'steal' <<< "$out" && grep -q 'netdev_max_backlog' <<< "$out" && grep -q 'rmem_max' <<< "$out" \
		&& grep -q 'ядро cpu0 занято' <<< "$out" && grep -q 'нет ответа (потери 100%)' <<< "$out" && grep -q 'ping не запускался' <<< "$out" \
		&& ! grep -q 'Потерь и упоров не найдено' <<< "$out" \
		&& ok "diag: steal, упор в ядро, потери разбора и UDP-буфера — подсказки" || fail "diag с потерями: $out"
	# Как на реальном VPS: лимит разбора срабатывал, но без потерь; Роутер на ping из Туннеля не отвечает.
	out=$(printf '%s\n' softnet.squeeze\ 590 softnet.dropped\ 0 | diag_report 60 '100% - - -' '0% 3.6 3.8 6.7')
	grep -q 'без потерь' <<< "$out" && ! grep -q netdev_budget <<< "$out" && grep -q 'Потерь и упоров не найдено' <<< "$out" \
		&& grep -q 'вход закрыт' <<< "$out" && ok "diag: лимит разбора без потерь и молчащий Роутер — не тревога" || fail "diag squeeze: $out"
	out=$(printf '%s\n' cpu.total\ 1000 cpu.steal\ 69 | diag_report 60 '' '')
	grep -q 'только если под нагрузкой растёт RTT' <<< "$out" && ! grep -q '^! steal' <<< "$out" \
		&& ok "diag: steal 6,9 % — к сведению, не тревога" || fail "diag steal 6.9: $out"
	printf '%s\n' 'PING 10.77.77.2 (10.77.77.2) 56(84) bytes of data.' '' '--- 10.77.77.2 ping statistics ---' \
		'30 packets transmitted, 29 received, 3.33333% packet loss, time 29040ms' 'rtt min/avg/max/mdev = 30.123/31.456/40.789/1.234 ms' > "$T/pingout"
	[ "$(ping_summary "$T/pingout")" = '3.33333% 30.123 31.456 40.789' ] && ok "diag: разбор итога ping" || fail "ping_summary: $(ping_summary "$T/pingout")"
)
case "$( (main diag 3) 2>&1 )" in *"от 5 до 600"*) ok "параметры: diag — длительность в пределах";; *) fail "параметры: diag 3";; esac

# Транзакция: снимок файлов до изменений, откат возвращает их, а созданные — удаляет.
(
	TXN_DIR="$T/txn"; OWNED="$T/owned.env"; AWG_DROPIN="$T/awg-dropin2/10-truba.conf"
	SSHD_DROPIN="$T/txn-sshd.conf"; NFT_FILE="$T/txn.nft"; PIPE_UNIT="$T/txn-pipe.service"
	AWG_CONF="$T/txn-awg0.conf"; ROUTER_CONF="$T/txn-router.conf"; STATE="$T/txn-pipe.env"
	systemctl() {
		echo "$*" >> "$T/txn-sysd"
		case $1 in
			is-active|is-enabled) [ "$2" = -q ] && [ "${3:-}" = truba-pipe.service ] && [ "${PIPE_WAS:-0}" = 1 ] ;;
			cat) return 0 ;;
			*) return 0 ;;
		esac
	}
	nft() { echo "$*" >> "$T/txn-nft"; }
	ssh_restart() { echo restart >> "$T/txn-ssh"; }
	ufw() { echo "$*" >> "$T/txn-ufw"; }
	echo 'Port 50022' > "$SSHD_DROPIN"; echo old > "$AWG_CONF"; rm -f "$PIPE_UNIT" "$NFT_FILE"
	PIPE_WAS=0 txn_begin
	echo 'Port 50022' > "$SSHD_DROPIN.new"; echo 'Port 51022' > "$SSHD_DROPIN"; echo new > "$AWG_CONF"
	echo unit > "$PIPE_UNIT"; echo rules > "$NFT_FILE"; touch "$TXN_DIR/ufw-off"
	txn_restore
	[ "$(cat "$SSHD_DROPIN")" = 'Port 50022' ] && [ "$(cat "$AWG_CONF")" = old ] && [ ! -e "$PIPE_UNIT" ] && [ ! -e "$NFT_FILE" ] \
		&& [ ! -e "$TXN_DIR" ] && grep -q 'delete table inet truba_filter' "$T/txn-nft" && grep -qx 'disable truba-pipe.service' "$T/txn-sysd" \
		&& grep -q 'enable' "$T/txn-ufw" && [ -s "$T/txn-ssh" ] \
		&& ok "откат: прежние SSH и конфиги, новые файлы удалены, правила сняты, ufw включён" \
		|| fail "откат: $(cat "$SSHD_DROPIN" "$AWG_CONF" 2>&1; ls "$T" | grep txn)"
	# Правила работали до запуска — откат загружает прежние, а не снимает их.
	echo old-rules > "$NFT_FILE"; echo unit > "$PIPE_UNIT"; : > "$T/txn-nft"
	PIPE_WAS=1 txn_begin
	echo new-rules > "$NFT_FILE"
	PIPE_WAS=1 txn_restore
	[ "$(cat "$NFT_FILE")" = old-rules ] && grep -qxe "-f $NFT_FILE" "$T/txn-nft" && ! grep -q delete "$T/txn-nft" \
		&& ok "откат: работавшие правила загружаются прежними" || fail "откат прежних правил: $(cat "$T/txn-nft")"
	# Снимок без списка файлов (оборвался при записи) просто удаляется.
	mkdir -p "$TXN_DIR"; echo junk > "$TXN_DIR/1"; echo new-rules > "$NFT_FILE"
	txn_restore
	[ ! -e "$TXN_DIR" ] && [ "$(cat "$NFT_FILE")" = new-rules ] && ok "откат: неполный снимок не применяется" || fail "неполный снимок"
	# Подтверждение: снимок удаляется, выключенный ufw записывается для uninstall.
	txn_begin; touch "$TXN_DIR/ufw-off"
	txn_commit
	[ ! -e "$TXN_DIR" ] && grep -qx "UFW_DISABLED='1'" "$OWNED" && grep -q "stop $ROLLBACK_UNIT.timer" "$T/txn-sysd" \
		&& ok "подтверждение: снимок удалён, таймер остановлен, выключенный ufw записан" || fail "txn_commit: $(cat "$OWNED")"
	# Выход по ошибке посреди транзакции — откат сразу (в основном процессе скрипта).
	txn_begin; echo broken > "$AWG_CONF"
	TXN_DIR=$TXN_DIR AWG_CONF=$AWG_CONF bash -c '
		source "$1"; TXN_DIR=$2; AWG_CONF=$3
		systemctl() { :; }; nft() { :; }; ssh_restart() { :; }
		TXN_ACTIVE=1; trap txn_on_exit EXIT; exit 1' _ "$SCRIPT" "$TXN_DIR" "$AWG_CONF" 2>/dev/null
	[ "$(cat "$AWG_CONF")" = old ] && [ ! -e "$TXN_DIR" ] && ok "ошибка или обрыв сессии — откат сразу" || fail "откат при выходе: $(cat "$AWG_CONF")"
)

# Таймер отката — отдельный юнит systemd с копией скрипта: переживает гибель установщика.
(
	TXN_DIR="$T/txn-timer"; mkdir -p "$TXN_DIR"
	systemd-run() { echo "$*" > "$T/sdrun"; }
	systemctl() { :; }
	rollback_timer_start
	grep -q -- "--unit=truba-rollback --on-active=${ROLLBACK_DELAY}s" "$T/sdrun" && grep -q "$TXN_DIR/install-vps.sh txn-rollback" "$T/sdrun" \
		&& cmp -s "$TXN_DIR/install-vps.sh" "$SCRIPT" && [ "$ROLLBACK_DELAY" -gt "$CONFIRM_TIMEOUT" ] \
		&& ok "таймер отката: копия скрипта, срабатывает позже окна подтверждения" || fail "таймер отката: $(cat "$T/sdrun")"
	# Без снимка таймеру делать нечего.
	rm -rf "$TXN_DIR"; txn_restore() { echo RESTORE; }
	out=$( (cmd_txn_rollback) 2>&1 ); [ -z "$out" ] && ok "таймер отката: изменения подтверждены — ничего не делает" || fail "txn-rollback: $out"
	mkdir -p "$TXN_DIR"; touch "$TXN_DIR/manifest"
	out=$( (cmd_txn_rollback) 2>&1 ); grep -q RESTORE <<< "$out" && ok "таймер отката: не подтверждено — откат" || fail "txn-rollback: $out"
)

# Исходное состояние для uninstall пишется один раз и только у новой установки.
(
	OWNED="$T/owned2.env"; PIPE_UNIT="$T/none.service"; rm -f "$OWNED" "$PIPE_UNIT"
	systemctl() { [ "$*" = "is-enabled -q unbound" ]; }
	VPS_PRIV='' record_owned
	grep -qx "UNBOUND_PREEXISTING='1'" "$OWNED" && grep -qx "RESOLVCONF_ENABLED='0'" "$OWNED" && grep -qx "UFW_DISABLED='0'" "$OWNED" \
		&& ok "исходное состояние: unbound был включён до Трубы" || fail "record_owned: $(cat "$OWNED")"
	systemctl() { return 1; }
	VPS_PRIV='' record_owned
	grep -qx "UNBOUND_PREEXISTING='1'" "$OWNED" && ok "исходное состояние: не перезаписывается повторным install" || fail "record_owned повторно"
	rm -f "$OWNED"; VPS_PRIV=a2V5 record_owned
	grep -qx "UNBOUND_PREEXISTING=''" "$OWNED" && ok "исходное состояние: у Трубы прежней версии — неизвестно" || fail "record_owned старой: $(cat "$OWNED")"
)

# Чужой awg0.conf первая установка не перезаписывает.
(
	AWG_CONF="$T/foreign.conf"; VPS_PRIV=''
	echo '[Interface]' > "$AWG_CONF"
	! ( check_foreign_awg_conf ) 2>/dev/null && ok "чужой awg0.conf — отказ" || fail "чужой awg0.conf"
	echo '# Труба: Туннель к Роутеру' > "$AWG_CONF"
	( check_foreign_awg_conf ) && ok "свой awg0.conf — продолжение" || fail "свой awg0.conf"
)
# Параметры: порт без значения или не число — понятная ошибка до любых изменений, а не
# «unbound variable» и не отказ nftables посреди установки.
arg_err() { ( main install "$@" ) 2>&1 >/dev/null; }
case "$(arg_err --ssh-port)" in *"укажите номер порта"*) ok "параметры: порт без значения";; *) fail "параметры: порт без значения: $(arg_err --ssh-port)";; esac
case "$(arg_err --awg-port 70000)" in *"неверный номер порта"*) ok "параметры: порт вне 1–65535";; *) fail "параметры: порт вне 1–65535: $(arg_err --awg-port 70000)";; esac
case "$(arg_err --ssh-port 22x)" in *"неверный номер порта"*) ok "параметры: порт не число";; *) fail "параметры: порт не число: $(arg_err --ssh-port 22x)";; esac

echo
# FAILS — ошибки до появления $T; дальше каждая — строка в файле, в том числе из подоболочек.
FAILS=$((FAILS + $(cat "$T/fails" 2>/dev/null | wc -l)))
[ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"
exit "$FAILS"
