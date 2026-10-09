#!/usr/bin/env bash
# Все проверки Трубы в Docker (Linux / CI; на Windows — из Git Bash). Нужен docker с правом --privileged.
#   tests/run.sh            — всё
#   tests/run.sh units|dat|router|vps|luci|ui
# Наборы правил — зафиксированные выпуски из tests/dat.pin, с точными числами снимка.
# DAT_FRESH=1 — свежие из release-веток (ежедневная проверка источника);
# DAT_DIR — свой каталог с geoip.dat и geosite.dat (тогда TRUBA_SNAPSHOT — по желанию).
# UPDATE_GOLDEN=1 tests/run.sh units — записать эталоны правил и конфига mosdns заново.
# UI_OUT — каталог для снимков вкладок LuCI (ui).
set -euo pipefail
# Git Bash иначе переписывает пути контейнера (/repo) в аргументах docker.
export MSYS_NO_PATHCONV=1

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=immortalwrt/rootfs:x86-64-openwrt-25.12
TEST_IMG=truba-test:wg
# Браузер для проверки интерфейса — по дайджесту: образ не меняется сам.
BROWSER_IMG=zenika/alpine-chrome@sha256:ee10e24217aa27443e6b58da628f3b09ea9b814459915b8b62fe15a555f9692a
WHAT=${1:-all}
FAILED=()

# Путь каталога для docker -v. В Git Bash /tmp — это папка Windows, которую docker под этим
# именем не видит: нужен путь Windows (pwd -W). В Linux — обычный путь.
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

# Наборы правил нужны dat, router и ui: скачиваются один раз и только для них.
dat_dir() {
	[ -z "${DAT_DIR:-}" ] || return 0
	local d
	# Сразу путь для хоста: curl в Git Bash — программа Windows, /tmp она не знает.
	d=$(hostpath "$(mktemp -d)")
	if [ -n "${DAT_FRESH:-}" ]; then
		curl -fsSL -o "$d/geoip.dat" https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat || return 1
		curl -fsSL -o "$d/geosite.dat" https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat || return 1
	else
		# shellcheck source=tests/dat.pin
		. "$ROOT/tests/dat.pin"
		curl -fsSL -o "$d/geoip.dat" "https://github.com/kirilllavrov/geoip-builder/releases/download/$GEOIP_TAG/geoip.dat" || return 1
		curl -fsSL -o "$d/geosite.dat" "https://github.com/kirilllavrov/geosite-builder/releases/download/$GEOSITE_TAG/geosite.dat" || return 1
		printf '%s  %s\n%s  %s\n' "$GEOIP_SHA256" "$d/geoip.dat" "$GEOSITE_SHA256" "$d/geosite.dat" | sha256sum -c --quiet - || return 1
		export TRUBA_SNAPSHOT=${TRUBA_SNAPSHOT:-$SNAPSHOT}
	fi
	DAT_DIR=$d
}

# Образ с зависимостями Роутера — заранее: под procd у контейнера нет сети.
test_img() {
	docker image inspect "$TEST_IMG" >/dev/null 2>&1 && return 0
	docker rm -f truba-base >/dev/null 2>&1 || true
	docker run --name truba-base "$IMG" sh -c 'apk update >/dev/null && apk add mosdns ucode-mod-socket curl ip-full wireguard-tools >/dev/null' || return 1
	docker commit truba-base "$TEST_IMG" >/dev/null
	docker rm truba-base >/dev/null
}

run() {
	local name=$1; shift
	echo "=== $name"
	if "$@"; then echo "=== $name: OK"; else echo "=== $name: FAILED"; FAILED+=("$name"); fi
}

t_units() {
	local mode=ro
	if [ -n "${UPDATE_GOLDEN:-}" ]; then
		mode=rw
		mkdir -p "$ROOT/tests/router/golden"
	fi
	# NET_ADMIN — для nft -c: ядро проверяет сгенерированные таблицы, ничего не загружая.
	docker run --rm --cap-add NET_ADMIN -e UPDATE_GOLDEN="${UPDATE_GOLDEN:-}" -v "$(hostpath "$ROOT"):/repo:$mode" "$IMG" \
		ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' /repo/tests/router/test_units.uc /repo/tests/router/golden
}

t_dat() {
	dat_dir || return 1
	docker run --rm -e TRUBA_SNAPSHOT="${TRUBA_SNAPSHOT:-}" -v "$(hostpath "$ROOT"):/repo:ro" -v "$DAT_DIR:/dat:ro" "$IMG" \
		ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' /repo/tests/router/test_dat.uc /dat/geoip.dat /dat/geosite.dat
}

t_router() {
	dat_dir || return 1
	test_img || return 1
	docker rm -f truba-it >/dev/null 2>&1 || true
	docker run -d --privileged --name truba-it -v "$(hostpath "$ROOT"):/repo:ro" -v "$DAT_DIR:/dat:ro" "$TEST_IMG" /sbin/init >/dev/null
	sleep 10
	local rc=0
	docker exec truba-it sh /repo/tests/router/integration.sh || rc=$?
	docker rm -f truba-it >/dev/null
	return $rc
}

t_vps() {
	docker run --rm --cap-add NET_ADMIN -v "$(hostpath "$ROOT"):/repo:ro" ubuntu:24.04 bash /repo/tests/vps/test.sh
}

t_luci() {
	docker run --rm -v "$(hostpath "$ROOT"):/repo:ro" node:22-alpine node /repo/tests/luci/check.mjs
}

# Интерфейс в браузере: живой стенд LuCI (tests/luci/setup-live.sh), headless Chromium обходит
# все вкладки (ошибки JS, сломанные страницы) и проверяет «Сохранить и применить» по шагам.
t_ui() {
	dat_dir || return 1
	test_img || return 1
	local out=${UI_OUT:-} ip rc=0 step
	[ -n "$out" ] || out=$(mktemp -d)
	mkdir -p "$out"
	docker rm -f truba-ui >/dev/null 2>&1 || true
	docker run -d --privileged --name truba-ui -v "$(hostpath "$ROOT"):/repo:ro" -v "$DAT_DIR:/dat:ro" "$TEST_IMG" /sbin/init >/dev/null
	sleep 10
	# Адрес Docker netifd стенда снимает при загрузке (wan по DHCP): стенд получает его отсюда.
	ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' truba-ui)
	local len gw
	len=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPPrefixLen}}{{end}}' truba-ui)
	gw=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' truba-ui)
	if docker exec -e STAND_ADDR="$ip/$len" -e STAND_GW="$gw" truba-ui sh /repo/tests/luci/setup-live.sh; then
		browser() {
			# root и --no-sandbox (в скриптах): каталог снимков смонтирован с хоста.
			docker run --rm -u 0 -e NODE_PATH=/usr/src/app/node_modules --entrypoint node \
				-v "$(hostpath "$ROOT"):/repo:ro" -v "$(hostpath "$out"):/out" "$BROWSER_IMG" "$@"
		}
		browser /repo/tests/luci/screens.js "http://$ip" /out || rc=1
		for step in step1 step2 step3; do
			browser /repo/tests/luci/apply.js "http://$ip" "$step" || { rc=1; break; }
			docker exec truba-ui sh /repo/tests/luci/verify-apply.sh "$step" || rc=1
		done
	else
		rc=1
	fi
	[ "$rc" = 0 ] || docker exec truba-ui sh -c 'logread | tail -40' || true
	docker rm -f truba-ui >/dev/null
	echo "снимки вкладок: $out"
	return $rc
}

case "$WHAT" in
	units) run "модули (план, правила, настройки)" t_units ;;
	dat) run "распаковщик .dat" t_dat ;;
	router) run "роутер (procd)" t_router ;;
	vps) run "VPS" t_vps ;;
	luci) run "LuCI (синтаксис, перевод)" t_luci ;;
	ui) run "LuCI в браузере" t_ui ;;
	all)
		run "модули (план, правила, настройки)" t_units
		run "распаковщик .dat" t_dat
		run "роутер (procd)" t_router
		run "VPS" t_vps
		run "LuCI (синтаксис, перевод)" t_luci
		run "LuCI в браузере" t_ui
		;;
	*) echo "неизвестно: $WHAT"; exit 2 ;;
esac

if [ ${#FAILED[@]} -gt 0 ]; then
	echo "НЕ ПРОШЛИ: ${FAILED[*]}"
	exit 1
fi
echo "ВСЕ ПРОВЕРКИ ПРОШЛИ"
