#!/bin/sh
# Наборы правил: обновление (скачивание в tmpfs, перенос на флеш, предыдущая версия для отката),
# откат через rpcd в фоне, обновление без изменений, файл, который не разбирается, нечитаемые
# текущие списки при применении, свежая установка без списков.
. /repo/tests/router/stand.sh

section "обновление"
# На роутере /tmp — tmpfs, а /etc — overlay: rename между ними не работает (EXDEV).
mount | grep -q ' on /tmp type tmpfs' || echo "внимание: /tmp не tmpfs, перенос между ФС не проверяется"
# Источник — каталог на стенде. Другая, но правильная версия: дописана Категория.
mkdir -p /root/src
src() { cp "$2" "/root/src/$1" && (cd /root/src && sha256sum "$1" > "$1.sha256sum"); }
for f in geoip.dat geosite.dat; do src "$f" "/dat/$f"; done
ucode -L '/repo/tests/lib/*.uc' /repo/tests/lib/mkdat.uc geoip /root/src/geoip.dat zztest 198.18.0.0/24
ucode -L '/repo/tests/lib/*.uc' /repo/tests/lib/mkdat.uc geosite /root/src/geosite.dat zztest domain:zztest.trubatest
for f in geoip.dat geosite.dat; do (cd /root/src && sha256sum "$f" > "$f.sha256sum"); done
uci -q batch <<-'EOF'
	set truba.lists.via_tunnel='0'
	set truba.lists.geoip_url='file:///root/src/geoip.dat'
	set truba.lists.geoip_mirror='file:///root/src/geoip.dat'
	set truba.lists.geosite_url='file:///root/src/geosite.dat'
	set truba.lists.geosite_mirror='file:///root/src/geosite.dat'
	commit truba
EOF
# update-lists и его reload — фоном, как из cron; ждём, пока процессы Трубы не закончатся.
lists_step() {
	truba "$@" > /tmp/step.json 2>&1 & LP=$!
	check "truba $* и его reload завершились" eval 'wait_pid 60 $LP && wait_for 60 idle'
	unstick
}
lists_step update-lists -f
check "оба набора скачаны" test "$(grep -o '"ok": true' /etc/truba/state/lists.json | wc -l)" -eq 2
for f in geoip.dat geosite.dat; do
	check "$f: новый на флеше, контрольная сумма рядом, прежний — в prev, в /tmp не остался" eval \
		'cmp -s /etc/truba/lists/'$f' /root/src/'$f' && [ -s /etc/truba/lists/'$f'.sha256sum ] && [ -s /etc/truba/lists/prev/'$f' ] && [ ! -e /tmp/truba-dl/'$f' ]'
done
check "новая Категория появилась" test -s /var/lib/truba/geosite/zztest.txt

section "откат через rpcd: файлы сразу, применение в фоне"
# Иначе rpcd ждал бы распаковку и загрузку подсетей geoip, и стоял бы весь LuCI.
T_APPLIED="$(applied '@.time')"; sleep 1
T0=$(date +%s); ubus call truba rollback_lists > /tmp/rb.json; T1=$(date +%s)
check "ответ сразу (было $((T1 - T0)) с), оба набора, применение в фоне" eval '[ $((T1 - T0)) -le 1 ] && grep -q geosite.dat /tmp/rb.json && [ "$(jsonfilter -i /tmp/rb.json -e "@.applying")" = true ]'
applied_after() { [ "$(applied '@.time')" -gt "$1" ]; }
check "применено в фоне, процессы закончились" eval 'wait_for 60 applied_after "$T_APPLIED" && wait_for 60 idle'
unstick
check "откатилось: Категории из новой версии нет, lists: применение не идёт" eval '[ ! -e /var/lib/truba/geosite/zztest.txt ] && [ "$(ubus call truba lists | jsonfilter -e "@.applying")" = false ]'

section "обновление без изменений (-f)"
for f in geoip.dat geosite.dat; do src "$f" "/etc/truba/lists/$f"; done
PREV="$(sha256sum < /etc/truba/lists/prev/geosite.dat)"; T_APPLIED="$(applied '@.time')"; sleep 1
lists_step update-lists -f
check "предыдущая версия — по-прежнему версия для отката, настройки применены заново" eval '[ "$(sha256sum < /etc/truba/lists/prev/geosite.dat)" = "$PREV" ] && applied_after "$T_APPLIED"'

section "скачанный файл не разбирается"
# Контрольная сумма у источника честная: файл скачан целиком, но повреждён (или нового формата).
CUR="$(sha256sum < /etc/truba/lists/geosite.dat)"
head -c 1500000 /dat/geosite.dat > /tmp/broken.dat; src geosite.dat /tmp/broken.dat
lists_step update-lists
check "не принят (parse failed), текущий не заменён, mosdns работает" eval 'jsonfilter -i /etc/truba/state/lists.json -e "@.sets.geosite.errors[*]" | grep -q "parse failed" && [ "$(sha256sum < /etc/truba/lists/geosite.dat)" = "$CUR" ] && pidof mosdns'

section "текущие списки не читаются при применении"
cp /tmp/broken.dat /etc/truba/lists/geosite.dat
(cd /etc/truba/lists && sha256sum geosite.dat > geosite.dat.sha256sum)
reload "нечитаемые списки"
check "без ошибки, предупреждение для «Обзора»" eval 'no_error && grep -q lists_rolled_back "$APPLIED"'
check "текущим стал предыдущий, mosdns работает" eval '[ "$(wc -c < /etc/truba/lists/geosite.dat)" -gt 1500000 ] && wait_for 10 mosdns_up'

section "свежая установка без списков"
# apply сам скачивает их в фоне; фоновый update-lists не должен наследовать блокировки apply
# и rc.common — иначе его собственный reload ждал бы их вечно.
src geosite.dat /dat/geosite.dat
rm -f /etc/truba/lists/*.dat /etc/truba/lists/*.sha256sum /etc/truba/lists/prev/*
/etc/init.d/truba reload
check "списки скачаны в фоне" wait_for 60 test -s /etc/truba/lists/geosite.dat
check "нет зависших apply / update-lists / reload" wait_for 60 idle
unstick
check "нет lists_missing, блокировки свободны" eval '! grep -q lists_missing "$APPLIED" && ! grep -q " -> FLOCK" /proc/locks'

finish
