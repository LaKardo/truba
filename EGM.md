# Труба — Blueprint

Архитектурный контракт репозитория по модели EGM. Пользовательская документация — в [README.md](README.md), термины — в [CONTEXT.md](CONTEXT.md), устройство и решения — в [docs/architecture.md](docs/architecture.md) и [docs/adr/](docs/adr/README.md).

## System Overview

Две стороны и Туннель между ними:

- **Труба** (VPS, Ubuntu 24.04) — `vps/install-vps.sh`. nftables `ip truba_nat` пробрасывает весь публичный IP (кроме порта SSH и порта AWG) на адрес Роутера в Туннеле `10.77.77.2`; `inet truba_filter` закрывает всё остальное. На `10.77.77.1` работает unbound (DoT к Cloudflare и Google) как первый DNS-сервер «Туннеля» для Роутера (ADR 0013). Состояние — в `/etc/truba/pipe.env`, для Роутера генерируется `/root/truba/router.conf`.
- **Роутер** (ImmortalWrt) — пакет `router/truba`. Служба строит таблицу nftables `inet truba`: метки `0x01000000` (Туннель), `0x02000000` (Напрямую), `0x04000000` (входящие) в маске `0x0f000000` (ADR 0011), правила `ip -4 rule` priority 1000/1001 ведут в таблицу 77, где маршрут по умолчанию — Туннель, blackhole или ничего (`net.uc:set_table`); подъём и падение Туннеля — полное применение настроек через `truba hotplug` (ADR 0009). mosdns на `127.0.0.1:5335` классифицирует домены по Категориям geosite и наполняет наборы `gs_tunnel4`/`gs_direct4` (ADR 0003, 0007); dnsmasq перенаправляется на него. Контроль Туннеля, статистика скорости и устройств живут в RAM (ADR 0010, 0018). Всё доступно через ubus `truba` (ADR 0008).
- **Интерфейс** — пакет `router/luci-app-truba`. Семь вкладок LuCI на Preact в Shadow DOM (ADR 0017), читают только ubus `truba.*`, схему берут из `truba.schema` (ADR 0015), правят UCI и применяют через LuCI с откатом.

Синхронные границы: LuCI → rpcd → `truba-api.uc` → `S.status()`/CLI `truba …`; `truba apply` → `nft -f`, `ip`, UCI `dhcp`/`firewall`. Асинхронные: `nat_test`, `tunnel_test`, `update_lists` стартуют фоновый CLI и опрашиваются через `*_result`/`lists`; procd-экземпляры `stats` (всегда), `mosdns` и `watchdog` (по настройкам); cron `truba update-lists` ежечасно; на Трубе — таймер отката `truba-rollback` в окне подтверждения SSH и `truba-pipe.service` перед юнитом AWG.

## Subdirectories & System Boundaries

- vps: [./vps/EGM.md](./vps/EGM.md) — установщик Трубы: AmneziaWG из PPA, nftables 1:1, unbound, SSH с подтверждением и транзакционным откатом, `router.conf`
- router: [./router/EGM.md](./router/EGM.md) — пакеты Роутера
  - router/truba: [./router/truba/EGM.md](./router/truba/EGM.md) — служба, ubus-API, CLI, хуки установки и переустановки
  - router/luci-app-truba: [./router/luci-app-truba/EGM.md](./router/luci-app-truba/EGM.md) — интерфейс LuCI
- tests: [./tests/README.md](./tests/README.md) — проверки в Docker на настоящей ImmortalWrt (ADR 0012): `units`, `dat`, `luci`, `vps`, `router-*`, `ui`; эталоны в `tests/golden/`
- docs: [./docs/architecture.md](./docs/architecture.md), [./docs/adr/README.md](./docs/adr/README.md), [./docs/roadmap.md](./docs/roadmap.md) — устройство, решения, план
- .github/workflows: `build.yml` (фид apk в GitHub Pages), `tests.yml`, `watch-releases.yml` (новые ImmortalWrt 25.12.x), `upstream-lists.yml`

## Global Invariants

- Контракт между сторонами — `router.conf` от Трубы: адреса `10.77.77.1/30` и `10.77.77.2`, порт и параметры AWG на обеих сторонах должны совпадать; `RandomTrailers` и смена протокола требуют повторного импорта [vps/install-vps.sh:router_conf, write_router_conf; router/luci-app-truba awg.js:applyConf]
- Версии `truba` и `luci-app-truba` движутся парой: `LUCI_EXTRA_DEPENDS:=truba (>=1.2.0-r7)`; оба `PKG_VERSION:=1.2.0`, `PKG_RELEASE:=7` [router/truba/Makefile, router/luci-app-truba/Makefile]
- Версия AmneziaWG в фиде (`router/awg/SOURCES`) должна совпадать с версией из PPA `amnezia/ppa` на Трубе [router/awg/SOURCES; vps/install-vps.sh:awg_version]
- Пути, имена наборов, метки и схема настроек определяются один раз в `const.uc`/`conf.uc` службы; shell, интерфейс и тесты получают их через `truba env` и `truba.schema` (ADR 0015) [router/truba/files/usr/share/ucode/truba/const.uc, conf.uc]
- Маршрутизация через Трубу — только IPv4; IPv6 внутри сети не трогается, выход в интернет по IPv6 закрывается только зонам Маршрутизации правилом REJECT (ADR 0005, 0016) [router/truba net.uc:no6_rule, dns.uc:mosdns]
- Неудачное применение не останавливает службу и не отнимает DNS: действуют прежние правила или последняя удачная копия с флеша (ADR 0006) [router/truba core.uc:keep_running, init.d/truba]
- Метки Трубы не затирают чужие биты fwmark; чужие цепочки и mesh-VPN переживают загрузку в любом порядке (ADR 0011) [router/truba render.uc:set_meta]
- Туннель на Трубе никогда не поднимается без правил фильтра: `truba-pipe.service` обязателен для юнита AWG [vps/install-vps.sh:write_pipe_unit, setup_awg_service]
- Ключи и конфиги Туннеля (`*.pem`, `router.conf`, `pipe.env`, `*.dat`) не попадают в репозиторий [.gitignore]
- Файлы `lib/` интерфейса закреплены по sha256 и не минифицируются; CI и тесты сверяют их [router/luci-app-truba/Makefile, lib/VERSIONS]

## Global Side Effects

- Труба: системные файлы в `/etc/truba`, `/etc/amnezia/amneziawg`, `/etc/systemd/system`, `/etc/sysctl.d`, `/etc/ssh/sshd_config.d`, `/etc/unbound/unbound.conf.d`, `/etc/fail2ban/jail.d`; таблицы nft `truba_nat`/`truba_filter`; пакеты из PPA `amnezia/ppa`; трафик к keyserver Ubuntu, `1.1.1.1`/`1.0.0.1`/`8.8.8.8`/`8.8.4.4` [vps/EGM.md]
- Роутер: таблица `inet truba`, таблица маршрутов 77, UCI `dhcp`/`firewall`/`upnpd`/`network`, `/etc/crontabs/root`, `/etc/rc.local`, флеш `/etc/truba/{lists,state,good}`, RAM `/var/run/truba`, `/var/lib/truba`, `/var/etc/truba`; загрузка `.dat` с GitHub/jsDelivr (`kirilllavrov/geoip-builder`, `geosite-builder`); STUN к Google и Cloudflare; переустановка пакетов через `apk` после sysupgrade [router/truba/EGM.md]
- Интерфейс: браузерный UCI и `localStorage['truba.span']`; изменяющие ubus-вызовы `update_lists`, `rollback_lists`, `nat_test`, `tunnel_test` [router/luci-app-truba/EGM.md]
- CI: ветка `gh-pages` — подписанный фид apk (`APK_SIGN_KEY`/`APK_SIGN_PUB` в Secrets) [README.md, .github/workflows/build.yml]

## System Verification

- Run: `bash tests/run.sh` (все части параллельно в Docker; одна часть — `bash tests/run.sh <часть>`, подробности в [tests/README.md](./tests/README.md))
- Приёмочные тесты на живой сети — в [docs/roadmap.md](./docs/roadmap.md#приёмочные-тесты)
