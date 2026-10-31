# luci-app-truba — интерфейс LuCI

## Overview

OpenWrt-пакет `luci-app-truba` — интерфейс «Службы → Труба» из семи вкладок. Каждая вкладка — представление LuCI. Внутри оно рендерит страницу на Preact + htm в Shadow DOM (ADR 0017) и рисует графики uPlot. Интерфейс не хранит своих копий значений службы: схему, умолчания, пределы и константы он берёт из ubus `truba.schema` (ADR 0015), а состояние — из ubus-API пакета [truba](../truba/EGM.md). Правки копятся в браузерном UCI и применяются стандартным «Сохранить и применить» LuCI с откатом.

## Interface

### Представления — `htdocs/luci-static/resources/view/truba/`

| Файл | Вкладка | Вызовы `truba.*` | Что правит в UCI |
|---|---|---|---|
| `overview.js` | Обзор | `status`, `rates`, `devices` (lite), `schema` | `network.<iface>.disabled`, `truba.main.routing` |
| `devices.js` | Устройства | `devices`, `connections`, `check`, `schema` | секции `truba.device` |
| `rules.js` | Правила | `categories`, `lists`, `status` (`rules`), `sets`, `update_lists`, `rollback_lists`, `check`, `schema` | `truba.main.{routing,mode,zone}`, `truba.lists.*`, секции `truba.rule` |
| `tunnel.js` | Туннель | `status`, `tunnel_test`, `tunnel_result`, `schema` | `network.<iface>` (`disabled`, MTU, `awg_*`; при импорте — `proto`, `private_key`, `listen_port`, `addresses`), пиры `amneziawg_<iface>`, список `network` зоны `firewall`, `truba.watchdog.*`, `truba.main.killswitch` |
| `dns.js` | DNS | `status` (`dns`), `schema` | `truba.main.dns_hijack`, `truba.dns.*` |
| `inbound.js` | Входящие | `status`, `devices` (lite), `nat_test`, `nat_result`, `schema` | `truba.main.upnp`, секции `firewall.redirect` из зоны Туннеля |
| `log.js` | Журнал | `log`, `schema` | — |

### Общие модули — `htdocs/luci-static/resources/truba/`

- `common.js` — объявления rpc (`callStatus`, `callLists`, `callCategories`, `callSets`, `callCheck`, `callUpdateLists`, `callRollbackLists`, `callRates`, `callLog`, `callDevices`, `callDevicesLite`, `callConnections`, `runNatTest`, `runTunnelTest`), схема (`loadSchema`, `schema`, `get`, `fieldError`, `upstreamError`), хелперы правил, устройств, пробросов, Туннеля, журнала и форматирования; константы `TABS`, `WARNINGS`, `ACTION_LABELS`, `REASON_LABELS`, `VIA_LABELS`, `NAT_ERRORS`, `CHECK_ERRORS`, `UPNP_MISSING`, `NBSP` [common.js]
- `awg.js` — разбор и импорт `router.conf`: `parseConf`, `applyConf`, `peerSection`, `configured`, `version`, проверки `mtuError`, `rangeError`, `paramError`; карты `IFACE_KEYS`, `IFACE_BOOL`, `NUM_PARAMS`, `CPS_PARAMS` [awg.js]
- `ui/app.js` — `load`, `lib`, `mount` (Shadow DOM), `luminance`, `schemeFrom`, `scheme`, `changes`, `changeCount`, `pending`, `changed`, `store`, `use`, `usePoll`, `poll`, `every`, `set`, `add`, `remove`, `restore`, `invalid`, `toast`, `toasts`, `onFlush`, `flush`, `reset`, `actions` [ui/app.js]
- `ui/kit.js` — компоненты `Card`, `Stat`, `Badge`, `Dot`, `Icon`, `KV`, `Busy`, `Empty`, `Go`, `Fold`, `PageHead`, `Switch`, `Segmented`, `step`, `Chips`, `ActionTag`, `ShareBar`, `ActionPicker`, `FieldBox`, `Field`, `UpstreamList`, `DropZone`, `Dialog`, `Toast`, `Check`, `ChangesBar` [ui/kit.js]
- `ui/chart.js` — `TimeChart`, `Spark`, `scaleTop`, `gaps`, `areaFill` [ui/chart.js]
- `ui/flow.js` — схема «устройства → Роутер → Туннель/Напрямую» `Flow`, `width` [ui/flow.js]
- `ui/icons.js` — SVG-иконки lucide [ui/icons.js]
- `lib/` — закреплённые копии `preact-htm.js` (htm 3.1.1), `uplot.js`/`uplot.css` (uPlot 1.6.32) с sha256 в `lib/VERSIONS` и лицензиями в `lib/LICENSES/`

### Регистрация — `root/`

- `usr/share/luci/menu.d/luci-app-truba.json` — `admin/services/truba` и дочерние `overview`, `devices`, `rules`, `tunnel`, `dns`, `inbound`, `log`
- `usr/share/rpcd/acl.d/luci-app-truba.json` — ACL `luci-app-truba`
- `usr/share/ucitrack/luci-app-truba.json` — конфиг `truba` → init `truba`
- `etc/uci-defaults/luci-truba` — сброс кэша LuCI и `rpcd reload`

### Перевод — `po/`

- `po/templates/truba.pot`, `po/ru/truba.po` → пакет `luci-i18n-truba-ru`

## Invariants

- Зависимость `truba (>=1.2.0-r7)`: версии интерфейса и службы совпадают, ubus-API поставляет пакет `truba` (ADR 0008) [Makefile:LUCI_EXTRA_DEPENDS]
- `LUCI_MINIFY_JS:=0`, `LUCI_MINIFY_CSS:=0`: jsmin не понимает шаблонные строки htm, а файлы `lib/` должны побайтно совпадать с sha256 из `lib/VERSIONS` [Makefile, lib/VERSIONS]
- `PKG_PO_VERSION` задан явно: в CI нет git-истории `po/`, и без него перевод получил бы версию 0 [Makefile:PKG_PO_VERSION]
- Схема загружается один раз за страницу; `get()` и `fieldError()` повторяют семантику `conf.uc:check_value` службы (неверное → умолчание); адреса DNS проверяются регулярным выражением `upstream_re` из схемы [common.js:loadSchema, get, fieldError, upstreamError]
- Семантика ключей правил и устройств повторяет `conf.uc`: `set` не `geoip` → `geosite`, тег в нижнем регистре, MAC без учёта регистра, первая секция на MAC побеждает [common.js:ruleKey, ruleOf, deviceIndex]
- ACL: на чтение — `status`, `lists`, `categories`, `sets`, `schema`, `check`, `nat_result`, `tunnel_result`, `rates`, `log`, `devices`, `connections`; на запись — только `update_lists`, `rollback_lists`, `nat_test`, `tunnel_test`; UCI `truba`, `network`, `firewall`, `upnpd` [acl.d/luci-app-truba.json]
- `callStatus` без ключа `service` в ответе считается «нет связи», а не «служба остановлена» [common.js:callStatus]
- Фоновые проверки принимают только результат с `time >= started`; иначе через 20 с (NAT) или 30 с (Туннель) — `timeout` [common.js:runInBackground]
- Страница монтируется в открытый Shadow DOM на `div.truba-root`; тема определяется по яркости фона предков (тёмная при luminance < 0.4), иначе по `prefers-color-scheme` [ui/app.js:mount, detect, schemeFrom]
- Ошибка опроса не стирает данные, а только выставляет `offline`; опрос пропускается, пока вкладка скрыта; следующий запрос — только после завершения предыдущего [ui/app.js:pollStore, every, usePoll]
- Возврат значения к сохранённому убирает изменение из счётчика: A→B→A даёт ноль изменений [ui/app.js:setOpt]
- Неверное значение поля не пишется в UCI; «Применить» недоступно и отклоняется, пока есть подсвеченные поля [ui/kit.js:Field, ChangesBar; ui/app.js:actions]
- Хотя бы одна зона Маршрутизации остаётся выбранной; собственная зона Туннеля (`consts.fw_zone`) в выбор не попадает [view/truba/rules.js:Zones]
- Смена Действия Категории даёт ровно одно изменение UCI [view/truba/rules.js:setAction]
- Импорт `router.conf` требует `PrivateKey` в `[Interface]` и `PublicKey` у каждого `[Peer]`; пиры получают `route_allowed_ips='0'`, потому что маршрутами управляет служба (таблица 77) [awg.js:parseConf, applyConf]
- Параметры AWG — опции `network`, их нет в схеме службы; `awg.js` держит свои пределы: MTU 576–1500, H1–H4 ≤ 4294967295, S1–S4 ≥ 12 при `awg_header_protection_key` [awg.js:paramError, mtuError]
- Проброс портов: внешний порт 1–65535 и без пересечения с другими включёнными пробросами того же протокола; адрес назначения — IPv4 [common.js:forwardErrors]
- Периоды опроса: «Обзор», «Правила», «Туннель», «Устройства» — 5 с; «DNS», «Входящие» — 10 с; «Журнал» в режиме «Следить» — 5 с [view/truba/*.js:POLL]
- Модули `ui/` не обращаются к DOM и сети на верхнем уровне (`lib` заполняется в `load()`), поэтому `tests/luci/static.mjs` запускает их в Node с заглушками [ui/app.js:lib]

## Side Effects

- Браузерный UCI: `uci.set/unset/add/remove` в конфигах `truba`, `network`, `firewall`; применение через `uci.save` и `handleSaveApply` LuCI с откатом; сброс — `uci.callLoad` [ui/app.js:setOpt, actions, reset]
- Изменяющие вызовы ubus: `truba.update_lists`, `truba.rollback_lists`, `truba.nat_test`, `truba.tunnel_test` [common.js; view/truba/rules.js, tunnel.js, inbound.js]
- Импорт `router.conf`: пересоздаёт интерфейс AmneziaWG и все секции `amneziawg_<iface>`, добавляет интерфейс в зону межсетевого экрана [awg.js:applyConf]
- `localStorage['truba.span']` — выбранный период графика скорости [view/truba/overview.js:SPAN_KEY]
- Скачивание журнала как `truba-log-YYYYMMDD-HHMM.txt` [view/truba/log.js:download]
- DOM: Shadow DOM, `MutationObserver` на `html`/`body`, слушатели `matchMedia` и `transitionend`, `ResizeObserver` графиков, регистрация в `poll` LuCI [ui/app.js:mount, ui/chart.js:usePlot]
- Загрузка `lib/preact-htm.js`, `lib/uplot.js`, `lib/uplot.css`, `ui/style.css` с `?v=resource_version` [ui/app.js:load]
- Установка пакета: `rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/*`, `/etc/init.d/rpcd reload` [root/etc/uci-defaults/luci-truba]
- ucitrack: сохранение UCI `truba` перезапускает init `truba` [root/usr/share/ucitrack/luci-app-truba.json]

## Verification

- Run: `bash tests/run.sh luci ui` (статические проверки интерфейса и живой стенд LuCI с headless Chromium; см. [tests/README.md](../../tests/README.md))
- Быстрый предпросмотр без Docker: `node tests/luci/preview.mjs`
