'use strict';
'require view';
'require uci';
'require truba.common as common';
'require truba.ui.app as app';
'require truba.ui.kit as kit';

// «Журнал» (spec §5.7): последние строки журнала Трубы, её watchdog, mosdns и интерфейса Туннеля — новые
// сверху. Фильтр — в браузере: уровень (порог) и источники. «Следить» спрашивает журнал раз в 5 с,
// «Скачать» сохраняет отфильтрованные строки. Настроек на вкладке нет. Страница — компоненты Preact
// в Shadow DOM (ADR 0017).

const LINES = 300;          // строк журнала — как на прежней «Диагностике»
const FOLLOW_MS = 5000;     // «Следить» — раз в 5 с
const SOURCES = [ 'truba', 'mosdns', 'watchdog', 'awg' ];

function fetchLog() {
	return common.callLog(LINES).then((t) => ({ lines: common.parseLog(t, common.tunnelIface()), error: null }));
}

// Ключ строки — она сама и номер её повтора: новые строки сверху не пересоздают прежние, и выделенный
// в журнале текст при «Следить» не сбрасывается.
function keyed(lines) {
	const seen = {};
	return lines.map((l) => ({ l, k: l.raw + '#' + (seen[l.raw] = (seen[l.raw] || 0) + 1) }));
}

// truba-log-ГГГГММДД-ЧЧММ.txt — по часам компьютера: файл сохраняет он.
function fileName(d) {
	const p = (n) => String(n).padStart(2, '0');
	return 'truba-log-%d%s%s-%s%s.txt'.format(d.getFullYear(), p(d.getMonth() + 1), p(d.getDate()), p(d.getHours()), p(d.getMinutes()));
}

// Строки — как их записал syslog, по порядку времени: в файле они нужны целиком, с датой и уровнем.
function download(lines) {
	const href = URL.createObjectURL(new Blob([ lines.map((l) => l.raw).join('\n') + '\n' ], { type: 'text/plain' }));
	E('a', { 'href': href, 'download': fileName(new Date()) }).click();
	setTimeout(() => URL.revokeObjectURL(href), 1000);
}

function Page({ first }) {
	const { html, useState, useEffect } = app.lib;
	const [ data, setData ] = useState(first);
	const [ offline, setOffline ] = useState(false);
	const [ level, setLevel ] = useState('all');
	const [ sources, setSources ] = useState(SOURCES);
	const [ follow, setFollow ] = useState(true);

	// Пока включено «Следить», журнал — раз в 5 с; ответ, пришедший после выключения, не показывается.
	useEffect(() => {
		// Без «Следить» журнал не спрашивается — и связи с Роутером не о чем судить.
		if (!follow) {
			setOffline(false);
			return;
		}
		let alive = true;
		const stop = app.every(() => fetchLog().then((d) => {
			if (alive) {
				setData(d);
				setOffline(false);
			}
		}, () => { if (alive) setOffline(true); }), FOLLOW_MS);
		return () => {
			alive = false;
			stop();
		};
	}, [ follow ]);

	const lines = data.lines || [];
	const shown = common.logShown(lines, level, sources);
	const count = (lv) => common.logShown(lines, lv, sources).length;
	const toggle = (s) => setSources((cur) => cur.includes(s) ? cur.filter((x) => x != s) : cur.concat([ s ]));
	return html`
		<div class="head">
			<h2>${_('Log', 'truba')}</h2>
			<span class="mu">${_('Truba, its watchdog, mosdns and the tunnel interface: the last %d lines, newest first.').format(LINES)}</span>
			${offline ? html`<${kit.Badge} level="err"><${kit.Icon} name="wifi-off" />${_('No connection to the router')}</${kit.Badge}>` : ''}
		</div>
		<div class="grid g2">
			<${kit.Card} cls="w3 log">
				<div class="log-bar">
					<${kit.Chips} label=${_('Level')} value=${level} onChange=${setLevel}
						items=${[ [ 'all', _('All'), count('all') ], [ 'warn', _('Warnings'), count('warn') ], [ 'err', _('Errors'), count('err') ] ]} />
					<${kit.Chips} label=${_('Sources')} value=${sources} onChange=${toggle}
						items=${SOURCES.map((s) => [ s, s, lines.filter((l) => l.source == s).length ])} />
					<div class="end">
						<${kit.Switch} label=${_('Follow', 'truba')} checked=${follow} onChange=${setFollow} />
						<button type="button" class="btn" data-act="download" disabled=${!shown.length} onClick=${() => download(shown)}>
							<${kit.Icon} name="download" />${_('Download')}</button>
					</div>
				</div>
				<div class="loglines">
					${data.error ? html`<${kit.Empty} text=${_('Error: %s').format(data.error)} />`
						: !shown.length ? html`<${kit.Empty} text=${_('Nothing to show.')} />`
						: keyed(shown).reverse().map(({ l, k }) => html`<div key=${k} class=${'ln ' + ((l.level == 'info') ? '' : l.level)} data-level=${l.level} data-source=${l.source}>
							<span>${l.time}</span><span>${l.src}</span><span>${l.text}</span></div>`)}
				</div>
			</${kit.Card}>
		</div>`;
}

return view.extend({
	load: function() {
		return Promise.all([ app.load(), common.loadSchema(), uci.load('truba') ]).then(() => fetchLog().catch((e) => ({ lines: [], error: e.message })));
	},

	render: function(first) {
		return app.mount(this, Page, { first });
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
