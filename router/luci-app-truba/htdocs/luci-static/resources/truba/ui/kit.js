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

// Переключатель опции UCI. opt — «конфиг.секция.опция»: по нему тесты находят элемент.
function Switch({ label, checked, disabled, opt, onChange }) {
	const { html } = app.lib;
	return html`<label class="sw">
		<input type="checkbox" data-opt=${opt} checked=${!!checked} disabled=${!!disabled}
			onChange=${(ev) => onChange(ev.target.checked)} />
		<span>${label}</span>
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
// фокус идёт за ним (spec §4.3).
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
			onClick=${() => onChange(v)}>${l}</button>`)}
	</div>`;
}

// Фильтры-чипы: items — [ [ значение, подпись, число ], … ], нажат один.
function Chips({ items, value, onChange, label }) {
	const { html } = app.lib;
	return html`<div class="chips" role="group" aria-label=${label}>
		${items.map(([ v, l, n ]) => html`<button type="button" class="chip" aria-pressed=${String(v == value)}
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
// помечает поле неверным, и «Применить» недоступна. sid — для секций без имени.
function Field({ sec, key, sid, label, hint, msg, disabled }) {
	const { html, useState, useEffect } = app.lib;
	const s = sid || sec, opt = 'truba.%s.%s'.format(s, key);
	const saved = () => uci.get('truba', s, key) ?? '';
	const [ v, setV ] = useState(saved);
	// Выключенное поле не проверяется и показывает то, что в настройках: неверный ввод в нём не держит «Применить».
	useEffect(() => { if (disabled) setV(saved()); }, [ disabled ]);
	const err = disabled ? null : common.fieldError(sec, key, v.trim());
	useEffect(() => { app.invalid(opt, !!err); }, [ opt, !!err ]);
	useEffect(() => () => app.invalid(opt, false), [ opt ]);
	const onInput = (ev) => {
		const x = ev.target.value;
		setV(x);
		if (!common.fieldError(sec, key, x.trim()) && x.trim() !== saved())
			app.set('truba', s, key, x.trim() === '' ? null : x.trim());
	};
	const def = common.schema().sections?.[sec]?.[key]?.def;
	const changed = uci.state?.changes?.truba?.[s]?.[key] !== undefined;
	const id = 'f-' + s + '-' + key;
	return html`<div class=${'field' + (err ? ' bad' : '')}>
		<label for=${id}>${label}${changed ? html` <${Dot} level="warn" label=${_('changed, not applied yet')} />` : ''}</label>
		<input id=${id} data-opt=${opt} autocomplete="off" value=${v} disabled=${!!disabled}
			placeholder=${(def != null && typeof def != 'object') ? String(def) : ''}
			aria-invalid=${err ? 'true' : undefined} aria-describedby=${err ? id + '-e' : undefined} onInput=${onInput} />
		${err ? html`<div class="err-text" id=${id + '-e'} role="alert">${msg || err}</div>` : ''}
		${hint ? html`<div class="mu">${hint}</div>` : ''}
	</div>`;
}

// Сворачиваемый блок («Версии», «Настройки обновления»).
function Fold({ title, open, children }) {
	const { html } = app.lib;
	return html`<details class="fold" open=${!!open}><summary>${title}</summary><div class="fold-b">${children}</div></details>`;
}

// Подтверждение: родной <dialog> в верхнем слое — не зависит от container-type у .tr, фокус внутри
// окна и Esc — у браузера. Закрытие любым путём (Esc, «Отмена») — onClose.
function Dialog({ open, title, confirm, onConfirm, onClose, children }) {
	const { html, useRef, useEffect } = app.lib;
	const ref = useRef(null);
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
	return html`<dialog class="dlg" ref=${ref} onClose=${onClose}>
		<h3>${title}</h3>
		${children ? html`<div class="dlg-b">${children}</div>` : ''}
		<div class="acts">
			<button type="button" class="btn" data-act="cancel" onClick=${() => ref.current?.close()}>${_('Cancel')}</button>
			<button type="button" class="btn p" data-act="confirm" onClick=${yes}>${confirm}</button>
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
		return html`<div class="check-res err-text">${common.CHECK_ERRORS[r.error]
			? _('Not checked: %s').format(common.CHECK_ERRORS[r.error]) : _('The check failed.')}</div>`;
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
			.then((r) => setRes(r), () => setRes({ error: 'rpc' })).finally(() => setBusy(false));
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
	const { html, useRef, useLayoutEffect } = app.lib;
	const { n, bad } = app.use(app.changes);
	const ref = useRef(null);
	useLayoutEffect(() => {
		const el = ref.current, root = el?.parentElement;
		if (!el || !root)
			return;
		root.style.setProperty('--changes-h', (el.offsetHeight + 16) + 'px');
		return () => root.style.removeProperty('--changes-h');
	}, [ n, !!bad ]);
	if (!n)
		return null;
	return html`<div class="changes" role="status" ref=${ref}>
		<${Icon} name="pencil" />
		<span>${_('Unapplied changes: %d').format(n)}${bad ? html` · <b>${_('Fix the highlighted fields')}</b>` : ''}</span>
		<button type="button" class="btn" data-act="reset" onClick=${() => view.handleReset()}>${_('Reset')}</button>
		<button type="button" class="btn p" data-act="apply" disabled=${!!bad} onClick=${() => view.handleSaveApply(null, '0')}>${_('Apply')}</button>
	</div>`;
}

return baseclass.extend({ Card, Stat, Badge, Dot, Icon, Switch, Segmented, Chips, ActionTag, ShareBar, KV, Busy, Empty, Go, ChangesBar, step,
	ActionPicker, Field, Fold, Dialog, Toast, Check });
