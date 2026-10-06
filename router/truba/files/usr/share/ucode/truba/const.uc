// Константы Трубы: метки, таблица маршрутов, пути.
'use strict';

export const MARK_TUNNEL  = 0x00010000;
export const MARK_DIRECT  = 0x00020000;
export const MARK_INBOUND = 0x00040000;
export const MARK_MASK    = 0x00ff0000;

export const RT_TABLE       = 77;
export const PRIO_RULE_MARK = 1000;
export const PRIO_RULE_OIF  = 1001;

export const NFT_TABLE = 'truba';

export const LISTS_DIR = '/etc/truba/lists';
export const PREV_DIR  = '/etc/truba/lists/prev';
export const STATE_DIR = '/etc/truba/state';
export const DATA_DIR  = '/var/lib/truba';
export const RUN_DIR   = '/var/run/truba';
export const ETC_DIR   = '/var/etc/truba';

export const MOSDNS_CONF = '/var/etc/truba/mosdns.json';
export const MOSDNS_DUMP = '/var/lib/truba/mosdns-cache.dump';
export const NFT_FILE    = '/var/etc/truba/truba.nft';
export const STAMP_FILE  = '/var/lib/truba/stamp';
export const CATS_FILE   = '/var/lib/truba/categories.json';
export const HEALTH_FILE = '/var/run/truba/health.json';
export const APPLIED_FILE = '/var/run/truba/applied.json';
export const LISTS_STATE = '/etc/truba/state/lists.json';
export const DNSMASQ_BACKUP = '/etc/truba/state/dnsmasq.json';
export const UPNP_BACKUP = '/etc/truba/state/upnpd.json';

export const DAT_FILES = { geoip: 'geoip.dat', geosite: 'geosite.dat' };

export const ACTIONS = [ 'direct', 'tunnel', 'block' ];

export const CRON_BEGIN = '# truba-begin';
export const CRON_END   = '# truba-end';
