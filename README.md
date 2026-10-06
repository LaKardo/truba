# Труба

Домашняя сеть через собственный VPS: **Труба** (VPS на Ubuntu 24.04) отдаёт **Роутеру** (ImmortalWrt 25.12) весь свой публичный IP по **Туннелю** AmneziaWG, а Роутер сам решает, какой трафик пускать через Туннель, и делает Full cone NAT. Трафик распределяется по Категориям из [geoip.dat](https://github.com/kirilllavrov/geoip-builder) и [geosite.dat](https://github.com/kirilllavrov/geosite-builder), которые используются без изменений. Всё управляется из LuCI: «Службы → Труба».

Термины — в [CONTEXT.md](CONTEXT.md), архитектура и решения — в [PLAN.md](PLAN.md) и [docs/adr/](docs/adr/).

## Что в репозитории

| Путь | Что это |
|---|---|
| [vps/install-vps.sh](vps/install-vps.sh) | Настройка VPS как Трубы: AmneziaWG, проброс всех портов на Роутер (nftables 1:1), SSH на высоком порту, fail2ban |
| [router/truba/](router/truba/) | Пакет `truba`: служба procd, ucode-модули, распаковщик `.dat`, mosdns, nftables, контроль Туннеля |
| [router/luci-app-truba/](router/luci-app-truba/) | Интерфейс LuCI (6 вкладок, русский перевод) |
| [router/awg/](router/awg/) | Источники AmneziaWG для фида (модуль ядра, утилиты, LuCI-протокол) |
| [.github/workflows/](.github/workflows/) | CI: тесты, сборка под ImmortalWrt SDK, подписанный apk-фид в GitHub Pages, отслеживание новых релизов |
| [tests/](tests/) | Проверки в Docker: распаковщик, служба под настоящим procd, скрипт VPS, интерфейс |

## Установка

### 1. Фид пакетов (один раз)

AmneziaWG нет в фидах ImmortalWrt, а сторонние сборки модуля ядра не совпадают с ядром ImmortalWrt, поэтому пакеты собирает свой CI ([ADR 0004](docs/adr/0004-own-apk-feed-over-stock-firmware.md)).

1. Репозиторий: [github.com/LaKardo/truba](https://github.com/LaKardo/truba).
2. Создайте ключ подписи фида и добавьте его в **Settings → Secrets and variables → Actions**:
   ```bash
   openssl ecparam -name prime256v1 -genkey -noout -out truba-feed.pem
   ```
   ```bash
   openssl ec -in truba-feed.pem -pubout > truba-feed.pub.pem
   ```
   `APK_SIGN_KEY` — содержимое `truba-feed.pem`, `APK_SIGN_PUB` — содержимое `truba-feed.pub.pem`. Закрытый ключ в репозиторий не кладите.
3. **Actions → build → Run workflow**. После сборки включите **Settings → Pages → ветка `gh-pages`**.
4. Фид появится по адресу `https://lakardo.github.io/truba/<версия>/mediatek/filogic/packages.adb`.

`watch-releases` каждый день проверяет новые ImmortalWrt 25.12.x и сам собирает под них пакеты.

### 2. VPS

Нужны: Ubuntu 24.04, полноценная ВМ (KVM и т.п., не контейнер), публичный IPv4 прямо на интерфейсе, SSH-ключ в `/root/.ssh/authorized_keys`.

```bash
curl -fsSLO https://raw.githubusercontent.com/LaKardo/truba/main/vps/install-vps.sh
```
```bash
sudo bash install-vps.sh install
```

Скрипт временно оставит SSH и на 22-м, и на новом порту и попросит войти по новому порту из другого окна. Без подтверждения за 120 с всё откатится. После установки:

- порт 22 и все остальные порты IP VPS уходят на Роутер, SSH самого VPS — только на новом порту;
- `/root/truba/router.conf` — конфиг для Роутера. Заберите его:
  ```bash
  scp -P <SSH-порт> root@<IP VPS>:/root/truba/router.conf .
  ```

Команды: `install-vps.sh status | show-config | rotate-keys | random-trailers on|off | uninstall [--purge]`.

Если модуль поддерживает AmneziaWG 3.1, Туннель сразу получает защиту заголовков (`HeaderProtectionKey`) и `DisableCookies`. Если VPS ставился на более старой версии, перейти на 3.1 можно через `rotate-keys`; после этого импортируйте `router.conf` в Роутер заново.

`RandomTrailers` лежит в запасе — на случай, если DPI начнёт узнавать Туннель по размерам пакетов. Он увеличивает трафик на мелких пакетах, поэтому по умолчанию выключен. Включать надо на обеих сторонах сразу:

```bash
install-vps.sh random-trailers on
```

Затем на Роутере: **Сеть → Интерфейсы → awg0 → AmneziaWG → Random Trailers → Сохранить и применить**. Выключается так же, командой `off` и снятием флага.

### 3. Роутер (ImmortalWrt 25.12, Netcraze NC-1812)

```bash
wget -O /etc/apk/keys/truba.pem https://lakardo.github.io/truba/keys/truba.pem
```
```bash
. /etc/os-release; echo "https://lakardo.github.io/truba/${VERSION}/mediatek/filogic/packages.adb" > /etc/apk/repositories.d/truba.list
```
```bash
apk update && apk add kmod-amneziawg amneziawg-tools luci-proto-amneziawg truba luci-app-truba luci-i18n-truba-ru luci-app-upnp
```

netifd узнаёт о новом протоколе `amneziawg` только при запуске, поэтому перезапустите сеть (или роутер). Без этого интерфейс Туннеля не поднимется (`proto none`, `NO_DEVICE`). Связь пропадёт секунд на 20–30:

```bash
/etc/init.d/network restart
```

Затем в LuCI:

1. **Службы → Труба → Туннель → Импорт .conf** — вставьте `router.conf` → **Сохранить и применить**.
2. **Обзор** — Туннель «работает», handshake свежий, IP Трубы виден.
3. **Маршрутизация** — Режим и Действия Категорий (Стартовые настройки уже выставлены).

При установке пакет сам создаёт зону `truba`, включает fullcone, выключает аппаратное ускорение и закрывает выход в интернет по IPv6 из `lan`. Программное ускорение он не трогает: при нём пакеты ускоренных соединений идут мимо счётчиков Трубы и мимо ограничения скорости qosmate, о чём предупреждает «Обзор». IPv6 внутри сети (нужен roamd) он не трогает. При удалении пакета всё это откатывается. Не выключайте IPv6 на `br-lan` (`network.lan.ipv6`): по нему roamd находит узлы.

### Рядом с OpenClash и qosmate

Обе службы можно не выключать.

- **qosmate** перезаписывает ct mark целиком, поэтому Труба записывает в него своё решение последней и меняет только свой байт метки.
- **OpenClash** ставит свою метку исходящему трафику Роутера. Труба возвращает свою метку собственным сокетам (нужен `kmod-nft-socket`, ставится зависимостью), а пакеты самого Туннеля к IP Трубы всегда отправляет напрямую. Добавлять IP Трубы в исключения OpenClash не нужно.
- Если OpenClash работает в режиме fake-ip, кнопка «Проверить NAT» показывает ошибку: STUN-серверы резолвятся в адреса `198.18.x.x`. Сам Full cone при этом работает. Проверяйте NAT при выключенном OpenClash.

## Как пользоваться

| Вкладка | Что там |
|---|---|
| Обзор | Переключатели «Туннель» и «Маршрутизация»; сводка с предупреждениями о соседях (ускорение, OpenClash, UPnP); Туннель: handshake, задержка и потери до Трубы; DNS и списки: попадания в кэш, даты файлов, последняя и следующая проверка, размеры наборов; трафик устройств по Действиям с графиком за 10 минут; новые соединения; проверка NAT |
| Туннель | Импорт `.conf`, ключи и параметры маскировки AWG (в том числе AmneziaWG 3.1: защита заголовков, DisableCookies, RandomTrailers), контроль Туннеля |
| Маршрутизация | Режим, Аварийная блокировка, зоны, Политики устройств по MAC («Всё в туннель», «Всё напрямую», «По правилам»), таблица всех Категорий с Действиями для каждого Режима |
| DNS и списки | DNS: серверы для «Туннель» и «Напрямую», кэш (в том числе ленивый), перехват DNS. Списки: источники, расписание, «Обновить сейчас», версии и откат |
| Входящие | UPnP/NAT-PMP на Туннеле и его действующие пробросы, пробросы портов из зоны `truba`, трафик входящих |
| Диагностика | «Проверить домен/IP» — какая Категория и какое Действие сработают и почему; журнал Трубы и mosdns |

Любое изменение применяется кнопкой **«Сохранить и применить»**: служба `truba` сама включает или снимает правила nftables, маршруты, mosdns, перенаправление dnsmasq, cron и контроль Туннеля.

Из командной строки:

```bash
truba status
```
```bash
truba check gosuslugi.ru
```
```bash
logread -e truba
```

## Обновление ImmortalWrt

Обновляйте Роутер только после того, как в фиде появился каталог новой версии (`watch-releases` собирает его автоматически). После sysupgrade настройки и ключ фида сохраняются, а `/etc/truba/reinstall.sh` из `rc.local` сам ставит пакеты заново. Если модуля ядра под новую версию ещё нет, Туннель не поднимется: скрипт пишет в журнал, как доставить модуль, когда сборка появится.

## Проверки

Все проверки идут в Docker:

```bash
bash tests/run.sh
```

- `dat` — распаковщик на свежих `.dat`: записи переносятся один в один, `full:` и `regexp:` на месте, вложенность Категорий;
- `router` — пакет под настоящим procd/netifd/fw4, Туннель — настоящий WireGuard до netns «VPS»: таблица nftables, правила, mosdns, Блок, Аварийная блокировка, режимы, входящие через Туннель, соседство с qosmate и OpenClash, обновление и откат списков, teardown и uninstall;
- `vps` — shellcheck, пределы параметров AWG, конфиги AWG 3.1 у обеих сторон, правила nftables с загрузкой в ядро, sysctl;
- `luci` — синтаксис интерфейса и полнота русского перевода.

Приёмочные тесты на живой сети (Full cone по RFC 5780, входящие, утечки, roamd) — в [PLAN.md §8](PLAN.md).
