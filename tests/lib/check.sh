#!/bin/sh
# Общие функции проверок на стенде Роутера (busybox sh). Подключается: . /repo/tests/lib/check.sh

set -u
exec 3>&1   # настоящий вывод: check прячет вывод команд в /dev/null
FAILS=0
CHECK_T0=$(date +%s)

ok()      { echo "ok    $*"; }
fail()    { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
section() { echo "== $* [+$(( $(date +%s) - CHECK_T0 )) с]"; }
# check ИМЯ cmd… — проверка; вывод команды прячется. Составное условие с функциями отсюда —
# через eval в одинарных кавычках: в «sh -c» этих функций нет.
check()   { name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }
# Итог части: код возврата — число провалов.
finish()  { echo; echo "за $(( $(date +%s) - CHECK_T0 )) с"; [ "$FAILS" -eq 0 ] && echo "ALL OK" || echo "$FAILS FAILED"; exit "$FAILS"; }

# wait_for N cmd… — ждать до N секунд, пока команда не выполнится успешно.
wait_for() {
	n=$1; shift
	while ! "$@" >/dev/null 2>&1; do
		[ "$n" -gt 0 ] || return 1
		sleep 1; n=$((n - 1))
	done
}
# wait_pid N PID — ждать до N секунд, пока процесс не завершится.
wait_pid() {
	t=$1
	while [ "$t" -gt 0 ] && kill -0 "$2" 2>/dev/null; do sleep 1; t=$((t - 1)); done
	! kill -0 "$2" 2>/dev/null
}

# Процессы apply / update-lists / rollback-lists и rc.common Трубы. Скобки в шаблонах —
# чтобы pgrep не находил собственную обёртку sh -c, в командной строке которой есть шаблон.
busy() { pgrep -f '/usr/sbin/truba [aur]'; pgrep -f 'init[.]d/truba'; }
idle() { [ -z "$(busy)" ]; }
# Снять зависшие процессы, чтобы следующие проверки не повисли следом.
unstick() { for p in $(busy) $(pgrep -f 'flock 1000'); do kill "$p" 2>/dev/null; done; return 0; }

# bounded N cmd… — шаг не дольше N секунд. Если повис — кто чего ждёт, блокировки, журнал,
# и снять, чтобы часть дошла до конца, а не обрывалась по тайм-ауту CI.
bounded() {
	n=$1; shift
	"$@" & bp=$!
	wait_pid "$n" "$bp" && { wait "$bp"; return; }
	{
	echo "TIMEOUT: $*"
	for d in /proc/[0-9]*; do
		c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null); [ -n "$c" ] || continue
		echo "  ${d#/proc/} $(cut -d' ' -f3 "$d/stat") wchan=$(cat "$d/wchan" 2>/dev/null): $(echo "$c" | cut -c1-110)"
	done
	echo "  locks:"; sed 's/^/    /' /proc/locks
	# logread читает журнал через ubus: если встали procd или ubusd, он висит и сам.
	logread > /tmp/bounded.log 2>&1 & lp=$!
	wait_pid 5 "$lp" || { kill "$lp" 2>/dev/null; echo "    (logread не ответил за 5 с)"; }
	tail -25 /tmp/bounded.log | cut -c1-200 | sed 's/^/    /'
	} >&3 2>&3
	kill "$bp" 2>/dev/null; unstick
	return 124
}

# ---- служба ----

APPLIED=/var/run/truba/applied.json
applied() { jsonfilter -i "$APPLIED" -e "$1" 2>/dev/null; }
no_error() { ! grep -q '"error"' "$APPLIED"; }
# reload и проверка, что он завершился за 90 с. Применение синхронное: после возврата правила
# уже в ядре, а mosdns procd перезапускает сам — его ждут проверки, которым он нужен.
reload() { check "reload${1:+: $1}" bounded 90 /etc/init.d/truba reload; }
dns_port() { uci -q get truba.dns.port || echo 5335; }
mosdns_up() { netstat -lnu 2>/dev/null | grep -q "127.0.0.1:${1:-$(dns_port)} "; }

# ---- nftables ----

in_set() { nft list set inet truba "$1" 2>/dev/null | grep -qi -- "$2"; }
bytes() { nft list counter inet truba "$1" 2>/dev/null | sed -n 's/.*bytes \([0-9]*\).*/\1/p'; }
gt0() { [ "$(bytes "$1")" -gt 0 ] 2>/dev/null; }
# Решение по умолчанию в classify: последняя строка цепочки ставит метку Режима.
mode_mark() { nft list chain inet truba classify | grep -E 'meta mark set' | tail -1 | grep -oE '0x000[12]0000$'; }

# ---- сеть стенда (tests/router/stand.sh) ----

# Входящее из интернета через Туннель: 203.0.113.77 → 10.77.77.2:48080 → DNAT → lanhost:8080.
# Ответ доходит, только если Труба отправила его обратно в Туннель, а не в «интернет».
probe() { ip netns exec vps ucode /repo/tests/lib/tcp_probe.uc client 203.0.113.77 10.77.77.2 48080; }
# Устройство домашней сети → HOST:PORT.
lan_tcp() { ip netns exec lanhost ucode /repo/tests/lib/tcp_probe.uc client 192.168.1.50 "$1" "$2"; }
# Свой UDP Роутера (с меткой, если задана) → сервер за Туннелем; печатает, кто ответил.
udp_out() { ucode /repo/tests/lib/udp_probe.uc client 203.0.113.77 40001 "$@"; }
