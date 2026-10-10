# Архитектура «Трубы»

Как устроена версия 1.1: узлы и потоки трафика, Труба, Роутер, интерфейс и автоматика, сборка и доставка, риски, а в конце — принципы, которые должны пережить любые будущие изменения, и точки расширения. Термины — в [CONTEXT.md](../CONTEXT.md), причины ключевых решений — в [docs/adr/](adr/README.md), что осталось сделать и приёмочные тесты — в [docs/roadmap.md](roadmap.md). Ссылки вида «§4.4» в коде ведут сюда.

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
              │  DNS Роутера: 10.77.77.1:53 ──► unbound ─TLS─► 1.1.1.1  │
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
              └─────────────┬───────────────────────────────────────────┘
                            │  IPv4: Маршрутизация Трубы
                            │  IPv6: только внутри сети (link-local/ULA), в интернет — REJECT
                   Устройства домашней сети · mesh-узлы (WDS, MAC клиентов сохраняются)
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
| Метка INBOUND | `0x00040000`. Труба меняет в meta mark и ct mark только байт `0x00ff0000`: в остальных битах хранят своё другие службы (ADR 0011) | служба `truba` |
| Метка своих сокетов Роутера | TUNNEL через `SO_MARK` (mosdns, «Проверить NAT»); после чужих цепочек output её байт возвращается из метки сокета (§4.4, цепочка `output`) | служба `truba` |
| Порт mosdns | `127.0.0.1:5335` | `/etc/config/truba` |

---

## 2. Потоки трафика

### 2.1 Исходящий, Действие «Туннель»

```
ПК 192.168.1.10:51000 → youtube.com
  1. DNS: dnsmasq → mosdns. Домен в Категории с Действием «Туннель»
     (или «По режиму» в Режиме «Всё в туннель») → через Туннель (so_mark TUNNEL)
     сразу к unbound на Трубе (10.77.77.1) и к DoH 1.1.1.1, ответ — первый;
     IP ответа → набор gs_tunnel4 (если Категория явная).
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
     каждом пакете: чужая цепочка, которая перезаписывает ct mark целиком, иначе стёрла
     бы метку INBOUND уже на первом пакете (ADR 0011).
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
| `install` | Полная установка. При повторном запуске ключи и порты берутся из `/etc/truba/pipe.env` и не меняются; Туннель, unbound, fail2ban и sshd перезапускаются, только если их конфиг изменился |
| `show-config` | Печатает `.conf` для импорта в Роутер |
| `rotate-keys` | Новые ключи и параметры AWG под версию модуля на сейчас (в том числе переход на AWG 3.1); после этого конфиг Роутера нужно импортировать заново |
| `random-trailers on\|off` | RandomTrailers на Трубе и в `router.conf` (AWG 3.1); на Роутере переключить так же сразу после |
| `status` | Версия AmneziaWG (модуль и сборка PPA), Туннель, handshake, MTU, очередь WAN с дочерними, правила nft, счётчики conntrack, запросы и SERVFAIL у unbound; есть ли модуль amneziawg у ядра, которое загрузится после перезагрузки; какие строки sysctl при загрузке перебьют настройки Трубы |
| `uninstall [--purge]` | Снимает правила, останавливает Туннель, возвращает SSH к настройкам до установки (обычно порт 22); `--purge` удаляет и ключи, параметры и `router.conf`. Пакеты amneziawg и unbound остаются |

### 3.2 Шаги `install`

1. **Предусловия** — проверяются до любых изменений, иначе выход с объяснением:
   - запуск от root (это проверяют все команды);
   - Ubuntu 24.04;
   - VPS — полноценная ВМ, а не контейнер (`systemd-detect-virt --container`): KVM, VMware, Xen, Hyper-V подходят, OpenVZ/LXC — нет;
   - в `/root/.ssh/authorized_keys` есть ключ: после переноса SSH вход по паролю закрывается;
   - внешний IP (`curl -4 https://api.ipify.org`; если curl нет, он ставится) — среди IPv4 интерфейса маршрута по умолчанию (`ip -4 route show default`): значит, Труба не за NAT провайдера;
   - порты SSH и Туннеля выбраны и не совпадают.
2. **Пакеты.** Сначала подключается `ppa:amnezia/ppa` (`add-apt-repository -n`), затем один `apt-get update`. Ставятся `nftables fail2ban unattended-upgrades curl unbound`, заголовки работающего ядра и метапакеты заголовков под метапакеты ядра, что стоят в системе (`linux-image-generic` → `linux-headers-generic` и т.п.). Метапакет нужен, чтобы ядро, которое поставит unattended-upgrades, пришло вместе со своими заголовками и DKMS собрал под него модуль.
   - В архиве Ubuntu лежат заголовки не всех сборок ядра. Если у работающего ядра их там нет (образ на промежуточной сборке), установка останавливается до изменений и просит обновить ядро (`apt-get full-upgrade`), перезагрузиться и запустить `install` снова.
   - Заголовки работающего ядра ставятся без пометки «вручную»: их держит метапакет, а когда VPS перейдёт на новое ядро, их уберёт `apt autoremove`.
   - Исходники ядра (deb-src) не нужны: DKMS собирает amneziawg по одним заголовкам.
   - Свежий VPS первые минуты сам держит apt (cloud-init, автообновления). Скрипт ждёт до 10 минут: `DPkg::Lock::Timeout` для установки, повтор `apt-get update` при занятых списках.
   - ufw выключается: он мешает нашим правилам nftables.
3. **AmneziaWG:** `apt install amneziawg` (DKMS + tools), `modprobe amneziawg`. Версия протокола определяется пробным интерфейсом (п. 6); если интерфейс AmneziaWG не создаётся (модуль не собрался), `install` и `rotate-keys` останавливаются, а не генерируют параметры AWG 1.x. `status` показывает версию модуля (`/sys/module/amneziawg/version`) и сборку PPA (дата и коммит). Модуль для Роутера CI собирает не по ней, а из `router/awg/SOURCES` (закреплённый коммит awg-openwrt): VPS он не видит. Версии протокола у сторон сверяет владелец — по `status` и `SOURCES`.
4. **SSH на высокий порт.** В Ubuntu 24.04 SSH запускается через сокет-активацию, поэтому нужно:
   - `/etc/ssh/sshd_config.d/10-truba.conf`: `Port <SSH_PORT>`, `PasswordAuthentication no`, `PermitRootLogin prohibit-password`;
   - `systemctl daemon-reload && systemctl restart ssh.socket` — только если сокет включён; иначе перезапускается служба `ssh`.
   - На время проверки нового порта остаются прежние: при первой установке — те, что sshd слушает сейчас (`sshd -T`, обычно 22), при смене порта — прежний порт Трубы. Если sshd уже слушает только новый порт, проверка не нужна.
5. **sysctl** `/etc/sysctl.d/90-truba.conf`:
   ```
   net.ipv4.ip_forward = 1
   net.core.default_qdisc = fq_codel
   net.ipv4.tcp_congestion_control = bbr
   net.netfilter.nf_conntrack_max = 262144
   net.netfilter.nf_conntrack_buckets = 262144
   net.ipv6.conf.all.forwarding = 0
   ```
   И `/etc/modules-load.d/truba.conf` с `nf_conntrack`. Без него при загрузке VPS `systemd-sysctl` пропускает ключи `nf_conntrack_*`: модуля ещё нет. Тогда остаётся ядерный предел (7680 на 1 ГБ), и при полной таблице новые соединения отбрасываются. Корзин хэш-таблицы столько же, сколько записей, как ядро само ставит на машинах от 4 ГБ: на 1 ГБ их по умолчанию около 7680, и у полной таблицы поиск идёт по цепочкам в десятки записей. Цена — 2 МБ памяти.

   При загрузке `systemd-sysctl` применяет файлы по имени, и более поздний перебивает ключ. Обычно это `/etc/sysctl.conf` (`99-sysctl.conf`), куда гайды по BBR пишут `net.core.default_qdisc = fq`. Такие строки `install` и `status` показывают с предупреждением: убрать их должен владелец.

   Очередь — `fq_codel`, а не `fq`, и у WAN она заменяется сразу: `default_qdisc` действует только на новые очереди. У карты с несколькими очередями корень — `mq` с очередью на каждую, и скрипт ставит новый `mq`, который берёт их по `default_qdisc`; у карты с одной очередью корень — `fq_codel`. У `fq` предел — 100 пакетов на поток, а весь Туннель для неё один поток: на пиках она отбрасывает пачки пакетов, и скачивание через Туннель встаёт на несколько секунд. BBR с ядра 4.13 сам задаёт темп отправки и без `fq`.

   **MTU Туннеля** считается от MTU интерфейса WAN: пакет Туннеля с обёрткой (IPv4 20 + UDP 8 + заголовок и тег AWG 32 + `S4` до 27 = 87 байт) должен помещаться в сеть VPS целиком, иначе почти каждый пакет режется на два фрагмента. При обычной сети 1500 остаётся 1380, при 1400 — 1313.
6. **Ключи и параметры AWG.**
   - Генерируются пары ключей Трубы и Роутера и PSK.
   - Параметры маскировки (`Jc/Jmin/Jmax`, `S1–S4`, `H1–H4`, `I1`) генерируются по правилам Amnezia для установленной версии: например, `Jmax ≤ 1280`, `S1 + 56 ≠ S2`, диапазоны `H` не пересекаются. `I1` — пакет-приманка в форме DNS-ответа; `I2–I5` не задаются.
   - Версия протокола определяется пробным интерфейсом: 1 — классический AWG, 2 — AWG 2.0 (`S3/S4`, диапазоны `H`, `I1`), 3 — AWG 3.1. Для 3.1 добавляются:
     - `HeaderProtectionKey` — свой ключ (`awg genkey`), одинаковый у сторон. Шифрует индекс получателя и счётчик, по которым иначе узнаётся WireGuard: у всех пакетов сессии одинаковый индекс, а счётчик растёт по порядку. Защите нужны `S1–S4 ≥ 12`, поэтому `S3` и `S4` генерируются от 12.
     - `DisableCookies = on` у обеих сторон. Ответ cookie шлётся только под нагрузкой и узнаваем по размеру; с одним пиром он не нужен.
     - `RandomTrailers` — в запасе, по умолчанию выключен. Добивает пакеты до случайной длины против DPI по размерам, но мелкие пакеты (ACK, звонки, игры) растут в среднем на 600–700 байт. Должен совпадать у сторон: пока он разный, рукопожатие не проходит. Включается `install-vps.sh random-trailers on` на Трубе и флагом Random Trailers у `awg0` на Роутере.
   - Повторный `install` параметры не меняет, даже если модуль обновился до 3.1: иначе старый конфиг Роутера перестал бы подключаться. Переход на 3.1 — через `rotate-keys` и новый импорт `router.conf`.
7. **`/etc/amnezia/amneziawg/awg0.conf`**, unit `awg-quick@awg0`. Повторный `install` перезапускает Туннель, только если конфиг изменился или Туннель не работает: после перезапуска Труба не знает адреса Роутера, и Туннель стоит, пока Роутер не сделает новое рукопожатие (до ~15 с). Если изменился `router.conf` (адрес, порт или MTU), `install` предупреждает, что его нужно импортировать в Роутер заново.
   ```ini
   [Interface]
   PrivateKey = <vps_priv>
   Address    = 10.77.77.1/30
   ListenPort = <AWG_PORT>
   MTU        = <MTU сети VPS − 87, не больше 1380>
   Jc = … ; Jmin = … ; Jmax = … ; S1..S4 = … ; H1..H4 = … ; I1 = …
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
   define WAN      = "eth0"          # интерфейс маршрута по умолчанию (ip -4 route show default)
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
       meta l4proto ipv6-icmp accept                  # обнаружение соседей и RA для IPv6 самого VPS
       iifname $WAN tcp dport $SSH_PORT accept
       iifname $WAN udp dport $AWG_PORT accept
       iifname $WAN udp sport 67 udp dport 68 accept     # DHCP-клиент самого VPS
       iifname $WAN udp sport 547 udp dport 546 accept   # DHCPv6: ответ на запрос к multicast conntrack не узнаёт
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
   Применение безопасное: скрипт загружает правила и ждёт 120 с, пока пользователь подтвердит вход по SSH на новом порту. Без подтверждения правила и SSH откатываются. Подтверждение требует терминала: без него `install` сразу выходит с ошибкой (или нужен `--no-confirm`).
9. **DNS для Роутера (ADR 0013):** unbound слушает только `10.77.77.1:53` (`ip-freebind`: стартует раньше `awg0`) и отвечает только `10.77.77.2`. Запросы он пересылает по TLS в Cloudflare и Google, с проверкой имени сервера; DNSSEC проверяют они, своей проверки нет. Конфиг — `/etc/unbound/unbound.conf.d/truba.conf`, пишется до установки пакета, чтобы служба сразу стартовала с ним; повторный `install` перезапускает unbound, только если конфиг изменился (перезапуск сбрасывает кэш). `unbound-resolvconf` выключается: сам VPS резолвит как прежде. Новых правил nftables не нужно: вход из `awg0` от Роутера уже открыт, а с WAN порт 53 уходит на Роутер (DNAT).
10. **fail2ban:** jail `sshd` на `<SSH_PORT>`, `banaction = nftables-multiport`.
11. **unattended-upgrades:** включён. DKMS сам пересобирает модуль AWG при обновлении ядра Ubuntu; `status` предупреждает, если у ядра, которое загрузится следующим, модуля нет.
12. **Итог:** `/root/truba/router.conf` — стандартный AWG-`.conf` для Роутера (`Address = 10.77.77.2/30`, `Endpoint = <VPS_IP>:<AWG_PORT>`, `AllowedIPs = 0.0.0.0/0`, `PersistentKeepalive = 25`, все параметры маскировки).

Все файлы скрипт пишет целиком через временный файл рядом и с явными правами: ключи (`pipe.env`, `awg0.conf`, `router.conf`) — 600 в каталогах 700, остальное — 644. Если команда упала без своего сообщения, скрипт печатает строку и команду (`trap ERR`).

---

## 4. Часть B — Роутер: каркас данных

### 4.1 Пакеты

| Пакет | Откуда | Назначение |
|---|---|---|
| `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` | наш фид (сборка из `amnezia-vpn/amneziawg-openwrt` того же тега, что на VPS) | Туннель как стандартный интерфейс netifd |
| `truba` | наш фид | ядро: init, ucode-модули, ubus-API (rpcd-плагин, ADR 0008), контроль Туннеля, обновление списков, история скорости |
| `luci-app-truba` | наш фид | интерфейс (6 вкладок, RU/EN) |
| `mosdns` (5.3.3), `ca-bundle`, `curl` | фид ImmortalWrt | DNS-классификатор, скачивание списков |
| `kmod-nft-socket` | фид ImmortalWrt (в стоковом образе его нет) | `socket mark` в цепочке `output` (§4.4). Без модуля Труба работает, но правила `socket mark` нет — в syslog предупреждение |
| `luci-app-upnp` (`miniupnpd-nftables`) | фид ImmortalWrt | UPnP/NAT-PMP на Туннеле (по переключателю) |

### 4.2 Что пакет `truba` настраивает при установке (uci-defaults, откатывается при удалении)

```sh
# Full cone; аппаратное ускорение выключено — оно обходит netfilter целиком.
# Программное ускорение не трогаем (в стоковой ImmortalWrt оно включено): при нём пакеты
# ускоренных соединений идут мимо счётчиков Трубы и мимо шейперов трафика — «Обзор» предупреждает.
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

# IPv6 домашней сети не трогаем (link-local нужен mesh-узлам, ADR 0005): ra/dhcpv6/ip6assign/ULA остаются как есть.
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

Правило 1000 сравнивает только байт Трубы (маска `0x00ff0000`), поэтому чужие биты в метке ему не мешают. Чужие правила с меньшим приоритетом и точной меткой (например, `999: fwmark 0x162 lookup 354`) после возврата байта Трубы уже не срабатывают — см. цепочку `output` в §4.4 и ADR 0011.

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
  set gs_tunnel4 { type ipv4_addr; flags timeout; timeout 1d; }          # наполняет mosdns; срок — ADR 0007
  set gs_direct4 { type ipv4_addr; flags timeout; timeout 1d; }          # наполняет mosdns
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

    meta nfproto != ipv4 return                                         # IPv6 (link-local, ULA) не трогаем

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
- **Только IPv4.** Первое правило пропускает весь IPv6 без изменений: на нём mesh-узлы находят друг друга (`ff02::1` на `br-lan`). Без этого IPv6-пакеты попадали бы под действие Режима по умолчанию, и счётчики врали бы. Перехват DNS тоже только для IPv4 (ADR 0005).
- **Блок для geosite** выполняется на уровне DNS (mosdns отвечает NXDOMAIN), а не по IP. Блокировка по IP задела бы общие CDN.
- **Блок для geoip** — отбрасывание пакетов по IP.
- **Наборы `gi_*`** — объединение Категорий geoip с одинаковым Действием. Обычно в Режиме «Всё в туннель» `ru` и `private` → `gi_direct4`.
- **Счётчики двух видов.** `c_tunnel`, `c_direct`, `c_inbound` считают новые соединения: классификацию проходит только первый пакет соединения, остальные идут по ct mark мимо неё. `c_block` — отброшенные пакеты. Объём трафика устройств по Действиям и направлениям считает цепочка `stats` (`c_*_down` — к устройствам, `c_*_up` — от них). Значения переносятся в новую таблицу при каждом применении, отсчёт — с запуска службы (`applied.counters_since`). При программном ускорении пакеты ускоренных соединений идут мимо `stats`, и учёт неполный.
- **Липкость через ct mark:** изменение наборов (обновление списков, новые ответы DNS) не переводит уже открытые соединения на другой путь. Отсюда приёмочный тест 6 — «без обрыва» ([roadmap](roadmap.md#приёмочные-тесты)).
- **Наборы `gs_*` — со сроком** (`dns.set_timeout`, по умолчанию сутки, ADR 0007). Они полностью сбрасываются при изменении Действий или Режима и при обновлении geosite, а между сбросами каждый IP действует не дольше срока: адрес CDN, которым домен Категории больше не пользуется, перестаёт направлять трафик. Повторный ответ срок не продлевает (mosdns добавляет элемент без срока), при переносе в новую таблицу элемент сохраняет оставшийся срок. Ответы классифицированных доменов mosdns отдаёт с TTL не больше 300 с, чтобы после сброса или истечения срока устройства быстро перерезолвили адреса.
- **Цепочка `output` — для своих сокетов Роутера (ADR 0011).** Чужая route-цепочка output может перезаписать meta mark целиком: прозрачный прокси для трафика самого Роутера ставит, например, `0x162` почти всему исходящему, и его правило 999 уводит пакеты в свою таблицу. Тогда «Проверить NAT» показала бы IP прокси вместо IP Трубы, а запросы mosdns к DNS-серверам «Туннеля» ушли бы мимо Туннеля. Цепочка Трубы идёт после mangle и берёт решение из метки сокета (`socket mark`), а не из meta mark, поэтому ей неважно, кто и в каком порядке переписал метку до неё. Она возвращает только байт Трубы (`0x162` → `0x10162`), а route-цепочка при смене метки маршрутизирует пакет заново: правило 1000 с маской срабатывает, а чужое правило с точной меткой — уже нет. Трафик без метки Туннеля цепочка не трогает.
- **Пакетам к IP Трубы — только «Напрямую»** (байт Трубы `0x02`), и это первое правило цепочки `output`. Это сам Туннель — внешние зашифрованные пакеты AmneziaWG. Они проходят output ещё раз и несут сокет исходного пакета с его меткой «Туннель»: без этого правила `socket mark` заворачивал бы Туннель в `awg0` — петля, `tx_dropped`. А чужая цепочка, которая метит всё подряд, увела бы Туннель в свою таблицу. С меткой «Напрямую» чужое правило с точной меткой уже не срабатывает, и IP Трубы не нужно добавлять ни в чьи исключения. Правило не требует `nft_socket`; без известного IP Трубы цепочки нет. На veth петля не воспроизводится, поэтому Туннель в тестах — настоящий WireGuard.
- **Чего метки не лечат.** Чужие правила с маской, которая включает байт Трубы, и перенаправление DNAT в nat output (прокси в режиме redirect вместо TPROXY).

### 4.5 DNS: dnsmasq → mosdns

**dnsmasq** — через UCI, служба сохраняет исходные значения и восстанавливает их при выключении:
- `noresolv=1`;
- `server=127.0.0.1#5335`;
- `cachesize=0`;
- фильтр AAAA выполняет mosdns, и только для интернет-доменов: имена из домашней сети (DHCP-хосты, `.lan`), включая их AAAA, dnsmasq отвечает сам, не пересылая в mosdns.

**mosdns** — конфиг `/var/etc/truba/mosdns.yaml` генерируется из UCI. Эскиз под Режим «Всё в туннель» (YAML для читаемости; настоящий конфиг — JSON, см. ниже):

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

  # Серверы одного пути: свой forward на каждый, запрос сразу ко всем, ответ — первый годный.
  # idle_timeout 180: соединение живёт в паузах до 3 мин (сам mosdns закрыл бы DoH через 30 с).
  - { tag: up_tunnel_0, type: forward, args: { upstreams: [ { addr: "udp://10.77.77.1", idle_timeout: 180, so_mark: 0x00010000 } ] } }   # unbound на Трубе (ADR 0013)
  - { tag: up_tunnel_0_ok, type: sequence, args: [ { exec: $up_tunnel_0 }, { matches: [ "!rcode 0 3" ], exec: drop_resp } ] }   # SERVFAIL, REFUSED… — ждать другой сервер
  - { tag: up_tunnel_1, type: forward, args: { upstreams: [ { addr: "https://1.1.1.1/dns-query", idle_timeout: 180, so_mark: 0x00010000 } ] } }   # запасной
  - { tag: up_tunnel_1_ok, type: sequence, args: [ { exec: $up_tunnel_1 }, { matches: [ "!rcode 0 3" ], exec: drop_resp } ] }
  - { tag: up_tunnel, type: fallback, args: { primary: up_tunnel_0_ok, secondary: up_tunnel_1_ok, threshold: 1, always_standby: true } }
  # up_direct — так же из tls+pipeline://common.dot.dns.yandex.net с dial_addr 77.88.8.8 и 77.88.8.1;
  # один сервер — просто forward.

  # Ленивый кэш: истёкшая запись отдаётся сразу с TTL 5 с, а свежий ответ запрашивается в фоне у тех же
  # серверов. Повторные запросы не ждут DNS. Дамп в /var (tmpfs): переживает перезапуск mosdns, но не
  # перезагрузку; флеш не изнашивается. Имя — по поколению настроек DNS (см. ниже «Кэш»).
  - { tag: cache, type: cache, args: { size: 65536, lazy_cache_ttl: 86400, dump_file: /var/lib/truba/mosdns-cache-<поколение>.dump } }

  # Кэш — в своей цепочке fetch_* у каждого пути: ответ сохраняется, когда она завершилась, — с TTL сервера,
  # но не дольше часа. TTL для устройств и nftset — после неё, во flow_*.
  - tag: fetch_tunnel
    type: sequence
    args:
      - { exec: $cache }
      - { matches: [ "!has_resp" ], exec: $up_tunnel }
      - { exec: ttl 0-3600 }
  # fetch_direct, fetch_router — так же с $up_direct; fetch_default — с сервером Режима ($up_tunnel в «Всё в туннель»)

  # nftset в mosdns 5 — только встроенное действие «семейство,таблица,набор,тип,маска», не тип плагина.
  # Ответ из кэша тоже проходит через nftset — до ответа устройству: после пересборки наборов IP возвращаются сами.
  - tag: flow_tunnel
    type: sequence
    args:
      - { exec: $fetch_tunnel }
      - { exec: ttl 0-300 }                # устройствам — не больше ttl_max
      - { exec: "nftset inet,truba,gs_tunnel4,ipv4_addr,32" }
  - tag: flow_direct
    type: sequence
    args:
      - { exec: $fetch_direct }
      - { exec: ttl 0-300 }
      - { exec: "nftset inet,truba,gs_direct4,ipv4_addr,32" }
  - { tag: flow_router, type: sequence, args: [ { exec: $fetch_router } ] }     # NTP, зеркала списков, endpoint Трубы — Напрямую, без nftset
  - { tag: flow_default, type: sequence, args: [ { exec: $fetch_default } ] }   # По Режиму, без nftset

  - tag: main
    type: sequence
    args:
      - { matches: [ qtype 28 ], exec: reject 0 }        # AAAA → пустой ответ: Маршрутизация только IPv4, IPv6-интернет закрыт (ADR 0005)
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

Настоящий конфиг генерирует [render.uc](../router/truba/files/usr/share/ucode/truba/render.uc) в виде JSON (подмножество YAML). Эталон — `tests/golden/mosdns.json`, запуск проверяется на mosdns 5.3.3 из фида в тестах Роутера.

**Серверы DNS.** Каждый запрос, которого нет в кэше, уходит сразу ко всем серверам своего пути, и в ответ идёт первый годный: NOERROR или NXDOMAIN. Поэтому зависший или оборвавший соединение сервер не задерживает ответ. Штатный `concurrent` плагина forward для этого не годится: он выбирает сервер для каждого параллельного запроса случайно и с повторами, и при двух серверах половина запросов ушла бы дважды к одному. Простаивающее соединение mosdns держит 3 минуты (`idle_timeout`). Его собственный срок для DoH — 30 с, хотя серверы держат соединение дольше: Google — 4 мин, Cloudflare — 6,5 мин. Без этого первый промах кэша после паузы ждал бы новых TCP и TLS: через Туннель это 100–170 мс. Если сервер закрывает соединение раньше (Яндекс — через 30 с), mosdns просто открывает новое. Первый сервер «Туннеля» по умолчанию — unbound на самой Трубе (`udp://10.77.77.1`, ADR 0013). Ему Роутер шлёт обычный UDP внутри Туннеля, а TLS до Cloudflare и Google держит VPS, рядом с ними. Поэтому промах через Туннель стоит одну поездку через Туннель всегда, даже после долгой паузы. DoH 1.1.1.1 — запасной: если сервера на Трубе нет, его порт сразу отвечает «закрыт». DoT «Напрямую» идёт с pipelining (`tls+pipeline://`): несколько запросов, пришедших разом, идут по одному соединению, а не открывают TLS на каждый. Яндекс, Cloudflare и Google отвечают на такие запросы в любом порядке, как требует RFC 7766. Без pipelining mosdns не применяет к DoT и `idle_timeout`.

**Кэш.** Ответ хранится свежим столько, сколько разрешил сервер, но не дольше часа. Устройствам доменов из Категорий он уходит с TTL не больше `ttl_max` (300 с): они часто перепроверяют адрес, и после сброса наборов IP быстро возвращаются (ADR 0007). Запись в кэше при этом не устаревает каждые 5 минут, и mosdns не обновляет её в фоне так часто. На Роутере владельца у четверти записей «Напрямую» TTL сервера больше 300 с (медиана — 9 минут). Граница проходит по цепочке `fetch_*`: кэш сохраняет ответ, когда завершилась часть цепочки после него. Поэтому `ttl` для устройств стоит после неё, а не рядом с сервером. Фоновое обновление ленивого кэша идёт только в `fetch_*`, без nftset: новые IP попадут в набор со следующим ответом устройству, тоже до него.

Час — предел, потому что дольше устаревший ответ живёт заметно дольше `ttl_max`. Во-первых, после обновления списков домен, перешедший в другую Категорию, ещё получает ответ прежнего сервера; маршрут при этом сразу идёт по новой Категории. Во-вторых, mosdns 5.3.3 не пишет в дамп время сохранения записи, и после перезапуска ответы из дампа уходят с TTL 1, пока запись не устареет: устройства в это время переспрашивают раз в секунду. Ответ Блока (`reject 3`) в кэш не попадает: он отдаётся раньше.

Имя дампа зависит от поколения настроек, которые решают, у каких серверов спрошен ответ: это серверы путей, Режим и Действия Категорий (`R.cache_dump`, FNV-1a). После их смены mosdns начинает с пустым кэшем, а не отдаёт ответы прежних серверов. Смена `ttl_max` или размера кэша и обновление списков кэш сохраняют. Дампы прежних поколений служба удаляет при применении.

**Порядок проверки Категорий («узость»).** Категории сортируются по числу записей: вложенная всегда меньше объемлющей, поэтому вложенность соблюдается сама. При равенстве — Блок → Туннель → Напрямую. Вложенность (A ⊂ B, если все записи A есть в B) распаковщик вычисляет для колонки «Вложена в» в интерфейсе.

**Служебные хосты Роутера резолвятся Напрямую.** Это NTP-серверы из `system`, хосты зеркал списков и endpoint Трубы, если он задан именем. Иначе при Аварийной блокировке получается тупик: после перезагрузки без верного времени AmneziaWG-сервер отвергает handshake (защита от повтора по метке времени), а NTP не может отрезолвить свой сервер через неработающий Туннель.

**Политики устройств действуют только на маршрутизацию.** DNS общий: mosdns видит запросы от dnsmasq, а не от устройств.

### 4.6 Распаковщик `.dat` (ucode, `/usr/share/ucode/truba/dat.uc`)

- **Вход:** `geoip.dat` и `geosite.dat` без изменений.
- **Разбор:** protobuf `GeoIPList` / `GeoSiteList` разбирается побайтово, внешних бинарников нет.
- **Выход** в tmpfs `/var/lib/truba/`:
  - `geosite/<tag>.txt` — строки `domain:` / `full:` / `regexp:` / `keyword:` **ровно** как в файле. Атрибуты не используются; регулярные выражения Go RE2 одинаково понимают и v2ray, и mosdns.
  - `geoip/<tag>.v4` — IPv4-подсети (IPv6-записи пропускаются: Маршрутизация только IPv4, ADR 0005).
  - `categories.json` — для интерфейса и порядка проверки: `[{set, tag, count, types:{domain,full,regexp,keyword}, subset_of:[…]}]`.
- **Регистр тегов.** В файле теги в верхнем регистре (`CATEGORY-RU`), в интерфейсе и именах файлов — в нижнем. Сопоставление без учёта регистра, как в v2ray.
- **Кэш:** распаковка выполняется только если изменился sha256 `.dat`.
- **Проверка на закреплённых выпусках** (`tests/dat.pin`, снимок 2026-10-04) — распаковка ничего не теряет:
  - geosite — 61 Категория, `category-ru` = 429 записей, `category-ads` = 42 535, уникальных `regexp` 5 (4 в `netflix`, 1 в `private`; сборная `category-streaming` повторяет 4 из `netflix`);
  - geoip — `ru` = 35 696 записей (IPv4 + IPv6), `private` = 17.

### 4.7 Обновление Наборов правил (`truba update-lists`)

1. **Расписание.** Блок cron между маркерами `# truba-begin` / `# truba-end`, если `lists.auto_update` включён. Время хранится в UTC (по умолчанию 12:00) и переводится в часовой пояс Роутера. geoip выходит раз в три дня около 10–11 UTC, geosite — нерегулярно, обычно до 09 UTC: в 12:00 новый выпуск подхватывается в тот же день. «Обзор» показывает время и результат последней проверки и предупреждает, если её не было больше 36 часов или она не удалась.
2. **Скачивание.** Для каждого файла:
   - основной путь — `curl --interface awg0 --fail --max-time 120` с `raw.githubusercontent.com/kirilllavrov/<repo>/release/<file>`;
   - при ошибке — `curl` напрямую с `cdn.jsdelivr.net/gh/kirilllavrov/<repo>@release/<file>`;
   - так же скачивается `<file>.sha256sum`.
3. **Проверка.** `sha256sum -c`, затем файл разбирается распаковщиком. Контрольная сумма подтверждает только, что файл скачан целиком: файл, повреждённый у источника или нового формата, ломал бы каждое применение настроек. При любом отказе (`sha256 mismatch`, `parse failed`) — запись в журнал, текущие файлы не трогаются.
4. **Без изменений.** Если sha256 совпадает с текущим, выход без перезагрузки; с `-f` — применить ещё раз, не трогая файлы (`prev` остаётся версией для отката).
5. **Атомарная замена.** Текущий файл переносится в `/etc/truba/lists/prev/`, новый — в `/etc/truba/lists/`.
6. **Применение.** `truba reload`: распаковка → атомарная замена наборов `gi_*` → перезапуск mosdns и сброс `gs_*`. Открытые соединения сохраняют путь благодаря ct mark. Если текущие файлы всё же не распаковываются (например, повреждены на флеше), apply сам возвращает предыдущие и предупреждает об этом на «Обзоре».
7. **Откат.** Обратная перестановка `prev` ↔ текущий и `truba reload`. Кнопка «Откатить» переставляет файлы сразу, а применяет их в фоне (`rollback-lists --bg`): rpcd обслуживает вызовы по одному, и, пока он ждал бы применения, стоял бы весь LuCI. Ход применения «DNS и списки» видит в `lists` (`applying`).

«Идёт обновление» — это занятая блокировка `/var/lock/truba-lists.lock`, а не файл-флаг: она снимается сама, даже если процесс убит.

### 4.8 Контроль туннеля (`truba watchdog`, procd-инстанс)

- **Цикл.** Каждые `interval` секунд (30) проверяются:
  - возраст handshake из `awg show awg0 latest-handshakes` (не больше 180 с);
  - `ping -I awg0 -c1 -W2 <probe>`. По умолчанию это адрес Трубы внутри Туннеля (`10.77.77.1`): адрес в интернете не ответил бы, пока в таблице 77 стоит blackhole, и Туннель никогда не признался бы восстановленным. Поэтому подсеть Туннеля держится в таблице 77 всегда.
- **Для «Обзора».** Время ответа на ping и окно последних 20 проверок (около 10 минут при интервале 30 с; потеря — `null`) пишутся в `/var/run/truba/health.json` — в оперативную память. Когда Туннель в порядке, а итог «Проверки NAT» старше этого момента или его нет, watchdog запускает проверку в фоне (§5.2). Новых пингов ради этого нет: используется та же проверка. Отдельно — крупные пакеты: сразу после подъёма Туннеля и затем раз в 10 проверок watchdog пингует Трубу пакетом во весь MTU Туннеля (`health.json` → `big`). Обычный ping мелкий и не видит пути, который теряет полноразмерные пакеты (MTU Туннеля больше, чем пропускает сеть VPS): страницы при этом открываются, а загрузки замирают на секунды. procd следит и за кодом watchdog, поэтому после обновления пакета `reload` перезапускает его с новым кодом; перезапуск (и при смене настроек) не обнуляет «в порядке с» и окно проверок.
- **Перезапуск.** После `fails` (3) неудач подряд — `ifup awg0` (то есть `down` и `up` интерфейса), и так каждые `fails` неудач, пока Туннель не ответит. Состояние «упал» → `table 77` по правилу из §4.3.
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

### 4.10 История скорости для «Обзора» (`truba stats`, procd-инстанс)

Историю ведёт сам Роутер, а «Обзор» её только показывает: график не зависит от того, открыта ли вкладка (ADR 0010).

- **Замер.** Раз в 5 с — счётчики таблицы Трубы одним `nft -j list counters`, скорость по разнице с прошлым замером: байт/с к устройствам и от них по Действиям (Туннель, Напрямую, Входящие) и новых соединений в минуту. Интервал меряется монотонными часами: NTP, поправляя время, не искажает скорость.
- **Разрывы.** Счётчики начаты заново (новый `counters_since` в `applied.json`), таблицы нет, перерыв дольше минуты — в истории разрыв, а не скачок. Счётчик, который уменьшился или исчез, — `null` только на своём месте.
- **Хранение.** В оперативной памяти: точки по 5 с за последний час (`rates.json`, переписывается каждый замер) и поминутные средние за сутки (`rates-min.json`, переписывается раз в минуту; в них только четыре значения графика). Флеш не изнашивается, а после перезагрузки счётчики и так начинаются с нуля. Перезапуск процесса (смена кода, сбой) продолжает историю из файлов без разрыва: монотонные часы общие для всей загрузки.
- **Цена.** Два процесса (`sh` и `nft`) раз в 5 с, постоянно.
- **Чтение.** `truba.rates` читает файл в самом rpcd, без запуска процессов, и отдаёт только точки новее `since`: страница при открытии забирает историю целиком, дальше — по одной точке за опрос. После свёрнутой вкладки первый же опрос приносит всё пропущенное. Ось графика строится по времени Роутера из ответа (`now`), а не по часам компьютера.

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
	list   tunnel_upstream 'udp://10.77.77.1'            # unbound на Трубе (ADR 0013)
	list   tunnel_upstream 'https://1.1.1.1/dns-query'
	list   direct_upstream 'tls+pipeline://common.dot.dns.yandex.net@77.88.8.8'
	list   direct_upstream 'tls+pipeline://common.dot.dns.yandex.net@77.88.8.1'
	option port            '5335'
	option ttl_max         '300'
	option cache_size      '65536'
	option lazy_cache_ttl  '86400'   # сколько хранить истёкшие ответы для ленивого кэша; 0 — выключен
	option set_timeout     '86400'   # срок IP из DNS в наборах gs_* (ADR 0007); 0 — без срока

config lists 'lists'
	option geoip_url      'https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat'
	option geoip_mirror   'https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat'
	option geosite_url    'https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat'
	option geosite_mirror 'https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat'
	option update_utc     '12:00'
	option via_tunnel     '1'
	option auto_update    '1'        # 0 — только кнопкой «Обновить сейчас»

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
| **Обзор** | Сводка, без подробностей: каждый факт показывается на одной вкладке, рядом со своими настройками. Плитки со ссылками на вкладки: «Туннель» (состояние, задержка, handshake и потери, крупные пакеты; переключатель интерфейса), «Маршрутизация» (Режим, доля новых соединений через Туннель, зоны; переключатель), «DNS и списки» (mosdns, доля ответов из кэша, дата списков, следующая проверка), «Входящие» (IP Трубы, итог проверки NAT, число пробросов UPnP и ручных). Переключатели меняют конфигурацию в браузере; сохраняет её «Сохранить и применить». Предупреждения — списком, у каждого ссылка туда, где его исправляют (ошибка применения и что действует вместо него, пропущенные неверные настройки, программное ускорение, UPnP без miniupnpd, крупные пакеты, проверки NAT и списков). Трафик устройств: таблица по Действиям (к устройствам, от устройств, новые соединения в минуту; строка «Блок» — отброшенные пакеты), доля исходящих соединений через Туннель, график скорости за 10 минут, час или сутки — единственное место для счётчиков, в том числе входящих. Страница строится один раз, опрос меняет только текст: колонки фиксированы, цифры моноширинные. Историю графика и скорость в таблице ведёт сам Роутер (§4.10): график не рвётся, когда вкладка свёрнута или закрыта; выбранный срок помнит браузер |
| **Туннель** | Состояние (опрос раз в 5 с): handshake с подсветкой (жёлтый > 3 мин, красный > 5 мин), задержка и потери до Трубы за ~10 мин с мини-графиком, крупные пакеты (итог ping во весь MTU от watchdog), контроль туннеля, таблица 77, rx/tx интерфейса. Импорт `.conf` (файл или вставка) → запись в `network.awg0` и пир; параметры AWG; MTU; keepalive. Те же данные видны и в стандартном luci-proto-amneziawg. Контроль Туннеля и Аварийная блокировка — в одном блоке: что проверять и что делать, пока Туннель не отвечает |
| **Маршрутизация** | Режим (переключатель из двух вариантов); зоны; «В наборах сейчас» — подсети geoip по Действиям и IP из DNS; Политики устройств (из DHCP-клиентов: MAC, а рядом имя и IP устройства в сети; «Всё в туннель / Всё напрямую / По правилам»); таблица Категорий (Набор · Категория · Записей · Типы · Вложена в · Действие) с поиском и фильтром по Действию со счётчиками; Категории, которых нет в наборе, убираются одной кнопкой; «Сбросить к Стартовым настройкам» |
| **DNS и списки** | Одна страница. Состояние DNS (опрос раз в 10 с): mosdns, доля ответов из кэша и истёкших, заполнение кэша. DNS: серверы для «Туннель» и «Напрямую»; перехват DNS; кэш (в том числе ленивый); максимальный TTL; порт mosdns — во вкладке «Дополнительно». Наборы правил: текущая и предыдущая версии (sha256, дата) и итог последней проверки, следующая проверка; «Обновить сейчас», «Откатить»; время обновления (UTC), «через Туннель»; источники и зеркала — во вкладке «Источники» |
| **Входящие** | Проверка NAT: итог последней проверки (внешний адрес, IP Трубы, сохранение порта, одинаковое отображение, когда и как запущена; ответы STUN-серверов — по клику; кнопка «Проверить NAT»). Переключатель UPnP/NAT-PMP; текущие UPnP-отображения; ссылка на перенаправления портов из зоны `truba`. Трафик входящих — на «Обзоре» |
| **Диагностика** | «Проверить домен/IP» → отрезолвленные IP, совпавшие Категории (geosite/geoip), итоговое Действие и правило Приоритета, которое сработало; «Проверка Туннеля» — ping Трубы пакетами трёх размеров (84 байта, 1028 и весь MTU), потери и задержка по каждому; журнал Трубы и mosdns с фильтром. Уровень строки mosdns берётся из неё самой: mosdns пишет всё в stderr, и syslog помечает каждую строку как ошибку |

Цвета значков — из переменных темы (Bootstrap, светлая и тёмная), общие стили — `truba/truba.css`. Вид у вкладок общий: таблицы «название — значение» (`truba-kv`) и числовые таблицы (`truba-grid`) — свои, списки записей (Категории, пробросы, отображения UPnP) — стандартные таблицы LuCI; у каждого Действия свой цвет на всех вкладках (`ACTION_LEVELS`: Туннель — синий, Напрямую — зелёный, Блок — красный); сами таблицы, кнопки-фильтры, значки состояния, пустые списки, индикатор загрузки и общие предупреждения строятся помощниками из `truba/common.js` — новые вкладки берут их оттуда, а не копируют.

«Проверить NAT» проверяет только слой Трубы: внешний IP равен IP Трубы, порт сохраняется, отображение одинаково для разных серверов. Запросы уходят через Туннель (`SO_MARK`) сразу ко всем STUN-серверам с одного сокета, повторы — только тем, кто не ответил: худший случай — одно окно 3 × 1,5 с, а не по окну на сервер. Кнопка запускает проверку в фоне: rpcd обслуживает вызовы по одному, и, пока он ждал бы её, стоял бы весь LuCI. Серверы — `truba.main.stun` (список `host:port`), по умолчанию два Google и Cloudflare. Итог с временем сохраняется в `/var/run/truba/nat.json`, и «Обзор» показывает его без новой проверки. Контроль Туннеля сам запускает проверку, когда Туннель в порядке, а итог старше момента, с которого он в порядке (то есть после подъёма Туннеля и после перезагрузки); если не ответил ни один сервер — повтор не чаще раза в 10 минут. При выключенном контроле Туннеля — только кнопкой. STUN-серверы резолвятся через DNS Роутера, поэтому резолвер, который подменяет адреса, ломает проверку, но не сам Full cone. Полный тест по RFC 5780 запускается с ПК в домашней сети — см. приёмочный тест 1 в [roadmap](roadmap.md#приёмочные-тесты).

### 5.3 rpcd / ubus API (`/usr/share/rpcd/ucode/truba-api.uc`, пакет `truba`, ADR 0008)

| Метод | Ответ / действие |
|---|---|
| `truba.status` | всё для «Обзора», который опрашивает его раз в 5 с: Туннель, здоровье (с задержкой и окном проверок), счётчики nft, счётчики кэша mosdns, даты и размеры списков, итог последней их проверки и время следующего запуска по строке cron (в местном времени Роутера), итог последней проверки NAT, IP Трубы, итог последнего применения (ошибка, что действует вместо неприменённого, пропущенные неверные настройки). Без лишних процессов: работа mosdns и miniupnpd — по `service list` procd через одно соединение ubus, счётчики кэша — HTTP-запросом к API mosdns из ucode (без `pidof`, `curl` и `grep`), имя Трубы не резолвится. Командная строка загружает для него только `truba.state`, без распаковщика, генератора правил и watchdog |
| `truba.lists` | версии Наборов правил для вкладки «DNS и списки»: текущие и предыдущие, с контрольными суммами; итог последней проверки; идёт ли обновление (`updating`) или применение настроек (`applying`) |
| `truba.sets` | размеры наборов: подсети geoip по Действиям (считаются при применении — читать огромный набор из ядра дорого) и IP, положенные mosdns по ответам. «Обзор» вызывает раз в минуту |
| `truba.categories` | содержимое `categories.json` + Действия из UCI для текущего Режима; `busy`, пока списки распаковывает apply (после загрузки) — тогда не распаковывает сам, чтобы не писать те же файлы одновременно |
| `truba.check {target}` | разбор домена или IP по Приоритету. Домен резолвится через Роутер, как это сделало бы устройство, поэтому его IP попадает в набор своей Категории — итог совпадает с тем, что увидит nftables |
| `truba.update_lists` / `truba.rollback_lists` | обновление — в фоне → `{ started }`; откат переставляет файлы сразу и применяет их в фоне (`truba rollback-lists --bg`) → `{ swapped, applying }`, а если идёт обновление — `{ error: busy }`, не дожидаясь его |
| `truba.nat_test` | запуск STUN-проверки слоя Трубы в фоне (до ~5 с) → `{ started }`; итог сохраняется в `nat.json` |
| `truba.nat_result` | итог последней проверки NAT (из файла, без запуска процессов); интерфейс ждёт итог с `time ≥ started` |
| `truba.tunnel_test` | запуск в фоне ping Трубы внутри Туннеля пакетами трёх размеров до полного MTU, разом (~5 с) → `{ started }` |
| `truba.tunnel_result` | итог последней проверки Туннеля: отправлено, получено, средняя задержка по каждому размеру |
| `truba.rates {span, since}` | история скорости (§4.10) из файла, без запуска процессов: точки новее `since` за последние `span` секунд — по 5 с, а дольше часа — поминутные средние; `now` — время Роутера для оси графика |
| `truba.log` | последние строки журнала |

Долгие проверки идут в фоне: rpcd обслуживает вызовы по одному, и пока он ждал бы проверку, остальные вызовы LuCI стояли бы секундами.

Объект `truba` регистрирует ровно один плагин — `truba-api.uc`: два плагина одного объекта роняют rpcd (ADR 0008).

**Права:** ACL `/usr/share/rpcd/acl.d/luci-app-truba.json` — чтение и запись `uci: truba, network, firewall, upnpd`; на чтение — методы, которые только показывают, на запись — те, что что-то запускают (обновление и откат списков, проверки NAT и Туннеля).
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

**Если применить не удалось** (nft не принял таблицу, исключение), служба не останавливается и DNS сети не пропадает ([ADR 0006](adr/0006-failed-apply-keeps-last-good-rules.md)): `nft -f` атомарен, поэтому действует прежняя таблица, и mosdns продолжает работать с конфигом, который ей соответствует (новый пишется только после загрузки таблицы). После перезагрузки, когда прежней таблицы нет, загружается последняя удачная копия с флеша (`/etc/truba/good`); если нет и её — правил Трубы нет, и dnsmasq возвращается к обычному DNS. Нужен ли mosdns, init-скрипт узнаёт из `applied.json` (`mosdns`). Неверное значение в UCI (MAC, адрес DNS-сервера, порт, адрес для ping) не доходит до nft и mosdns: оно пропускается, вместо него — значение по умолчанию, «Обзор» перечисляет пропущенное.

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
| `/etc/truba/good/` | последняя удачная копия правил: `truba.nft` без счётчиков и IP из DNS, `mosdns.json` без API, списки доменов, на которые он ссылается, `meta.json`; пишется, только когда что-то изменилось (ADR 0006) | да (keep.d) |
| `/etc/apk/keys/truba.pem`, `/etc/apk/repositories.d/truba.list` | ключ и адрес фида | да (keep.d) |
| `/var/lib/truba/` | распакованные списки, `categories.json`, хеши | нет (tmpfs, восстанавливается) |
| `/var/etc/truba/` | `mosdns.yaml`, `truba.nft` | нет (генерируется) |
| `/var/run/truba/` | `applied.json`, `health.json` (контроль Туннеля), `nat.json` (итог «Проверки NAT»), `tunnel-test.json` (итог «Проверки Туннеля»), `rates.json` и `rates-min.json` (история скорости, §4.10) | нет (оперативная память) |

---

## 6. Часть D — сборка и доставка

### 6.1 Репозиторий

```
truba/
├─ README.md  CONTEXT.md  CHANGELOG.md
├─ docs/
│  ├─ architecture.md        # это описание
│  ├─ roadmap.md             # что осталось, приёмочные тесты
│  └─ adr/                   # решения: README.md — список
├─ vps/
│  └─ install-vps.sh
├─ router/
│  ├─ VERSIONS               # версии ImmortalWrt, под которые собирается фид
│  ├─ awg/SOURCES            # AmneziaWG: awg-openwrt на зафиксированном коммите
│  ├─ truba/                 # пакет: Makefile, files/etc/init.d/truba, files/usr/sbin/truba (CLI),
│  │                         #   files/usr/share/ucode/truba/*.uc, rpcd-плагин (ubus-API, ADR 0008),
│  │                         #   uci-defaults, keep.d, hotplug, reinstall.sh, uninstall.sh
│  └─ luci-app-truba/        # luci.mk: htdocs/…/view/truba/*.js, ACL, меню, po/{ru,templates}
├─ tests/                   # README.md — части, стенд, как добавить проверку (ADR 0012)
│  ├─ run.sh                 # всё в Docker, части параллельно
│  ├─ dat.pin                # выпуски Наборов правил для проверок на PR
│  ├─ golden/                # эталоны правил nftables и конфига mosdns
│  ├─ lib/                   # общие функции, синтетические .dat, пробы TCP/UDP/STUN
│  ├─ unit/                  # модули на ucode, распаковщик на настоящих выпусках
│  ├─ router/                # стенд Роутера под procd и части: net, dns, lists, life, tunnel, stats
│  ├─ luci/                  # перевод и вызовы API, стенд LuCI, проход Chromium
│  └─ vps/                   # shellcheck и функции install-vps.sh
└─ .github/workflows/
   ├─ tests.yml              # части tests/run.sh параллельно: на PR и перед публикацией фида
   ├─ build.yml              # матрица версий ImmortalWrt 25.12.x × mediatek/filogic, фид
   ├─ watch-releases.yml     # ежедневно: появилась новая 25.12.x? → build.yml
   └─ upstream-lists.yml     # ежедневно: свежие geoip/geosite разбираются и работают
```

В репозитории никогда не бывает приватных ключей AWG, `router.conf`, IP Трубы и ключа подписи.

### 6.2 `build.yml`

1. Скачать ImmortalWrt SDK `25.12.x` для `mediatek/filogic` с `downloads.immortalwrt.org`. Архив хранится в кэше GitHub Actions по контрольной сумме из `sha256sums`: сервер ImmortalWrt бывает медленным, а архив одной версии не меняется.
2. Решить, собирать ли AmneziaWG. Отпечаток — `router/awg/*` и `AWG_BUILD_REV` в workflow; в опубликованном фиде он лежит в `awg.json` рядом с пакетами. Совпал — `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` берутся из фида этой же версии ImmortalWrt (модуль ядра собран под то же ядро). Полная сборка — при новой версии ImmortalWrt, смене источников AWG или вручную (`full`).
3. Подключить фиды `base` и `luci` (для полной сборки AmneziaWG ещё `packages` и `awg-openwrt` на зафиксированном коммите) и локальный фид `router/`.
4. `make package/<пакет>/compile` для нужных пакетов. Зависимости `truba` и `luci-app-truba` записаны в `EXTRA_DEPENDS`: SDK кладёт их в метаданные, но не компилирует (иначе он собирал бы mosdns вместе с Go, curl, openssl, luci-base и выбрасывал). CI сверяет зависимости готовых пакетов с Makefile и падает, если у пакета версия `0` (непереведённый LuCI).
5. Подписать индекс apk ключом из `secrets.APK_SIGN_KEY`.
6. Опубликовать в GitHub Pages: `/<версия>/mediatek/filogic/` (`packages.adb` + `.apk` + `awg.json`), публичный ключ — `/keys/truba.pem`. Каталог собранной версии заменяется целиком, в нём только пакеты из индекса; каталоги других версий остаются как были. Публикация ждёт проверок `tests.yml`, которые идут параллельно со сборкой.

`watch-releases.yml` собирает только выпуски новее последнего опубликованного фида (`/versions.txt`). Поэтому фид прежней версии можно убрать, удалив её каталог из `gh-pages`: заново его не соберут. Вернуть — добавить версию в `router/VERSIONS`.

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
  1. возвращает dnsmasq к значениям из бэкапа Трубы (`/etc/truba/state/dnsmasq.json`), как `truba teardown`. sysupgrade сохраняет `/etc/config/dhcp`, где dnsmasq направлен в mosdns, а mosdns ещё нет: без этого не было бы DNS ни у сети, ни у самого Роутера, и пакеты не скачались бы;
  2. ждёт интернет;
  3. подставляет `VERSION` из `/etc/os-release` в адрес фида;
  4. `apk update`;
  5. ставит модуль ядра, если он собран под эту версию. Если нет — пишет в журнал, что Туннель не поднимется, и как доставить модуль, когда сборка появится; остальное ставит всё равно (запасного `amneziawg-go` нет: решено не использовать);
  6. ставит `truba` и `luci-app-truba`, перезапускает сеть (обработчик протокола amneziawg netifd находит только при запуске) → служба поднимается с сохранёнными настройками и снова направляет dnsmasq в mosdns.
- **Правило эксплуатации:** обновлять ImmortalWrt только после того, как `watch-releases.yml` собрал пакеты под новую версию (отметка в README фида).

---

## 7. Риски и ограничения

| Риск | Последствие | Что делаем |
|---|---|---|
| Версии AWG на Трубе и Роутере разошлись | Туннель не поднимается | Модуль Роутера собирается из `router/awg/SOURCES`, на VPS стоит версия из PPA на момент установки. `install-vps.sh status` показывает её — её сверяют с `SOURCES`; новая версия протокола включается только `rotate-keys` с новым импортом `router.conf` |
| ImmortalWrt обновили раньше, чем CI собрал модуль | Туннеля нет до сборки | Правило эксплуатации §6.4; `watch-releases.yml` собирает новую версию в течение суток |
| Браузеры с собственным DoH | Доменные Категории не срабатывают для этих устройств | В «Всё в туннель» безопасно (трафик уходит в Туннель, `geoip:ru` всё равно работает). В «Выборочном» такие домены идут напрямую — ограничение ADR 0002 |
| Общие CDN-адреса | Домены с разными Действиями на одном IP | Между Категориями Туннель побеждает Напрямую (ADR 0002). Домены «По режиму» в наборы не попадают: в «Всё в туннель» их адрес, общий с доменом «Напрямую», идёт Напрямую. IP из DNS действуют не дольше суток, поэтому устаревшая связь адреса с доменом проходит сама; активный конфликт остаётся (ADR 0007) |
| Категории ограничены 61 тегом | В «Выборочном» нет Telegram/Meta/Discord/X/OpenAI | Осознанно: новых Категорий не добавляем; основной Режим — «Всё в туннель» |
| В README geosite указан тег `ru`, а в файле его нет | Ошибка при ручной настройке | Интерфейс показывает только реальные теги из файла (`category-ru`) |
| Весь входящий трафик идёт на IP Трубы | Жалобы на абузы хостеру (торренты, открытые сервисы) | Учитывать при выборе хостера; UPnP по умолчанию выключен |
| SNAT на Трубе совпал с собственным соединением VPS | Отдельный порт не сохранится | Редко; при необходимости сузить `ip_local_port_range` на VPS |
| `raw.githubusercontent.com` медленный или заблокирован | Списки не обновились | Загрузка через Туннель + зеркало jsDelivr; старые списки продолжают работать |
| Источник выпустил `.dat`, который распаковщик не разбирает (повреждён, новый формат) | Каждое применение настроек падало бы | `update-lists` разбирает файл до замены и оставляет текущий; apply при нечитаемых текущих возвращает предыдущие |
| Применить настройки не удалось (ошибка nft, опечатка в UCI) | Без защиты procd остановил бы mosdns, а dnsmasq продолжал бы слать запросы ему: DNS всей сети пропал бы | Действуют прежние правила, после перезагрузки — последняя удачная копия; неверные значения UCI пропускаются (ADR 0006) |
| Новая ревизия NC-1812 с NAND FM25G02B ([openwrt#23855](https://github.com/openwrt/openwrt/issues/23855)) | Возможен bootloop при перепрошивке | Касается только перепрошивки, не установки пакетов; перед sysupgrade проверить ревизию |
| fullcone в ImmortalWrt включается глобально | Fullcone действует и на `wan` | Ожидаемо и безвредно |
| Провайдер включит IPv6 | Устройства получат «белые» IPv6, трафик мог бы пойти мимо Туннеля | Правило `lan → wan` IPv6 REJECT и фильтр AAAA уже стоят; полная поддержка IPv6 — отдельное расширение (ADR 0005) |
| Кто-то выключит IPv6 на `br-lan` (например, `network.lan.ipv6='0'`) | mesh-узлы перестанут находить друг друга | Труба IPv6 домашней сети не меняет; в README — предупреждение не выключать IPv6 на `br-lan` |
| Другая служба на Роутере перезапишет метки | Ответы на входящие уходят в `wan`, свои сокеты Роутера — мимо Туннеля | Свой байт метки, решение в ct mark пишется последним, метка своих сокетов — из `socket mark` (ADR 0011). Не лечится: чужая маска с байтом `0x00ff0000`, DNAT в nat output |
| DNS-сервер на Трубе не отвечает (VPS ставился раньше или unbound упал) | Ответы идут от запасного DoH 1.1.1.1: DNS работает, но холодные соединения снова стоят две поездки через Туннель | `install-vps.sh status` — запросы и SERVFAIL у unbound; ошибки сервера — в журнале mosdns («Диагностика»). Повторный `install-vps.sh install` ставит unbound на прежних ключах |
| DPI начнёт узнавать Туннель по размерам пакетов | Туннель блокируется или режется | В запасе RandomTrailers: `install-vps.sh random-trailers on` и флаг Random Trailers у `awg0` на Роутере. Цена — трафик на мелких пакетах, поэтому по умолчанию выключен |

---

## 8. Параметры по умолчанию

Разумные значения, отдельного ADR у них нет; любое можно поменять, не трогая решений из `docs/adr/`:

1. Подсеть Туннеля `10.77.77.0/30`, таблица `77`, метки `0x00010000` / `0x00020000` / `0x00040000` под маской `0x00ff0000` (как ими пользоваться — ADR 0011).
2. Блок для geosite — на уровне DNS (NXDOMAIN), для geoip — отбрасывание по IP.
3. «Узость» Категории: вложенность, а если её нет — меньшее число записей.
4. Наборы `gs_*` со сроком сутки (ADR 0007), сбрасываются при изменении правил или geosite; TTL классифицированных ответов ≤ 300 с.
5. Перехват DNS (порт 53 из `lan`) включён, переключатель — на вкладке «DNS и списки».
6. Политики устройств действуют на маршрутизацию, DNS общий.
7. `PersistentKeepalive = 25`, MTU по сети VPS: её MTU − 87, не больше 1380.
8. Время обновления хранится в UTC и переводится в часовой пояс Роутера.
9. «Проверить NAT» в интерфейсе — только слой Трубы; полный тест RFC 5780 — с ПК.
10. Пакет `truba` при установке сам включает fullcone, выключает аппаратное ускорение (программное не трогает), создаёт зону `truba`, добавляет правило `lan → wan` IPv6 REJECT и выключает стоковый init mosdns. IPv6-настройки домашней сети не трогает. Всё откатывается при удалении.
11. Теги показываются в нижнем регистре (в файле — верхний; v2ray сравнивает без учёта регистра).
12. SSH и порт Туннеля — случайные порты 40000–59999; правила на VPS применяются с автооткатом через 120 с.

---

## 9. Принципы и инварианты

То, на что опирается вся система. Изменение, которое нарушает один из пунктов, — это новое решение: сначала ADR, потом код.

1. **Решения о трафике принимает только Роутер.** Труба — прозрачная труба 1:1 без своей логики; на ней нет ни списков, ни Категорий (ADR 0001).
2. **На пути трафика нет процессов.** Пакеты идут через ядро: метки, таблица 77, наборы nftables. Процессы Трубы (mosdns, watchdog, stats) только наполняют наборы и следят за состоянием; их падение не рвёт открытые соединения (ADR 0002).
3. **Наборы правил — без изменений.** `.dat` используются как есть, Категории — только целиком, своих Категорий и атрибутов нет; распаковщик меняет формат, а не содержимое (ADR 0003).
4. **Один путь применения.** Любое изменение — «Сохранить и применить», событие Туннеля, обновление списков — сводится к `truba apply`: вычислить желаемое состояние из UCI и привести к нему систему. Таблица `inet truba` генерируется целиком и загружается атомарно; дорогие шаги пропускаются по хешам входных данных (ADR 0009).
5. **Отказ не ломает сеть.** Ошибка применения оставляет последние удачные правила, DNS сети не пропадает; неверное значение UCI пропускается с предупреждением; скачанный список, который не разбирается, текущий не заменяет (ADR 0006).
6. **Открытые соединения не меняют путь.** Решение для соединения живёт в ct mark; обновление наборов действует только на новые соединения.
7. **Свой байт метки.** Труба пишет только в байт `0x00ff0000` meta mark и ct mark и пишет решение последней (ADR 0011).
8. **Только IPv4.** IPv6 домашней сети не трогаем, IPv6-интернет закрыт (ADR 0005).
9. **Флеш не изнашивается.** Всё, что меняется часто (распакованные списки, история скорости, состояние проверок, кэш DNS), — в tmpfs. На флеше — только настройки, Наборы правил и последняя удачная копия правил, и они пишутся, только когда изменились.
10. **rpcd не ждёт.** Метод ubus отвечает быстро: всё долгое (проверки NAT и Туннеля, обновление и откат списков) запускается в фоне, итог читается отдельным методом из файла. `status` не запускает лишних процессов.
11. **API — это CLI.** Каждый метод объекта `truba` — команда `/usr/sbin/truba`; интерфейс не вычисляет того, что знает служба, и работает только через ubus и UCI (ADR 0008).
12. **Всё, что пакет поменял, он возвращает.** Настройки firewall, dnsmasq, cron, init mosdns: исходные значения сохраняются при установке и возвращаются при удалении (`teardown`, `uninstall.sh`). Данные службы — Наборы правил с предыдущими версиями, последняя удачная копия, распакованные списки — удаляются вместе с пакетом.
13. **Секреты не попадают в репозиторий.** Ключи AWG, `router.conf`, IP Трубы и ключ подписи фида живут только на своих машинах и в секретах CI.
14. **Изменение правил видно в диффе.** Генерация таблицы nftables и конфига mosdns сверяется с эталонами в `tests/golden`; новое поведение — новые эталоны в том же коммите (ADR 0012).

## 10. Точки расширения

| Что добавить | Где и как |
|---|---|
| Уведомления (Telegram и т.п.) | Подписаться на событие `ubus listen truba.tunnel` (`{state}` при падении и подъёме Туннеля) и читать `ubus call truba status`; отдельным пакетом, не трогая `truba` |
| Метод API | Команда в `/usr/sbin/truba` (модуль в `truba.*`) → метод в `truba-api.uc` → право в ACL `luci-app-truba.json` → вызов в интерфейсе. Проверка `luci` найдёт метод, которого нет в плагине или ACL |
| Настройка | Опция в `/etc/config/truba` со значением по умолчанию → разбор и проверка в `conf.uc` (неверное значение пропускается, ADR 0006) → поле в интерфейсе → строка перевода |
| Вкладка или блок интерфейса | Представление в `view/truba/`, пункт в `menu.d`, общие элементы — `truba/common.js` и `truba.css`; строки — в `po/templates` и `po/ru` |
| Другой Роутер (платформа) | Новая пара `target/subtarget` в матрице `build.yml` и каталог фида; пакеты `truba` и `luci-app-truba` от платформы не зависят (`PKGARCH:=all`) |
| Новая версия ImmortalWrt | Сама: `watch-releases.yml` → `build.yml`; вручную — `router/VERSIONS` |
| IPv6 в Маршрутизации | Отдельное расширение по ADR 0005: IPv6-наборы geoip, IPv6 на Трубе и в Туннеле, NAT66 или /64, метки и перехват DNS для IPv6 |
| Другой источник Наборов правил | Только в формате v2ray `.dat`: адреса в `lists.*_url` / `*_mirror`; распаковщик и тесты `dat` (свежие выпуски — каждый день) |
