// Распаковщик на настоящих Наборах правил: ничего не теряется и не меняется.
// Выпуски — из tests/dat.pin (точные числа снимка) или свежие (DAT_FRESH=1: только структура).
//   ucode -L '/repo/router/truba/files/usr/share/ucode/*.uc' -L '/repo/tests/lib/*.uc' dat.uc <geoip.dat> <geosite.dat>
'use strict';

import * as D from 'truba.dat';
import * as T from 'tlib';

const check = T.check;
const geoip = ARGV[0], geosite = ARGV[1];
// Точные числа сняты со снимка 2026-10-04 (tests/dat.pin, TRUBA_SNAPSHOT).
const snapshot = (getenv('TRUBA_SNAPSHOT') == '2026-10-04');

let t0 = time();
let gs = D.parse_geosite(geosite);
let gi = D.parse_geoip(geoip);
print(sprintf('разбор: %d с\n', time() - t0));

let by = {}, kw = 0, rx = {};
for (let c in gs) {
	by[c.tag] = c;
	kw += c.types.keyword;
	for (let e in c.entries)
		if (index(e, 'regexp:') == 0)
			rx[e] = true;
}
let bad = filter(gs, c => c.types.regexp + c.types.full + c.types.keyword + c.types.domain != c.count);
check('geosite: у каждой Категории типы записей в сумме = числу записей', !length(bad), join(' ', map(bad, c => c.tag)));
check('geosite: тега ru нет, category-ru и category-ads есть',
	by['ru'] == null && by['category-ru']?.count > 0 && by['category-ads']?.count > 0);
check('geosite: regexp — 4 в netflix, 1 в private; keyword нет',
	by['netflix']?.types?.regexp == 4 && by['private']?.types?.regexp == 1 && kw == 0);
if (snapshot) {
	check('снимок: 61 Категория', length(gs) == 61, '' + length(gs));
	check('снимок: category-ru = 429, category-ads = 42535',
		by['category-ru']?.count == 429 && by['category-ads']?.count == 42535,
		sprintf('%d, %d', by['category-ru']?.count, by['category-ads']?.count));
	check('снимок: уникальных regexp 5, category-streaming несёт 4 из netflix',
		length(keys(rx)) == 5 && by['category-streaming']?.types?.regexp == 4);
}

let gby = {};
for (let c in gi)
	gby[c.tag] = c;
check('geoip: ru и private есть, ru без reverse_match', gby['ru']?.count > 0 && gby['private']?.count > 0 && gby['ru']?.reverse == false);
check('geoip: IPv4 ru — правильный CIDR', match(gby['ru']?.v4?.[0] ?? '', /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) != null,
	gby['ru']?.v4?.[0]);
if (snapshot)
	check('снимок: geoip — 2 Категории, ru = 35696 (IPv4 + IPv6), private = 17',
		length(gi) == 2 && gby['ru']?.count == 35696 && gby['private']?.count == 17);

// Полная распаковка: вложенность и файлы.
t0 = time();
let cats = D.unpack(geoip, geosite);
print(sprintf('распаковка: %d с\n', time() - t0));
let cby = {};
for (let c in cats)
	cby[c.set + ':' + c.tag] = c;
let sub = (a) => cby['geosite:' + a]?.subset_of ?? [];
check('вложенность: youtube ⊂ category-streaming, bank-ru ⊂ category-ru, category-ru ни в чём',
	('category-streaming' in sub('youtube')) && ('category-ru' in sub('bank-ru')) && cby['geosite:category-ru'] && !length(sub('category-ru')));
if (snapshot)
	check('снимок: hagezi не целиком в category-ads (2 домена hola.org)', !('category-ads' in sub('hagezi')));

let lines = D.geosite_entries('netflix');
check('файл netflix: строки один в один с записями', T.same(lines, by['netflix'].entries));
check('файл geoip ru: строк столько же, сколько IPv4', length(D.geoip_cidrs('ru')) == gby['ru'].count4);

T.finish();
