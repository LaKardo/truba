#!/bin/sh
# История скорости (ADR 0010): процесс truba stats под procd пишет точки раз в 5 с без браузера,
# rpcd отдаёт их, перезапуск процесса продолжает историю, новый отсчёт счётчиков — разрыв.
# Расчёт точек, минут, сроков и выборку rates проверяет часть units.
. /repo/tests/router/stand.sh

# Сводка файла истории или ответа rates: 1 — точек, 2 — время первой, 3 — время последней,
# 4 — точек со скоростью, 5 — шаг; среди точек новее ARGV[1]: 6 — наибольшая скорость
# Туннеля от устройств, 7 — разрывов.
cat > /tmp/rates.uc <<-'EOF'
	import { readfile } from 'fs';
	let d = json(readfile(ARGV[0]) ?? '{}'), p = d.points ?? [], after = int(ARGV[1] ?? 0);
	let up = 0, gaps = 0;
	for (let x in p) {
		if (x[0] <= after)
			continue;
		if (length(x) == 1)
			gaps++;
		else if ((x[2] ?? 0) > up)
			up = x[2];
	}
	printf('%d %d %d %d %d %d %d\n', length(p), p[0]?.[0] ?? 0, p[length(p) - 1]?.[0] ?? 0,
		length(filter(p, (x) => length(x) > 1)), d.step ?? 0, up, gaps);
EOF
rf() { ucode /tmp/rates.uc "$2" "${3:-0}" 2>/dev/null | cut -d' ' -f"$1"; }   # rf ПОЛЕ ФАЙЛ [НОВЕЕ]
R=/var/run/truba/rates.json
# after_tick — дождаться очередного замера и напечатать время его точки. Действие сразу после
# него целиком попадает в следующую точку, новее этого времени, а всё прежнее — в точки не новее.
new_point() { [ "$(rf 3 $R)" -gt "$P0" ] 2>/dev/null; }
after_tick() { P0=$(rf 3 $R); wait_for 7 new_point; rf 3 $R; }

section "запись без браузера"
running() { ubus call service list '{"name":"truba"}' | jsonfilter -e '@.truba.instances.stats.running' | grep -q true; }
check "процесс stats запущен procd" running
has_rates() { [ "$(rf 4 $R)" -ge 2 ] 2>/dev/null; }
check "точки со скоростью — в /var/run (оперативная память), раз в 5 с" eval 'wait_for 15 has_rates && [ "$(rf 5 $R)" = 5 ]'
# 1.2.3.4 нет ни в одной Категории: по Режиму «Всё в туннель» — через Туннель на сервер в netns vps.
ip -n vps addr add 1.2.3.4/32 dev lo
ip netns exec vps ucode /repo/tests/lib/tcp_probe.uc server 48081 >/dev/null 2>&1 &
wait_for 5 lan_tcp 1.2.3.4 48081
T0=$(after_tick)
for i in 1 2 3; do lan_tcp 1.2.3.4 48081 >/dev/null 2>&1; done
tun_seen() { [ "$(rf 6 $R "$T0")" -gt 0 ] 2>/dev/null; }
check "скорость Туннеля от устройств видна в следующей точке" wait_for 15 tun_seen
# История по устройствам (ADR 0018) — тем же процессом, в том же каталоге в RAM.
D=/var/run/truba/devices.json
dev_f() { jsonfilter -i $D -e "@.devices['192.168.1.50'].$1" 2>/dev/null; }
dev_seen() { [ -n "$(dev_f last)" ]; }
check "devices.json: устройство с трафиком, в RAM" wait_for 15 dev_seen
# Без таблицы (Труба останавливается) счётчиков устройств нет, а сообщения nft не уходят в
# stderr процесса stats: procd записал бы их в журнал как daemon.err. В netns lanhost таблицы нет.
cat > /tmp/devc.uc <<-'EOF'
	import * as S from 'truba.state';
	let c = S.dev_counters();
	print(c == null ? 'null' : type(c), '\n');
EOF
devc() { "$@" ucode -L '/usr/share/ucode/*.uc' /tmp/devc.uc 2>/tmp/devc.err; }   # devc [ip netns exec …]
check "счётчики устройств: объект, stderr пуст" eval '[ "$(devc)" = object ] && [ ! -s /tmp/devc.err ]'
check "счётчики устройств без таблицы: null, stderr пуст" eval '[ "$(devc ip netns exec lanhost)" = null ] && [ ! -s /tmp/devc.err ]'
# rpcd devices: устройство из истории — с MAC соседа, зоной его интерфейса и скоростью.
ubus call truba devices > /tmp/d.json
dj() { jsonfilter -i /tmp/d.json -e "@.devices[@.ip='192.168.1.50'].$1" 2>/dev/null; }
LH_MAC="$(ip -n lanhost link show lh0 | awk '/link\/ether/ { print $2 }')"
check "rpcd devices: зона lan, MAC соседа, источник neigh, скорость есть" \
	eval '[ "$(dj zone)" = lan ] && [ "$(dj mac)" = "$LH_MAC" ] && [ "$(dj source)" = neigh ] && [ -n "$(dj rate)" ]'
# Сотни чужих адресов в наборе (подменённые источники, большая mesh-сеть): список ограничен, ответ
# ubus быстрый — интерфейс адресов без соседа ищется одним вызовом ip, а не процессом на адрес.
nft add element inet truba dv_tunnel_up "{ $(seq 0 299 | awk '{ printf "%s10.201.%d.%d counter packets 1 bytes 100", (NR > 1 ? "," : ""), int($1 / 256), $1 % 256 }') }"
many_seen() { [ "$(grep -o '"10\.201\.[0-9]*\.[0-9]*": {"seen' $D | wc -l)" -ge 300 ]; }
wait_for 15 many_seen
T0=$(date +%s); ubus -t 20 call truba devices > /tmp/d2.json; T1=$(date +%s)
check "300 чужих адресов: devices отвечает не дольше 3 с, в списке не больше 256" \
	eval '[ $((T1 - T0)) -le 3 ] && [ "$(jsonfilter -i /tmp/d2.json -e "@.devices[*].ip" | wc -l)" -le 256 ]'
ubus call truba rates '{"span":600}' > /tmp/r.json
check "rpcd rates: время Роутера, точки за 10 минут" eval '[ "$(jsonfilter -i /tmp/r.json -e "@.now")" -ge "$T0" ] && [ "$(rf 4 /tmp/r.json)" -ge 2 ]'

section "перезапуск процесса продолжает историю"
F0="$(rf 2 $R)"; L0="$(rf 3 $R)"; S0="$(dev_f seen)"
kill "$(pgrep -f 'truba stat[s]')"   # procd перезапустит через 5 с
newer() { [ "$(rf 3 $R)" -gt "$L0" ] 2>/dev/null; }
check "процесс перезапущен procd, история та же, без разрыва" eval 'wait_for 20 newer && [ "$(rf 2 $R)" = "$F0" ] && [ "$(rf 7 $R "$L0")" = 0 ]'
check "история устройства продолжена после перезапуска" eval '[ -n "$S0" ] && [ "$(dev_f seen)" = "$S0" ]'

section "счётчики начаты заново — разрыв, а не скачок"
T1=$(after_tick)
sed -i 's/"counters_since": *[0-9]*/"counters_since": 1/' "$APPLIED"
gap_after() { [ "$(rf 7 $R "$T1")" -ge 1 ] 2>/dev/null; }
check "в истории разрыв" wait_for 15 gap_after

finish
