// Константы Трубы: метки, таблица маршрутов, пути.
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

export const LISTS_DIR = '/etc/truba/lists';
export const PREV_DIR  = '/etc/truba/lists/prev';
export const STATE_DIR = '/etc/truba/state';
export const DATA_DIR  = '/var/lib/truba';
export const RUN_DIR   = '/var/run/truba';
export const ETC_DIR   = '/var/etc/truba';

export const MOSDNS_CONF = '/var/etc/truba/mosdns.json';
export const NFT_FILE    = '/var/etc/truba/truba.nft';
export const STAMP_FILE  = '/var/lib/truba/stamp';
export const CATS_FILE   = '/var/lib/truba/categories.json';
export const HEALTH_FILE = '/var/run/truba/health.json';
export const APPLIED_FILE = '/var/run/truba/applied.json';
export const NAT_FILE    = '/var/run/truba/nat.json';
export const TT_FILE     = '/var/run/truba/tunnel-test.json';
// История скорости для графика «Обзора» (truba.stats): точки по 5 с за час и поминутные за сутки.
export const RATES_FILE     = '/var/run/truba/rates.json';
export const RATES_MIN_FILE = '/var/run/truba/rates-min.json';
export const LISTS_STATE = '/etc/truba/state/lists.json';
export const DNSMASQ_BACKUP = '/etc/truba/state/dnsmasq.json';
export const UPNP_BACKUP = '/etc/truba/state/upnpd.json';

// Последняя удачная копия правил (ADR 0006) — на флеше: нужна после перезагрузки,
// когда применить настройки не удалось, а прежних правил в памяти уже нет.
export const GOOD_NFT    = '/etc/truba/good/truba.nft';
export const GOOD_MOSDNS  = '/etc/truba/good/mosdns.json';
export const GOOD_GEOSITE = '/etc/truba/good/geosite';
export const GOOD_META    = '/etc/truba/good/meta.json';

// Блокировки: применение настроек и Наборы правил.
export const LOCK_APPLY = 'truba';
export const LOCK_LISTS = 'truba-lists';

export const DAT_FILES = { geoip: 'geoip.dat', geosite: 'geosite.dat' };

export const ACTIONS = [ 'direct', 'tunnel', 'block' ];

export const CRON_BEGIN = '# truba-begin';
export const CRON_END   = '# truba-end';
