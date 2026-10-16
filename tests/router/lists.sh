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

section "проверка без изменений: только контрольные суммы"
# Проверка идёт каждый час: пока сумма у источника та же, сам файл (мегабайты) не скачивается.
mkdir -p /root/src-off; mv /root/src/geoip.dat /root/src/geosite.dat /root/src-off/
lists_step update-lists
check "оба набора — без изменений, файлы у источника не понадобились" eval '[ "$(grep -o "\"ok\": true, \"changed\": false" /etc/truba/state/lists.json | wc -l)" -eq 2 ]'
mv /root/src-off/* /root/src/

section "«Обновить сейчас» через rpcd"
# rpcd работает с umask 077: скачанные файлы и состояние — с обычными правами, как из cron.
ucode -L '/repo/tests/lib/*.uc' /repo/tests/lib/mkdat.uc geoip /root/src/geoip.dat zzrpcd 198.18.1.0/24
(cd /root/src && sha256sum geoip.dat > geoip.dat.sha256sum)
T_LISTS="$(jsonfilter -i /etc/truba/state/lists.json -e '@.time')"; sleep 1
ubus call truba update_lists '{ "force": false }' > /tmp/ul.json
STARTED="$(jsonfilter -i /tmp/ul.json -e '@.started')"
# Итог для интерфейса — lists.last со временем не раньше started.
checked_since() { [ "$(jsonfilter -i /etc/truba/state/lists.json -e '@.time')" -ge "$1" ]; }
check "ответ сразу — время запуска, проверка прошла в фоне" eval '[ "$STARTED" -gt "$T_LISTS" ] && wait_for 60 checked_since "$STARTED" && wait_for 60 idle'
unstick
perm() { ls -l "$1" | cut -c1-10; }   # stat в образе нет
check "geoip.dat заменён, права 644 у файла и состояния" eval 'cmp -s /etc/truba/lists/geoip.dat /root/src/geoip.dat && [ "$(perm /etc/truba/lists/geoip.dat)" = -rw-r--r-- ] && [ "$(perm /etc/truba/state/lists.json)" = -rw-r--r-- ]'

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

section "изменение только geoip меняет таблицу"
uci set truba.audit_geoip=rule
uci set truba.audit_geoip.mode=all
uci set truba.audit_geoip.set=geoip
uci set truba.audit_geoip.tag=zzrpcd
uci set truba.audit_geoip.action=block
uci commit truba
ucode -L '/repo/tests/lib/*.uc' /repo/tests/lib/mkdat.uc geoip /etc/truba/lists/geoip.dat zzrpcd 198.18.1.0/24
(cd /etc/truba/lists && sha256sum geoip.dat > geoip.dat.sha256sum)
reload "новое Действие geoip"
check "Категория geoip загружена в Блок" eval 'nft get element inet truba gi_block4 "{ 198.18.1.1 }" >/dev/null 2>&1'
ucode -L '/repo/tests/lib/*.uc' /repo/tests/lib/mkdat.uc geoip /etc/truba/lists/geoip.dat zzrpcd 198.18.2.0/24
(cd /etc/truba/lists && sha256sum geoip.dat > geoip.dat.sha256sum)
reload "изменился только geoip.dat"
check "новая подсеть geoip загружена без изменения geosite" eval 'nft get element inet truba gi_block4 "{ 198.18.2.1 }" >/dev/null 2>&1'
uci delete truba.audit_geoip
uci commit truba

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
