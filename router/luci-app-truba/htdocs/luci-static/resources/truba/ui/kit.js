'use strict';
'require baseclass';
'require uci';
'require truba.common as common';
'require truba.ui.app as app';
'require truba.ui.icons as icons';

// Компоненты интерфейса (spec §4.3) — на Preact + htm из app.lib. Здесь только то, что нужно уже
// построенным вкладкам; остальные компоненты добавляются вместе со своими вкладками.
// html и хуки берутся при отрисовке: app.lib заполняется в app.load(), позже загрузки модуля.

function Card({ title, aside, cls, children }) {
	const { html } = app.lib;
	return html`<section class=${'card ' + (cls || '')}>
		${(title || aside) ? html`<div class="card-h">${title ? html`<h3>${title}</h3>` : ''}${aside ? html`<span class="aside">${aside}</span>` : ''}</div>` : ''}
		${children}
	</section>`;
}

// Плитка «подпись — значение»; level красит значение (ok / warn / err / info).
function Stat({ label, value, level }) {
	const { html } = app.lib;
	return html`<div class="stat"><span class="mu">${label}</span><b class=${level || ''}>${value}</b></div>`;
}

function Badge({ level, children }) {
	const { html } = app.lib;
	return html`<span class=${'badge ' + (level || '')}>${children}</span>`;
}

// Точка уровня; label — когда она сама что-то сообщает («изменено»), иначе экранному чтецу она не нужна.
function Dot({ level, label }) {
	const { html } = app.lib;
	return label ? html`<span class=${'dot ' + (level || '')} role="img" aria-label=${label} title=${label}></span>`
		: html`<span class=${'dot ' + (level || '')} aria-hidden="true"></span>`;
}

function Icon({ name }) {
	const { html } = app.lib;
	return html`<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
		stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" dangerouslySetInnerHTML=${{ __html: icons[name] || '' }}></svg>`;
}

// Переключатель опции UCI. opt — «конфиг.секция.опция»: по нему тесты находят элемент. aria — имя для экранного
// чтеца, когда подписи мало (одинаковые переключатели в строках списка). Несохранённое изменение опции отмечено
// точкой, как у полей (spec §3.6); dot=false — у строки уже своя точка.
function Switch({ label, checked, disabled, opt, aria, dot, onChange }) {
	const { html } = app.lib;
	const [ c, s, o ] = (opt || '').split('.');
	const st = uci.state || {};
	const changed = dot !== false && !!o && (st.changes?.[c]?.[s]?.[o] !== undefined || (st.deletes?.[c]?.[s] || {})[o] !== undefined);
	return html`<label class="sw">
		<input type="checkbox" data-opt=${opt} aria-label=${aria} checked=${!!checked} disabled=${!!disabled}
			onChange=${(ev) => onChange(ev.target.checked)} />
		<span>${label}</span>${changed ? html`<${Dot} level="warn" label=${_('changed, not applied yet')} />` : ''}
	</label>`;
}

// Вариант по стрелке: → и ↓ — следующий, ← и ↑ — предыдущий, по кругу; другие клавиши — тот же.
function step(items, value, key) {
	const d = (key == 'ArrowRight' || key == 'ArrowDown') ? 1 : (key == 'ArrowLeft' || key == 'ArrowUp') ? -1 : 0;
	const n = items.length;
	if (!d || !n)
		return value;
	const i = items.findIndex(([ v ]) => v == value);
	return items[(((i < 0) ? (d > 0 ? -1 : 0) : i) + d + n) % n][0];
}

// Один вариант из нескольких: items — [ [ значение, подпись ], … ]. Стрелки переключают вариант,
// фокус идёт за ним (spec §4.3). Нажатие на уже выбранный — не изменение: uci.set записал бы его и с тем же значением.
function Segmented({ items, value, onChange, label, disabled }) {
	const { html } = app.lib;
	const onKey = (ev) => {
		const v = step(items, value, ev.key);
		if (disabled || v === value)
			return;
		ev.preventDefault();
		onChange(v);
		ev.currentTarget.querySelectorAll('button')[items.findIndex(([ x ]) => x == v)]?.focus();
	};
	return html`<div class="seg" role="group" aria-label=${label} onKeyDown=${onKey}>
		${items.map(([ v, l ]) => html`<button type="button" aria-pressed=${String(v == value)} disabled=${!!disabled}
			onClick=${() => { if (v != value) onChange(v); }}>${l}</button>`)}
	</div>`;
}

// Фильтры-чипы: items — [ [ значение, подпись, число ], … ], нажат один; value — массив: нажаты все его
// значения (источники «Журнала»), onChange получает нажатое и решает сам.
function Chips({ items, value, onChange, label }) {
	const { html } = app.lib;
	const on = (v) => Array.isArray(value) ? value.includes(v) : v == value;
	return html`<div class="chips" role="group" aria-label=${label}>
		${items.map(([ v, l, n ]) => html`<button type="button" class="chip" aria-pressed=${String(on(v))}
			onClick=${() => onChange(v)}>${l}${(n != null) ? html` <span class="n">${n}</span>` : ''}</button>`)}
	</div>`;
}

// Действие — подписью его цвета (один на всех вкладках, spec §4.1).
const TAG = { tunnel: 'tun', direct: 'dir', block: 'blk' };
function ActionTag({ action }) {
	const { html } = app.lib;
	return html`<span class=${'tag ' + (TAG[action] || '')}>${common.ACTION_LABELS[action] || action}</span>`;
}

// Доля Туннеля и Напрямую одной полосой; без трафика — пустая. span: полоса бывает внутри кнопки строки.
function ShareBar({ tunnel, direct }) {
	const { html } = app.lib;
	const all = (tunnel || 0) + (direct || 0);
	const pct = (x) => all ? Math.round(100 * (x || 0) / all) : 0;
	return html`<span class="bar" role="img" aria-label=${_('Tunnel %d%%, direct %d%%').format(pct(tunnel), pct(direct))}>
		<span class="t" style=${{ width: pct(tunnel) + '%' }}></span><span class="d" style=${{ width: pct(direct) + '%' }}></span>
	</span>`;
}

// «Название — значение»: rows — [ [ название, значение ], … ].
function KV({ rows }) {
	const { html } = app.lib;
	return html`<dl class="kv">${rows.map(([ k, v ]) => html`<dt>${k}</dt><dd>${v}</dd>`)}</dl>`;
}

// Идёт загрузка: класс spinning ждёт tests/luci/browser.js.
function Busy({ text }) {
	const { html } = app.lib;
	return html`<em class="spinning">${text}</em>`;
}

function Empty({ text }) {
	const { html } = app.lib;
	return html`<em class="empty">${text}</em>`;
}

// Ссылка на вкладку Трубы (или другую страницу LuCI) со стрелкой.
function Go({ tab, href, label }) {
	const { html } = app.lib;
	return html`<a class="go" href=${href || common.tabUrl(tab)}>${label || common.TABS[tab]}<${Icon} name="arrow-right" /></a>`;
}

// Действие Категории: сегменты «По режиму / Напрямую / Туннель / Блок»; на узком месте (до 600 px) —
// родной select в виде значка Действия, на телефоне он открывает системный выбор. В разметке оба,
// видимость переключает @container в style.css.
const PICK = [ 'mode', 'direct', 'tunnel', 'block' ];
function ActionPicker({ value, onChange, label }) {
	const { html } = app.lib;
	const items = PICK.map((a) => [ a, common.ACTION_LABELS[a] ]);
	return html`<span class=${'ap a-' + value}>
		<${Segmented} items=${items} value=${value} onChange=${onChange} label=${label} />
		<select class="ap-sel" aria-label=${label} value=${value} onChange=${(ev) => onChange(ev.target.value)}>
			${items.map(([ v, l ]) => html`<option value=${v} selected=${v == value}>${l}</option>`)}
		</select>
	</span>`;
}

// Поле опции по схеме (spec §3.6): подсказка — умолчание службы, ошибка — под полем. Верное значение
// пишется в UCI браузера (пустое — опция удаляется, служба берёт умолчание), неверное — нет: оно только
// помечает поле неверным, и «Применить» недоступна. name — опция (не key: его Preact забирает себе),
// sid — для секций без имени. Опции не Трубы (network: MTU, AWG) — config, своя проверка check(v) → текст
// или null и своя подсказка placeholder: в схеме службы их нет.
function Field({ config, sec, name, sid, label, hint, msg, disabled, check, placeholder }) {
	const { html, useState, useEffect, useRef } = app.lib;
	const ref = useRef(null);
	const c = config || 'truba', s = sid || sec, opt = '%s.%s.%s'.format(c, s, name);
	const saved = () => uci.get(c, s, name) ?? '';
	const errOf = (x) => check ? check(x) : common.fieldError(sec, name, x);
	const [ v, setV ] = useState(saved);
	const base = useRef(saved());   // значение на начало правки: при появлении поля и при каждом фокусе
	// Выключенное поле не проверяется и показывает то, что в настройках: неверный ввод в нём не держит «Применить».
	useEffect(() => { if (disabled) setV(saved()); }, [ disabled ]);
	const err = disabled ? null : errOf(v.trim());
	// Ошибка видна после паузы в наборе (или ухода из поля), а не на каждое нажатие: на «1» из «12:00» экранный
	// чтец объявлял бы её. «Применить» недоступна сразу — по err.
	const [ quiet, setQuiet ] = useState(false);
	const timer = useRef(null);
	useEffect(() => () => clearTimeout(timer.current), []);
	const settle = () => {
		clearTimeout(timer.current);
		setQuiet(false);
	};
	const shown = err && !quiet;
	useEffect(() => { app.invalid(opt, !!err); }, [ opt, !!err ]);
	useEffect(() => () => app.invalid(opt, false), [ opt ]);
	// Неверное поле в свёрнутом блоке (значение из настроек) — блок раскрывается: иначе «Применить»
	// недоступна без видимой причины.
	useEffect(() => { if (err) ref.current?.closest('details')?.setAttribute('open', ''); }, [ !!err ]);
	const onInput = (ev) => {
		const x = ev.target.value;
		setV(x);
		setQuiet(true);
		clearTimeout(timer.current);
		timer.current = setTimeout(settle, 800);
		const t = x.trim();
		if (!errOf(t)) {
			if (t !== saved())
				app.set(c, s, name, t === '' ? null : t);
		}
		// Неверное не пишется, а верное, набранное по пути к нему («900» на пути к «9000»), снимается: в настройках
		// остаётся то, что было на начало правки, — иначе «Сохранить» LuCI незаметно отправил бы промежуточное.
		else if (saved() !== base.current)
			app.set(c, s, name, base.current === '' ? null : base.current);
	};
	// Подсказка опции Трубы (без config) — умолчание схемы службы.
	const def = (placeholder != null) ? placeholder : !config ? common.schema().sections?.[sec]?.[name]?.def : null;
	const changed = uci.state?.changes?.[c]?.[s]?.[name] !== undefined;
	const id = 'f-' + c + '-' + s + '-' + name;
	return html`<div class=${'field' + (shown ? ' bad' : '')} ref=${ref}>
		<label for=${id}>${label}${changed ? html` <${Dot} level="warn" label=${_('changed, not applied yet')} />` : ''}</label>
		<input id=${id} data-opt=${opt} autocomplete="off" value=${v} disabled=${!!disabled}
			placeholder=${(def != null && typeof def != 'object') ? String(def) : ''}
			aria-invalid=${err ? 'true' : undefined} aria-describedby=${shown ? id + '-e' : undefined} onInput=${onInput} onBlur=${settle}
			onFocus=${() => { if (!err) base.current = saved(); }} />
		${shown ? html`<div class="err-text" id=${id + '-e'} role="alert">${msg || err}</div>` : ''}
		${hint ? html`<div class="mu">${hint}</div>` : ''}
	</div>`;
}

// Сворачиваемый блок («Версии», «Настройки обновления»).
function Fold({ title, open, children }) {
	const { html } = app.lib;
	return html`<details class="fold" open=${!!open}><summary>${title}</summary><div class="fold-b">${children}</div></details>`;
}

// Список DNS-серверов опции truba.sec.name (spec §4.3, §5.5): добавить, удалить, проверка адреса как у службы.
// Запрос идёт ко всем серверам пути сразу — порядка нет. Без списка в настройках действует умолчание схемы.
// Список, равный сохранённому (без учёта порядка), — не изменение; равный умолчанию при пустых настройках —
// снова без опции. Последний верный сервер не удаляется: без верных служба молча взяла бы умолчание.
// Адрес добавляется по Enter и «Add server», а набранный верный и не добавленный — при сохранении (app.flush):
// «Сохранить и применить» сразу после набора его не теряет. При уходе из поля страница не меняется — иначе
// сдвиг под нажатой кнопкой съедал бы клик. Неверный набранный держит «Применить», пока поле не очищено;
// повтор — нет: этот сервер уже в списке. Неверный адрес из сохранённых настроек служба пропускает — он
// помечен, и его можно удалить.
function UpstreamList({ sec, name, label }) {
	const { html, useState, useEffect, useRef } = app.lib;
	// Как служба (to_list): массив — как есть, строка (option вместо list) — один адрес, без деления по пробелам.
	const asList = (v) => (v == null) ? [] : Array.isArray(v) ? v : [ v ];
	const def = common.schema().sections?.[sec]?.[name]?.def || [];
	const list = asList(uci.get('truba', sec, name));
	const rows = list.length ? list : def;
	const savedRaw = uci.state?.values?.truba?.[sec]?.[name], saved = asList(savedRaw);
	const base = saved.length ? saved : def;
	const key = 'truba.%s.%s.new'.format(sec, name), id = 'ups-' + sec + '-' + name;
	const ul = useRef(null), inp = useRef(null);
	const [ text, setText ] = useState('');
	// Ошибка видна после Enter или «Add server», а её текст — по тому, что сейчас в поле и в списке: удалили
	// строку-повтор — ошибки больше нет.
	const [ tried, setTried ] = useState(false);
	const v = text.trim(), vErr = common.upstreamError(v), dup = !vErr && !!v && rows.includes(v);
	const err = !tried ? null : vErr || (dup ? _('This server is already in the list') : null);
	useEffect(() => { app.invalid(key, !!vErr); }, [ key, !!vErr ]);
	useEffect(() => () => app.invalid(key, false), [ key ]);
	const sameSet = (a, b) => a.length == b.length && a.every((x) => b.includes(x));
	// Набор, равный сохранённому, пишется самим сохранённым значением — app.set сравнит его как есть и снимет правку.
	const write = (arr) => app.set('truba', sec, name, sameSet(arr, base) ? (saved.length ? savedRaw : null) : arr);
	// quiet — при сохранении: неверное там не показывается (его держит проверка «Применить»), повтор просто убирается.
	const add = (quiet) => {
		if (!v)
			return;
		if (vErr || dup) {
			if (!quiet)
				setTried(true);
			else if (dup)
				setText('');
			return;
		}
		write([ ...rows, v ]);
		setText('');
		setTried(false);
	};
	const addNow = useRef(add);
	addNow.current = add;
	useEffect(() => app.onFlush(() => addNow.current(true)), []);
	const onKey = (ev) => {
		if (ev.key == 'Enter') {
			ev.preventDefault();
			add();
		}
	};
	// Без строки i остался бы хоть один верный сервер.
	const keeps = (i) => rows.some((x, j) => j != i && !common.upstreamError(x));
	// Удаляется одна строка (дубль — по одному). Фокус с удалённой кнопки — на соседнюю или в поле, а не в никуда.
	const remove = (i, ev) => {
		const had = ev.currentTarget == ev.currentTarget.getRootNode().activeElement;
		write(rows.filter((x, j) => j != i));
		if (had)
			requestAnimationFrame(() => {
				const bs = [ ...(ul.current?.querySelectorAll('[data-act="remove-upstream"]') || []) ].filter((b) => !b.disabled);
				(bs[Math.min(i, bs.length - 1)] || inp.current)?.focus();
			});
	};
	const lone = _('At least one valid server is needed');
	// Ключ строки — адрес и номер его повтора: удаление не переносит фокус и точки на соседнюю строку.
	const seen = {};
	return html`<div class="ups">
		<ul aria-label=${label} ref=${ul}>${rows.map((u, i) => {
			const n = seen[u] = (seen[u] || 0) + 1, off = !keeps(i);
			return html`<li key=${u + '#' + n}>
				<span class="ups-a"><code>${u}</code>${common.upstreamError(u)
					? html`<em class="err"><${Dot} level="err" />${_('invalid address, not used')}</em>` : ''}</span>
				${!common.upstreamError(u) && !base.includes(u) ? html`<${Dot} level="warn" label=${_('changed, not applied yet')} />` : ''}
				<button type="button" class="btn ic" data-act="remove-upstream" disabled=${off} title=${off ? lone : _('Remove')}
					aria-label=${off ? '%s — %s'.format(_('Remove %s').format(u), lone) : _('Remove %s').format(u)}
					onClick=${(ev) => remove(i, ev)}><${Icon} name="x" /></button>
			</li>`;
		})}</ul>
		${list.length ? '' : html`<div class="mu">${_('Default servers')}</div>`}
		<div class=${'ups-add' + (vErr ? ' bad' : '')}>
			<input data-act="new-upstream" ref=${inp} aria-label=${'%s: %s'.format(label, _('Server address'))} placeholder="https://… tls://… udp://…"
				autocomplete="off" spellcheck="false" value=${text} aria-invalid=${vErr ? 'true' : undefined} aria-describedby=${err ? id + '-e' : undefined}
				onInput=${(ev) => { setText(ev.target.value); setTried(false); }} onKeyDown=${onKey} />
			<button type="button" class="btn" data-act="add-upstream" aria-label=${'%s: %s'.format(label, _('Add server'))}
				onClick=${() => add()}><${Icon} name="plus" />${_('Add server')}</button>
		</div>
		${err ? html`<div class="err-text" id=${id + '-e'} role="alert">${err}</div>` : ''}
	</div>`;
}

// Файл или текст для импорта (router.conf): файл перетаскивают в зону или выбирают нажатием на неё, текст
// вставляют в поле под ней — на телефоне вставить можно только в поле ввода. onText получает текст;
// error — почему он не подошёл, под зоной.
const DROP_MAX = 64 * 1024;   // router.conf — меньше 1 КиБ; файл больше — не он

function DropZone({ label, accept, placeholder, error, onText }) {
	const { html, useState } = app.lib;
	const [ over, setOver ] = useState(false), [ text, setText ] = useState(''), [ own, setOwn ] = useState(null);
	const read = (f) => {
		if (!f)
			return;
		if (f.size > DROP_MAX) {
			setOwn(_('The file is too large for router.conf: %d KiB').format(Math.ceil(f.size / 1024)));
			return;
		}
		setOwn(null);
		f.text().then(onText, (e) => setOwn(_('The file cannot be read: %s').format(e?.message || e)));
	};
	const drop = (ev) => {
		ev.preventDefault();
		setOver(false);
		read(ev.dataTransfer?.files?.[0]);
	};
	// Файл, брошенный мимо зоны (на поле текста), браузер открыл бы вместо страницы.
	const block = (ev) => { if (ev.dataTransfer?.types?.includes?.('Files')) ev.preventDefault(); };
	return html`<div class="drop" onDragOver=${block} onDrop=${block}>
		<label class=${'zone' + (over ? ' over' : '')} onDragOver=${(ev) => { ev.preventDefault(); setOver(true); }}
				onDragLeave=${() => setOver(false)} onDrop=${drop}>
			<${Icon} name="file-up" /><span>${label}</span>
			<input type="file" accept=${accept} onChange=${(ev) => { read(ev.target.files[0]); ev.target.value = ''; }} />
		</label>
		<textarea name="conf" rows="3" autocomplete="off" spellcheck="false" aria-label=${placeholder} placeholder=${placeholder} value=${text}
			onInput=${(ev) => setText(ev.target.value)}></textarea>
		<div class="acts"><button type="button" class="btn" data-act="import" disabled=${!text.trim()} onClick=${() => onText(text)}>${_('Import')}</button></div>
		${(own || error) ? html`<div class="err-text" role="alert">${own || error}</div>` : ''}
	</div>`;
}

// Подтверждение: родной <dialog> в верхнем слое — не зависит от container-type у .tr, фокус внутри
// окна и Esc — у браузера. Закрытие любым путём (Esc, «Отмена») — onClose. disabled — подтверждение недоступно
// (в окне неверные поля).
let dialogs = 0;   // для id заголовка: окон на странице может быть несколько

function Dialog({ open, title, confirm, disabled, onConfirm, onClose, children }) {
	const { html, useRef, useEffect, useState } = app.lib;
	const ref = useRef(null);
	const [ id ] = useState(() => 'dlg-' + (++dialogs));
	useEffect(() => {
		const d = ref.current;
		if (!d)
			return;
		if (open && !d.open)
			d.showModal();
		else if (!open && d.open)
			d.close();
	}, [ open ]);
	const yes = () => {
		ref.current?.close();
		onConfirm();
	};
	return html`<dialog class="dlg" ref=${ref} onClose=${onClose} aria-labelledby=${id}>
		<h3 id=${id}>${title}</h3>
		${children ? html`<div class="dlg-b">${children}</div>` : ''}
		<div class="acts">
			<button type="button" class="btn" data-act="cancel" onClick=${() => ref.current?.close()}>${_('Cancel')}</button>
			<button type="button" class="btn p" data-act="confirm" disabled=${!!disabled} onClick=${yes}>${confirm}</button>
		</div>
	</dialog>`;
}

// Последнее сообщение app.toast; через 5 с скрывается. Область role="status" есть всегда: экранный
// чтец объявляет текст, который в неё приходит.
function Toast() {
	const { html, useState, useEffect } = app.lib;
	const { text, id } = app.use(app.toasts);
	const [ shown, setShown ] = useState(0);
	useEffect(() => {
		if (!id)
			return;
		setShown(id);
		const t = setTimeout(() => setShown(0), 5000);
		return () => clearTimeout(t);
	}, [ id ]);
	return html`<div class="toasts" role="status">${(shown && shown == id) ? html`<div class="toast">${text}</div>` : ''}</div>`;
}

// Итог check: цель → Действие · причина; full — ещё Категории geosite домена и адреса.
function CheckResult({ r, full }) {
	const { html } = app.lib;
	if (r.error || !r.action)
		return html`<div class="check-res err-text">${common.checkErrorText(r)}</div>`;
	const reason = (v) => (common.REASON_LABELS[v.reason] || v.reason) + (v.device ? ' (%s)'.format(v.device) : '');
	const hits = r.geosite || [], ips = r.ips || [];
	return html`<div class="check-res">
		<div class="res"><b>${r.target}</b> → <${ActionTag} action=${r.action} /> <span class="mu">${reason(r)}</span></div>
		${(full && r.kind == 'domain') ? html`
			<h4 class="sub">${_('geosite categories containing the domain')}</h4>
			${hits.length ? html`<div class="hits">${hits.map((h) => html`<div class="hit">
				<b>${h.tag}${(r.decisive?.tag == h.tag) ? ' ✓' : ''}</b><code>${h.entry}</code><${ActionTag} action=${h.action} />
			</div>`)}</div>` : html`<${Empty} text=${_('none')} />`}
			${r.decisive ? html`<div class="mu">${_('Decisive category (the narrowest one with an explicit action): %s').format(r.decisive.tag)}</div>` : ''}` : ''}
		${(full && ips.length) ? html`<${Fold} title=${_('Addresses (%d)').format(ips.length)}>
			${ips.map((v) => html`<div class="hit"><b>${v.ip}</b><span class="mu">${(v.geoip || []).join(', ') || '—'}</span>
				<${ActionTag} action=${v.action} /><span class="mu">${reason(v)}</span></div>`)}
		</${Fold}>` : ''}
	</div>`;
}

// «Проверить домен/IP» (spec §5.3): та же проверка службы, что видит новое соединение. mac — для одного
// устройства (с его Политикой), без него — для всех; full — с Категориями и адресами.
function Check({ mac, full }) {
	const { html, useState } = app.lib;
	const [ q, setQ ] = useState(''), [ res, setRes ] = useState(null), [ busy, setBusy ] = useState(false);
	const run = (ev) => {
		ev.preventDefault();
		const t = q.trim();
		if (!t || busy)
			return;
		setBusy(true);
		// Без MAC (для всех устройств, узел mesh-VPN) аргумент mac не передаётся вовсе: rpcd отклоняет null вместо строки.
		(mac ? common.callCheck(t, mac) : common.callCheck(t))
			.then((r) => setRes(r), (e) => setRes({ error: 'rpc', message: e?.message })).finally(() => setBusy(false));
	};
	return html`<form class="check" onSubmit=${run}>
		<input name="target" autocomplete="off" aria-label=${_('Domain or IP')}
			placeholder=${full ? _('domain or IPv4, e.g. gosuslugi.ru') : _('domain or IP')} value=${q} onInput=${(ev) => setQ(ev.target.value)} />
		<button type="submit" class="btn" disabled=${busy}>${_('Check')}</button>
	</form>
	${busy ? html`<${Busy} text=${_('Checking…')} />` : res ? html`<${CheckResult} r=${res} full=${full} />` : ''}`;
}

// Несохранённые изменения страницы: «Применить» — то же, что «Сохранить и применить» LuCI (с откатом),
// «Сбросить» — перечитать страницу. Без изменений панели нет. Пока есть неверные поля, «Применить»
// недоступна (spec §3.6).
// Высота панели — в --changes-h у корня страницы: на телефоне панель устройства, тоже прилипшая к низу
// экрана, поднимается над ней, а не прячется под ней.
function ChangesBar({ view }) {
	const { html, useRef, useLayoutEffect, useState } = app.lib;
	const { n, bad } = app.use(app.changes);
	const ref = useRef(null);
	// Пока изменения сохраняются, кнопки недоступны: второе нажатие запустило бы второе применение. Отказ
	// сохранения — текстом на панели, а не необработанной ошибкой. busy — и ref: два нажатия в одном кадре
	// приходят раньше перерисовки.
	const busy = useRef(false), [ , setBusy ] = useState(false), [ err, setErr ] = useState(null);
	const run = (fn) => {
		if (busy.current)
			return;
		busy.current = true;
		setBusy(true);
		setErr(null);
		Promise.resolve().then(fn).catch((e) => setErr(e?.message || String(e))).finally(() => {
			busy.current = false;
			setBusy(false);
		});
	};
	useLayoutEffect(() => {
		const el = ref.current, root = el?.parentElement;
		if (!el || !root)
			return;
		root.style.setProperty('--changes-h', (el.offsetHeight + 16) + 'px');
		return () => root.style.removeProperty('--changes-h');
	}, [ n, !!bad ]);
	if (!n)
		return null;
	// К первому неверному полю: блок с ним раскрывается, фокус — в поле.
	const showBad = () => {
		const el = ref.current?.parentElement?.querySelector('[aria-invalid="true"]');
		el?.closest('details')?.setAttribute('open', '');
		el?.focus();
	};
	return html`<div class="changes" role="status" ref=${ref}>
		<${Icon} name="pencil" />
		<span>${_('Unapplied changes: %d').format(n)}${bad ? html` · <button type="button" class="link" data-act="show-bad" onClick=${showBad}>${_('Fix the highlighted fields')}</button>` : ''}</span>
		<button type="button" class="btn" data-act="reset" disabled=${busy.current} onClick=${() => run(() => view.handleReset())}>${_('Reset')}</button>
		<button type="button" class="btn p" data-act="apply" disabled=${!!bad || busy.current}
			onClick=${() => run(() => view.handleSaveApply(null, '0'))}>${_('Apply')}</button>
		${err ? html`<span class="err-text" role="alert">${_('The changes were not saved: %s').format(err)}</span>` : ''}
	</div>`;
}

return baseclass.extend({ Card, Stat, Badge, Dot, Icon, Switch, Segmented, Chips, ActionTag, ShareBar, KV, Busy, Empty, Go, ChangesBar, step,
	ActionPicker, Field, Fold, UpstreamList, DropZone, Dialog, Toast, Check });
