#!/bin/sh
# Туннель: «Проверить NAT» (STUN через Туннель), «Проверка Туннеля» (три размера пакетов),
# долгие проверки через rpcd в фоне, контроль Туннеля (задержка, окно проверок, крупные
# пакеты, проверка NAT после подъёма, перезапуск с новым кодом, устаревшая запись).
. /repo/tests/router/stand.sh

section "Проверка NAT: STUN через Туннель"
# Два STUN-сервера в netns vps отвечают IP Трубы и портом источника; .83 и .84 молчат.
# По очереди молчащие стоили бы по 4,5 с каждый, разом — одно окно повторов.
# Молчащие — первыми в списке: ответ должен достаться своему серверу, а не первому ждущему.
for a in 81 82; do
	ip -n vps addr add 203.0.113.$a/32 dev lo
	ip netns exec vps ucode /repo/tests/lib/stun_server.uc 203.0.113.$a 3478 198.51.100.2 >/dev/null 2>&1 &
done
for a in 83 84 81 82; do uci add_list truba.main.stun="203.0.113.$a:3478"; done
uci commit truba
T0=$(date +%s); truba nat-test > /tmp/nat.json; T1=$(date +%s)
nat() { jsonfilter -i /tmp/nat.json -e "$1"; }
check "ответили два сервера из четырёх" test "$(nat @.answered)" = 2
check "ответ записан своему серверу, молчащие — тайм-аут" eval '[ "$(nat "@.servers[0].error")" = timeout ] && [ "$(nat "@.servers[1].error")" = timeout ] && [ -n "$(nat "@.servers[2].mapped.port")" ] && [ -n "$(nat "@.servers[3].mapped.port")" ]'
check "внешний IP — IP Трубы, порт сохранён, отображение одинаково, итог OK" eval '[ "$(nat @.ip_is_vps)" = true ] && [ "$(nat @.port_preserved)" = true ] && [ "$(nat @.consistent)" = true ] && [ "$(nat @.ok)" = true ]'
check "серверы опрашиваются разом (не дольше 7 с, было $((T1 - T0)) с)" test $((T1 - T0)) -le 7
check "status: итог для «Обзора»" test "$(truba status | jsonfilter -e '@.nat.ok')" = true

section "Проверка Туннеля: пакеты трёх размеров"
MTU="$(cat /sys/class/net/awg0/mtu)"
truba tunnel-test > /tmp/tt.json
tt() { jsonfilter -i /tmp/tt.json -e "$1"; }
check "три размера, последний — весь MTU ($MTU), все проходят, задержка посчитана" eval '[ "$(tt "@.results[*].size" | wc -l)" -eq 3 ] && [ "$(tt "@.results[2].size")" = "$MTU" ] && [ "$(tt @.ok)" = true ] && tt "@.results[2].avg" | grep -qE "^[0-9.]+$"'
check "временные файлы убраны" eval '! ls -d /tmp/truba-tt.* 2>/dev/null'
# Путь, который теряет крупные пакеты: Труба отбрасывает пакеты Туннеля длиннее 1300 байт.
ip netns exec vps nft -f - <<-'EOF'
	table inet bigdrop {
		chain in {
			type filter hook prerouting priority -300;
			iifname "ul1" meta l4proto udp meta length gt 1300 drop
		}
	}
EOF
truba tunnel-test > /tmp/tt.json
check "путь теряет крупные пакеты: мелкие проходят, во весь MTU — нет, итог не OK" eval '[ "$(tt "@.results[0].ok")" = true ] && [ "$(tt "@.results[2].ok")" = false ] && [ "$(tt @.ok)" = false ]'
ip netns exec vps nft delete table inet bigdrop

section "rpcd: долгие проверки в фоне не держат остальные вызовы LuCI"
# rpcd обслуживает вызовы по одному: пока он ждал бы проверку (до ~5 с), стоял бы весь LuCI.
# Прежние итоги — из той же секунды, что и запуск: убрать, чтобы ждать именно новых.
rm -f /var/run/truba/tunnel-test.json /var/run/truba/nat.json
T0=$(date +%s); ubus call truba tunnel_test > /tmp/rt.json; T1=$(date +%s)
STARTED="$(jsonfilter -i /tmp/rt.json -e '@.started')"
T2=$(date +%s); ubus call luci-rpc getHostHints >/dev/null 2>&1; T3=$(date +%s)
check "tunnel_test отвечает сразу ($((T1 - T0)) с), другие вызовы не ждут ($((T3 - T2)) с)" eval '[ $((T1 - T0)) -le 1 ] && [ $((T3 - T2)) -le 2 ]'
done_after() { [ "$(ubus call truba "$1" | jsonfilter -e '@.time')" -ge "$2" ] 2>/dev/null; }
check "итог проверки Туннеля появился, все размеры проходят" eval 'wait_for 20 done_after tunnel_result "$STARTED" && [ "$(ubus call truba tunnel_result | jsonfilter -e "@.ok")" = true ]'
STARTED="$(ubus call truba nat_test | jsonfilter -e '@.started')"
check "итог проверки NAT появился, OK" eval 'wait_for 20 done_after nat_result "$STARTED" && [ "$(ubus call truba nat_result | jsonfilter -e "@.ok")" = true ]'

section "контроль Туннеля"
cat > /tmp/rtt.uc <<-'EOF'
	import { ping_rtt } from 'truba.watchdog';
	print(sprintf('%J %J\n', ping_rtt('awg0', '10.77.77.1'), ping_rtt('awg0', '192.0.2.200')));
EOF
# 192.0.2.200 уходит в Туннель, но Труба его не пересылает — ответа нет.
check "ping_rtt: задержка до Трубы через Туннель, без ответа — null" eval 'ucode /tmp/rtt.uc | grep -qE "^[0-9.]+ null$"'
uci set truba.watchdog.enabled='1'; uci set truba.watchdog.interval='10'; uci commit truba
rm -f /var/run/truba/nat.json   # как после перезагрузки: итога проверки NAT ещё нет
reload "контроль вкл"
H=/var/run/truba/health.json
health() { jsonfilter -i "$H" -e "$1" 2>/dev/null; }
probes() { [ "$(health '@.probes[0]' | cut -d. -f1)" -ge 0 ] 2>/dev/null; }
check "задержка и окно проверок — в health.json в /var/run, интервал 10" eval 'wait_for 15 probes && [ "$(health @.interval)" = 10 ]'
nat_auto() { [ "$(jsonfilter -i /var/run/truba/nat.json -e '@.auto' 2>/dev/null)" = true ]; }
check "проверка NAT запущена сама после подъёма, итог OK" eval 'wait_for 20 nat_auto && [ "$(jsonfilter -i /var/run/truba/nat.json -e "@.ok")" = true ]'
big_ok() { [ "$(health '@.big.ok')" = true ]; }
check "крупные пакеты во весь MTU проходят, status видит итог" eval 'wait_for 20 big_ok && [ "$(health @.big.size)" = "$MTU" ] && [ "$(truba status | jsonfilter -e "@.health.big.ok")" = true ]'
NAT_TIME="$(jsonfilter -i /var/run/truba/nat.json -e '@.time')"; LAST="$(health '@.last_check')"
next_cycle() { [ "$(health '@.last_check')" -gt "$LAST" ]; }
check "следующий цикл: без нового подъёма Туннеля NAT не перепроверяется" eval 'wait_for 15 next_cycle && [ "$(jsonfilter -i /var/run/truba/nat.json -e "@.time")" = "$NAT_TIME" ]'
# Обновление пакета меняет код, но не команду инстанса: reload должен перезапустить watchdog.
WD="$(pgrep -f 'truba watchdo[g]')"; SINCE="$(health '@.since')"
echo '// обновлено' >> /usr/share/ucode/truba/const.uc
reload "новый код"
new_wd() { P="$(pgrep -f 'truba watchdo[g]')" && [ -n "$P" ] && [ "$P" != "$WD" ]; }
check "новый код вступает в силу при reload, «в порядке с» не обнуляется" eval 'wait_for 10 new_wd && [ "$(health @.since)" = "$SINCE" ]'
sed -i '$d' /usr/share/ucode/truba/const.uc
# Запись после перерыва (контроль был выключен) описывает прошлое — её «в порядке с» и окно не берутся.
echo '{"state":"healthy","since":1000,"last_check":1000,"interval":10,"probes":[1,2,3]}' > "$H"
kill "$(pgrep -f 'truba watchdo[g]')"   # procd перезапустит через 5 с
fresh() { [ "$(health '@.since')" != 1000 ]; }
check "устаревшая запись: «в порядке с» заново, окно проверок не взято" eval 'wait_for 20 fresh && [ "$(health "@.probes[*]" | wc -l)" -le 1 ]'

finish
