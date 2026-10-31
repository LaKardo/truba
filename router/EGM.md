# router

## Overview

Всё, что ставится на Роутер (ImmortalWrt 25.12, версия в `VERSIONS`): пакет службы `truba`, пакет интерфейса `luci-app-truba` и источники AmneziaWG для фида. Служба и интерфейс выпускаются парой и зависят друг от друга по версии (ADR 0008); AmneziaWG собирается CI из закреплённого коммита `awg-openwrt` (ADR 0004).

## Subdirectories & Boundaries

- truba: [./truba/EGM.md](./truba/EGM.md) — служба Роутера: распаковщик `.dat`, план Категорий, nftables `inet truba`, policy routing в таблицу 77, mosdns, контроль Туннеля, статистика в RAM, ubus-объект `truba` (плагин rpcd), CLI `/usr/sbin/truba`
- luci-app-truba: [./luci-app-truba/EGM.md](./luci-app-truba/EGM.md) — интерфейс LuCI из семи вкладок на Preact + htm в Shadow DOM; читает схему и состояние только из ubus `truba.*`, правит UCI `truba`, `network`, `firewall`
- awg: `./awg/SOURCES` — репозиторий и коммит `awg-openwrt`, из которых CI собирает `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` (без исходного кода в репозитории)
- `VERSIONS` — целевая версия ImmortalWrt для сборки фида
