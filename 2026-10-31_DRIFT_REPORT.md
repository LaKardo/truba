# EGM Drift Report — 2026-10-31

Проверка пяти контрактов `EGM.md`, созданных `egm-bootstrap`, против исходного кода. Перечислены только расхождения. `doc→code` — контракт утверждает то, чего в коде нет или что в коде иначе; `code→doc` — в коде есть заметное поведение, не отражённое в контракте.

Статус: все пункты `doc→code` и существенные `code→doc` исправлены в контрактах в тот же день (см. раздел «Исправлено»). Остальные `code→doc` оставлены как осознанно опущенные детали.

## vps/EGM.md

- **[doc→code]** `Генерация: … [install-vps.sh:934-1051]` — `gen_i1` на 830–869, `gen_params` на 880–932, вне указанного диапазона.
- **[doc→code]** `непустой /root/.ssh/authorized_keys` — `have_key_login` дополнительно требует, чтобы `ssh-keygen -l -f` прочитал валидный ключ [install-vps.sh:have_key_login].
- **[doc→code]** `(приватные и multicast диапазоны отвергаются)` — `public_ipv4` отвергает также 0/8, 127/8, 100.64/10, 169.254/16 и всё ≥ 224 [install-vps.sh:public_ipv4].
- **[doc→code]** `все файлы пишутся атомарно через put_file` — `/run/truba/pipe-vars.nft` пишется простым `>`; файлы транзакции (`manifest.tmp`, `awg-unit`, копия скрипта) — через `>>`, `echo >`, `cp` [install-vps.sh:write_nft, txn_begin, rollback_timer_start].
- **[doc→code]** `любой существующий *.sources с amnezia/ppa — тоже` — без `gpg` `ppa_key_check` только предупреждает; `*.list` с `amnezia/ppa` — только предупреждение [install-vps.sh:ppa_key_check].
- **[doc→code]** `Повторный install не меняет AWG_PROTO и параметры AWG` — `refresh_i1` регенерирует `I1`/`I1_SRV`, если `AWG_PROTO ≥ 2` и `I1_SRV` пуст [install-vps.sh:refresh_i1].
- **[doc→code]** `Без --no-confirm требуется /dev/tty и реальный файл скрипта` — только при `SSH_CONFIRMED != 1`; повторный install с подтверждённым портом этого не требует [install-vps.sh:cmd_install].
- **[doc→code]** `Таймер отката … сработает, даже если установщик убит` — таймер запускается только когда SSH ещё не подтверждён, есть `SSH_FALLBACK` и `NO_CONFIRM != 1`; при `--no-confirm` и в `rotate-keys` таймера нет [install-vps.sh:cmd_install].
- **[doc→code]** `Любая изменяющая команда берёт flock … и сначала выполняет txn_recover` — `txn-rollback` использует `flock -w 60`, продолжает без замка и не вызывает `txn_recover` [install-vps.sh:main].
- **[doc→code]** `unbound … — после txn_commit` — только `setup_unbound`; `pick_forwarders` и `write_unbound_conf` выполняются в `install_packages`, до `txn_begin` [install-vps.sh:install_packages].
- **[doc→code]** `DNAT … всего UDP кроме AWG_PORT` — UDP-порт 68 (DHCP-клиент VPS) тоже исключён [install-vps.sh:write_nft].
- **[doc→code]** `Снимок транзакции … (копия скрипта) создаётся в txn_begin` — копию скрипта делает `rollback_timer_start`, маркер `ufw-off` — `ufw_off`; `TXN_DIR` удаляется ещё и в `cmd_uninstall`.
- **[doc→code]** Цитаты у списка файлов: `owned.env` пишет `save_owned`, `pipe-vars.sh` — `write_pipe_vars_sh`, drop-in AWG и `truba-awg.service` — `setup_awg_service` (не `write_pipe_unit`).
- **[doc→code]** Список пакетов не включает `gpg` (ставится вместе с `curl` в `ppa_add`).
- **[code→doc]** `uninstall` включает обратно `unbound-resolvconf.service` при `RESOLVCONF_ENABLED=1`, перезапускает `systemd-journald` и `fail2ban`, удаляет каталог drop-in, сбрасывает `UFW_DISABLED=0` [install-vps.sh:cmd_uninstall].
- **[code→doc]** `diag` принимает только 5–600 с (по умолчанию 30), иначе `die` [install-vps.sh:cmd_diag].
- **[code→doc]** Без команды или с неизвестной — usage и exit 2; неизвестный флаг — `die`; флаги разбираются для любой команды [install-vps.sh:main].
- **[code→doc]** `mtu-check` ищет от 1028 до MTU WAN, рекомендует результат минус `tun_overhead`, не больше `MTU_MAX` [install-vps.sh:cmd_mtu_check].
- **[code→doc]** `repair-module` также делает `modprobe amneziawg` и перезапускает юнит AWG, если интерфейса нет [install-vps.sh:cmd_repair_module].
- **[code→doc]** `install_packages` делает `apt-mark auto` на заголовки текущего ядра [install-vps.sh:install_packages].
- **[code→doc]** `status` предупреждает об оставшемся `txn/manifest`, о расхождении WAN/IP с `pipe.env`, печатает conntrack count/max [install-vps.sh:cmd_status].
- **[code→doc]** `diag` читает также `/proc/meminfo`, `/proc/cpuinfo`, `systemd-detect-virt`.
- **[code→doc]** Drop-in sshd задаёт также `MaxAuthTries 3`, `LoginGraceTime 20`, `X11Forwarding no` [install-vps.sh:ssh_apply].
- **[code→doc]** `tc qdisc del dev WAN root` перед `replace … mq` [install-vps.sh:wan_qdisc].

## router/truba/EGM.md

- **[code→doc]** Экспорт `util.uc`: не перечислены `info`, `warn_log`, `err`, `now_ms`, `mkdirp`, `sha_from_sumfile`, `write_if_changed`, `errmsg`, `is_ipv4`, `to_list`.
- **[code→doc]** Экспорт `conf.uc`: не перечислены `UPSTREAM_SCHEMES`, `UPSTREAM_RE`.
- **[code→doc]** Экспорт `const.uc`: не покрыты `FW_FWD_SUFFIX`, `FW_NO6_SUFFIX`, `LOG_TAG`, `WATCHDOG_TAG`, `CLI`, `INIT`, `MOSDNS_ADDR`, `CONN_TOP`, `PROBE_WINDOW`, `DAT_FILES`, `CRON_BEGIN`, `CRON_END`.
- **[doc→code]** `Неверное значение UCI … попадает в cfg.invalid` — только типы `int`, `pattern`, `ipv4`, `upstreams`; неверные `bool`, `enum`, `list` молча становятся умолчанием [conf.uc:check_value].
- **[doc→code]** `устройства — до 256` — `DEV_LIST_MAX=256` ограничивает только вывод `devices()` (устройства с Политикой выходят за предел); наборы ядра вмещают `DEV_SET_SIZE=1024`; `devstats.add` предела не имеет [const.uc, devices.uc:merge].
- **[doc→code]** `при полной перезагрузке элементы gs_*4 и счётчики переносятся из ядра` — счётчики всегда, элементы `gs_*4` — только при `prev.routing && prev.gkey == gkey` [core.uc:apply_config].
- **[doc→code]** `start_service … открывает procd-экземпляры mosdns, watchdog, stats` — `mosdns` только при `applied.mosdns == true` и непустом конфиге, `watchdog` только при `TRUBA_WATCHDOG=1`; безусловно — только `stats` [init.d/truba:start_service].
- **[doc→code]** `успех — внешний IP равен IP Трубы, порт сохранён и согласован` — условие `consistent !== false`: при ответе одного STUN-сервера `consistent == null`, и проверка всё равно успешна [nattest.uc:run].
- **[doc→code]** `awg set <dev> listen-port 0 … при повторных сбоях` — только если `network.<iface>.listen_port` не задан или 0; `ifup` — всегда [watchdog.uc:tick].
- **[doc→code]** `main: … stun` — в поставляемом `files/etc/config/truba` опции `stun` не было; она есть только в `SCHEMA.main.stun` (по умолчанию `[]`). **Исправлено в коде**: добавлен закомментированный пример `list stun` в конфиг.

## router/luci-app-truba/EGM.md

- **[doc→code]** Строка `rules.js` не упоминает `schema`, хотя `load()` вызывает `common.loadSchema()` и `Zones` читает `consts.fw_zone` и `sections.main.zone.def`.
- **[code→doc]** Строка `tunnel.js` неполна: пишет также `network.<iface>.disabled` (переключатель Туннеля), через `awg.applyConf` — `proto`, `private_key`, `listen_port`, `addresses` и список `network` зоны `firewall`.
- **[code→doc]** `common.js` экспортирует `callCheck` (используется `kit.Check`), а также `VIA_LABELS`, `NAT_ERRORS`, `CHECK_ERRORS`, `UPNP_MISSING`, `NBSP`.
- **[doc→code]** `ui/kit.js … CheckResult` — определён, но не экспортируется.
- **[code→doc]** `ui/app.js` экспортирует также `luminance`, `schemeFrom`, `changeCount`, `pending`, `changed`, `toasts`.
- **[doc→code]** `Импорт router.conf требует … хотя бы один [Peer] с PublicKey` — требовалось `PublicKey` только у **первого** `[Peer]` (`!res.peers[0].publickey`); второй пир без ключа попадал в UCI и ломал интерфейс. **Исправлено в коде**: проверяется каждый пир [awg.js:parseConf], тест в `tests/luci/static.mjs`.

## EGM.md (корень)

No drift detected (все утверждения — свёртка проверенных дочерних контрактов; ссылка на ADR 0009 уточнена при проверке ссылок).

## router/EGM.md

No drift detected.

## Исправлено

Все пункты `doc→code` из трёх разделов выше и следующие `code→doc`: `uninstall` на Трубе (resolvconf/journald/fail2ban/`UFW_DISABLED=0`), диапазон `diag`, usage/exit 2, доп. опции sshd, `gpg`; экспорт `UPSTREAM_SCHEMES`/`UPSTREAM_RE`, `callCheck`, `CheckResult` → убран, экспорты `ui/app.js`, строки `rules.js` и `tunnel.js`.

Правки кода по итогам (остальные расхождения — осознанное поведение, подтверждённое комментариями в исходниках):

- `router/luci-app-truba/htdocs/luci-static/resources/truba/awg.js:parseConf` — `PublicKey` обязателен у каждого `[Peer]`, а не только у первого; тест в `tests/luci/static.mjs`.
- `router/truba/files/etc/config/truba` — закомментированный пример `list stun`.
