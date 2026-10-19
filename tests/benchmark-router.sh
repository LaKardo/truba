#!/bin/sh
# Запускать на Роутере до/после обновления: sh benchmark-router.sh [число повторов].
# Не применяет настройки; API может обновить диагностические кэши в RAM.
set -eu
N=${1:-10}
case "$N" in ''|*[!0-9]*) echo 'Число повторов должно быть целым' >&2; exit 1 ;; esac
[ "$N" -ge 1 ] && [ "$N" -le 100 ] || exit 1
echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ) repeats=$N"
uname -a
grep -E 'MemTotal|MemAvailable|SwapTotal' /proc/meminfo
bench() {
	name=$1; shift
	echo "=== $name"
	i=0
	while [ "$i" -lt "$N" ]; do
		# Измеряется клиент ubus: CPU/RSS процесса rpcd сюда не входят.
		/usr/bin/time -f 'elapsed=%e user=%U system=%S rss_kib=%M' "$@" >/dev/null
		i=$((i + 1))
	done
}
bench status ubus call truba status '{}'
bench status-cached ubus call truba status '{"cached":true}'
bench dns ubus call truba status '{"part":"dns"}'
bench rules ubus call truba status '{"part":"rules"}'
bench devices ubus call truba devices '{}'
bench devices-lite ubus call truba devices '{"lite":true}'
bench sets ubus call truba sets '{}'
echo '=== response-bytes'
ubus call truba devices '{}' | wc -c
ubus call truba devices '{"lite":true}' | wc -c
