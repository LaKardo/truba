// Дописать Категорию в Набор правил (нет файла — создать). В protobuf повторяющееся поле можно
// дописать в конец: файл остаётся правильным, но это другая версия с другим хешем.
//   ucode -L '/repo/tests/lib/*.uc' mkdat.uc geosite FILE TAG domain:x full:y regexp:z …
//   ucode -L '/repo/tests/lib/*.uc' mkdat.uc geoip FILE TAG 198.18.0.0/24 …
'use strict';

import { readfile, writefile } from 'fs';
import * as T from 'tlib';

const set = ARGV[0], path = ARGV[1], tag = ARGV[2], items = slice(ARGV, 3);
if (!(set in [ 'geosite', 'geoip' ]) || !path || !tag || !length(items))
	die('usage: mkdat.uc geosite|geoip FILE TAG ENTRY…');

writefile(path, (readfile(path) ?? '') + ((set == 'geosite') ? T.geosite_cat(tag, items) : T.geoip_cat(tag, items)));
