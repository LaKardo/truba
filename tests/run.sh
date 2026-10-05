#!/usr/bin/env bash
# Все проверки Трубы в Docker (Linux / CI). Нужен docker с правом --privileged.
#   tests/run.sh            — всё
#   tests/run.sh dat|router|vps|luci
# DAT_DIR — каталог с geoip.dat/geosite.dat (иначе скачиваются свежие из release-веток).
# TRUBA_SNAPSHOT=2026-10-04 — сверять точные числа (только для файлов от этой даты).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=immortalwrt/rootfs:x86-64-openwrt-25.12
TEST_IMG=truba-test:wg
WHAT=${1:-all}
FAILED=()

DAT_DIR=${DAT_DIR:-}
if [ -z "$DAT_DIR" ]; then
	DAT_DIR=$(mktemp -d)
	curl -fsSL -o "$DAT_DIR/geoip.dat" https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat
	curl -fsSL -o "$DAT_DIR/geosite.dat" https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat
fi

run() {
	local name=$1; shift
	echo "=== $name"
	if "$@"; then echo "=== $name: OK"; else echo "=== $name: FAILED"; FAILED+=("$name"); fi
}

t_dat() {
	docker run --rm -e TRUBA_SNAPSHOT="${TRUBA_SNAPSHOT:-}" -v "$ROOT:/repo:ro" -v "$DAT_DIR:/dat:ro" "$IMG" \
		ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' /repo/tests/router/test_dat.uc /dat/geoip.dat /dat/geosite.dat
}

t_router() {
	# Зависимости ставятся в образ заранее: под procd у контейнера нет сети.
	if ! docker image inspect "$TEST_IMG" >/dev/null 2>&1; then
		docker rm -f truba-base >/dev/null 2>&1 || true
		docker run --name truba-base "$IMG" sh -c 'apk update >/dev/null && apk add mosdns ucode-mod-socket curl ip-full wireguard-tools >/dev/null'
		docker commit truba-base "$TEST_IMG" >/dev/null
		docker rm truba-base >/dev/null
	fi
	docker rm -f truba-it >/dev/null 2>&1 || true
	docker run -d --privileged --name truba-it -v "$ROOT:/repo:ro" -v "$DAT_DIR:/dat:ro" "$TEST_IMG" /sbin/init >/dev/null
	sleep 10
	local rc=0
	docker exec truba-it sh /repo/tests/router/integration.sh || rc=$?
	docker rm -f truba-it >/dev/null
	return $rc
}

t_vps() {
	docker run --rm --cap-add NET_ADMIN -v "$ROOT:/repo:ro" ubuntu:24.04 bash /repo/tests/vps/test.sh
}

t_luci() {
	docker run --rm -v "$ROOT:/repo:ro" node:22-alpine node /repo/tests/luci/check.mjs
}

case "$WHAT" in
	dat) run "распаковщик .dat" t_dat ;;
	router) run "роутер (procd)" t_router ;;
	vps) run "VPS" t_vps ;;
	luci) run "LuCI (синтаксис, перевод)" t_luci ;;
	all)
		run "распаковщик .dat" t_dat
		run "роутер (procd)" t_router
		run "VPS" t_vps
		run "LuCI (синтаксис, перевод)" t_luci
		;;
	*) echo "неизвестно: $WHAT"; exit 2 ;;
esac

if [ ${#FAILED[@]} -gt 0 ]; then
	echo "НЕ ПРОШЛИ: ${FAILED[*]}"
	exit 1
fi
echo "ВСЕ ПРОВЕРКИ ПРОШЛИ"
