// Константы Трубы: метки, таблица маршрутов, пути. Пути и имена записаны только здесь (ADR 0015).
'use strict';

// Биты 24–27 (ADR 0011): байт 0x00ff0000 целиком занимают mesh-VPN и маршрутизация по политикам,
// старшие биты 29–30 — обход DPI.
export const MARK_TUNNEL  = 0x01000000;
export const MARK_DIRECT  = 0x02000000;
export const MARK_INBOUND = 0x04000000;
export const MARK_MASK    = 0x0f000000;

export const RT_TABLE       = 77;
export const PRIO_RULE_MARK = 1000;
export const PRIO_RULE_OIF  = 1001;

export const NFT_TABLE = 'truba';
// Зона межсетевого экрана Туннеля (её создаёт uci-defaults).
export const FW_ZONE = 'truba';
// Свои секции межсетевого экрана у зон Маршрутизации: <зона>_truba — перенаправление в зону Туннеля
// (ADR 0014), <зона>_truba_no_ipv6 — правило, закрывающее зоне IPv6-интернет (ADR 0016).
export const FW_FWD_SUFFIX = '_' + FW_ZONE;
export const FW_NO6_SUFFIX = FW_FWD_SUFFIX + '_no_ipv6';
// Тег журнала: под ним пишет служба, по нему «Журнал» отбирает её строки. У watchdog свой тег: на «Журнале»
// его строки — отдельный источник; в нём есть LOG_TAG, и logread -e находит их тем же выражением.
export const LOG_TAG = 'truba';
export const WATCHDOG_TAG = LOG_TAG + '-watchdog';

// Команда службы и её init-скрипт.
export const CLI  = '/usr/sbin/truba';
export const INIT = '/etc/init.d/truba';

// Адрес, на котором слушает mosdns: к нему dnsmasq пересылает запросы, там же API mosdns.
export const MOSDNS_ADDR = '127.0.0.1';

// На флеше: Наборы правил, бэкапы чужих настроек, последняя удачная копия правил.
export const CONF_DIR  = '/etc/truba';
export const LISTS_DIR = CONF_DIR + '/lists';
export const PREV_DIR  = LISTS_DIR + '/prev';
export const STATE_DIR = CONF_DIR + '/state';
export const GOOD_DIR  = CONF_DIR + '/good';
export const REINSTALL = CONF_DIR + '/reinstall.sh';
// В памяти: распакованные списки, итоги и состояние, сгенерированные конфиги.
export const DATA_DIR  = '/var/lib/truba';
export const RUN_DIR   = '/var/run/truba';
export const ETC_DIR   = '/var/etc/truba';
// Временные: скачивание Наборов правил, проверка Туннеля (каталог mktemp с этим префиксом).
export const TMP_DIR   = '/tmp';
export const DL_DIR    = TMP_DIR + '/truba-dl';
export const TT_TMP    = TMP_DIR + '/truba-tt';

export const MOSDNS_CONF = ETC_DIR + '/mosdns.json';
export const NFT_FILE    = ETC_DIR + '/truba.nft';
export const STAMP_FILE  = DATA_DIR + '/stamp';
export const CATS_FILE   = DATA_DIR + '/categories.json';
export const HEALTH_FILE = RUN_DIR + '/health.json';
export const APPLIED_FILE = RUN_DIR + '/applied.json';
export const COUNTERS_FILE = RUN_DIR + '/counters.json';
export const DNS_NAMES_FILE = RUN_DIR + '/dnsnames.json';
export const SET_SIZES_FILE = RUN_DIR + '/set-sizes.json';
export const NAT_FILE    = RUN_DIR + '/nat.json';
export const TT_FILE     = RUN_DIR + '/tunnel-test.json';
// Перезапуск dnsmasq ради адресов зон (dns.dns_heal): после какого процесса и для каких адресов.
export const DNS_HEAL_FILE = RUN_DIR + '/dns-heal.json';
// История скорости для графика «Обзора» (truba.stats): точки по 5 с за час и поминутные за сутки.
export const RATES_FILE     = RUN_DIR + '/rates.json';
export const RATES_MIN_FILE = RUN_DIR + '/rates-min.json';
export const LISTS_STATE = STATE_DIR + '/lists.json';
export const DNSMASQ_BACKUP = STATE_DIR + '/dnsmasq.json';
export const UPNP_BACKUP = STATE_DIR + '/upnpd.json';

// Последняя удачная копия правил (ADR 0006) — на флеше: нужна после перезагрузки,
// когда применить настройки не удалось, а прежних правил в памяти уже нет.
export const GOOD_NFT    = GOOD_DIR + '/truba.nft';
export const GOOD_MOSDNS  = GOOD_DIR + '/mosdns.json';
export const GOOD_GEOSITE = GOOD_DIR + '/geosite';
export const GOOD_META    = GOOD_DIR + '/meta.json';

// История скорости (truba stats, ADR 0010): step — шаг точек, с; span — сколько их хранится, с.
// fine — каждый замер за час, min — поминутные средние за сутки. Те же сроки — у графика «Обзора».
export const HISTORY = {
	fine: { step: 5, span: 3600 },
	min: { step: 60, span: 86400 },
};

// Трафик по устройствам (ADR 0018): динамические наборы цепочки stats, по одному на Действие и
// направление. Ключ — IPv4 устройства, у элемента — счётчик. Порядок — как у байтов истории
// скорости (truba.stats): к устройству и от него — Туннель, Напрямую, Входящие.
export const DEV_SETS = [ 'dv_tunnel_down', 'dv_tunnel_up', 'dv_direct_down', 'dv_direct_up', 'dv_inbound_down', 'dv_inbound_up' ];
export const DEV_SET_SIZE = 1024;
// Срок элемента набора и истории устройства без трафика, с.
export const DEV_SPAN = 86400;
// Поминутные средние устройства (мини-график вкладки «Устройства»): шаг и сколько хранится, с.
export const DEV_HISTORY = { step: 60, span: 3600 };
export const DEVICES_FILE = RUN_DIR + '/devices.json';
// Сколько устройств отдаёт devices: самые недавние и все с Политикой. В наборах адресов до DEV_SET_SIZE
// (в том числе подменённых), а ответ ubus и вкладка столько не вынесут.
export const DEV_LIST_MAX = 256;
// «Куда ходит сейчас»: таблица соединений ядра и сколько адресов отдавать.
export const CONNTRACK = '/proc/net/nf_conntrack';
export const CONN_TOP = 20;

// Окно последних проверок watchdog для «Обзора»: задержка и потери за ~10 минут при интервале 30 с.
export const PROBE_WINDOW = 20;

// Блокировки: применение настроек и Наборы правил.
export const LOCK_APPLY = 'truba';
export const LOCK_LISTS = 'truba-lists';

export const DAT_FILES = { geoip: 'geoip.dat', geosite: 'geosite.dat' };

export const ACTIONS = [ 'direct', 'tunnel', 'block' ];

export const CRON_BEGIN = '# truba-begin';
export const CRON_END   = '# truba-end';
