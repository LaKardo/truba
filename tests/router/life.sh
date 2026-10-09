#!/bin/sh
# Жизненный цикл и отказы: перенос настроек при обновлении пакета (uci-defaults), ошибка
# применения при работе и при загрузке (ADR 0006), плагин старого интерфейса в rpcd (ADR 0008),
# переустановка после sysupgrade (ADR 0004).
. /repo/tests/router/stand.sh

section "обновление пакета: uci-defaults переносит прежние значения по умолчанию"
DIRECT_DNS="$(uci -q get truba.dns.direct_upstream)"
direct_dns() { uci -q delete truba.dns.direct_upstream; for u in "$@"; do uci add_list truba.dns.direct_upstream="$u"; done; uci commit truba; }
uci set truba.lists.update_utc='04:00'
direct_dns 'tls://common.dot.dns.yandex.net@77.88.8.8'
sh /etc/uci-defaults/90-truba
check "время обновления списков: прежнее 04:00 → 12:00 UTC" test "$(uci -q get truba.lists.update_utc)" = 12:00
check "DNS «Напрямую»: к прежнему серверу добавлен второй" test "$(uci -q get truba.dns.direct_upstream)" = "$DIRECT_DNS"
sh /etc/uci-defaults/90-truba
check "повторный запуск ничего не добавляет" test "$(uci -q get truba.dns.direct_upstream)" = "$DIRECT_DNS"
direct_dns 'https://77.88.8.8/dns-query'
sh /etc/uci-defaults/90-truba
check "свой сервер пользователя не трогается" test "$(uci -q get truba.dns.direct_upstream)" = 'https://77.88.8.8/dns-query'
# shellcheck disable=SC2086
direct_dns $DIRECT_DNS

section "последняя удачная копия правил (ADR 0006)"
check "копия на флеше: правила, конфиг mosdns, описание" eval '[ -s /etc/truba/good/truba.nft ] && [ -s /etc/truba/good/mosdns.json ] && [ -s /etc/truba/good/meta.json ]'
check "копия: без накопленных счётчиков и без IP из DNS" eval '! grep -q "packets [1-9]" /etc/truba/good/truba.nft && ! sed -n "/set gs_direct4/,/}/p" /etc/truba/good/truba.nft | grep -q elements'
check "копия: mosdns без API, со своими списками доменов" eval '! grep -q "\"api\"" /etc/truba/good/mosdns.json && grep -q /etc/truba/good/geosite/category-ads.txt /etc/truba/good/mosdns.json && [ -s /etc/truba/good/geosite/category-ads.txt ]'
INODE="$(stat -c %i /etc/truba/good/truba.nft)"
uci set truba.lists.update_utc='13:00'; uci commit truba
reload "правила не меняются"
check "копия не переписывается, пока правила те же (флеш)" test "$(stat -c %i /etc/truba/good/truba.nft)" = "$INODE"

# Обёртка nft отказывается загружать новую таблицу Трубы, пока есть /tmp/nft-fail, — как при
# ошибке в правилах или нехватке памяти ядра. Остальное, в том числе загрузку последней
# удачной копии, выполняет настоящий nft.
NFT="$(command -v nft)"
mv "$NFT" "$NFT.real"
cat > "$NFT" <<-EOF
	#!/bin/sh
	if [ -f /tmp/nft-fail ]; then
		for a in "\$@"; do
			[ "\$a" = /var/etc/truba/truba.nft ] && { echo 'Error: simulated failure' >&2; exit 1; }
		done
	fi
	exec $NFT.real "\$@"
EOF
chmod +x "$NFT"
ADS="$(sed -n '1s/^domain://p' /var/lib/truba/geosite/category-ads.txt)"
dns_works() { nslookup "$ADS" 127.0.0.1 2>&1 | grep -q NXDOMAIN; }   # Блок → NXDOMAIN, через dnsmasq
# Код возврата самой команды не важен — проверки после, лишь бы она не повисла.
finished() { bounded 90 "$@"; [ $? -ne 124 ]; }

section "ошибка применения при работе"
PID="$(pidof mosdns)"
touch /tmp/nft-fail
uci set truba.main.mode='selective'; uci commit truba
check "reload при ошибке nft завершился" finished /etc/init.d/truba reload
check "ошибка записана для «Обзора», действуют правила до неё" eval 'applied "@.error" | grep -q "simulated failure" && [ "$(applied "@.fallback")" = kept ]'
check "в ядре прежняя таблица (Режим «Всё в туннель»), applied.json описывает её" eval '[ "$(mode_mark)" = 0x00010000 ] && [ "$(applied "@.mode")" = all ]'
check "mosdns не остановлен и не перезапущен, dnsmasq → mosdns" eval '[ "$(pidof mosdns)" = "$PID" ] && uci -q get dhcp.@dnsmasq[0].server | grep -q "127.0.0.1#5335"'
check "DNS сети отвечает" dns_works

section "ошибка применения при загрузке"
# Загрузка Роутера: таблицы в ядре нет, /var пуст (tmpfs), а применить настройки не удаётся.
/etc/init.d/truba stop
rm -rf /var/run/truba /var/etc/truba /var/lib/truba
check "старт при ошибке nft завершился" finished /etc/init.d/truba start
check "действует последняя удачная копия: подсети geoip на месте" eval '[ "$(applied "@.fallback")" = last_good ] && in_set gi_direct4 "[[:space:]{,]5\.[0-9]"'
check "mosdns — с конфигом и списками копии, dnsmasq → mosdns" eval 'grep -q /etc/truba/good/geosite/ /var/etc/truba/mosdns.json && uci -q get dhcp.@dnsmasq[0].server | grep -q "127.0.0.1#5335"'
check "DNS сети отвечает" wait_for 10 dns_works
check "правила ip и таблица Туннеля" eval 'ip rule show | grep -q "lookup 77" && ip route show table 77 | grep -q "default dev awg0"'

# Копии ещё не было ни разу: правил Трубы нет — и DNS идёт напрямую.
/etc/init.d/truba stop
rm -rf /var/run/truba /var/etc/truba /var/lib/truba /etc/truba/good
check "старт без копии при ошибке nft завершился" finished /etc/init.d/truba start
check "без копии: правил Трубы нет, dnsmasq без mosdns, mosdns не запущен" eval '[ "$(applied "@.fallback")" = none ] && ! nft list table inet truba && ! uci -q get dhcp.@dnsmasq[0].server | grep -q 5335 && ! pidof mosdns'

rm -f /tmp/nft-fail
uci set truba.main.mode='all'; uci commit truba
reload "ошибка устранена"
check "без ошибки, mosdns работает, копия снова есть" eval 'no_error && wait_for 10 mosdns_up && [ -s /etc/truba/good/meta.json ]'
mv "$NFT.real" "$NFT"

section "rpcd: плагин старого интерфейса (ADR 0008)"
# Плагин luci-app-truba до 1.0.0-r14 регистрировал тот же объект. Два плагина одного объекта
# rpcd не переносит: портит память и падает на HUP. На x86 это не проявляется, поэтому
# проверяется, что второй регистрации нет вовсе.
RP="$(pidof rpcd)"
echo "return { truba: { old_plugin: { call: function() { return { old: true }; } } } };" > /usr/share/rpcd/ucode/truba.uc
chmod 0644 /usr/share/rpcd/ucode/truba.uc
killall -HUP rpcd
old_owner() { [ "$(ubus call truba old_plugin | jsonfilter -e '@.old')" = true ]; }
check "объект — за старым плагином" wait_for 10 old_owner
check "truba-api.uc при нём не регистрирует ничего, rpcd пережил HUP" eval '! ubus -v list truba | grep -q "\"status\"" && [ "$(pidof rpcd)" = "$RP" ]'
rm /usr/share/rpcd/ucode/truba.uc
killall -HUP rpcd
check "без старого плагина объект снова у truba-api.uc" wait_for 10 ubus call truba lists

section "sysupgrade: reinstall.sh возвращает DNS сети до ожидания интернета (ADR 0004)"
# После sysupgrade /etc/config/dhcp и бэкап Трубы (/etc/truba в keep.d) на месте, а пакетов нет:
# dnsmasq шлёт запросы в mosdns, которого нет. Имитация: служба снята без teardown (procd
# убивает mosdns, настройки dnsmasq остаются); «исходный» DNS сети в бэкапе — свой сервер,
# который знает up.trubatest (не .test: эту зону dnsmasq OpenWrt отвечает сам). truba здесь
# стоит не из apk, поэтому reinstall.sh идёт дальше проверки «уже установлена».
cp /etc/truba/state/dnsmasq.json /tmp/dnsmasq.orig.json
printf '{"sid":"%s","noresolv":"1","server":["127.0.0.1#5399"]}' "$(jsonfilter -i /tmp/dnsmasq.orig.json -e '@.sid')" > /etc/truba/state/dnsmasq.json
dnsmasq --conf-file=/dev/null --port=5399 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
	--address=/up.trubatest/5.6.7.8 --pid-file=/tmp/dm-up.pid
ubus call service delete '{"name":"truba"}'
up_ok() { nslookup up.trubatest 127.0.0.1 2>&1 | grep -q 5.6.7.8; }
check "mosdns нет — DNS сети не отвечает" eval 'wait_for 5 eval "! pidof mosdns" && ! up_ok'
sh /etc/truba/reinstall.sh >/dev/null 2>&1 & RI=$!
check "DNS сети отвечает, не дожидаясь интернета" wait_for 20 up_ok
check "dnsmasq вернулся к серверам из бэкапа, бэкап использован и удалён" eval '[ "$(uci -q get dhcp.@dnsmasq[0].server)" = "127.0.0.1#5399" ] && [ ! -f /etc/truba/state/dnsmasq.json ]'
check "запись в журнале, дальше ждёт интернет" eval 'logread | grep -q "truba-reinstall.*DNS сети возвращён" && kill -0 "$RI"'
kill "$RI" 2>/dev/null; for p in $(pgrep -f 'truba/reinstall[.]sh'); do kill "$p" 2>/dev/null; done
kill "$(cat /tmp/dm-up.pid)" 2>/dev/null

finish
