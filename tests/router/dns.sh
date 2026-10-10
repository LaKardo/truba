#!/bin/sh
# DNS: классификация mosdns по Категориям (на синтетических Категориях и подставных DNS-серверах),
# Блок, AAAA, «Проверить домен/IP» с наборами из ядра, запасной сервер DNS, TTL в кэше и для устройств, сброс кэша при смене серверов, ленивый кэш и его дамп, занятый порт API,
# срок IP из DNS в наборах (ADR 0007), неверные настройки.
. /repo/tests/router/stand.sh

section "классификация: подставные серверы и синтетические Категории"
# Серверы «Туннеля» и «Напрямую» отвечают на всё своим адресом: по ответу видно, какой путь
# выбрал mosdns. Не test-net и не частные адреса — их dnsmasq отбрасывает (stop-dns-rebind),
# а «Проверить домен/IP» резолвит через dnsmasq.
upstream() {   # upstream ПОРТ АДРЕС
	dnsmasq --conf-file=/dev/null --port="$1" --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
		--address="/#/$2" --local-ttl=2 --pid-file="/tmp/up-$1.pid"
}
upstream 5401 44.0.0.1
upstream 5402 44.0.0.2
L=/etc/truba/lists
ucode -L '/repo/tests/lib/*.uc' /repo/tests/lib/mkdat.uc geosite $L/geosite.dat zzdirect \
	full:zz-full.trubatest domain:zz-dom.trubatest 'regexp:^zzrx-[0-9]+\.trubatest$'
ucode -L '/repo/tests/lib/*.uc' /repo/tests/lib/mkdat.uc geosite $L/geosite.dat zztunnel domain:zz-tun.trubatest
(cd $L && sha256sum geosite.dat > geosite.dat.sha256sum)
uci -q batch <<-'EOF'
	add truba rule
	set truba.@rule[-1].mode='all'
	set truba.@rule[-1].set='geosite'
	set truba.@rule[-1].tag='zzdirect'
	set truba.@rule[-1].action='direct'
	add truba rule
	set truba.@rule[-1].mode='all'
	set truba.@rule[-1].set='geosite'
	set truba.@rule[-1].tag='zztunnel'
	set truba.@rule[-1].action='tunnel'
	delete truba.dns.tunnel_upstream
	delete truba.dns.direct_upstream
	add_list truba.dns.tunnel_upstream='udp://127.0.0.1:5401'
	add_list truba.dns.direct_upstream='udp://127.0.0.1:5402'
	commit truba
EOF
reload "Категории и серверы"
wait_for 15 mosdns_up
# ask ИМЯ [ТИП] — адреса из ответа mosdns (мимо dnsmasq) через пробел; nx ИМЯ — ответ NXDOMAIN.
ask() { nslookup -type="${2:-A}" -port="$(dns_port)" "$1" 127.0.0.1 2>&1 | awk '/^Name:/ {n=1} n && /^Address/ {print $NF}' | xargs; }
nx() { nslookup -port="$(dns_port)" "$1" 127.0.0.1 2>&1 | grep -q NXDOMAIN; }
check "full: — точно, через «Напрямую», IP в gs_direct4" eval '[ "$(ask zz-full.trubatest)" = 44.0.0.2 ] && in_set gs_direct4 44.0.0.2'
check "full: — поддомен не совпадает, по Режиму через «Туннель», без набора" eval '[ "$(ask x.zz-full.trubatest)" = 44.0.0.1 ] && ! in_set gs_tunnel4 44.0.0.1'
check "domain: и regexp: — через «Напрямую»" eval '[ "$(ask a.zz-dom.trubatest)" = 44.0.0.2 ] && [ "$(ask zzrx-42.trubatest)" = 44.0.0.2 ]'
check "Категория «Туннель» — через «Туннель», IP в gs_tunnel4" eval '[ "$(ask zz-tun.trubatest)" = 44.0.0.1 ] && in_set gs_tunnel4 44.0.0.1'
ADS="$(sed -n '1s/^domain://p' /var/lib/truba/geosite/category-ads.txt)"
check "Блок ($ADS из category-ads) → NXDOMAIN, и поддомен тоже" eval 'nx "$ADS" && nx "sub.$ADS"'
check "AAAA → пустой ответ" eval '[ -z "$(ask zz-tun.trubatest AAAA)" ]'
check "Проверить домен: IP из DNS «Напрямую» — через набор в ядре" eval 'truba check zz-full.trubatest > /tmp/c1 && grep -q "\"reason\": \"geosite_ip\"" /tmp/c1 && grep -q "\"action\": \"direct\"" /tmp/c1'
check "Проверить IP: geoip:ru — через набор в ядре" eval 'truba check 77.88.8.8 > /tmp/c2 && grep -q "\"reason\": \"geoip\"" /tmp/c2 && [ "$(jsonfilter -i /tmp/c2 -e "@.ips[0].sets.gi_direct")" = true ]'
check "status и sets: счётчики кэша и IP из DNS" eval '[ "$(truba status | jsonfilter -e "@.dns_cache.query")" -gt 0 ] && [ "$(truba status | jsonfilter -e "@.dns_cache.max")" -eq 65536 ] && [ "$(truba sets | jsonfilter -e "@.dns.direct")" -ge 1 ] && [ "$(truba sets | jsonfilter -e "@.dns.tunnel")" -ge 1 ]'

section "второй сервер DNS страхует каждый запрос"
# Первый сервер «Туннеля» завис: принимает запросы и молчит. Запрос идёт сразу к обоим серверам,
# поэтому ответ второго не ждёт тайм-аута первого (5 с).
ucode -e "import * as socket from 'socket'; let s = socket.create(socket.AF_INET, socket.SOCK_DGRAM); s.bind({ address: '127.0.0.1', port: 5409 }); sleep(300000);" & MUTE=$!
PID="$(pidof mosdns)"
uci -q batch <<-'EOF'
	delete truba.dns.tunnel_upstream
	add_list truba.dns.tunnel_upstream='udp://127.0.0.1:5409'
	add_list truba.dns.tunnel_upstream='udp://127.0.0.1:5401'
	commit truba
EOF
reload "первый сервер «Туннеля» молчит"
restarted() { P="$(pidof mosdns)" && [ "$P" != "$PID" ] && mosdns_up; }
wait_for 10 restarted
# 20 новых имён: при случайном выборе сервера хотя бы одно ушло бы только к молчащему.
fast_answers() {
	t=$(date +%s)
	for i in $(seq 1 20); do [ "$(ask "mute-$i.zz-tun.trubatest")" = 44.0.0.1 ] || return 1; done
	[ $(( $(date +%s) - t )) -le 3 ]
}
check "20 новых имён — все ответы от второго сервера, без тайм-аута" bounded 60 fast_answers
check "у серверов DNS — idle_timeout" eval 'grep -q "\"idle_timeout\": 180" /var/etc/truba/mosdns.json'
kill "$MUTE"
PID="$(pidof mosdns)"
uci -q batch <<-'EOF'
	delete truba.dns.tunnel_upstream
	add_list truba.dns.tunnel_upstream='udp://127.0.0.1:5401'
	commit truba
EOF
reload "один сервер «Туннеля»"
wait_for 10 restarted

section "кэш хранит ответ с TTL сервера (не больше часа), устройствам — не больше ttl_max"
# Сервер «Напрямую» отвечает с TTL 7200. Устройства получают не больше ttl_max (300) и часто перепроверяют
# адрес, а кэш mosdns держит ответ свежим TTL сервера, но не дольше часа, и не обновляет его в фоне каждые 5 минут.
dnsmasq --conf-file=/dev/null --port=5403 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
	--address=/#/44.0.0.3 --local-ttl=7200 --pid-file=/tmp/up-5403.pid
PID="$(pidof mosdns)"
uci -q batch <<-'EOF'
	delete truba.dns.direct_upstream
	add_list truba.dns.direct_upstream='udp://127.0.0.1:5403'
	commit truba
EOF
reload "сервер «Напрямую» с TTL 7200"
wait_for 10 restarted
# ttl_of ИМЯ IP — TTL A-записи IP в ответе mosdns.
ttl_of() { ucode /repo/tests/lib/dns_ttl.uc "$(dns_port)" "$1" | awk -v ip="$2" '$1 == ip {print $2}'; }
ttl_le() { T="$(ttl_of "$1" "$2")"; [ -n "$T" ] && [ "$T" -le "$3" ]; }
check "клиенту — не больше ttl_max: из сервера и из кэша" eval 'ttl_le keep.zz-dom.trubatest 44.0.0.3 300 && ttl_le keep.zz-dom.trubatest 44.0.0.3 300'
# В дампе кэша — A-запись 44.0.0.3 с TTL не больше часа: тип 1, класс 1, TTL 3600 (0x00000e10), длина 4, адрес.
cached_ttl_3600() { curl -s http://127.0.0.1:5336/plugins/cache/dump | gunzip | hexdump -v -e '/1 "%02x"' | grep -q 0001000100000e1000042c000003; }
check "в кэше — TTL сервера, но не больше часа (7200 → 3600)" cached_ttl_3600
check "IP — в gs_direct4 до ответа, и из кэша тоже" eval 'nft flush set inet truba gs_direct4 && [ -n "$(ttl_of keep.zz-dom.trubatest 44.0.0.3)" ] && in_set gs_direct4 44.0.0.3'

section "смена серверов DNS — кэш с нуля"
# Ответ с TTL сервера пережил бы смену настроек на час и больше. Поэтому при смене серверов, Действий
# Категорий или Режима mosdns начинает с пустым кэшем, а при остальных (ttl_max) кэш сохраняется.
PID="$(pidof mosdns)"
uci -q batch <<-'EOF'
	delete truba.dns.direct_upstream
	add_list truba.dns.direct_upstream='udp://127.0.0.1:5402'
	commit truba
EOF
reload "сервер «Напрямую» сменился"
wait_for 10 restarted
# Тот же запрос, что выше (флаги AD/CD/DO входят в ключ кэша, поэтому не nslookup).
check "ответ — от нового сервера, а не из кэша" eval '[ "$(ucode /repo/tests/lib/dns_ttl.uc "$(dns_port)" keep.zz-dom.trubatest | cut -d" " -f1 | xargs)" = 44.0.0.2 ]'
kill "$(cat /tmp/up-5403.pid)"

section "ленивый кэш"
check "ответ от сервера «Напрямую»" eval '[ "$(ask lazy.zz-dom.trubatest)" = 44.0.0.2 ]'
sleep 3   # запись истекла (TTL 2 с)
kill "$(cat /tmp/up-5402.pid)"
# Сервер выключен: свежий запрос без ответа, а истёкший ответ отдаёт только ленивый кэш —
# и он тоже проходит через nftset: после пересборки наборов IP возвращаются сами.
nft flush set inet truba gs_direct4
check "контроль: сервер «Напрямую» выключен — нового ответа нет" eval '[ -z "$(ask fresh.zz-dom.trubatest)" ]'
check "истёкшая запись отдана из ленивого кэша и снова в gs_direct4" eval '[ "$(ask lazy.zz-dom.trubatest)" = 44.0.0.2 ] && in_set gs_direct4 44.0.0.2'
check "status: истёкшие ответы в счётчиках кэша" eval '[ "$(truba status | jsonfilter -e "@.dns_cache.lazy_hit")" -ge 1 ]'
# Дамп кэша в оперативной памяти: смена настройки DNS перезапускает mosdns, кэш остаётся.
PID="$(pidof mosdns)"
uci set truba.dns.ttl_max=299; uci commit truba
reload "ttl_max"
check "смена настройки DNS перезапустила mosdns" wait_for 10 restarted
check "дамп кэша — в /var/lib/truba (tmpfs)" eval '[ -s "$(jsonfilter -i /var/etc/truba/mosdns.json -e "@.plugins[@.tag=\"cache\"].args.dump_file")" ] && ls /var/lib/truba/mosdns-cache-*.dump'
check "после перезапуска запись взята из дампа" eval '[ "$(ask lazy.zz-dom.trubatest)" = 44.0.0.2 ]'

section "API mosdns: порт занят другой программой"
# Ошибка API останавливает mosdns целиком, а с ней DNS всей сети: тогда — без API.
ucode /repo/tests/lib/tcp_probe.uc server 5346 >/dev/null 2>&1 & BUSY=$!
uci set truba.dns.port=5345; uci commit truba
reload "порт 5345"
check "mosdns слушает 5345" wait_for 10 mosdns_up 5345
PID="$(pidof mosdns)"; sleep 2
check "mosdns без API работает и не перезапускается" eval '! grep -q "\"api\"" /var/etc/truba/mosdns.json && [ "$(pidof mosdns)" = "$PID" ]'
check "предупреждение в журнале, счётчиков кэша нет" eval 'logread | grep -q "порт 127.0.0.1:5346 занят" && [ -z "$(truba status | jsonfilter -e "@.dns_cache.query")" ]'
kill "$BUSY"
uci -q delete truba.dns.port; uci commit truba
reload "порт по умолчанию"
check "порт API свободен — API снова есть" wait_for 10 eval 'curl -s -m 2 http://127.0.0.1:5336/metrics | grep -q "^mosdns_cache_query_total"'

section "срок IP из DNS в наборах (ADR 0007)"
# left_le IP N — элементу IP в gs_direct4 осталось не больше N с.
left_le() { L="$(nft -j list set inet truba gs_direct4 | jsonfilter -e "@.nftables[*].set.elem[@.elem.val='$1'].elem.expires")"; [ -n "$L" ] && [ "$L" -le "$2" ]; }
check "по умолчанию сутки, IP от mosdns получает срок набора" eval 'nft list set inet truba gs_direct4 | grep -q "timeout 1d" && nft list set inet truba gs_direct4 | grep -q "44.0.0.2 expires"'
nft add element inet truba gs_direct4 '{ 198.51.100.9 expires 90s, 198.51.100.10 expires 80000s }'
uci set truba.dns.set_timeout=3600; uci commit truba
reload "срок 1 ч"
check "срок 1 ч: без ошибки" eval 'no_error && nft list set inet truba gs_direct4 | grep -q "timeout 1h"'
check "перенос в новую таблицу не продлевает срок" left_le 198.51.100.9 90
check "перенесённый IP укорочен до срока набора" left_le 198.51.100.10 3600
uci set truba.dns.set_timeout=0; uci commit truba
reload "без срока"
check "без срока: без ошибки, IP перенесены" eval 'no_error && ! nft list set inet truba gs_direct4 | grep -q timeout && in_set gs_direct4 198.51.100.10'
uci -q delete truba.dns.set_timeout; uci commit truba
reload "срок по умолчанию"
check "срок снова сутки, перенесённые без срока получили его" eval 'nft list set inet truba gs_direct4 | grep -q "timeout 1d" && nft list set inet truba gs_direct4 | grep -q "198.51.100.10 expires"'

section "неверные настройки пропускаются, а не ломают применение"
# Опечатки из консоли: MAC не дал бы загрузить таблицу nft, схема адреса DNS — запустить
# mosdns, адрес для ping сделал бы Туннель «неработающим» навсегда.
uci -q batch >/dev/null <<-'EOF'
	add truba device
	set truba.@device[-1].mac='AA:BB:CC:DD:EE:FF'
	set truba.@device[-1].policy='tunnel'
	add truba device
	set truba.@device[-1].mac='AA:BB:CC:DD:EE'
	set truba.@device[-1].policy='tunnel'
	add_list truba.dns.tunnel_upstream='htps://1.1.1.1/dns-query'
	set truba.watchdog.probe='10.77.77.l'
	commit truba
EOF
reload "с опечатками"
check "без ошибки, пропущенное перечислено для «Обзора»" eval 'no_error && [ "$(applied "@.invalid[*].key" | sort | xargs)" = "device.mac dns.tunnel_upstream watchdog.probe" ]'
check "MAC с опечаткой не в наборе, верный — в наборе" eval 'in_set dev_tunnel aa:bb:cc:dd:ee:ff && ! nft list set inet truba dev_tunnel | grep -qiE "aa:bb:cc:dd:ee( |,|$)"'
check "адрес DNS с опечаткой не в конфиге mosdns, верный — в нём, mosdns работает" eval '! grep -q htps /var/etc/truba/mosdns.json && grep -q "udp://127.0.0.1:5401" /var/etc/truba/mosdns.json && wait_for 10 mosdns_up'
uci -q delete truba.@device[-1]
uci del_list truba.dns.tunnel_upstream='htps://1.1.1.1/dns-query'
uci set truba.watchdog.probe=''; uci commit truba
reload "исправлено"
check "исправлено — пропущенных нет" eval '[ -z "$(applied "@.invalid[*]")" ]'

finish
