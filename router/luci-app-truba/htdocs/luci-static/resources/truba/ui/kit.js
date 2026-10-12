'use strict';
'require baseclass';
'require truba.common as common';
'require truba.ui.app as app';
'require truba.ui.icons as icons';

// Компоненты интерфейса (spec §4.3) — на Preact + htm из app.lib. Здесь только то, что нужно уже
// построенным вкладкам; остальные компоненты добавляются вместе со своими вкладками.
// html и хуки берутся при отрисовке: app.lib заполняется в app.load(), позже загрузки модуля.

function Card({ title, aside, cls, children }) {
	const { html } = app.lib;
	return html`<section class=${'card ' + (cls || '')}>
		${(title || aside) ? html`<div class="card-h"><h3>${title}</h3>${aside ? html`<span class="aside">${aside}</span>` : ''}</div>` : ''}
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

function Dot({ level }) {
	const { html } = app.lib;
	return html`<span class=${'dot ' + (level || '')} aria-hidden="true"></span>`;
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

// Доля Туннеля и Напрямую одной полосой; без трафика — пустая.
function ShareBar({ tunnel, direct }) {
	const { html } = app.lib;
	const all = (tunnel || 0) + (direct || 0);
	const pct = (x) => all ? Math.round(100 * (x || 0) / all) : 0;
	return html`<div class="bar" role="img" aria-label=${_('Tunnel %d%%, direct %d%%').format(pct(tunnel), pct(direct))}>
		<span class="t" style=${{ width: pct(tunnel) + '%' }}></span><span class="d" style=${{ width: pct(direct) + '%' }}></span>
	</div>`;
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

// Несохранённые изменения страницы: «Применить» — то же, что «Сохранить и применить» LuCI (с откатом),
// «Сбросить» — перечитать страницу. Без изменений панели нет.
function ChangesBar({ view }) {
	const { html } = app.lib;
	const { n } = app.use(app.changes);
	if (!n)
		return null;
	return html`<div class="changes" role="status">
		<${Icon} name="pencil" />
		<span>${_('Unapplied changes: %d').format(n)}</span>
		<button type="button" class="btn" data-act="reset" onClick=${() => view.handleReset()}>${_('Reset')}</button>
		<button type="button" class="btn p" data-act="apply" onClick=${() => view.handleSaveApply(null, '0')}>${_('Apply')}</button>
	</div>`;
}

return baseclass.extend({ Card, Stat, Badge, Dot, Icon, Switch, Segmented, Chips, ActionTag, ShareBar, KV, Busy, Empty, Go, ChangesBar, step });
