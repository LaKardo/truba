# truba — служба Роутера

## Overview

OpenWrt-пакет `truba` (ImmortalWrt 25.12, `PKGARCH:=all`) — служба Роутера на ucode. Она распаковывает `geoip.dat`/`geosite.dat` в Категории, собирает из настроек UCI план (Режим, Действия, Приоритет), генерирует таблицу nftables `inet truba` и конфиг mosdns, ведёт policy routing в таблицу 77 через Туннель AmneziaWG, следит за Туннелем, считает трафик и скорость в оперативной памяти и отдаёт всё это через ubus-объект `truba` (плагин rpcd) интерфейсу [luci-app-truba](../luci-app-truba/EGM.md). Исходники лежат в `files/` в виде будущей файловой системы Роутера; `Makefile` копирует их как есть (`Build/Compile` пуст).

## Interface

### ubus `truba` — `files/usr/share/rpcd/ucode/truba-api.uc`

- Чтение: `status(cached, part)` (`part='dns'|'rules'` — облегчённый ответ; `rules` отдаёт и `tunnel{configured,disabled,up,awg}`, `health`), `lists()`, `categories()`, `schema()`, `sets()`, `devices(lite)`, `connections(ip)`, `check(target, mac)`, `nat_result()`, `tunnel_result()`, `rates(span=600, since=0)`, `log(lines=200)` [truba-api.uc:methods]
- Фоновые действия: `nat_test()`, `tunnel_test()`, `update_lists(force)` возвращают `{started}`; `rollback_lists()` меняет файлы сразу, применение — в фоне [truba-api.uc:methods]

### CLI — `files/usr/sbin/truba`

- `apply`, `teardown`, `routes`, `refresh-bypass`, `hotplug`, `env`, `update-lists [-f]`, `rollback-lists [--bg]`, `check <домен|IP> [MAC]`, `status`, `lists`, `sets`, `log [n]`, `schema`, `categories`, `devices`, `connections <IP>`, `reset-rules <all|selective>`, `nat-test [auto]`, `tunnel-test`, `watchdog`, `stats` [usr/sbin/truba:switch(cmd)]

### Служба и хуки

- `files/etc/init.d/truba` — `START=99`, `USE_PROCD=1`; `start_service` выполняет `truba apply` и открывает procd-экземпляры: `stats` всегда, `mosdns` при `applied.mosdns == true` и непустом конфиге, `watchdog` при `TRUBA_WATCHDOG=1`; `stop_service` — `truba teardown`; `service_triggers` — reload по UCI `truba`/`network` и событиям интерфейса Туннеля [init.d/truba:start_service, stop_service, service_triggers]
- `files/etc/hotplug.d/iface/50-truba` — `truba hotplug` на каждое событие интерфейса
- `files/etc/uci-defaults/90-truba` — первая установка: зона `truba`, fullcone, Стартовые настройки, `routing '0'` (и при оставшемся конфиге), строка переустановки в `rc.local`; обновление без строки `routing` — `routing '1'` (ADR 0019)
- `files/etc/truba/reinstall.sh` — переустановка пакетов после sysupgrade; на время `apk add` `routing '0'`, прежнее значение возвращается, только если установился `kmod-amneziawg` (ADR 0019)
- `files/usr/share/truba/uninstall.sh` — откат при удалении (prerm)
- `files/lib/upgrade/keep.d/truba` — что сохраняет sysupgrade

### Настройки UCI — `files/etc/config/truba`

- `main`: `routing` (по умолчанию `0`, ADR 0019), `mode` (`all`|`selective`), `killswitch`, `iface` (`awg0`), `zone` (список), `dns_hijack`, `upnp`, `stun` (список STUN-серверов; пусто — встроенный список `nattest.uc:DEFAULT_SERVERS`; в поставляемом конфиге — закомментированный пример)
- `dns`: `tunnel_upstream`, `direct_upstream`, `port` (5335), `ttl_max`, `cache_size`, `lazy_cache_ttl`, `set_timeout`
- `lists`: `geoip_url`, `geoip_mirror`, `geosite_url`, `geosite_mirror`, `via_tunnel`, `auto_update`
- `watchdog`: `enabled`, `interval`, `handshake_max`, `fails`, `probe`
- секции `rule` (`mode`, `set`, `tag`, `action`) и `device` (`mac`, `name`, `policy`, `enabled`) [conf.uc:SCHEMA, conf.uc:load]

### ucode-модули — `files/usr/share/ucode/truba/`

| Модуль | Экспорт |
|---|---|
| `const.uc` | Биты меток `MARK_TUNNEL/DIRECT/INBOUND/MASK`, `RT_TABLE=77`, `PRIO_RULE_MARK=1000`, `PRIO_RULE_OIF=1001`, `NFT_TABLE`, `FW_ZONE`, `FW_FWD_SUFFIX`, `FW_NO6_SUFFIX`, `LOG_TAG`, `WATCHDOG_TAG`, `CLI`, `INIT`, `MOSDNS_ADDR`, все пути (`CONF_DIR`, `RUN_DIR`, `GOOD_DIR`…), `HISTORY`, `DEV_*`, `CONN_TOP`, `PROBE_WINDOW`, `LOCK_APPLY`, `LOCK_LISTS`, `DAT_FILES`, `ACTIONS`, `CRON_BEGIN`, `CRON_END` |
| `conf.uc` | `SCHEMA`, `UPSTREAM_SCHEMES`, `UPSTREAM_RE`, `schema`, `load`, `check_value`, `parse_upstream`, `upstream_ok`, `device_sections`, `env_lines`, `tunnel_info`, `vps_ip`, `zone_devices`, `dev_zones`, `connected_subnets`, `local_subnets`, `router_hosts` |
| `util.uc` | `log`, `info`, `warn_log`, `err`, `errmsg`, `run`, `shq`, `ubus_call`, `now_ms`, `mkdirp`, `write_atomic`, `write_json`, `write_if_changed`, `read_json`, `move_file`, `sha256_file`, `sha_from_sumfile`, `lock`, `lock_busy`, `nslookup`, `fnv1a`, `is_ipv4`, `to_list`, `ip2int`, `int2ip`, `cidr_range`, `cidr_contains` |
| `plan.uc` | `PRIORITY`, `STARTING`, `compute`, `geosite_key` |
| `render.uc` | `geoip_data`, `nft_full`, `nft_minimal` |
| `core.uc` | `apply`, `teardown`, `hotplug`, `refresh_bypass`, `update_lists`, `rollback_lists`, `reset_rules`, `categories` |
| `net.uc` | `iface_up`, `ensure_rules`, `remove_rules`, `routes`, `set_rp_filter`, `sync`, `zones_firewall`, `cron_next`, `cron_set`, `upnp_set` |
| `dns.uc` | `mosdns`, `apply`, `cache_dump`, `prune_cache_dumps`, `dnsmasq_enable`, `dnsmasq_restore`, `dns_heal`, `dns_unbound`, `api_port_taken`, `is_router_host` |
| `dat.uc` | `parse_geosite`, `parse_geoip`, `validate`, `unpack`, `ensure`, `cached`, `geoip_cidrs`, `geosite_file`, `geosite_entries` |
| `dnsnames.uc` | `parse`, `lookup` |
| `check.uc` | `check`, `match_domain`, `ip_verdict`, `ip_verdicts`, `geoip_hits` |
| `devices.uc` | `list`, `connections`, `merge`, `parse_leases`, `parse_conntrack`, `group`, `route_table`, `route_dev` |
| `devstats.uc` | `snapshot`, `add`, `day`, `load`, `save` |
| `stats.uc` | `snapshot`, `point`, `minute`, `add`, `run` |
| `state.uc` | `status`, `lists`, `log`, `sets`, `set_elements`, `counters_raw`, `dev_counters` |
| `nattest.uc` | `run` |
| `watchdog.uc` | `run`, `tunnel_test`, `ping_rtt` |

## Invariants

- Пути, имена и метки определены только в `const.uc` и схема — только в `conf.uc:SCHEMA` (ADR 0015); shell получает их через `truba env` (`TRUBA_*`), интерфейс — через `truba.schema` [const.uc, conf.uc:env_lines, conf.uc:schema]
- Метки Трубы занимают только `MARK_MASK = 0x0f000000`; каждая запись метки — `meta mark and ~MASK or <mark>`, чужие биты сохраняются (ADR 0011) [render.uc:set_meta, const.uc:MARK_MASK]
- Порядок цепочки `classify` — ровно `plan.uc:PRIORITY` (`gi_block4` → `dev_direct` → `dev_tunnel` → `gs_tunnel4` → `gs_direct4` → `gi_tunnel4` → `gi_direct4` → Режим по умолчанию); тот же список использует `check.uc`, поэтому «Проверить домен/IP» и правила ядра не расходятся [plan.uc:PRIORITY, render.uc:nft_full, check.uc:ip_verdict]
- Категории geosite сортируются по числу записей, затем block < tunnel < direct, затем по имени: узкие раньше широких [plan.uc:compute]
- Режим `all` → по умолчанию `tunnel`, `selective` → `direct`; действуют только секции `rule` с текущим Режимом [plan.uc:compute]
- Неверное значение UCI заменяется значением по умолчанию; для типов `int`, `pattern`, `ipv4`, `upstreams` оно попадает в `cfg.invalid` (неверные `bool`, `enum`, `list` заменяются молча); первая секция `device` на MAC побеждает [conf.uc:check_value, conf.uc:device_sections]
- `apply` целиком под замком `LOCK_APPLY`; результат всегда пишется в `applied.json`. Конфиг mosdns пишется только после успешного `nft -f` [core.uc:apply, core.uc:apply_config]
- При ошибке применения (ADR 0006): если таблица в ядре — `kept`; иначе загрузка последней удачной копии из `/etc/truba/good` — `last_good`; иначе `none` с восстановлением dnsmasq. Служба при этом не останавливается, а procd-экземпляры открываются [core.uc:keep_running, core.uc:load_good, init.d/truba:start_service]
- Таблица не перезагружается целиком, если не изменился `nft_key` (routing, mode, iface, vps, socket_mark, dns_hijack, set_timeout) — обновляются только наборы; при полной перезагрузке счётчики переносятся из ядра всегда, элементы `gs_*4` — только при неизменном `gkey` [core.uc:nft_table_key, core.uc:apply_config]
- Маршрутизация только IPv4 (ADR 0005): правила `ip -4` priority 1000 (fwmark) и 1001 (oif) в таблицу 77; mosdns отвечает пустым ответом на AAAA и HTTPS; IPv6-CIDR из geoip считаются, но не попадают в наборы [net.uc:ensure_rules, dns.uc:mosdns, dat.uc:parse_geoip]
- Таблица 77: Туннель здоров — `default dev <iface>`; упал и включена Аварийная блокировка — `blackhole default`; иначе маршрут по умолчанию удаляется [net.uc:set_table, net.uc:routes]
- Маршрутизация выключена — служба не трогает IPv4-трафик и DNS сети; применение с `routing=0` после включённой или первое после старта пишет `info` «Маршрутизация выключена…» (ADR 0019) [core.uc:apply_config]
- Секции межсетевого экрана `<zone>_truba` и `<zone>_truba_no_ipv6` (REJECT вне ULA/link-local/multicast) — свои; чужие секции с тем же именем не трогаются (ADR 0014, 0016) [net.uc:zones_firewall, net.uc:no6_rule]
- TTL в кэше mosdns не больше 3600 с, устройствам — не больше `ttl_max`; IP из DNS попадают в `gs_tunnel4`/`gs_direct4` со сроком `set_timeout` (ADR 0007) [dns.uc:mosdns, render.uc:dns_elems]
- Новый `.dat` заменяет текущий только после совпадения sha256 и успешного `dat.validate`; при сбое распаковки списки откатываются на предыдущие [core.uc:update_lists, core.uc:unpack_lists]
- Разбор protobuf строгий: неизвестный wiretype, обрезанное сообщение, тип Domain вне 0–3 — ошибка; дамп кэша mosdns ≤ 8 МиБ, имена ≤ 253 символов, защита от циклов указателей [dat.uc:fields, dnsnames.uc:parse, dnsnames.uc:name]
- История скорости и трафика устройств живёт только в RAM (`/var/run/truba`): точки по 5 с за час, минуты за сутки; наборы `dv_*` вмещают 1024 адреса (`DEV_SET_SIZE`), список `devices()` отдаёт не больше 256 (`DEV_LIST_MAX`) плюс все устройства с Политикой (ADR 0010, 0018) [const.uc:HISTORY, const.uc:DEV_*, stats.uc:add, devstats.uc:add, devices.uc:merge]
- Плагин rpcd оборачивает CLI в `umask 022`; долгие операции (`nat_test`, `tunnel_test`, `update_lists`) уходят в фон, потому что rpcd обслуживает вызовы по одному; `check` принимает только `^[A-Za-z0-9._-]{1,253}$` и MAC, `connections` — только IPv4 [truba-api.uc:CLI, truba-api.uc:methods]
- Только один плагин rpcd может регистрировать объект `truba` (ADR 0008)
- Контроль Туннеля: здоров, если ping прошёл и рукопожатие не старше `handshake_max`; `down` после `fails` неудач подряд; на каждой `fails`-й неудаче — `ifup`, а перед ним `awg set listen-port 0`, только если `network.<iface>.listen_port` не задан; `health.json` пишется до пересчёта маршрутов [watchdog.uc:tick, watchdog.uc:set_state]
- Проверка NAT шлёт STUN из одного UDP-сокета с `SO_MARK=MARK_TUNNEL`; успех — внешний IP равен IP Трубы, порт сохранён и ответы серверов не противоречат друг другу (`consistent !== false`; при одном ответившем сервере согласованность не проверяется) [nattest.uc:run]
- Зависимости объявлены в `EXTRA_DEPENDS` (`>=0`), а не в `DEPENDS`, чтобы SDK не собирал их из исходников [Makefile:Package/truba]
- `uninstall.sh` выходит с ошибкой, если `truba env` не дал `TRUBA_FW_ZONE`, `TRUBA_REINSTALL`, `TRUBA_NO6_SUFFIX` — никакого отката вслепую [uninstall.sh]

## Side Effects

- nftables: атомарная замена `table inet truba` из `/var/etc/truba/truba.nft`; дозаполнение наборов через `/var/run/truba/bypass.nft`; `nft delete table inet truba` в `teardown` [core.uc:apply_config, core.uc:refresh_bypass, core.uc:teardown]
- Маршрутизация: `ip -4 rule add/del` priority 1000/1001, `ip -4 route replace|del … table 77`, `sysctl net.ipv4.conf.<dev>.rp_filter=0` [net.uc:ensure_rules, net.uc:set_table, net.uc:set_rp_filter]
- UCI: `dhcp` (dnsmasq `noresolv`, `cachesize=0`, `server=127.0.0.1#port`, с копией в `/etc/truba/state/dnsmasq.json`), `firewall` (зона `truba`, перенаправления, правила IPv6, `fullcone=1`, `flow_offloading_hw=0`), `upnpd` (с копией `upnpd.json`), секции `rule` в `truba` [dns.uc:dnsmasq_enable, net.uc:zones_firewall, net.uc:upnp_set, uci-defaults/90-truba, core.uc:reset_rules]
- Перезапуски: `dnsmasq restart`, `firewall reload`, `cron restart`, `miniupnpd restart`, `/etc/init.d/truba reload`, `killall -HUP rpcd` в postinst/postrm [dns.uc, net.uc, core.uc:reload_service, Makefile:postinst]
- Файлы на флеше: `/etc/truba/lists/` (+`prev/`), `/etc/truba/state/`, `/etc/truba/good/` (последняя удачная копия), `/etc/crontabs/root` (блок `# truba-begin`…`# truba-end`), `/etc/rc.local` (строка `reinstall.sh`) [core.uc:update_lists, core.uc:save_good, net.uc:cron_set, uci-defaults/90-truba]
- Файлы в RAM: `/var/run/truba/{applied,health,counters,rates,rates-min,devices,dnsnames,nat,tunnel-test,set-sizes,dns-heal}.json`, `/var/etc/truba/mosdns.json`, `/var/lib/truba/` (распакованные Категории, `categories.json`, дампы кэша mosdns) [const.uc, dat.uc:unpack, stats.uc:save, devstats.uc:save]
- Процессы: procd запускает `mosdns`, `truba watchdog`, `truba stats` (`respawn 3600 5 0`); фоновые `truba update-lists`, `truba nat-test auto` [init.d/truba:start_service, core.uc:apply_config, watchdog.uc:tick]
- Сеть: `curl` за `.dat` и `.sha256sum` (GitHub/jsDelivr, через Туннель или напрямую); STUN к `stun.l.google.com:19302`, `stun.cloudflare.com:3478`, `stun1.l.google.com:19302`; ping через Туннель; HTTP к API mosdns на `127.0.0.1`; `nslookup`; `apk update/add` в `reinstall.sh` [core.uc:update_lists, nattest.uc:DEFAULT_SERVERS, watchdog.uc, dnsnames.uc:lookup, reinstall.sh]
- Туннель: `awg set <dev> listen-port 0` (если `listen_port` не задан в UCI) и `ifup <iface>` при повторных сбоях; `ubus send truba.tunnel` при смене состояния [watchdog.uc:tick, watchdog.uc:set_state]
- Чтение: `/proc/net/nf_conntrack`, `ip -4 -j neigh/route/addr`, файл аренд dnsmasq, `nft -j list set/counters`, `awg show`, `logread` [devices.uc, state.uc]
- Удаление пакета: откат межсетевого экрана и `rc.local`, удаление `/etc/truba/{lists,state,good}`, `/var/lib/truba`, `/var/run/truba`, `/var/etc/truba`, `/tmp/truba-dl` [uninstall.sh]

## Verification

- Run: `bash tests/run.sh units dat router` (модули, распаковщик и все части `router-*` на ImmortalWrt в Docker; см. [tests/README.md](../../tests/README.md))
