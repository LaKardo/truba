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

// Один вариант из нескольких: items — [ [ значение, подпись ], … ].
function Segmented({ items, value, onChange, label }) {
	const { html } = app.lib;
	return html`<div class="seg" role="group" aria-label=${label}>
		${items.map(([ v, l ]) => html`<button type="button" aria-pressed=${String(v == value)} onClick=${() => onChange(v)}>${l}</button>`)}
	</div>`;
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

return baseclass.extend({ Card, Stat, Badge, Dot, Icon, Switch, Segmented, Busy, Empty, Go, ChangesBar });
