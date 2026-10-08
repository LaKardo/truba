# План реализации «Труба»

Своя сеть через свой VPS: **Труба** (VPS, Ubuntu 24.04) → **Туннель** (AmneziaWG) → **Роутер** (Netcraze NC-1812, ImmortalWrt 25.12) с Full cone NAT, маршрутизацией по Наборам правил kirilllavrov и управлением из LuCI.

Термины — в [CONTEXT.md](CONTEXT.md). Ключевые решения и их причины — в [docs/adr/](docs/adr/):

| ADR | Решение |
|---|---|
| [0001](docs/adr/0001-full-cone-on-router-vps-as-pipe.md) | Full cone делает Роутер; VPS только транслирует 1:1 |
| [0002](docs/adr/0002-kernel-datapath-no-userspace-proxy.md) | Трафик Туннеля идёт через ядро (метки + nftables), без Xray/sing-box |
| [0003](docs/adr/0003-mosdns-with-own-dat-unpacker.md) | Домены классифицирует mosdns, `.dat` распаковывает свой ucode-скрипт |
| [0004](docs/adr/0004-own-apk-feed-over-stock-firmware.md) | Свой apk-фид поверх стоковой ImmortalWrt |
| [0005](docs/adr/0005-routing-ipv4-only-lan-ipv6-untouched.md) | Маршрутизация только IPv4; IPv6 домашней сети (нужен roamd) не трогаем, IPv6-интернет закрыт |

### Статус реализации (2026-10-06)

| Этап | Состояние | Как проверено |
|---|---|---|
| 0. Репозиторий, CI | Работает: [build.yml](.github/workflows/build.yml) публикует подписанный фид на [lakardo.github.io/truba](https://lakardo.github.io/truba/), [tests.yml](.github/workflows/tests.yml) гоняет тесты на PR с изменениями пакетов Роутера и тестов, [watch-releases.yml](.github/workflows/watch-releases.yml) следит за новыми ImmortalWrt | Сборка под 25.12.2 зелёная; CI падает, если в фиде есть пакет с версией `0` (непереведённый LuCI) |
| 1. `install-vps.sh` | Готов, работает на живом VPS (Ubuntu 24.04, ВМ Hyper-V); Туннель на AWG 3.1 с защитой заголовков | `tests/vps`: shellcheck, пределы параметров AWG 1.x/2.x/3.1, конфиги 3.1 у обеих сторон, `nft -c` и загрузка правил в ядро, sysctl и загрузка `nf_conntrack` при старте. На живом Туннеле: ключи защиты совпадают, индекс и счётчик в пакетах случайные |
| 2. AmneziaWG под ImmortalWrt | Собирается в CI (awg-openwrt на зафиксированном коммите) | `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` из фида стоят на NC-1812, Туннель поднят |
| 3–6. Пакет `truba` | Готов, на NC-1812 стоит 1.0.0-r5 | `tests/router`: ImmortalWrt 25.12.2 под настоящим procd/netifd/fw4 в Docker, Туннель — настоящий WireGuard до netns «VPS». 96 проверок: nftables, ip rule, таблица 77, mosdns 5.3.3 (Блок → NXDOMAIN, AAAA → пусто), `full:`/`regexp:`, Аварийная блокировка, оба Режима, входящие через Туннель (в том числе с qosmate), свои сокеты Роутера при OpenClash, обновление и откат списков, teardown, uninstall |
| 4. Распаковщик | Готов | `tests/dat` на реальных `.dat`: записи один в один, 2–3 с на оба файла |
| 7. `luci-app-truba` | Готов, 6 вкладок, перевод RU (276 строк) | Headless Chromium: все вкладки без ошибок JS; «Сохранить и применить» → служба перестраивает правила (смена Действия, Политика устройства, выключение Маршрутизации) |
| 8. Переустановка после sysupgrade | Скрипт готов | Не проверялся реальным sysupgrade |
| 9. Приёмка §8 | Частично | На живой сети: 1 — STUN через Туннель (IP Трубы, порт сохраняется, ответ одинаков у двух серверов), NatTypeTester ещё не запускался; 2 — входящие на IP Трубы доходят до устройства в `lan`, ответы уходят в `awg0`; 3 — зарубежные сайты видят IP Трубы, российские — IP провайдера. Тесты 4–7 не проводились |

Отличия реализации от первоначального текста плана внесены прямо в разделы ниже:
- проверка Туннеля пингует Трубу внутри Туннеля, а не 1.1.1.1;
- служебные хосты Роутера резолвятся Напрямую;
- входящие с `wan` помечаются для ответов Напрямую;
- Труба меняет в метках только свой байт и записывает решение в ct mark последней в postrouting: qosmate перезаписывает ct mark целиком;
- свои сокеты Роутера с меткой Туннеля защищены от чужих цепочек output (OpenClash), нужен `kmod-nft-socket`;
- пакеты к IP Трубы (сам Туннель) всегда идут «Напрямую»: иначе петля в `awg0` или Туннель через прокси OpenClash;
- на VPS `nf_conntrack` загружается при старте, иначе предел conntrack не применяется;
- fw4 не трогает таблицу Трубы, поэтому include для межсетевого экрана не понадобился;
- на VPS проверяется «не контейнер» вместо строго KVM;
- DHCP-клиент VPS исключён из DNAT.

---

## 1. Общая схема

```
                         ИНТЕРНЕТ
                            │
              ┌─────────────┴───────────────────────────────────────────┐
              │ ТРУБА  VPS Ubuntu 24.04 (KVM)    eth0 = <VPS_IP>        │
              │                                                         │
              │  вход <VPS_IP>:                                         │
              │    tcp/<SSH_PORT>  ──► sshd (только ключ, fail2ban)     │
              │    udp/<AWG_PORT>  ──► AmneziaWG awg0                   │
              │    всё остальное   ──► DNAT → 10.77.77.2 (Роутер)       │
              │  выход от 10.77.77.2 ──► SNAT → <VPS_IP>, порт сохраняется│
              └─────────────┬───────────────────────────────────────────┘
                            │  udp <VPS_IP>:<AWG_PORT>
                 ═══════════╪═══ Туннель AmneziaWG ≥2.0, MTU ≤1380 ═══
                            │  10.77.77.1 ◄──► 10.77.77.2, keepalive 25 с
              ┌─────────────┴───────────────────────────────────────────┐
              │ РОУТЕР  NC-1812 · ImmortalWrt 25.12 · 1 ГБ RAM          │
              │                                                         │
              │  зона wan   (провайдер) masq + fullcone                 │
              │  зона truba (awg0)      masq + fullcone, input REJECT   │
              │  зона lan   (br-lan)    ──► wan, ──► truba              │
              │                                                         │
              │  dnsmasq :53 (DHCP, без кэша) ─► mosdns :5335           │
              │     mosdns: Категории geosite → DNS-сервер + nftset     │
              │  nft table inet truba: наборы geoip/geosite/устройства  │
              │     → метка TUNNEL / DIRECT, ct mark (липкость)         │
              │  ip rule fwmark TUNNEL → table 77: default dev awg0     │
              │                      (или blackhole = Авар. блокировка) │
              │  truba-watchdog · обновление .dat · luci-app-truba      │
              │  roamd (mesh-контроллер): IPv6 link-local на br-lan     │
              └─────────────┬───────────────────────────────────────────┘
                            │  IPv4: Маршрутизация Трубы
                            │  IPv6: только внутри сети (link-local/ULA), в интернет — REJECT
                   Устройства домашней сети · узлы roamd (WDS, MAC клиентов сохраняются)
```

### Адресный план и параметры

| Параметр | Значение | Где задаётся |
|---|---|---|
| Подсеть Туннеля | `10.77.77.0/30`: `.1` — Труба, `.2` — Роутер | `install-vps.sh`, импорт `.conf` |
| UDP-порт Туннеля | случайный 40000–59999 | `install-vps.sh` |
| SSH-порт Трубы | случайный 40000–59999 (≠ порту Туннеля) | `install-vps.sh` |
| MTU Туннеля | MTU сети VPS − 87, не больше 1380 (обе стороны) + MSS clamping | `install-vps.sh`, конфиги AWG, зона `truba` `mtu_fix` |
| Таблица маршрутов Туннеля | `77` | служба `truba` |
| Метка TUNNEL / DIRECT | `0x00010000` / `0x00020000` (маска `0x00ff0000`) | служба `truba` |
| Метка INBOUND | `0x00040000`. Труба меняет в meta mark и ct mark только байт `0x00ff0000`: в остальных битах хранят своё другие (qosmate — DSCP в ct mark) | служба `truba` |
| Метка своих сокетов Роутера | TUNNEL через `SO_MARK` (mosdns, «Проверить NAT»); после чужих цепочек output её байт возвращается из метки сокета (§4.4, цепочка `output`) | служба `truba` |
| Порт mosdns | `127.0.0.1:5335` | `/etc/config/truba` |

---

## 2. Потоки трафика

### 2.1 Исходящий, Действие «Туннель»

```
ПК 192.168.1.10:51000 → youtube.com
  1. DNS: dnsmasq → mosdns. Домен в Категории с Действием «Туннель»
     (или «По режиму» в Режиме «Всё в туннель») → DoH 1.1.1.1 через
     Туннель (so_mark TUNNEL); IP ответа → набор gs_tunnel4 (если Категория явная).
  2. Пакет SYN: prerouting/mangle (table inet truba)
       iif br-lan, новый, не bypass → classify → meta mark = TUNNEL
       postrouting (persist, последним): ct mark = TUNNEL — все следующие пакеты
       соединения берут решение из ct mark, без классификации
  3. ip rule fwmark TUNNEL → table 77 → default dev awg0
  4. fw4 srcnat, зона truba: masq + fullcone → 10.77.77.2:51000 (порт сохраняется, если свободен)
  5. Труба: SNAT 10.77.77.2 → <VPS_IP>:51000 → интернет
```

### 2.2 Исходящий, Действие «Напрямую»

```
ПК → gosuslugi.ru (category-ru) или любой IP из geoip:ru
  mosdns → Яндекс DNS напрямую, IP → gs_direct4
  classify → meta mark = DIRECT → основная таблица → wan (masq + fullcone)
```

### 2.3 Входящий через IP Трубы (проброс / UPnP / fullcone-отображение)

```
Внешний узел → <VPS_IP>:27015
  1. Труба: DNAT → 10.77.77.2:27015 (источник не меняется)
  2. Роутер, iif awg0 (каждый пакет) → meta mark = INBOUND; persist → ct mark = INBOUND
  3. fw4 dstnat: проброс порта / UPnP / fullcone-отображение → 192.168.1.20:27015
  4. Ответ от 192.168.1.20 (iif br-lan): ct mark INBOUND → meta mark = TUNNEL
     → table 77 → awg0 → Труба → внешнему узлу.
     Без этого шага ответ ушёл бы в wan, и соединение развалилось бы. Это обязательная
     часть схемы. Решение пишется в ct mark последним в postrouting (priority 300) на
     каждом пакете: qosmate в postrouting перезаписывает ct mark целиком, и без этого
     метка INBOUND терялась уже на первом пакете (найдено на живом роутере).
```

### 2.4 Туннель упал

```
truba-watchdog: 3 неудачи подряд (handshake > 180 с или нет ping через awg0)
  → перезапуск интерфейса awg0
  → пока не восстановился, table 77:
       Аварийная блокировка ВКЛ  → blackhole default  (трафик «Туннель» отбрасывается)
       Аварийная блокировка ВЫКЛ → таблица пуста → ip rule проваливается в main → wan
  → после восстановления: default dev awg0 возвращается автоматически
```

---

## 3. Часть A — Труба (VPS)

Всё делает один повторяемый скрипт `vps/install-vps.sh`, запуск от root.

### 3.1 Подкоманды

| Команда | Что делает |
|---|---|
| `install` | Полная установка. При повторном запуске ключи и порты берутся из `/etc/truba/pipe.env` и не меняются |
| `show-config` | Печатает `.conf` для импорта в Роутер |
| `rotate-keys` | Новые ключи и параметры AWG под версию модуля на сейчас (в том числе переход на AWG 3.1); после этого конфиг Роутера нужно импортировать заново |
| `random-trailers on\|off` | RandomTrailers на Трубе и в `router.conf` (AWG 3.1); на Роутере переключить так же сразу после |
| `status` | Туннель, handshake, правила nft, счётчики conntrack |
| `uninstall` | Снимает правила, останавливает Туннель, возвращает SSH на прежний порт |

### 3.2 Шаги `install`

1. **Предусловия** (иначе выход с объяснением):
   - Ubuntu 24.04;
   - VPS — полноценная ВМ, а не контейнер (`systemd-detect-virt --container`): KVM, VMware, Xen, Hyper-V подходят, OpenVZ/LXC — нет;
   - в `/root/.ssh/authorized_keys` есть ключ: после переноса SSH вход по паролю закрывается;
   - IPv4 на интерфейсе маршрута по умолчанию совпадает с внешним IP (`curl -4 https://api.ipify.org`): значит, Труба не за NAT провайдера.
2. **Пакеты:** `nftables fail2ban unattended-upgrades linux-headers-$(uname -r) software-properties-common`. ufw выключается: он мешает нашим правилам nftables.
3. **AmneziaWG:** `add-apt-repository ppa:amnezia/ppa`, `apt install amneziawg` (DKMS + tools), `modprobe amneziawg`. Версия протокола (`awg --version` / версия пакета) записывается в `/etc/truba/pipe.env`: по ней CI собирает модуль для Роутера из того же тега.
4. **SSH на высокий порт.** В Ubuntu 24.04 SSH запускается через сокет-активацию, поэтому нужно:
   - `/etc/ssh/sshd_config.d/10-truba.conf`: `Port <SSH_PORT>`, `PasswordAuthentication no`, `PermitRootLogin prohibit-password`;
   - `systemctl daemon-reload && systemctl restart ssh.socket`.
5. **sysctl** `/etc/sysctl.d/90-truba.conf`:
   ```
   net.ipv4.ip_forward = 1
   net.core.default_qdisc = fq_codel
   net.ipv4.tcp_congestion_control = bbr
   net.netfilter.nf_conntrack_max = 262144
   net.ipv6.conf.all.forwarding = 0
   ```
   И `/etc/modules-load.d/truba.conf` с `nf_conntrack`. Без него при загрузке VPS `systemd-sysctl` пропускает `nf_conntrack_max`: модуля ещё нет. Тогда остаётся ядерный предел (7680 на 1 ГБ), и при полной таблице новые соединения отбрасываются. Найдено после перезагрузки живого VPS.

   Очередь — `fq_codel`, а не `fq`, и у WAN она заменяется сразу (`tc qdisc replace`): `default_qdisc` действует только на новые очереди. У `fq` предел — 100 пакетов на поток, а весь Туннель для неё один поток. На пиках она отбрасывала пачки пакетов, и скачивание через Туннель вставало на 2–5 с: на живом VPS отброшенные пакеты `fq` посекундно совпали с остановками. BBR с ядра 4.13 сам задаёт темп отправки и без `fq`.

   **MTU Туннеля** считается от MTU интерфейса WAN: пакет Туннеля с обёрткой (IPv4 20 + UDP 8 + заголовок и тег AWG 32 + `S4` до 27 = 87 байт) должен помещаться в сеть VPS целиком. Найдено на VPS с сетью 1400: при MTU 1380 почти каждый пакет резался на два фрагмента. При обычной сети 1500 остаётся 1380.
6. **Ключи и параметры AWG.**
   - Генерируются пары ключей Трубы и Роутера и PSK.
   - Параметры маскировки (`Jc/Jmin/Jmax`, `S1–S4`, `H1–H4`, `I1–I5`) генерируются по правилам Amnezia для установленной версии: например, `Jmax ≤ 1280`, `S1 + 56 ≠ S2`, диапазоны `H` не пересекаются.
   - Версия протокола определяется пробным интерфейсом: 1 — классический AWG, 2 — AWG 2.0 (`S3/S4`, диапазоны `H`, `I1`), 3 — AWG 3.1. Для 3.1 добавляются:
     - `HeaderProtectionKey` — свой ключ (`awg genkey`), одинаковый у сторон. Шифрует индекс получателя и счётчик, по которым иначе узнаётся WireGuard: у всех пакетов сессии одинаковый индекс, а счётчик растёт по порядку. Защите нужны `S1–S4 ≥ 12`, поэтому `S3` и `S4` генерируются от 12.
     - `DisableCookies = on` у обеих сторон. Ответ cookie шлётся только под нагрузкой и узнаваем по размеру; с одним пиром он не нужен.
     - `RandomTrailers` — в запасе, по умолчанию выключен. Добивает пакеты до случайной длины против DPI по размерам, но мелкие пакеты (ACK, звонки, игры) растут в среднем на 600–700 байт. Должен совпадать у сторон: пока он разный, рукопожатие не проходит. Включается `install-vps.sh random-trailers on` на Трубе и флагом Random Trailers у `awg0` на Роутере.
   - Повторный `install` параметры не меняет, даже если модуль обновился до 3.1: иначе старый конфиг Роутера перестал бы подключаться. Переход на 3.1 — через `rotate-keys` и новый импорт `router.conf`.
7. **`/etc/amnezia/amneziawg/awg0.conf`**, unit `awg-quick@awg0`:
   ```ini
   [Interface]
   PrivateKey = <vps_priv>
   Address    = 10.77.77.1/30
   ListenPort = <AWG_PORT>
   MTU        = <MTU сети VPS − 87, не больше 1380>
   Jc = … ; Jmin = … ; Jmax = … ; S1..S4 = … ; H1..H4 = … ; I1..I5 = …
   HeaderProtectionKey = <hpk> # AWG 3.1, одинаковый у сторон
   DisableCookies = on         # AWG 3.1
   # RandomTrailers = on       # только после install-vps.sh random-trailers on

   [Peer]                      # Роутер — единственный пир
   PublicKey    = <router_pub>
   PresharedKey = <psk>
   AllowedIPs   = 10.77.77.2/32
   ```
8. **Правила nft** `/etc/truba/pipe.nft` + unit `truba-pipe.service` (`Before=awg-quick@awg0`):
   ```nft
   #!/usr/sbin/nft -f
   define WAN      = "eth0"          # подставляется по ip route get 1.1.1.1
   define AWG      = "awg0"
   define PUB      = 203.0.113.10    # <VPS_IP>
   define RTR      = 10.77.77.2
   define SSH_PORT = 52222
   define AWG_PORT = 51820

   table ip truba_nat
   delete table ip truba_nat
   table ip truba_nat {
     chain prerouting {
       type nat hook prerouting priority dstnat; policy accept;
       iifname $WAN udp dport 68 return                                       # DHCP-клиент самого VPS
       iifname $WAN ip daddr $PUB tcp dport != $SSH_PORT dnat to $RTR
       iifname $WAN ip daddr $PUB udp dport != $AWG_PORT dnat to $RTR
       iifname $WAN ip daddr $PUB meta l4proto != { tcp, udp } dnat to $RTR   # ICMP echo и прочее → Роутер
     }
     chain postrouting {
       type nat hook postrouting priority srcnat; policy accept;
       oifname $WAN ip saddr $RTR snat to $PUB        # порт сохраняется, если свободен
     }
   }

   table inet truba_filter
   delete table inet truba_filter
   table inet truba_filter {
     chain input {
       type filter hook input priority filter; policy drop;
       iif lo accept
       ct state established,related accept
       ct state invalid drop
       iifname $WAN tcp dport $SSH_PORT accept
       iifname $WAN udp dport $AWG_PORT accept
       iifname $AWG ip saddr $RTR accept              # ping Роутера до 10.77.77.1
     }
     chain forward {
       type filter hook forward priority filter; policy drop;
       ct state established,related accept
       ct state invalid drop
       iifname $WAN oifname $AWG ct status dnat accept
       iifname $AWG oifname $WAN ip saddr $RTR accept
     }
     chain mss {
       type filter hook forward priority mangle; policy accept;
       tcp flags syn tcp option maxseg size set rt mtu
     }
   }
   ```
   Применение безопасное: скрипт загружает правила и ждёт 120 с, пока пользователь подтвердит вход по SSH на новом порту. Без подтверждения правила и SSH откатываются.
9. **fail2ban:** jail `sshd` на `<SSH_PORT>`, `banaction = nftables-multiport`.
10. **unattended-upgrades:** включён. DKMS сам пересобирает модуль AWG при обновлении ядра Ubuntu.
11. **Итог:** `/root/truba/router.conf` — стандартный AWG-`.conf` для Роутера (`Address = 10.77.77.2/30`, `Endpoint = <VPS_IP>:<AWG_PORT>`, `AllowedIPs = 0.0.0.0/0`, `PersistentKeepalive = 25`, все параметры маскировки).

---

## 4. Часть B — Роутер: каркас данных

### 4.1 Пакеты

| Пакет | Откуда | Назначение |
|---|---|---|
| `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` | наш фид (сборка из `amnezia-vpn/amneziawg-openwrt` того же тега, что на VPS) | Туннель как стандартный интерфейс netifd |
| `truba` | наш фид | ядро: init, ucode-скрипты, rpcd-плагин, контроль туннеля, обновление списков |
| `luci-app-truba` | наш фид | интерфейс (6 вкладок, RU/EN) |
| `mosdns` (5.3.3), `ca-bundle`, `curl` | фид ImmortalWrt | DNS-классификатор, скачивание списков |
| `kmod-nft-socket` | фид ImmortalWrt (в стоковом образе его нет) | `socket mark` в цепочке `output` (§4.4). Без модуля Труба работает, но правила `socket mark` нет — в syslog предупреждение |
| `luci-app-upnp` (`miniupnpd-nftables`) | фид ImmortalWrt | UPnP/NAT-PMP на Туннеле (по переключателю) |

### 4.2 Что пакет `truba` настраивает при установке (uci-defaults, откатывается при удалении)

```sh
# Full cone; аппаратное ускорение выключено — оно обходит netfilter целиком.
# Программное ускорение не трогаем (в стоковой ImmortalWrt оно включено): при нём пакеты
# ускоренных соединений идут мимо счётчиков Трубы и мимо qosmate — «Обзор» предупреждает.
uci set firewall.@defaults[0].fullcone='1'          # опция fw4 из патча ImmortalWrt
uci set firewall.@defaults[0].fullcone6='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'

# Зона Туннеля
uci set firewall.truba=zone
uci set firewall.truba.name='truba'
uci add_list firewall.truba.network='awg0'
uci set firewall.truba.input='REJECT'               # LuCI/SSH Роутера не видны из Туннеля
uci set firewall.truba.output='ACCEPT'
uci set firewall.truba.forward='REJECT'
uci set firewall.truba.masq='1'
uci set firewall.truba.mtu_fix='1'
uci set firewall.lan_truba=forwarding
uci set firewall.lan_truba.src='lan'
uci set firewall.lan_truba.dest='truba'

# IPv6 домашней сети не трогаем (нужен roamd, ADR 0005): ra/dhcpv6/ip6assign/ULA остаются как есть.
# Закрываем только выход в интернет по IPv6 — страховка на случай, если провайдер включит IPv6.
uci set firewall.truba_no_ipv6_inet=rule
uci set firewall.truba_no_ipv6_inet.name='Truba: no IPv6 internet from LAN'
uci set firewall.truba_no_ipv6_inet.src='lan'
uci set firewall.truba_no_ipv6_inet.dest='wan'
uci set firewall.truba_no_ipv6_inet.family='ipv6'
uci set firewall.truba_no_ipv6_inet.target='REJECT'   # REJECT, а не DROP: Happy Eyeballs сразу уходит на IPv4

# Стоковый init mosdns не используется — mosdns запускает служба truba
/etc/init.d/mosdns disable
```

### 4.3 Маршрутизация по меткам

```sh
ip rule add fwmark 0x00010000/0x00ff0000 lookup 77 priority 1000   # трафик Действия «Туннель» и mosdns so_mark
ip rule add oif awg0 lookup 77 priority 1001                       # сокеты, привязанные к awg0 (watchdog, curl --interface)
sysctl -w net.ipv4.conf.awg0.rp_filter=0                           # входящие из Туннеля с любыми источниками
# table 77 ведёт служба по состоянию Туннеля:
#   здоров                               → ip route replace default dev awg0 table 77
#   упал + Аварийная блокировка          → ip route replace blackhole default table 77
#   упал + без Аварийной блокировки      → ip route flush table 77
```

Правило 1000 сравнивает только байт Трубы (маска `0x00ff0000`), поэтому чужие биты в метке ему не мешают. Чужие правила с меньшим приоритетом и точной меткой (OpenClash: `999: fwmark 0x162 lookup 354`) после возврата байта Трубы уже не срабатывают — см. цепочку `output` в §4.4.

### 4.4 Таблица `inet truba` (генерируется целиком и применяется атомарно `nft -f`)

```nft
table inet truba
delete table inet truba
table inet truba {
  set lan_if     { type ifname; elements = { "br-lan" } }               # из выбранных зон
  set bypass4    { type ipv4_addr; flags interval; elements = {
                     192.168.1.0/24, 10.77.77.0/30, <VPS_IP>, 224.0.0.0/4, 255.255.255.255 } }
  set gi_block4  { type ipv4_addr; flags interval; auto-merge; }         # Категории geoip с Действием «Блок»
  set gi_tunnel4 { type ipv4_addr; flags interval; auto-merge; }         # … «Туннель»
  set gi_direct4 { type ipv4_addr; flags interval; auto-merge; }         # … «Напрямую»
  set gs_tunnel4 { type ipv4_addr; }                                     # наполняет mosdns
  set gs_direct4 { type ipv4_addr; }                                     # наполняет mosdns
  set dev_tunnel { type ether_addr; }                                    # Политика «Всё в туннель»
  set dev_direct { type ether_addr; }                                    # Политика «Всё напрямую»

  counter c_tunnel {}        # новые соединения устройств по Действиям
  counter c_direct {}
  counter c_block {}         # отброшенные пакеты
  counter c_inbound {}       # новые входящие через Туннель
  counter c_tunnel_down {}   # байты трафика устройств (цепочка stats): down — к устройствам,
  counter c_tunnel_up {}     # up — от них; так же c_direct_*, c_inbound_*.
                             # При применении переносятся значения прежней таблицы.

  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;

    meta nfproto != ipv4 return                                         # IPv6 (roamd, link-local, ULA) не трогаем

    # «meta mark set X» ниже — сокращение: на деле meta mark & 0xff00ffff | X,
    # чужие биты не трогаются

    # входящие через IP Трубы: каждый пакет — чтобы ответы вернулись в Туннель
    iifname "awg0" ct state new counter name c_inbound
    iifname "awg0" meta mark set 0x00040000 return
    # входящие с других внешних интерфейсов (fullcone-отображение на wan) — ответы Напрямую
    iifname != @lan_if ct state new meta mark set 0x00020000 return

    ct mark & 0x00ff0000 != 0 goto restore                              # липкость: решение уже принято
    iifname != @lan_if return
    ip daddr @bypass4 return

    jump classify
    meta mark & 0x00ff0000 == 0x00010000 counter name c_tunnel
    meta mark & 0x00ff0000 == 0x00020000 counter name c_direct
  }

  chain restore {
    ct mark & 0x00ff0000 == 0x00040000 meta mark set 0x00010000 return  # ответы на входящие
    ct mark & 0x00ff0000 == 0x00010000 meta mark set 0x00010000 return
    ct mark & 0x00ff0000 == 0x00020000 meta mark set 0x00020000 return
  }

  # Приоритет: Блок → Политика устройства → geosite (Туннель > Напрямую) → geoip → Режим
  chain classify {
    ip daddr @gi_block4  counter name c_block drop
    ether saddr @dev_direct meta mark set 0x00020000 return
    ether saddr @dev_tunnel meta mark set 0x00010000 return
    ip daddr @gs_tunnel4 meta mark set 0x00010000 return
    ip daddr @gs_direct4 meta mark set 0x00020000 return
    ip daddr @gi_tunnel4 meta mark set 0x00010000 return
    ip daddr @gi_direct4 meta mark set 0x00020000 return
    meta mark set 0x00010000          # Режим «Всё в туннель»  (в «Выборочном» — 0x00020000)
  }

  # Решение пакета → в соединение, последним: после всех, кто пишет ct mark целиком
  chain persist {
    type filter hook postrouting priority 300; policy accept;
    meta nfproto != ipv4 return
    meta mark & 0x00ff0000 == 0x00040000 ct mark set ct mark & 0xff00ffff | 0x00040000 return
    meta mark & 0x00ff0000 == 0x00010000 ct mark set ct mark & 0xff00ffff | 0x00010000 return
    meta mark & 0x00ff0000 == 0x00020000 ct mark set ct mark & 0xff00ffff | 0x00020000 return
  }

  # Учёт трафика устройств: только транзит, уже пропущенный fw4. Направление — по интерфейсам
  # и ct direction, не по ct mark (ответы из Туннеля переписывают её на «входящее»).
  chain stats {
    type filter hook forward priority filter + 10; policy accept;
    meta nfproto != ipv4 return
    iifname @lan_if oifname @lan_if return
    iifname @lan_if oifname "awg0" ct direction original counter name c_tunnel_up return
    iifname "awg0" oifname @lan_if ct direction reply counter name c_tunnel_down return
    iifname "awg0" oifname @lan_if counter name c_inbound_down return
    iifname @lan_if oifname "awg0" counter name c_inbound_up return
    iifname @lan_if ct direction original counter name c_direct_up return
    oifname @lan_if ct direction reply counter name c_direct_down return
  }

  # Свои сокеты Роутера с SO_MARK TUNNEL (mosdns, «Проверить NAT»): байт Трубы — из метки
  # сокета, после чужих цепочек output (нужен kmod-nft-socket; без него цепочки нет)
  chain output {
    type route hook output priority mangle + 10; policy accept;
    meta nfproto != ipv4 return
    ip daddr <IP Трубы> meta mark set 0x00020000 return   # сам Туннель: только напрямую
    socket mark & 0x00ff0000 == 0x00010000 meta mark set 0x00010000
  }

  # Перехват DNS: устройства с захардкоженным 8.8.8.8 всё равно идут через Роутер
  chain dns_hijack {
    type nat hook prerouting priority dstnat - 5; policy accept;
    meta nfproto ipv4 iifname @lan_if meta l4proto { tcp, udp } th dport 53 redirect to :53
  }
}
```

**Почему так:**
- **Только IPv4.** Первое правило пропускает весь IPv6 без изменений: на нём работает обнаружение узлов roamd (`ff02::1` на `br-lan`). Без этого IPv6-пакеты попадали бы под действие Режима по умолчанию, и счётчики врали бы. Перехват DNS тоже только для IPv4 (ADR 0005).
- **Блок для geosite** выполняется на уровне DNS (mosdns отвечает NXDOMAIN), а не по IP. Блокировка по IP задела бы общие CDN.
- **Блок для geoip** — отбрасывание пакетов по IP.
- **Наборы `gi_*`** — объединение Категорий geoip с одинаковым Действием. Обычно в Режиме «Всё в туннель» `ru` и `private` → `gi_direct4`.
- **Счётчики двух видов.** `c_tunnel`, `c_direct`, `c_inbound` считают новые соединения: классификацию проходит только первый пакет соединения, остальные идут по ct mark мимо неё. `c_block` — отброшенные пакеты. Объём трафика устройств по Действиям и направлениям считает цепочка `stats` (`c_*_down` — к устройствам, `c_*_up` — от них). Значения переносятся в новую таблицу при каждом применении, отсчёт — с запуска службы (`applied.counters_since`). При программном ускорении пакеты ускоренных соединений идут мимо `stats`, и учёт неполный.
- **Липкость через ct mark:** изменение наборов (обновление списков, новые ответы DNS) не переводит уже открытые соединения на другой путь. Отсюда тест 6 — «без обрыва».
- **Наборы `gs_*` без таймаута.** Они полностью сбрасываются при изменении Действий или Режима и при обновлении geosite. Ответы классифицированных доменов mosdns отдаёт с TTL не больше 300 с, чтобы после сброса устройства быстро перерезолвили адреса.
- **Цепочка `output` — для своих сокетов Роутера.** Чужая route-цепочка output может перезаписать meta mark целиком: OpenClash с `router_self_proxy` ставит `0x162` почти всему исходящему трафику Роутера, правило 999 уводит его в таблицу 354 и дальше в Clash. Тогда «Проверить NAT» показывала IP прокси вместо IP Трубы (найдено на живом роутере); так же уводились бы запросы mosdns к DNS-серверам «Туннеля». Цепочка Трубы идёт после mangle и берёт решение из метки сокета (`socket mark`), а не из meta mark, поэтому ей неважно, кто и в каком порядке переписал метку до неё. Она возвращает только байт Трубы (`0x162` → `0x10162`), а route-цепочка при смене метки маршрутизирует пакет заново: правило 1000 с маской срабатывает, а чужое правило с точной меткой — уже нет. Трафик без метки Туннеля цепочка не трогает. **Пакетам к IP Трубы — только «Напрямую»** (байт Трубы `0x02`), и это первое правило цепочки. Это сам Туннель — внешние зашифрованные пакеты AmneziaWG, и им грозили две вещи (обе найдены на живом роутере): они проходят output ещё раз и несут сокет исходного пакета с его меткой «Туннель», и правило `socket mark` заворачивало Туннель в `awg0` — петля, `tx_dropped` (r4); а OpenClash ставил им `0x162` и уводил Туннель через свой прокси. С меткой «Напрямую» чужое правило с точной меткой уже не срабатывает, и в исключения OpenClash IP Трубы добавлять не нужно. Правило не требует `nft_socket`; без известного IP Трубы цепочки нет. На veth обе беды в тесте не воспроизводились, поэтому Туннель в тесте теперь настоящий WireGuard. Чужие правила с маской, которая не включает байт Трубы, по-прежнему сработали бы раньше правила 1000. Перенаправление DNAT в nat output (режим redirect вместо TPROXY) метками не лечится.

### 4.5 DNS: dnsmasq → mosdns

**dnsmasq** — через UCI, служба сохраняет исходные значения и восстанавливает их при выключении:
- `noresolv=1`;
- `server=127.0.0.1#5335`;
- `cachesize=0`;
- фильтр AAAA выполняет mosdns, и только для интернет-доменов: имена из домашней сети (DHCP-хосты, `.lan`), включая их AAAA, dnsmasq отвечает сам, не пересылая в mosdns.

**mosdns** — конфиг `/var/etc/truba/mosdns.yaml` генерируется из UCI. Эскиз под Режим «Всё в туннель»; точный синтаксис проверяется на mosdns 5.3.3 на этапе 5:

```yaml
log: { level: warn }
api: { http: "127.0.0.1:5336" }   # порт DNS + 1: счётчики кэша (/metrics) для «Обзора»; там же /debug/pprof — только 127.0.0.1.
                                  # Ошибка API останавливает mosdns целиком: если порт занят другой программой (netstat -lntp), API не включается — пропадают только счётчики
plugins:
  # по одному domain_set на каждую Категорию с явным Действием; файлы — результат распаковщика
  - { tag: c_category_ads,       type: domain_set, args: { files: [/var/lib/truba/geosite/category-ads.txt] } }
  - { tag: c_category_ru,        type: domain_set, args: { files: [/var/lib/truba/geosite/category-ru.txt] } }
  - { tag: c_category_cdn_ru,    type: domain_set, args: { files: [/var/lib/truba/geosite/category-cdn-ru.txt] } }
  - { tag: c_private,            type: domain_set, args: { files: [/var/lib/truba/geosite/private.txt] } }

  - tag: up_tunnel
    type: forward
    args:
      concurrent: 2
      upstreams:
        - { addr: "https://1.1.1.1/dns-query", so_mark: 0x00010000 }
        - { addr: "https://8.8.8.8/dns-query", so_mark: 0x00010000 }
  - tag: up_direct
    type: forward
    args:
      upstreams:
        - { addr: "tls://common.dot.dns.yandex.net", dial_addr: "77.88.8.8" }

  # Ленивый кэш: истёкшая запись отдаётся сразу с TTL 5 с и проходит дальше по цепочке (nftset тоже),
  # а свежий ответ запрашивается в фоне по тем же правилам. Повторные запросы не ждут DNS.
  # Дамп в /var (tmpfs): кэш переживает перезапуск mosdns при смене настроек DNS или списков,
  # но не перезагрузку; флеш не изнашивается.
  - { tag: cache, type: cache, args: { size: 65536, lazy_cache_ttl: 86400, dump_file: /var/lib/truba/mosdns-cache.dump } }

  # nftset в mosdns 5 — только встроенное действие «семейство,таблица,набор,тип,маска», не тип плагина.
  # Ответ из кэша тоже проходит через nftset: после пересборки наборов IP возвращаются сами.
  - tag: flow_tunnel
    type: sequence
    args:
      - { matches: [ "!has_resp" ], exec: $up_tunnel }
      - { exec: ttl 0-300 }
      - { exec: "nftset inet,truba,gs_tunnel4,ipv4_addr,32" }
  - tag: flow_direct
    type: sequence
    args:
      - { matches: [ "!has_resp" ], exec: $up_direct }
      - { exec: ttl 0-300 }
      - { exec: "nftset inet,truba,gs_direct4,ipv4_addr,32" }
  - tag: flow_router                      # NTP, зеркала списков, endpoint Трубы — всегда Напрямую, без nftset
    type: sequence
    args: [ { matches: [ "!has_resp" ], exec: $up_direct } ]
  - tag: flow_default                     # Режим «Всё в туннель»: DNS через Туннель, без nftset
    type: sequence
    args: [ { matches: [ "!has_resp" ], exec: $up_tunnel } ]

  - tag: main
    type: sequence
    args:
      - { matches: [ qtype 28 ], exec: reject 0 }        # AAAA → пустой ответ: Маршрутизация только IPv4, IPv6-интернет закрыт (ADR 0005)
      - { exec: $cache }
      - { matches: [ qname $c_router ], exec: goto flow_router }
      # порядок генерируется: от узких Категорий к широким; при равенстве Блок → Туннель → Напрямую
      - { matches: [ qname $c_0 ], exec: goto flow_direct }   # category-cdn-ru (14)
      - { matches: [ qname $c_1 ], exec: goto flow_direct }   # private (131)
      - { matches: [ qname $c_2 ], exec: goto flow_direct }   # category-ru (429)
      - { matches: [ qname $c_3 ], exec: reject 3 }           # category-ads (42 535): Блок → NXDOMAIN
      - { exec: goto flow_default }

  - { tag: udp_in, type: udp_server, args: { entry: main, listen: "127.0.0.1:5335" } }
  - { tag: tcp_in, type: tcp_server, args: { entry: main, listen: "127.0.0.1:5335" } }
```

Настоящий конфиг генерирует [render.uc](router/truba/files/usr/share/ucode/truba/render.uc) в виде JSON (подмножество YAML). Он проверен на mosdns 5.3.3 в тесте `router`.

**Порядок проверки Категорий («узость»).** Категории сортируются по числу записей: вложенная всегда меньше объемлющей, поэтому вложенность соблюдается сама. При равенстве — Блок → Туннель → Напрямую. Вложенность (A ⊂ B, если все записи A есть в B) распаковщик вычисляет для колонки «Вложена в» в интерфейсе.

**Служебные хосты Роутера резолвятся Напрямую.** Это NTP-серверы из `system`, хосты зеркал списков и endpoint Трубы, если он задан именем. Иначе при Аварийной блокировке получается тупик: после перезагрузки без верного времени AmneziaWG-сервер отвергает handshake (защита от повтора по метке времени), а NTP не может отрезолвить свой сервер через неработающий Туннель.

**Политики устройств действуют только на маршрутизацию.** DNS общий: mosdns видит запросы от dnsmasq, а не от устройств.

### 4.6 Распаковщик `.dat` (ucode, `/usr/share/truba/dat.uc`)

- **Вход:** `geoip.dat` и `geosite.dat` без изменений.
- **Разбор:** protobuf `GeoIPList` / `GeoSiteList` разбирается побайтово, внешних бинарников нет.
- **Выход** в tmpfs `/var/lib/truba/`:
  - `geosite/<tag>.txt` — строки `domain:` / `full:` / `regexp:` / `keyword:` **ровно** как в файле. Атрибуты не используются; регулярные выражения Go RE2 одинаково понимают и v2ray, и mosdns.
  - `geoip/<tag>.v4` — IPv4-подсети (IPv6-записи пропускаются: Маршрутизация только IPv4, ADR 0005).
  - `categories.json` — для интерфейса и порядка проверки: `[{set, tag, count, types:{domain,full,regexp,keyword}, subset_of:[…]}]`.
- **Регистр тегов.** В файле теги в верхнем регистре (`CATEGORY-RU`), в интерфейсе и именах файлов — в нижнем. Сопоставление без учёта регистра, как в v2ray.
- **Кэш:** распаковка выполняется только если изменился sha256 `.dat`.
- **Тесты на реальных файлах от 2026-10-04** — проверка, что распаковка ничего не теряет:
  - geosite — 61 Категория, `category-ru` = 429 записей, `category-ads` = 42 535, уникальных `regexp` 5 (4 в `netflix`, 1 в `private`; сборная `category-streaming` повторяет 4 из `netflix`);
  - geoip — `ru` = 35 696 записей (IPv4 + IPv6), `private` = 17.

### 4.7 Обновление Наборов правил (`/usr/libexec/truba/update-lists`)

1. **Расписание.** Блок cron между маркерами `# truba-begin` / `# truba-end`. Время хранится в UTC (по умолчанию 12:00) и переводится в часовой пояс Роутера. geoip выходит раз в три дня около 10–11 UTC, geosite — нерегулярно, обычно до 09 UTC: в 12:00 новый выпуск подхватывается в тот же день (прежние 04:00 были раньше обоих, и выпуск ждал следующего утра; при обновлении пакета 04:00 меняется на 12:00). «Обзор» показывает время и результат последней проверки и предупреждает, если её не было больше 36 часов или она не удалась.
2. **Скачивание.** Для каждого файла:
   - основной путь — `curl --interface awg0 --fail --max-time 120` с `raw.githubusercontent.com/kirilllavrov/<repo>/release/<file>`;
   - при ошибке — `curl` напрямую с `cdn.jsdelivr.net/gh/kirilllavrov/<repo>@release/<file>`;
   - так же скачивается `<file>.sha256sum`.
3. **Проверка.** `sha256sum -c`. При несовпадении — отказ, запись в журнал, текущие файлы не трогаются.
4. **Без изменений.** Если sha256 совпадает с текущим, выход без перезагрузки.
5. **Атомарная замена.** Текущий файл переносится в `/etc/truba/lists/prev/`, новый — в `/etc/truba/lists/`.
6. **Применение.** `truba reload`: распаковка → атомарная замена наборов `gi_*` → перезапуск mosdns и сброс `gs_*`. Открытые соединения сохраняют путь благодаря ct mark.
7. **Откат.** Обратная перестановка `prev` ↔ текущий и `truba reload`.

### 4.8 Контроль туннеля (`truba-watchdog`, procd-инстанс)

- **Цикл.** Каждые `interval` секунд (30) проверяются:
  - возраст handshake из `awg show awg0 latest-handshakes` (не больше 180 с);
  - `ping -I awg0 -c1 -W2 <probe>`. По умолчанию это адрес Трубы внутри Туннеля (`10.77.77.1`): адрес в интернете не ответил бы, пока в таблице 77 стоит blackhole, и Туннель никогда не признался бы восстановленным. Поэтому подсеть Туннеля держится в таблице 77 всегда.
- **Для «Обзора».** Время ответа на ping и окно последних 20 проверок (около 10 минут при интервале 30 с; потеря — `null`) пишутся в `/var/run/truba/health.json` — в оперативную память. Когда Туннель в порядке, а итог «Проверки NAT» старше этого момента или его нет, watchdog запускает проверку в фоне (§5.2). Новых пингов ради этого нет: используется та же проверка. Отдельно — крупные пакеты: сразу после подъёма Туннеля и затем раз в 10 проверок watchdog пингует Трубу пакетом во весь MTU Туннеля (`health.json` → `big`). Обычный ping мелкий и не видит пути, который теряет полноразмерные пакеты: так было с VPS в сети 1400, когда MTU Туннеля 1380 не помещался и загрузки замирали на секунды. procd следит и за кодом watchdog, поэтому после обновления пакета `reload` перезапускает его с новым кодом; перезапуск (и при смене настроек) не обнуляет «в порядке с» и окно проверок.
- **Перезапуск.** После `fails` (3) неудач подряд — `ubus call network.interface.awg0 down` / `up`. Состояние «упал» → `table 77` по правилу из §4.3.
- **Восстановление.** Первая успешная проверка возвращает `default dev awg0`.
- **События.** Пишутся в журнал (`logger -t truba`). Отправляется `ubus send truba.tunnel {state}` — точка расширения для будущих уведомлений, например в Telegram.

### 4.9 UPnP / NAT-PMP

Переключатель «UPnP» на вкладке «Входящие» (по умолчанию выключен). При включении выставляется:

```
upnpd.config.enabled='1'
upnpd.config.external_iface='truba'        # зона/интерфейс awg0
upnpd.config.external_ip='<VPS_IP>'        # у awg0 частный адрес; устройствам сообщается IP Трубы
```

Ручные пробросы портов работают всегда: стандартный LuCI «Межсетевой экран → Перенаправления портов», источник — зона `truba`.

---

## 5. Часть C — `luci-app-truba`: интерфейс и автоматика

### 5.1 UCI-схема `/etc/config/truba`

```
config main 'main'
	option routing    '1'          # переключатель «Маршрутизация»
	option mode       'all'        # all = «Всё в туннель» | selective = «Выборочный»
	option killswitch '1'          # Аварийная блокировка
	option iface      'awg0'       # интерфейс netifd Туннеля (переключатель «Туннель» = network.awg0.disabled)
	list   zone       'lan'        # на какие зоны действует Маршрутизация
	option dns_hijack '1'
	option upnp       '0'
	# list stun 'host:port'        # STUN-серверы «Проверки NAT»; нет — стандартные (§5.2)

config rule                        # Действие Категории в конкретном Режиме; «По режиму» не хранится
	option mode   'all'
	option set    'geoip'          # geoip | geosite
	option tag    'ru'
	option action 'direct'         # direct | tunnel | block

config device                      # Политика устройства
	option name   'PS5'
	option mac    'AA:BB:CC:DD:EE:FF'
	option policy 'tunnel'         # tunnel | direct | rules

config dns 'dns'
	list   tunnel_upstream 'https://1.1.1.1/dns-query'
	list   tunnel_upstream 'https://8.8.8.8/dns-query'
	list   direct_upstream 'tls://common.dot.dns.yandex.net@77.88.8.8'
	option port            '5335'
	option ttl_max         '300'
	option cache_size      '65536'
	option lazy_cache_ttl  '86400'   # сколько хранить истёкшие ответы для ленивого кэша; 0 — выключен

config lists 'lists'
	option geoip_url      'https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat'
	option geoip_mirror   'https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat'
	option geosite_url    'https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat'
	option geosite_mirror 'https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat'
	option update_utc     '12:00'
	option via_tunnel     '1'

config watchdog 'watchdog'
	option enabled       '1'
	option interval      '30'
	option handshake_max '180'
	option fails         '3'
	option probe         ''          # пусто — адрес Трубы внутри Туннеля
```

**Стартовые настройки** — секции `rule`, которые создаются при установке и по кнопке «Сбросить»:

| Режим | Набор | Категория | Действие |
|---|---|---|---|
| all | geoip | `ru`, `private` | Напрямую |
| all | geosite | `category-ru`, `category-cdn-ru`, `private` | Напрямую |
| all | geosite | `category-ads` | Блок |
| selective | geosite | `category-streaming` | Туннель |
| selective | geosite | `category-ads` | Блок |

Все остальные Категории — «По режиму».

**Категория пропала из файла.** Если она есть в UCI, но отсутствует в текущем `.dat`, правило пропускается, а в интерфейсе висит предупреждение. Новая Категория в файле появляется в таблице с Действием «По режиму».

### 5.2 Вкладки («Службы → Труба», RU/EN)

| Вкладка | Содержимое |
|---|---|
| **Обзор** | Сводка, без подробностей: каждый факт показывается на одной вкладке, рядом со своими настройками. Плитки со ссылками на вкладки: «Туннель» (состояние, задержка, handshake и потери, крупные пакеты; переключатель интерфейса), «Маршрутизация» (Режим, доля новых соединений через Туннель, зоны; переключатель), «DNS и списки» (mosdns, доля ответов из кэша, дата списков, следующая проверка), «Входящие» (IP Трубы, итог проверки NAT, число пробросов UPnP и ручных). Переключатели меняют конфигурацию в браузере; сохраняет её «Сохранить и применить». Предупреждения — списком, у каждого ссылка туда, где его исправляют (о программном ускорении, OpenClash fake-ip, UPnP без miniupnpd, крупных пакетах, проверке NAT и списков). Трафик устройств: таблица по Действиям (к устройствам, от устройств, новые соединения в минуту; строка «Блок» — отброшенные пакеты), доля исходящих соединений через Туннель, график скорости за 10 минут — единственное место для счётчиков, в том числе входящих. Страница строится один раз, опрос меняет только текст: колонки фиксированы, цифры моноширинные. История графика — в `sessionStorage` браузера |
| **Туннель** | Состояние (опрос раз в 5 с): handshake с подсветкой (жёлтый > 3 мин, красный > 5 мин), задержка и потери до Трубы за ~10 мин с мини-графиком, крупные пакеты (итог ping во весь MTU от watchdog), контроль туннеля, таблица 77, rx/tx интерфейса. Импорт `.conf` (файл или вставка) → запись в `network.awg0` и пир; параметры AWG; MTU; keepalive. Те же данные видны и в стандартном luci-proto-amneziawg. Контроль Туннеля и Аварийная блокировка — в одном блоке: что проверять и что делать, пока Туннель не отвечает |
| **Маршрутизация** | Режим (переключатель из двух вариантов); зоны; «В наборах сейчас» — подсети geoip по Действиям и IP из DNS; Политики устройств (из DHCP-клиентов: MAC, а рядом имя и IP устройства в сети; «Всё в туннель / Всё напрямую / По правилам»); таблица Категорий (Набор · Категория · Записей · Типы · Вложена в · Действие) с поиском и фильтром по Действию со счётчиками; Категории, которых нет в наборе, убираются одной кнопкой; «Сбросить к Стартовым настройкам» |
| **DNS и списки** | Одна страница. Состояние DNS (опрос раз в 10 с): mosdns, доля ответов из кэша и истёкших, заполнение кэша. DNS: серверы для «Туннель» и «Напрямую»; перехват DNS; кэш (в том числе ленивый); максимальный TTL; порт mosdns — во вкладке «Дополнительно». Наборы правил: текущая и предыдущая версии (sha256, дата) и итог последней проверки, следующая проверка; «Обновить сейчас», «Откатить»; время обновления (UTC), «через Туннель»; источники и зеркала — во вкладке «Источники» |
| **Входящие** | Проверка NAT: итог последней проверки (внешний адрес, IP Трубы, сохранение порта, одинаковое отображение, когда и как запущена; ответы STUN-серверов — по клику; кнопка «Проверить NAT»). Переключатель UPnP/NAT-PMP; текущие UPnP-отображения; ссылка на перенаправления портов из зоны `truba`. Трафик входящих — на «Обзоре» |
| **Диагностика** | «Проверить домен/IP» → отрезолвленные IP, совпавшие Категории (geosite/geoip), итоговое Действие и правило Приоритета, которое сработало; «Проверка Туннеля» — ping Трубы пакетами трёх размеров (84 байта, 1028 и весь MTU), потери и задержка по каждому; журнал Трубы и mosdns с фильтром. Уровень строки mosdns берётся из неё самой: mosdns пишет всё в stderr, и syslog помечает каждую строку как ошибку |

Прежние адреса вкладок `…/truba/devices` и `…/truba/lists` — скрытые пункты меню, ведут на «Маршрутизацию» и «DNS и списки». Цвета значков — из переменных темы (Bootstrap, светлая и тёмная), общие стили — `truba/truba.css`. Вид у вкладок общий: таблицы «название — значение» (`truba-kv`) и числовые таблицы (`truba-grid`) — свои, списки записей (Категории, пробросы, отображения UPnP) — стандартные таблицы LuCI; у каждого Действия свой цвет на всех вкладках (`ACTION_LEVELS`: Туннель — синий, Напрямую — зелёный, Блок — красный); строки кнопок, пустые списки, индикатор загрузки и общие предупреждения — из `truba/common.js`.

«Проверить NAT» проверяет только слой Трубы: внешний IP равен IP Трубы, порт сохраняется, отображение одинаково для разных серверов. Запросы уходят через Туннель (`SO_MARK`) сразу ко всем STUN-серверам с одного сокета, повторы — только тем, кто не ответил: худший случай — одно окно 3 × 1,5 с, а не по окну на сервер (rpcd всё это время занят). Серверы — `truba.main.stun` (список `host:port`), по умолчанию два Google и Cloudflare. Итог с временем сохраняется в `/var/run/truba/nat.json`, и «Обзор» показывает его без новой проверки. Контроль Туннеля сам запускает проверку, когда Туннель в порядке, а итог старше момента, с которого он в порядке (то есть после подъёма Туннеля и после перезагрузки); если не ответил ни один сервер — повтор не чаще раза в 10 минут. При выключенном контроле Туннеля — только кнопкой. Полный тест по RFC 5780 запускается с ПК в домашней сети — см. приёмочный тест 1.

### 5.3 rpcd / ubus API (`/usr/share/rpcd/ucode/truba.uc`)

| Метод | Ответ / действие |
|---|---|
| `truba.status` | всё для «Обзора», который опрашивает его раз в 5 с: Туннель, здоровье (с задержкой и окном проверок), счётчики nft, счётчики кэша mosdns, даты и размеры списков, итог последней их проверки и время следующего запуска по строке cron (в местном времени Роутера), итог последней проверки NAT, IP Трубы. Без лишних процессов: работа mosdns и miniupnpd — по `service list` procd через ubus, счётчики кэша — HTTP-запросом к API mosdns из ucode (без `pidof`, `curl` и `grep`) |
| `truba.lists` | версии Наборов правил для вкладки «DNS и списки»: текущие и предыдущие, с контрольными суммами; итог последней проверки |
| `truba.sets` | размеры наборов: подсети geoip по Действиям (считаются при применении — читать огромный набор из ядра дорого) и IP, положенные mosdns по ответам. «Обзор» вызывает раз в минуту |
| `truba.categories` | содержимое `categories.json` + Действия из UCI для текущего Режима |
| `truba.check {target}` | разбор домена или IP по Приоритету. Домен резолвится через Роутер, как это сделало бы устройство, поэтому его IP попадает в набор своей Категории — итог совпадает с тем, что увидит nftables |
| `truba.lists_update` / `truba.lists_rollback` | запуск обновления / отката |
| `truba.nat_test` | STUN-проверка слоя Трубы (не дольше ~5 с); итог сохраняется для `truba.status` |
| `truba.tunnel_test` | Ping Трубы внутри Туннеля пакетами трёх размеров до полного MTU, разом (~5 с): отправлено, получено, средняя задержка по каждому |
| `truba.log` | последние строки журнала |

**Права:** ACL `/usr/share/rpcd/acl.d/luci-app-truba.json` — чтение и запись `uci: truba, network, firewall, upnpd`, вызов `truba.*`.
**Меню:** `/usr/share/luci/menu.d/luci-app-truba.json`.
**Применение:** `/usr/share/ucitrack/luci-app-truba.json` → `{"config":"truba","init":"truba"}`.

### 5.4 Автоматика: «Сохранить и применить» → что включается и выключается

Служба `/etc/init.d/truba` (procd, `START=99`) построена на одной операции `reconcile`: вычислить желаемое состояние из UCI и привести систему к нему. Дорогие шаги (распаковка, перезапуск mosdns) выполняются, только если изменились их входные данные (хеши).

```sh
service_triggers() {
	procd_add_reload_trigger "truba" "network" "firewall"
	procd_add_interface_trigger "interface.*" "awg0" /etc/init.d/truba reload
}
```

| Изменение в интерфейсе | Что делает служба |
|---|---|
| Маршрутизация ВКЛ | Распаковка (если нужно) → таблица `inet truba` → ip rule/table 77 → mosdns + перенаправление dnsmasq → cron → watchdog → UPnP (если включён) |
| Маршрутизация ВЫКЛ | Снимает всё перечисленное, восстанавливает dnsmasq, убирает блок cron. Туннель и входящие через IP Трубы продолжают работать: правило INBOUND и ip rule для ответов остаются в «минимальном» наборе |
| Туннель ВКЛ/ВЫКЛ | `network.awg0.disabled` → netifd поднимает/опускает интерфейс → hotplug → пересчёт table 77 |
| Режим / Действия Категорий | Перегенерация domain_set и наборов `gi_*`, сброс `gs_*`, перезапуск mosdns |
| Политики устройств | Атомарная замена наборов `dev_*` (без перезапуска mosdns) |
| Аварийная блокировка | Пересчёт table 77 |
| Серверы DNS / TTL | Перегенерация mosdns.yaml и перезапуск |
| Время обновления | Перезапись блока cron |
| Контроль туннеля вкл/выкл | procd-инстанс `watchdog` запускается или удаляется |
| UPnP | `upnpd.config.*` и перезапуск miniupnpd |
| Зоны | Перегенерация `lan_if` и `bypass4` |
| Перезапуск fw4 | Ничего: fw4 очищает только свою таблицу `inet fw4` (проверено на ImmortalWrt 25.12), таблица `inet truba` переживает его перезагрузки |

**Матрица двух главных переключателей:**

| | Маршрутизация ВКЛ | Маршрутизация ВЫКЛ |
|---|---|---|
| **Туннель ВКЛ** | Рабочий режим | Всё напрямую; входящие через IP Трубы и пробросы работают |
| **Туннель ВЫКЛ** | Аварийная блокировка (или обход напрямую — по её переключателю) | Обычный роутер |

### 5.5 Где что хранится

| Путь | Что | Переживает sysupgrade |
|---|---|---|
| `/etc/config/truba` | настройки | да (conffile + keep.d) |
| `/etc/truba/lists/`, `/etc/truba/lists/prev/` | `.dat` и `.sha256sum` (≈ 5 МБ всего) | да (keep.d) |
| `/etc/truba/reinstall.sh` | переустановка пакетов после sysupgrade | да (keep.d) |
| `/etc/apk/keys/truba.pem`, `/etc/apk/repositories.d/truba.list` | ключ и адрес фида | да (keep.d) |
| `/var/lib/truba/` | распакованные списки, `categories.json`, хеши | нет (tmpfs, восстанавливается) |
| `/var/etc/truba/` | `mosdns.yaml`, `truba.nft` | нет (генерируется) |
| `/var/run/truba/` | `applied.json`, `health.json` (контроль Туннеля), `nat.json` (итог «Проверки NAT») | нет (оперативная память) |

---

## 6. Часть D — сборка и доставка

### 6.1 Репозиторий (публичный, в вашем аккаунте GitHub)

```
truba/
├─ CONTEXT.md  PLAN.md  docs/adr/
├─ vps/
│  └─ install-vps.sh
├─ router/
│  ├─ truba/                  # OpenWrt-пакет: Makefile, files/etc/init.d/truba, files/usr/share/truba/*.uc,
│  │                          #   files/usr/libexec/truba/*, rpcd-плагин, uci-defaults, keep.d, hotplug
│  └─ luci-app-truba/         # luci.mk: htdocs/luci-static/resources/view/truba/*.js, root/, po/{ru,templates}
├─ tests/
│  ├─ dat/                    # проверки распаковщика на реальных .dat (счётчики из §4.6)
│  └─ vps/                    # shellcheck + прогон install в контейнере/ВМ
└─ .github/workflows/
   ├─ build.yml               # матрица версий ImmortalWrt 25.12.x × mediatek/filogic
   └─ watch-releases.yml      # ежедневно: появилась новая 25.12.x? → build.yml
```

В репозитории никогда не бывает приватных ключей AWG, `router.conf`, IP Трубы и ключа подписи.

### 6.2 `build.yml`

1. Скачать ImmortalWrt SDK `25.12.x` для `mediatek/filogic` с `downloads.immortalwrt.org`. Архив хранится в кэше GitHub Actions по контрольной сумме из `sha256sums`: сервер ImmortalWrt бывает медленным, а архив одной версии не меняется.
2. Решить, собирать ли AmneziaWG. Отпечаток — `router/awg/*` и `AWG_BUILD_REV` в workflow; в опубликованном фиде он лежит в `awg.json` рядом с пакетами. Совпал — `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` берутся из фида этой же версии ImmortalWrt (модуль ядра собран под то же ядро). Полная сборка — при новой версии ImmortalWrt, смене источников AWG или вручную (`full`).
3. Подключить фиды `base` и `luci` (для полной сборки AmneziaWG ещё `packages` и `awg-openwrt` на зафиксированном коммите) и локальный фид `router/`.
4. `make package/<пакет>/compile` для нужных пакетов. Зависимости `truba` и `luci-app-truba` записаны в `EXTRA_DEPENDS`: SDK кладёт их в метаданные, но не компилирует (раньше он собирал mosdns вместе с Go, curl, openssl, luci-base и выбрасывал). CI сверяет зависимости готовых пакетов с Makefile.
5. Подписать индекс apk ключом из `secrets.APK_SIGN_KEY`.
6. Опубликовать в GitHub Pages: `/<версия>/mediatek/filogic/` (`packages.adb` + `.apk` + `awg.json`), публичный ключ — `/keys/truba.pem`. Публикация ждёт тестов, которые идут параллельно со сборкой.

Сборку можно проверить на ветке без публикации: `gh workflow run build.yml --ref <ветка> -f publish=false`.

### 6.3 Установка на Роутер (первый раз)

```sh
wget -O /etc/apk/keys/truba.pem https://<user>.github.io/truba/keys/truba.pem
. /etc/os-release
echo "https://<user>.github.io/truba/${VERSION}/mediatek/filogic/packages.adb" > /etc/apk/repositories.d/truba.list
apk update
apk add kmod-amneziawg amneziawg-tools luci-proto-amneziawg truba luci-app-truba luci-i18n-truba-ru luci-app-upnp
/etc/init.d/network restart
```

netifd загружает обработчики протоколов только при запуске, поэтому после установки `amneziawg-tools` нужен перезапуск сети: без него интерфейс Туннеля остаётся `proto none`, `NO_DEVICE`.

Дальше всё делается в интерфейсе: «Службы → Труба → Туннель → Импорт `.conf`» → «Сохранить и применить» → «Обзор».

### 6.4 После sysupgrade (вариант (a) из ADR 0004)

- Строка в `/etc/rc.local` (стандартный conffile, переживает обновление): `[ -x /etc/truba/reinstall.sh ] && /etc/truba/reinstall.sh &`.
- `reinstall.sh` ничего не делает, если `truba` уже установлен. Иначе:
  1. ждёт интернет;
  2. подставляет `VERSION` из `/etc/os-release` в адрес фида;
  3. `apk update`;
  4. ставит модуль ядра, если он собран под эту версию. Если нет — пишет в журнал, что Туннель не поднимется, и как доставить модуль, когда сборка появится; остальное ставит всё равно (запасного `amneziawg-go` нет: решено не использовать);
  5. ставит `truba` и `luci-app-truba` → служба поднимается с сохранёнными настройками.
- **Правило эксплуатации:** обновлять ImmortalWrt только после того, как `watch-releases.yml` собрал пакеты под новую версию (отметка в README фида).

---

## 7. Этапы работ

| № | Этап | Результат / критерий выхода |
|---|---|---|
| 0 | Репозиторий, CI-каркас, ключ подписи | `build.yml` собирает пустые пакеты `truba` под 25.12.x |
| 1 | `install-vps.sh` | С тестового клиента AWG: внешний IP = IP Трубы; `nc` на любой порт IP Трубы доходит до клиента; SSH только на новом порту; откат через 120 с работает |
| 2 | AmneziaWG под ImmortalWrt | Пакеты из фида ставятся на NC-1812, Туннель поднят через luci-proto-amneziawg, handshake есть |
| 3 | Каркас данных без интерфейса | Зона `truba`, fullcone, таблица `inet truba` с geoip, ip rule/table 77, ct mark INBOUND (скриптом вручную) → приёмочные тесты 1 и 2 |
| 4 | Распаковщик ucode | Тесты §4.6 зелёные; распаковка `geosite.dat` на NC-1812 укладывается в разумное время (ориентир < 10 с) |
| 5 | mosdns-классификатор | Генерация `mosdns.yaml`, dnsmasq → mosdns, nftset, Блок через NXDOMAIN, AAAA → пусто, перехват DNS → тесты 3 и 4 |
| 6 | Служба `truba` | `reconcile`, обновление списков, откат, watchdog, Аварийная блокировка, cron → тесты 5 и 6 |
| 7 | `luci-app-truba` | 6 вкладок, rpcd API, ACL, меню, переводы RU/EN; каждое изменение применяется по «Сохранить и применить» без SSH |
| 8 | Жизненный цикл | `reinstall.sh` проверен реальным sysupgrade, `watch-releases.yml` |
| 9 | Приёмка | Все 7 тестов §8 на реальной сети, включая совместимость с roamd; затем отдельно — опыт с аппаратным ускорением |

---

## 8. Приёмочные тесты

| № | Что | Как проверить | Ожидание |
|---|---|---|---|
| 1 | Full cone | ПК в `lan` с Политикой «Всё в туннель»; NatTypeTester (RFC 5780) с двумя STUN-серверами | Mapping и Filtering: *Endpoint Independent*; публичный IP = IP Трубы |
| 2 | Входящие | Проброс `truba:8080 → ПК:8080`; с мобильного интернета РФ `curl http://<VPS_IP>:8080`; `tcpdump -i awg0` на Роутере | Ответ приходит; ответные пакеты уходят в `awg0`, а не в `wan` |
| 3 | Маршрутизация | «Проверить домен/IP» и `traceroute` для домена `category-ru`, домена «По режиму», IP из `geoip:ru`, записи `full:` (её поддомен **не** должен совпасть), записи `regexp:` из `netflix`, домена `category-ads` | Действия и Приоритет совпадают с ожидаемыми; первый хоп — провайдер или `10.77.77.1` соответственно; Блок → NXDOMAIN |
| 4 | Утечки и IPv6 | ipleak.net, dnsleaktest.com, test-ipv6.com с устройства; на Роутере `ping -6 -c3 ff02::1%br-lan` | IP = IP Трубы; DNS — Cloudflare/Google; IPv6-интернета нет; при этом узлы roamd отвечают по link-local |
| 5 | Аварийная блокировка | На Трубе `systemctl stop awg-quick@awg0` | Через ≤ 2 мин зарубежные сайты недоступны, российские работают; при выключенном переключателе зарубежные идут через провайдера; после `start` всё восстанавливается само |
| 6 | Обновление списков | Долгая загрузка или SSH-сессия через Туннель; «Обновить сейчас» и «Откатить» | Сессия не рвётся; размеры наборов в `nft list set` меняются; версии в интерфейсе обновляются |
| 7 | Совместимость с roamd | Интерфейс roamd; клиент с Политикой устройства подключён к узлу roamd → «Проверить домен/IP» и счётчики; затем клиент переходит между узлами во время загрузки через Туннель | roamd видит все узлы; Политика срабатывает по MAC клиента за узлом; переход между узлами не рвёт соединение |

---

## 9. Риски и ограничения

| Риск | Последствие | Что делаем |
|---|---|---|
| Версии AWG на Трубе и Роутере разошлись | Туннель не поднимается | Тег сборки Роутера = версия из `/etc/truba/pipe.env`; `install-vps.sh` предупреждает при обновлении PPA |
| ImmortalWrt обновили раньше, чем CI собрал модуль | Туннеля нет до сборки | Правило эксплуатации §6.4; `watch-releases.yml` собирает новую версию в течение суток |
| Браузеры с собственным DoH | Доменные Категории не срабатывают для этих устройств | В «Всё в туннель» безопасно (трафик уходит в Туннель, `geoip:ru` всё равно работает). В «Выборочном» такие домены идут напрямую — ограничение ADR 0002 |
| Общие CDN-адреса | Домены с разными Действиями на одном IP | Туннель побеждает Напрямую (ADR 0002) |
| Категории ограничены 61 тегом | В «Выборочном» нет Telegram/Meta/Discord/X/OpenAI | Осознанно: новых Категорий не добавляем; основной Режим — «Всё в туннель» |
| В README geosite указан тег `ru`, а в файле его нет | Ошибка при ручной настройке | Интерфейс показывает только реальные теги из файла (`category-ru`) |
| Весь входящий трафик идёт на IP Трубы | Жалобы на абузы хостеру (торренты, открытые сервисы) | Учитывать при выборе хостера; UPnP по умолчанию выключен |
| SNAT на Трубе совпал с собственным соединением VPS | Отдельный порт не сохранится | Редко; при необходимости сузить `ip_local_port_range` на VPS |
| `raw.githubusercontent.com` медленный или заблокирован | Списки не обновились | Загрузка через Туннель + зеркало jsDelivr; старые списки продолжают работать |
| Новая ревизия NC-1812 с NAND FM25G02B ([openwrt#23855](https://github.com/openwrt/openwrt/issues/23855)) | Возможен bootloop при перепрошивке | Касается только перепрошивки, не установки пакетов; перед sysupgrade проверить ревизию |
| fullcone в ImmortalWrt включается глобально | Fullcone действует и на `wan` | Ожидаемо и безвредно |
| Провайдер включит IPv6 | Устройства получат «белые» IPv6, трафик мог бы пойти мимо Туннеля | Правило `lan → wan` IPv6 REJECT и фильтр AAAA уже стоят; полная поддержка IPv6 — отдельное расширение (ADR 0005) |
| roamd скачивает пакеты для узлов с GitHub напрямую | Подключение нового узла может не пройти, если GitHub тормозит | Осознанно оставлено как есть: операция разовая, у roamd есть запасные пути (кэш контроллера, фиды узла) |
| Кто-то выключит IPv6 на `br-lan` (например, `network.lan.ipv6='0'`) | roamd перестанет находить узлы | Труба IPv6 домашней сети не меняет; в README — предупреждение не выключать IPv6 на `br-lan` |
| DPI начнёт узнавать Туннель по размерам пакетов | Туннель блокируется или режется | В запасе RandomTrailers: `install-vps.sh random-trailers on` и флаг Random Trailers у `awg0` на Роутере. Цена — трафик на мелких пакетах, поэтому по умолчанию выключен |
| Включён OpenClash в режиме fake-ip | «Проверить NAT» получает от DNS Роутера адреса `198.18.0.0/15` вместо STUN-серверов и показывает ошибку, хотя Full cone работает | Известно, не исправлено: проверку нужно резолвить мимо DNS Роутера. Пока — проверять при выключенном OpenClash |

---

## 10. Решения, принятые по умолчанию (на ваш просмотр)

Эти параметры не обсуждались отдельно. Я выбрал их как разумные значения по умолчанию, любое можно поменять:

1. Подсеть Туннеля `10.77.77.0/30`, таблица `77`, метки `0x00010000` / `0x00020000` / `0x00040000` под маской `0x00ff0000`. Труба меняет только этот байт meta mark и ct mark и записывает решение в ct mark последней в postrouting: так она уживается с qosmate и другими, кто пользуется ct mark. Для своих сокетов Роутера байт Трубы возвращается из метки сокета после чужих цепочек output (OpenClash).
2. Блок для geosite — на уровне DNS (NXDOMAIN), для geoip — отбрасывание по IP.
3. «Узость» Категории: вложенность, а если её нет — меньшее число записей.
4. Наборы `gs_*` без таймаута, сбрасываются при изменении правил или geosite; TTL классифицированных ответов ≤ 300 с.
5. Перехват DNS (порт 53 из `lan`) включён, переключатель — на вкладке «DNS и списки».
6. Политики устройств действуют на маршрутизацию, DNS общий.
7. `PersistentKeepalive = 25`, MTU по сети VPS: её MTU − 87, не больше 1380.
8. Время обновления хранится в UTC и переводится в часовой пояс Роутера.
9. «Проверить NAT» в интерфейсе — только слой Трубы; полный тест RFC 5780 — с ПК.
10. Пакет `truba` при установке сам включает fullcone, выключает аппаратное ускорение (программное не трогает), создаёт зону `truba`, добавляет правило `lan → wan` IPv6 REJECT и выключает стоковый init mosdns. IPv6-настройки домашней сети не трогает. Всё откатывается при удалении.
11. Теги показываются в нижнем регистре (в файле — верхний; v2ray сравнивает без учёта регистра).
12. SSH и порт Туннеля — случайные порты 40000–59999; правила на VPS применяются с автооткатом через 120 с.
