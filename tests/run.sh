#!/usr/bin/env bash
# Проверки «Трубы» в Docker (Linux, CI; на Windows — из Git Bash). Нужен docker с --privileged.
#   tests/run.sh                  — все части параллельно
#   tests/run.sh units router     — выбранные (router — все части Роутера)
# Части: units dat vps luci ui router-net router-dns router-lists router-life router-tunnel router-stats
# Одна часть — вывод сразу в консоль; несколько — каждая в свой журнал (LOG_DIR), в конце таблица.
# Переменные:
#   JOBS=N          — не больше N частей одновременно (по умолчанию — все сразу)
#   DAT_FRESH=1     — свежие Наборы правил из release-веток вместо закреплённых в tests/dat.pin
#   DAT_DIR=…       — свой каталог с geoip.dat и geosite.dat
#   UPDATE_GOLDEN=1 — записать эталоны tests/golden заново (часть units)
#   UI_OUT=…        — каталог для снимков вкладок LuCI (часть ui)
#   IMAGE_CACHE=…   — каталог архивов образов Docker: образ берётся оттуда, а не из Docker Hub
#                     (CI хранит его в actions/cache и обновляет раз в неделю)
set -euo pipefail
# Git Bash иначе переписывает пути контейнера (/repo) в аргументах docker.
export MSYS_NO_PATHCONV=1

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Роутер — последняя ImmortalWrt 25.12.x: тег плавающий намеренно, проверки идут на той же
# ветке выпусков, что ставят на Роутер (в CI образ обновляется с недельным кэшем).
IMG=immortalwrt/rootfs:x86-64-openwrt-25.12
# Образ Роутера с зависимостями Трубы. Имя — по базовому образу и списку пакетов: другой
# список или другая база — другой образ, а не старый из локального кэша.
TEST_PKGS="mosdns ucode-mod-socket curl ip-full wireguard-tools"
TEST_IMG=truba-test:$(printf '%s %s' "$IMG" "$TEST_PKGS" | sha256sum | cut -c1-12)
# Браузер — по дайджесту: образ не меняется сам.
BROWSER_IMG=zenika/alpine-chrome@sha256:ee10e24217aa27443e6b58da628f3b09ea9b814459915b8b62fe15a555f9692a
VPS_IMG=ubuntu:24.04
NODE_IMG=node:22-alpine
ROUTER_PARTS=(router-net router-dns router-lists router-life router-tunnel router-stats)
ALL=(units dat vps luci ui "${ROUTER_PARTS[@]}")
# Имена контейнеров этого запуска: два запуска рядом друг другу не мешают.
RUN_ID=truba-t$$

# Путь каталога для docker -v. В Git Bash /tmp — это папка Windows, которую docker под этим
# именем не видит: нужен путь Windows (pwd -W). В Linux — обычный путь.
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
REPO=$(hostpath "$ROOT")

# ---- подготовка: один раз до параллельного запуска ----

# Наборы правил для dat, router и ui. Закреплённые выпуски не меняются: скачанные один раз
# лежат в кэше (DAT_CACHE) и сверяются по SHA-256 из tests/dat.pin.
dat_dir() {
	[ -z "${DAT_DIR:-}" ] || return 0
	local d
	if [ -n "${DAT_FRESH:-}" ]; then
		# Сразу путь для хоста: curl в Git Bash — программа Windows, /tmp она не знает.
		d=$(hostpath "$(mktemp -d)")
		curl -fsSL -o "$d/geoip.dat" https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat
		curl -fsSL -o "$d/geosite.dat" https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat
	else
		# shellcheck source=tests/dat.pin
		. "$ROOT/tests/dat.pin"
		d=${DAT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/truba-tests}/$GEOIP_TAG-$GEOSITE_TAG
		mkdir -p "$d"
		d=$(hostpath "$d")
		pinned() { printf '%s  %s\n%s  %s\n' "$GEOIP_SHA256" "$d/geoip.dat" "$GEOSITE_SHA256" "$d/geosite.dat" | sha256sum -c --quiet - >/dev/null 2>&1; }
		if ! pinned; then
			curl -fsSL -o "$d/geoip.dat" "https://github.com/kirilllavrov/geoip-builder/releases/download/$GEOIP_TAG/geoip.dat"
			curl -fsSL -o "$d/geosite.dat" "https://github.com/kirilllavrov/geosite-builder/releases/download/$GEOSITE_TAG/geosite.dat"
			pinned || { echo "Наборы правил не совпали с tests/dat.pin"; return 1; }
		fi
		export TRUBA_SNAPSHOT=${TRUBA_SNAPSHOT:-$SNAPSHOT}
	fi
	export DAT_DIR=$d
}

# ---- образы: локально, из IMAGE_CACHE или из Docker Hub (тогда — в IMAGE_CACHE) ----

img_file() { echo "$IMAGE_CACHE/$(echo "$1" | tr '/:@' '___').tar"; }
img_cached() {
	docker image inspect "$1" >/dev/null 2>&1 && return 0
	[ -n "${IMAGE_CACHE:-}" ] && [ -f "$(img_file "$1")" ] && docker load -q -i "$(img_file "$1")" >/dev/null
}
img_save() {
	[ -n "${IMAGE_CACHE:-}" ] || return 0
	mkdir -p "$IMAGE_CACHE"
	docker save -o "$(img_file "$1")" "$1"
}
img() { img_cached "$1" || { docker pull -q "$1" >/dev/null && img_save "$1"; }; }

# Образ Роутера с зависимостями Трубы — заранее: под procd у контейнера нет сети.
test_img() {
	img_cached "$TEST_IMG" && return 0
	docker rm -f "$RUN_ID-base" >/dev/null 2>&1 || true
	docker run --name "$RUN_ID-base" "$IMG" sh -c "apk update >/dev/null && apk add $TEST_PKGS >/dev/null"
	docker commit "$RUN_ID-base" "$TEST_IMG" >/dev/null
	docker rm "$RUN_ID-base" >/dev/null
	img_save "$TEST_IMG"
}

# ---- стенд: Роутер под настоящим procd ----

# --privileged открывает /proc/kmsg хоста, а logd читает его сам. Если на хосте /proc/kmsg
# читает кто-то ещё (раннер CI), logd может повиснуть в read, а с ним logread, метод log
# в rpcd и весь LuCI: стенду ядро хоста не нужно — /dev/null до запуска procd.
# Готовность — маркер из /etc/rc.local: его запускает S95done, когда службы загрузки уже стоят.
stand() {
	local name=$RUN_ID-$1
	docker rm -f "$name" >/dev/null 2>&1 || true
	docker run -d --privileged --name "$name" -v "$REPO:/repo:ro" -v "$DAT_DIR:/dat:ro" --entrypoint sh "$TEST_IMG" \
		-c 'mount --bind /dev/null /proc/kmsg && echo "touch /tmp/booted" > /etc/rc.local && exec /sbin/init' >/dev/null
	for _ in $(seq 60); do
		docker exec "$name" test -e /tmp/booted 2>/dev/null && return 0
		sleep 0.5
	done
	echo "стенд $name не загрузился за 30 с"
	return 1
}
unstand() { docker rm -f "$RUN_ID-$1" >/dev/null 2>&1 || true; }

# ---- части ----

t_units() {
	local mode=ro
	[ -z "${UPDATE_GOLDEN:-}" ] || mode=rw
	# NET_ADMIN — для nft -c: ядро проверяет сгенерированные таблицы, ничего не загружая.
	docker run --rm --cap-add NET_ADMIN -e UPDATE_GOLDEN="${UPDATE_GOLDEN:-}" -v "$REPO:/repo:$mode" "$TEST_IMG" \
		ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' -L '/repo/tests/lib/*.uc' /repo/tests/unit/units.uc /repo/tests/golden
}

t_dat() {
	docker run --rm -e TRUBA_SNAPSHOT="${TRUBA_SNAPSHOT:-}" -v "$REPO:/repo:ro" -v "$DAT_DIR:/dat:ro" "$IMG" \
		ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' -L '/repo/tests/lib/*.uc' /repo/tests/unit/dat.uc /dat/geoip.dat /dat/geosite.dat
}

t_vps() {
	docker run --rm --cap-add NET_ADMIN -v "$REPO:/repo:ro" "$VPS_IMG" bash /repo/tests/vps/test.sh
}

# Node есть на машине (и на раннере CI) — без контейнера.
host_node() { command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 18 ]; }
t_luci() {
	if host_node; then
		node "$REPO/tests/luci/static.mjs"
	else
		docker run --rm -v "$REPO:/repo:ro" "$NODE_IMG" node /repo/tests/luci/static.mjs
	fi
}

# Часть Роутера: свой стенд, сценарий tests/router/<часть>.sh.
t_router() {
	local part=$1 rc=0
	stand "$part" || { unstand "$part"; return 1; }
	docker exec "$RUN_ID-$part" sh "/repo/tests/router/$part.sh" || rc=$?
	unstand "$part"
	return $rc
}

# Интерфейс в браузере: живой стенд LuCI и один проход headless Chromium (tests/luci/browser.js).
t_ui() {
	local out=${UI_OUT:-} name=$RUN_ID-ui ip len gw rc=0
	[ -n "$out" ] || out=$(mktemp -d)
	mkdir -p "$out"
	stand ui || { unstand ui; return 1; }
	# Адрес Docker netifd стенда снимает при загрузке (wan по DHCP): стенд получает его отсюда.
	ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
	len=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPPrefixLen}}{{end}}' "$name")
	gw=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$name")
	if docker exec -e STAND_ADDR="$ip/$len" -e STAND_GW="$gw" "$name" sh /repo/tests/luci/stand.sh; then
		# root и --no-sandbox (в скрипте): каталог снимков смонтирован с хоста.
		docker run --rm -u 0 -e NODE_PATH=/usr/src/app/node_modules --entrypoint node \
			-v "$REPO:/repo:ro" -v "$(hostpath "$out"):/out" "$BROWSER_IMG" /repo/tests/luci/browser.js "http://$ip" /out || rc=1
	else
		rc=1
	fi
	[ "$rc" = 0 ] || docker exec "$name" sh -c 'logread | tail -40' || true
	unstand ui
	echo "снимки вкладок: $out"
	return $rc
}

run_part() {
	case "$1" in
		units|dat|vps|luci|ui) "t_$1" ;;
		router-*) t_router "${1#router-}" ;;
	esac
}

# ---- запуск ----

PARTS=()
for a in "${@:-all}"; do
	case "$a" in
		all) PARTS+=("${ALL[@]}") ;;
		router) PARTS+=("${ROUTER_PARTS[@]}") ;;
		units|dat|vps|luci|ui|router-net|router-dns|router-lists|router-life|router-tunnel|router-stats) PARTS+=("$a") ;;
		*) echo "неизвестная часть: $a (есть: ${ALL[*]}, router, all)"; exit 2 ;;
	esac
done

trap 'docker ps -aq --filter "name=^$RUN_ID-" | xargs -r docker rm -f >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM

# need ШАБЛОН… — нужна ли выбранным частям подготовка.
# shellcheck disable=SC2254 # шаблоны частей — намеренно glob
need() { local p w; for p in "${PARTS[@]}"; do for w in "$@"; do case "$p" in $w) return 0 ;; esac; done; done; return 1; }
if need dat ui 'router-*'; then dat_dir; fi
# Образы — до параллельного запуска: одна часть не тянет тот же образ, пока его пишет другая.
if need dat; then img "$IMG"; fi
if need units ui 'router-*'; then test_img; fi
if need vps; then img "$VPS_IMG"; fi
if need ui; then img "$BROWSER_IMG"; fi
if need luci && ! host_node; then img "$NODE_IMG"; fi

if [ ${#PARTS[@]} -eq 1 ]; then
	echo "=== ${PARTS[0]}"
	if run_part "${PARTS[0]}"; then echo "=== ${PARTS[0]}: OK"; exit 0; fi
	echo "=== ${PARTS[0]}: FAILED"; exit 1
fi

LOG_DIR=${LOG_DIR:-$(mktemp -d)}
mkdir -p "$LOG_DIR"
declare -A PID
for p in "${PARTS[@]}"; do
	while [ -n "${JOBS:-}" ] && [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
	# Время части пишет она сама: ждём их по порядку, а заканчиваются они как придётся.
	(
		s=$(date +%s)
		if run_part "$p" > "$LOG_DIR/$p.log" 2>&1; then rc=0; else rc=$?; fi
		echo $(( $(date +%s) - s )) > "$LOG_DIR/$p.time"
		exit $rc
	) &
	PID[$p]=$!
	echo "▶ $p"
done

FAILED=()
for p in "${PARTS[@]}"; do
	if wait "${PID[$p]}"; then
		printf '  ok    %-14s %4s с\n' "$p" "$(cat "$LOG_DIR/$p.time" 2>/dev/null)"
	else
		printf '  FAIL  %-14s %4s с   %s\n' "$p" "$(cat "$LOG_DIR/$p.time" 2>/dev/null)" "$LOG_DIR/$p.log"
		FAILED+=("$p")
	fi
done
echo "журналы: $LOG_DIR, всего $SECONDS с"

if [ ${#FAILED[@]} -gt 0 ]; then
	for p in "${FAILED[@]}"; do
		echo
		echo "=== $p: провалы и конец журнала"
		grep -E '^(FAIL|TIMEOUT|JSERR)' "$LOG_DIR/$p.log" || true
		tail -15 "$LOG_DIR/$p.log"
	done
	echo
	echo "НЕ ПРОШЛИ: ${FAILED[*]}"
	exit 1
fi
echo "ВСЕ ПРОВЕРКИ ПРОШЛИ"
