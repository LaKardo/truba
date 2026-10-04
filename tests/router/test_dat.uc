// Проверка распаковщика на реальных .dat: ничего не теряется и не меняется.
// Запуск: ucode -L /path/to/ucode tests/router/test_dat.uc <geoip.dat> <geosite.dat>
'use strict';

import * as D from 'truba.dat';
import { readfile } from 'fs';

let geoip = ARGV[0], geosite = ARGV[1];
let fails = 0;

function check(name, cond, detail) {
	if (cond) {
		print('ok   ', name, '\n');
	}
	else {
		print('FAIL ', name, detail ? (' — ' + detail) : '', '\n');
		fails++;
	}
}

let t0 = time();
let gs = D.parse_geosite(geosite);
let gi = D.parse_geoip(geoip);
print(sprintf('parse: %d s\n', time() - t0));

let by = {};
for (let c in gs) by[c.tag] = c;
let kw = 0, rx_unique = {};
for (let c in gs) {
	kw += c.types.keyword;
	for (let e in c.entries)
		if (index(e, 'regexp:') == 0)
			rx_unique[e] = true;
	check('geosite ' + c.tag + ': типы в сумме = числу записей',
		c.types.regexp + c.types.full + c.types.keyword + c.types.domain == c.count);
}

// Точные числа сняты с файлов release-ветки от 2026-10-04 и проверяются только на них
// (TRUBA_SNAPSHOT=2026-10-04); списки обновляются ежедневно, поэтому в CI — только структура.
const snapshot = (getenv('TRUBA_SNAPSHOT') == '2026-10-04');
check('geosite: тега ru нет', by['ru'] == null);
check('geosite: category-ru есть', by['category-ru']?.count > 0);
check('geosite: category-ads есть', by['category-ads']?.count > 0);
check('geosite: есть regexp-записи', length(keys(rx_unique)) > 0);
if (snapshot) {
	check('снимок: 61 категория', length(gs) == 61, 'получено ' + length(gs));
	check('снимок: category-ru = 429', by['category-ru']?.count == 429, '' + by['category-ru']?.count);
	check('снимок: category-ads = 42535', by['category-ads']?.count == 42535, '' + by['category-ads']?.count);
	check('снимок: уникальных regexp 5', length(keys(rx_unique)) == 5, '' + length(keys(rx_unique)));
	check('снимок: category-streaming несёт 4 regexp из netflix', by['category-streaming']?.types?.regexp == 4);
}
check('geosite: netflix regexp = 4', by['netflix']?.types?.regexp == 4);
check('geosite: private regexp = 1', by['private']?.types?.regexp == 1);
check('geosite: keyword нет', kw == 0, '' + kw);

let gby = {};
for (let c in gi) gby[c.tag] = c;
check('geoip: есть ru и private', gby['ru']?.count > 0 && gby['private']?.count > 0);
if (snapshot) {
	check('снимок: geoip 2 категории', length(gi) == 2, '' + length(gi));
	check('снимок: geoip ru = 35696 (IPv4+IPv6)', gby['ru']?.count == 35696, '' + gby['ru']?.count);
	check('снимок: geoip private = 17', gby['private']?.count == 17, '' + gby['private']?.count);
}
check('geoip: ru без reverse_match', gby['ru']?.reverse == false);
check('geoip: первый IPv4 ru — корректный CIDR',
	match(gby['ru']?.v4?.[0] ?? '', /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) != null, gby['ru']?.v4?.[0]);
print(sprintf('geoip ru: %d IPv4, %d IPv6\n', gby['ru']?.count4, gby['ru']?.count6));

// Полная распаковка с вложенностью и записью файлов.
t0 = time();
let cats = D.unpack(geoip, geosite);
print(sprintf('unpack: %d s\n', time() - t0));
let cby = {};
for (let c in cats) cby[c.set + ':' + c.tag] = c;
check('вложенность: youtube ⊂ category-streaming',
	'category-streaming' in (cby['geosite:youtube']?.subset_of ?? []));
if (snapshot)
	check('снимок: hagezi НЕ целиком в category-ads (2 домена hola.org)',
		!('category-ads' in (cby['geosite:hagezi']?.subset_of ?? [])));
check('вложенность: bank-ru ⊂ category-ru',
	'category-ru' in (cby['geosite:bank-ru']?.subset_of ?? []));
check('вложенность: category-ru ни в чём', length(cby['geosite:category-ru']?.subset_of ?? [ 'x' ]) == 0);

// Файл = записи один в один.
let lines = D.geosite_entries('netflix');
check('файл netflix: столько же строк, сколько записей', length(lines) == by['netflix'].count);
let same = true;
for (let i = 0; i < length(lines); i++)
	if (lines[i] != by['netflix'].entries[i]) same = false;
check('файл netflix: строки совпадают с записями', same);
check('файл netflix: regexp-записи на месте',
	length(filter(lines, l => index(l, 'regexp:') == 0)) == by['netflix'].types.regexp);
check('файл geoip ru: число строк = IPv4', length(D.geoip_cidrs('ru')) == gby['ru'].count4);

print(fails ? sprintf('\n%d FAILED\n', fails) : '\nALL OK\n');
exit(fails ? 1 : 0);
