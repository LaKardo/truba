# vps — установщик Трубы

## Overview

Один bash-скрипт `install-vps.sh` превращает Ubuntu 24.04 ВМ в Трубу: ставит AmneziaWG из PPA, генерирует ключи и параметры AWG для обеих сторон, пробрасывает весь публичный IP на Роутер через nftables, поднимает DNS-сервер unbound для Роутера в Туннеле, переносит SSH на высокий порт с подтверждением и откатом, настраивает fail2ban, sysctl, очередь WAN и журнал. Все изменения идут транзакцией со снимком файлов и таймером отката systemd, чтобы обрыв SSH не оставил VPS недоступной. Контракт с Роутером — файл `/root/truba/router.conf`, который импортируется в LuCI.

## Interface

### Команды CLI (`main`)

- `install [--ssh-port N] [--awg-port N] [--mtu N|auto] [--no-confirm]` — установка и повторная установка; ключи и порты берутся из `/etc/truba/pipe.env` [install-vps.sh:cmd_install]
- `status` — IP, порты, протокол AWG, MTU, qdisc, флаги AWG 3.1, модуль ядра, sysctl, таблицы nft, unbound, состояние юнитов [install-vps.sh:cmd_status]
- `show-config` — вывод `router.conf` [install-vps.sh:cmd_show_config]
- `mtu-check` — бинарный поиск path MTU DF-пингами до Роутера; при молчании — пассивный замер по счётчикам фрагментации 30 с [install-vps.sh:cmd_mtu_check, path_mtu, mtu_passive]
- `diag [секунд]` — два снимка счётчиков NIC/tc/UDP/softnet/CPU/conntrack с параллельными ping до `10.77.77.2` и `1.1.1.1` [install-vps.sh:cmd_diag, diag_snapshot, diag_report]
- `repair-module` — сборка DKMS-модуля amneziawg под ядра без него [install-vps.sh:cmd_repair_module, repair_kernel]
- `rotate-keys` — новые ключи и параметры AWG, переход на `AWG_PROTO_NOW` [install-vps.sh:cmd_rotate_keys]
- `random-trailers on|off` — переключение `RandomTrailers` на лету и в конфигах [install-vps.sh:cmd_random_trailers]
- `uninstall [--purge]` — снятие юнитов, таблиц nft и файлов; `--purge` удаляет `/etc/truba`, `/root/truba`, `awg0.conf` [install-vps.sh:cmd_uninstall]
- `txn-rollback` — внутренняя команда таймера отката [install-vps.sh:cmd_txn_rollback]

### Ключевые константы

- `STATE=/etc/truba/pipe.env`, `OWNED=/etc/truba/owned.env`, `TXN_DIR=/etc/truba/txn`, `NFT_FILE=/etc/truba/pipe.nft`, `PIPE_VARS_SH=/etc/truba/pipe-vars.sh` [install-vps.sh:20-50]
- `AWG_IF=awg0`, `AWG_CONF=/etc/amnezia/amneziawg/awg0.conf`, `ROUTER_CONF=/root/truba/router.conf` [install-vps.sh:28-32]
- `VPS_TUN=10.77.77.1`, `RTR_TUN=10.77.77.2` (/30) [install-vps.sh:55-56]
- `MTU_MAX=1380`, `MTU_MIN=1280`, `TUN_HDR=60`, `S4_MAX=27`, `MTU_STEAM=1328` [install-vps.sh:66-76]
- `CONFIRM_TIMEOUT=120`, `ROLLBACK_DELAY=180`, `APT_WAIT=600` [install-vps.sh:139-146]
- `PPA_FPR=75C9DD72C799870E310542E24166F2C257290828` — отпечаток ключа PPA `amnezia/ppa` [install-vps.sh:611]
- `STATE_KEYS` — белый список ключей `pipe.env`/`owned.env` [install-vps.sh:271-273]

### Основные функции

- Генерация: `gen_keys`, `gen_params`, `gen_i1`, `refresh_i1`, `awg_conf`, `router_conf`, `write_awg_conf`, `write_router_conf` [install-vps.sh:830-1051]
- nftables: `write_nft`, `write_pipe_vars_sh`, `snat_ports_off_awg`, `write_pipe_unit` [install-vps.sh:1058-1222]
- Транзакция: `txn_begin`, `txn_restore`, `txn_recover`, `txn_commit`, `txn_on_exit`, `rollback_timer_start`, `rollback_timer_stop` [install-vps.sh:1597-1722]
- SSH: `choose_ssh_port`, `ssh_apply`, `ssh_validate_effective`, `confirm_ssh`, `rollback_ssh`, `ssh_restart` [install-vps.sh:1499-1595, 1774]
- DNS: `pick_forwarders`, `write_unbound_conf`, `setup_unbound`, `unbound_status` [install-vps.sh:1383-1497]
- Система: `write_sysctl`, `sysctl_overrides`, `wan_qdisc`, `setup_awg_service`, `awg_apply_live`, `setup_fail2ban`, `setup_unattended`, `setup_journal` [install-vps.sh:1224-1771]

## Invariants

- `main` без команды или с неизвестной печатает usage и выходит с кодом 2; неизвестный флаг — `die`; флаги разбираются для любой команды; `diag` принимает только 5–600 с (по умолчанию 30) [install-vps.sh:main, cmd_diag]
- Только root, только Ubuntu 24.04, не контейнер (`systemd-detect-virt --container`), в `/root/.ssh/authorized_keys` есть ключ, который читает `ssh-keygen -l`, есть маршрут по умолчанию и публичный IPv4 на WAN (отвергаются 0/8, 10/8, 127/8, 100.64/10, 169.254/16, 172.16/12, 192.168/16 и всё ≥ 224) [install-vps.sh:need_root, preflight, have_key_login, public_ipv4]
- Скрипт работает под `set -Eeuo pipefail`; `main` не выполняется при `source` [install-vps.sh:18, main]
- `pipe.env`/`owned.env`: обычный файл (не symlink), владелец uid 0, без прав записи group/other; каждая строка `^KEY='value'$`; значения проверяются по типу (`state_value_ok`: порты 1–65535, `AWG_PROTO ∈ {1,2,3}`, `TUN_MTU ∈ [1280,1380]`, H1–H4 как `N` или `N-N`) [install-vps.sh:load_env, state_value_ok]
- `/etc/truba` создаётся с правами 700, `pipe.env`, `owned.env`, `awg0.conf`, `router.conf` — 600; конфиги и юниты пишутся атомарно через `put_file` (mktemp + mv); исключения — `/run/truba/pipe-vars.nft` и служебные файлы снимка в `txn/` [install-vps.sh:put_file, save_state, write_awg_conf, write_router_conf, write_nft, txn_begin]
- MTU Туннеля = min(MTU WAN − (60 + S4), 1380); S4 ≥ 12 при AWG 3.x, иначе ≥ 4; предупреждение, если MTU < 1328 (Steam) [install-vps.sh:auto_mtu, s4_floor, s4_fit, warn_steam_mtu]
- Случайные порты из 40000–59999, не занятые (`ss`) и не совпадающие с портами других WG/AWG-туннелей; `SSH_PORT ≠ AWG_PORT` [install-vps.sh:pick_port, check_port_available, cmd_install]
- Ключ PPA, полученный с keyserver, должен иметь отпечаток ровно `PPA_FPR`; существующие `*.sources` с `amnezia/ppa` проверяются на тот же отпечаток, если установлен `gpg` (иначе — предупреждение); `*.list` с `amnezia/ppa` — только предупреждение [install-vps.sh:ppa_add, ppa_key_check]
- Параметры AWG: JC 4–8, JMIN 40–80, JMAX 300–900, S1/S2 15–150 с `S2 ≠ S1+56`, `S3 ≠ S2+28`; H1–H4 = `1 2 3 4` допустимы только при `HeaderProtectionKey` (AWG ≥ 3), иначе `die` [install-vps.sh:gen_params, awg_check_h]
- Повторный `install` не меняет `AWG_PROTO`, ключи и параметры AWG (кроме дозаполнения `I1`/`I1_SRV` через `refresh_i1`, если `AWG_PROTO ≥ 2` и `I1_SRV` пуст); только `rotate-keys` поднимает протокол до `AWG_PROTO_NOW` [install-vps.sh:cmd_install, refresh_i1, cmd_rotate_keys]
- Первая установка отказывается перезаписать чужой `awg0.conf` без первой строки `# Труба:` [install-vps.sh:check_foreign_awg_conf]
- Пока порт SSH не подтверждён (`SSH_CONFIRMED != 1`) и нет `--no-confirm`, требуется `/dev/tty` и реальный файл скрипта (`bash <(curl …)` отвергается); подтверждение — только литерал `yes` за 120 с. Повторный `install` с уже подтверждённым портом этого не требует [install-vps.sh:cmd_install, confirm_ssh]
- Таймер отката запускается только в окне подтверждения SSH (порт не подтверждён, есть `SSH_FALLBACK`, нет `--no-confirm`): он запускает копию скрипта из `/etc/truba/txn/install-vps.sh` через `systemd-run --on-active=180s`, поэтому откат сработает, даже если установщик убит вместе с SSH-сессией. При `--no-confirm` и в `rotate-keys` защищает только EXIT-trap [install-vps.sh:cmd_install, rollback_timer_start]
- EXIT-trap `txn_on_exit` откатывает транзакцию при `TXN_ACTIVE=1` в главном процессе; HUP/INT/TERM транслируются в exit 129/130/143 [install-vps.sh:txn_on_exit, main]
- Изменяющие команды (`install`, `rotate-keys`, `random-trailers`, `uninstall`, `repair-module`) берут `flock -n` на `/run/lock/truba-installer.lock` (иначе `die`) и сначала выполняют `txn_recover`, если остался `TXN_DIR`; `txn-rollback` ждёт замок до 60 с и продолжает без него [install-vps.sh:main, txn_recover]
- `sysctl` и qdisc WAN применяются до `txn_begin` и не откатываются; конфиг unbound пишется в `install_packages` до `txn_begin`, а `setup_unbound`, fail2ban, unattended и journald выполняются после `txn_commit` [install-vps.sh:cmd_install, install_packages]
- `sshd -t` и эффективные значения `sshd -T` (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password|without-password`) обязаны проходить, иначе `die` с именем перебивающего файла; drop-in задаёт также `MaxAuthTries 3`, `LoginGraceTime 20`, `X11Forwarding no` [install-vps.sh:ssh_apply, sshd_expect]
- `truba-pipe.service` имеет `Before=awg-quick@awg0.service`, а юнит AWG — `Requires=truba-pipe.service`: Туннель никогда не работает без правил фильтра [install-vps.sh:write_pipe_unit, setup_awg_service]
- Неизменённые правила nft не перезагружаются (сохраняется счётчик `tunnel_frag_in`); `pipe.nft` обязан пройти `nft -c -f` [install-vps.sh:write_nft, write_pipe_unit]
- Форвардер DNS меняется только при выигрыше ≥ 5 мс (`DNS_SWITCH_MS`) при ответе обоих адресов пары [install-vps.sh:pick_near]
- `uninstall` не удаляет пакеты amneziawg/unbound; ранее существовавший unbound перезапускается, а не выключается; `unbound-resolvconf.service` включается обратно при `RESOLVCONF_ENABLED=1`; ufw включается обратно только при `UFW_DISABLED=1`, после чего в `owned.env` пишется `UFW_DISABLED=0` [install-vps.sh:cmd_uninstall]

## Side Effects

- Файлы: `/etc/truba/{pipe.env,owned.env,pipe.nft,pipe-vars.sh}`, `/run/truba/pipe-vars.nft`, `/etc/amnezia/amneziawg/awg0.conf`, `/root/truba/router.conf`, `/etc/systemd/system/truba-pipe.service`, `/etc/systemd/system/awg-quick@awg0.service.d/10-truba.conf` (или `truba-awg.service`), `/etc/sysctl.d/90-truba.conf`, `/etc/modules-load.d/truba.conf`, `/etc/unbound/unbound.conf.d/truba.conf`, `/etc/ssh/sshd_config.d/10-truba.conf`, `/etc/fail2ban/jail.d/truba.local`, `/etc/apt/apt.conf.d/52truba`, `/etc/systemd/journald.conf.d/90-truba.conf`, `/etc/apt/sources.list.d/amnezia-ubuntu-ppa-noble.sources` [install-vps.sh:save_state, save_owned, write_nft, write_pipe_vars_sh, write_awg_conf, write_router_conf, write_pipe_unit, setup_awg_service, write_sysctl, write_unbound_conf, ssh_apply, setup_fail2ban, setup_unattended, setup_journal, ppa_add]
- Сеть: `curl` к `keyserver.ubuntu.com` за ключом PPA; `apt-get update`/`install` (`curl`, `gpg`, nftables, fail2ban, unattended-upgrades, unbound, `linux-headers-*` с `apt-mark auto` для текущего ядра, amneziawg); `getent ahosts*` для адресов I1; ping к `1.1.1.1`, `1.0.0.1`, `8.8.8.8`, `8.8.4.4` при выборе форвардеров; DF-пинги до Роутера в `mtu-check` [install-vps.sh:ppa_add, install_packages, i1_resolve, pick_forwarders, ping_df]
- Ядро и сеть: `modprobe amneziawg`, `modprobe nf_conntrack`, `sysctl -p` (ip_forward, bbr, fq_codel, conntrack 262144, ipv6 forwarding 0), `tc qdisc del` + `replace dev WAN root mq|fq_codel`, временный интерфейс `awgprobe$$`, `awg syncconf`/`ip link set mtu` на лету, `awg set awg0 random-trailers …` [install-vps.sh:install_packages, write_sysctl, wan_qdisc, awg_proto_supported, awg_apply_live, cmd_random_trailers]
- nftables: таблицы `ip truba_nat` (DNAT всего TCP кроме SSH, всего UDP кроме `AWG_PORT` и порта 68 DHCP-клиента, всех прочих протоколов → `10.77.77.2`; SNAT с исключением порта AWG) и `inet truba_filter` (input/forward policy drop, notrack для внешнего UDP Туннеля, MSS clamp, DSCP cs0) [install-vps.sh:write_nft, snat_ports_off_awg]
- systemd: `daemon-reload`, enable/restart/reload `truba-pipe`, юнита AWG, `unbound`, `fail2ban`, `systemd-journald`, `ssh.socket`/`ssh.service`; `disable --now unbound-resolvconf.service` (и `enable --now` обратно в `uninstall` при `RESOLVCONF_ENABLED=1`); транзиентный таймер `truba-rollback` [install-vps.sh:unit_apply, setup_unbound, ssh_restart, setup_journal, rollback_timer_start, cmd_uninstall]
- `ufw disable` при активном ufw (с маркером `txn/ufw-off`), обратное включение при откате или `uninstall` [install-vps.sh:ufw_off, txn_restore, cmd_uninstall]
- Снимок транзакции `/etc/truba/txn/` (копии файлов, `manifest`, маркеры состояния юнитов) создаётся в `txn_begin`; копию скрипта добавляет `rollback_timer_start`, маркер `ufw-off` — `ufw_off`; каталог удаляется в `txn_commit`, `txn_restore` и `cmd_uninstall` [install-vps.sh:txn_begin, rollback_timer_start, ufw_off, txn_commit, txn_restore, cmd_uninstall]
- `repair-module`: установка `linux-headers-<k>`, `dkms autoinstall -k`, `depmod -a`, `modprobe amneziawg`, перезапуск юнита AWG, если интерфейса нет [install-vps.sh:repair_kernel, cmd_repair_module]
- Чтение `/proc/net/snmp`, `/proc/net/softnet_stat`, `/proc/stat`, `/proc/net/stat/nf_conntrack`, `/proc/meminfo`, `/proc/cpuinfo`, `/proc/sys/net/netfilter/nf_conntrack_{count,max}`, `/sys/class/net/*`, `systemd-detect-virt` в `diag`/`mtu-check`/`status` [install-vps.sh:diag_snapshot, ip_frag_counters, wan_mtu, cmd_status]

## Verification

- Run: `bash tests/run.sh vps` (shellcheck и ~40 с проверок `install-vps.sh` в Docker; см. [tests/README.md](../tests/README.md))
