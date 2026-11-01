#!/bin/sh
# Жизненный цикл и отказы: обновление пакета, ошибка применения при работе и при загрузке
# (ADR 0006), переустановка после sysupgrade (ADR 0004).
. /repo/tests/router/stand.sh

section "обновление пакета: убранные Категории не возвращаются"
# uci-defaults идёт и после каждого обновления; Стартовые правила — только при первой установке.
while uci -q delete 'truba.@rule[0]'; do :; done
uci commit truba
sh /etc/uci-defaults/90-truba
check "после повторного uci-defaults правил по-прежнему нет" test -z "$(uci show truba | grep '=rule$')"
truba reset-rules all >/dev/null; truba reset-rules selective >/dev/null

section "обновление пакета: Маршрутизация (ADR 0019)"
rt() { uci -q get truba.main.routing; }
sh /etc/uci-defaults/90-truba
check "обновление: включённая Маршрутизация остаётся" test "$(rt)" = 1
uci delete truba.main.routing; uci commit truba
sh /etc/uci-defaults/90-truba
check "обновление без строки routing: прежнее умолчание «вкл» записано" test "$(rt)" = 1
# Повторная установка после apk del: /etc/config/truba остался, firewall.orig удалён вместе с пакетом.
FWO="$(eval "$(truba env)"; echo "$TRUBA_STATE_DIR")/firewall.orig"
cp "$FWO" /tmp/firewall.orig.bak; rm -f "$FWO"
sh /etc/uci-defaults/90-truba
check "повторная установка: Маршрутизация выключена и при оставшемся конфиге" test "$(rt)" = 0
cp /tmp/firewall.orig.bak "$FWO"
uci set truba.main.routing='1'; uci commit truba

section "последняя удачная копия правил (ADR 0006)"
[ -s /etc/truba/good/meta.json ] || logread -e 'последняя удачная копия'
check "копия на флеше: правила, конфиг mosdns, описание" eval '[ -s /etc/truba/good/truba.nft ] && [ -s /etc/truba/good/mosdns.json ] && [ -s /etc/truba/good/meta.json ]'
check "копия: без накопленных счётчиков и без IP из DNS" eval '! grep -q "packets [1-9]" /etc/truba/good/truba.nft && ! sed -n "/set gs_direct4/,/}/p" /etc/truba/good/truba.nft | grep -q elements'
check "копия: mosdns без API, со своими списками доменов" eval '! grep -q "\"api\"" /etc/truba/good/mosdns.json && grep -q /etc/truba/good/geosite/category-ads.txt /etc/truba/good/mosdns.json && [ -s /etc/truba/good/geosite/category-ads.txt ]'
# stat в образе нет: номер inode — из ls -i.
ino() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
INODE="$(ino /etc/truba/good/truba.nft)"
uci set truba.watchdog.handshake_max='200'; uci commit truba
reload "правила не меняются"
check "копия не переписывается, пока правила те же (флеш)" eval '[ -n "$INODE" ] && [ "$(ino /etc/truba/good/truba.nft)" = "$INODE" ]'
GEO_FILE="$(find /etc/truba/good -name 'geoip-*.nft' | head -1)"
GEO_INODE="$(ino "$GEO_FILE")"
uci set truba.good_test=device
uci set truba.good_test.mac='02:aa:bb:cc:dd:ee'
uci set truba.good_test.policy='direct'
uci commit truba
reload "копия: новая Политика устройства"
check "копия: Политика не переписывает geoip" eval '[ -n "$GEO_INODE" ] && [ "$(ino "$GEO_FILE")" = "$GEO_INODE" ] && grep -q "02:aa:bb:cc:dd:ee" /etc/truba/good/truba.nft'
check "копия: include geoip проходит проверку nft" nft -c -f /etc/truba/good/truba.nft
uci delete truba.good_test; uci commit truba
reload "копия: убрать тестовую Политику"

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
check "в ядре прежняя таблица (Режим «Всё в туннель»), applied.json описывает её" eval '[ "$(mode_mark)" = 0x01000000 ] && [ "$(applied "@.mode")" = all ]'
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

section "sysupgrade: Маршрутизация выключена на время установки (ADR 0019)"
# Вернуть то, что сняла прошлая секция: бэкап DNS и службу. reinstall.sh меняет dhcp и truba — копии.
cp /tmp/dnsmasq.orig.json /etc/truba/state/dnsmasq.json
check "служба снова запущена" bounded 90 /etc/init.d/truba start
cp /etc/config/dhcp /tmp/dhcp.ri; cp /etc/config/truba /tmp/truba.ri; cp /etc/truba/state/dnsmasq.json /tmp/dnsmasq.ri.json
# Заглушки: интернет есть, apk «ставит» пакеты и запоминает routing на момент установки Трубы.
# Перезапуск сети и службы — через NETWORK_RESTART и TRUBA_INIT: их пути в скрипте абсолютные.
mkdir -p /tmp/ri-bin
printf '#!/bin/sh\nexit 0\n' > /tmp/ri-bin/nslookup
cat > /tmp/ri-bin/apk <<-'EOF'
	#!/bin/sh
	case "$1" in
	list|update) exit 0 ;;
	esac
	[ "$2" = kmod-amneziawg ] && exit "$(cat /tmp/apk-kmod)"
	case " $* " in
	*" truba "*) uci -q get truba.main.routing > /tmp/apk-routing; exit "$(cat /tmp/apk-rc)" ;;
	esac
	exit 0
EOF
chmod +x /tmp/ri-bin/nslookup /tmp/ri-bin/apk
LIST=/etc/apk/repositories.d/truba.list
[ -f "$LIST" ] && cp "$LIST" /tmp/truba.list.ri
mkdir -p "${LIST%/*}"
echo 'https://lakardo.github.io/truba/25.12.0/mediatek/filogic/packages.adb' > "$LIST"
# ri N KMOD RC [нет-строки] — один прогон reinstall.sh; журнал прогона — в /tmp/ri.log.
ri() {
	echo "$2" > /tmp/apk-kmod; echo "$3" > /tmp/apk-rc; rm -f /tmp/apk-routing
	uci set truba.main.routing='1'
	[ -n "${4:-}" ] && uci delete truba.main.routing
	uci commit truba
	logger -t truba-test "reinstall $1"
	bounded 60 env PATH="/tmp/ri-bin:$PATH" NETWORK_RESTART=true TRUBA_INIT=true sh /etc/truba/reinstall.sh >/dev/null 2>&1
	logread | sed -n "/truba-test: reinstall $1\$/,\$p" | grep truba-reinstall > /tmp/ri.log
}
rt() { uci -q get truba.main.routing; }
inlog() { grep -qF "$1" /tmp/ri.log; }
ri 1 0 0
check "модуль есть: apk ставит Трубу с выключенной Маршрутизацией, потом она возвращена" \
	eval '[ "$(cat /tmp/apk-routing)" = 0 ] && [ "$(rt)" = 1 ]'
check "модуль есть: в журнале выключение и возврат" \
	eval 'inlog "Маршрутизация выключена на время установки (была: 1)" && inlog "Маршрутизация возвращена: 1"'
ri 2 1 0
check "модуля нет: Маршрутизация остаётся выключенной" test "$(rt)" = 0
check "модуля нет: в журнале команда установки модуля и возврата" \
	eval 'inlog "apk add kmod-amneziawg" && inlog "uci set truba.main.routing=1" && ! inlog "Маршрутизация возвращена"'
ri 3 0 1
check "установка не удалась: Маршрутизация остаётся выключенной" test "$(rt)" = 0
check "установка не удалась: в журнале команда возврата" eval 'inlog "не удалось установить" && inlog "uci set truba.main.routing=1"'
ri 4 0 0 nostring
check "строки routing не было: после переустановки «вкл» записано явно" \
	eval '[ "$(cat /tmp/apk-routing)" = 0 ] && [ "$(rt)" = 1 ] && inlog "(была: 1)"'
rm -rf /tmp/ri-bin /tmp/apk-kmod /tmp/apk-rc /tmp/apk-routing /tmp/ri.log
if [ -f /tmp/truba.list.ri ]; then mv /tmp/truba.list.ri "$LIST"; else rm -f "$LIST"; fi
cp /tmp/dhcp.ri /etc/config/dhcp; cp /tmp/truba.ri /etc/config/truba; cp /tmp/dnsmasq.ri.json /etc/truba/state/dnsmasq.json
/etc/init.d/dnsmasq restart >/dev/null 2>&1
reload "после reinstall.sh"

finish
