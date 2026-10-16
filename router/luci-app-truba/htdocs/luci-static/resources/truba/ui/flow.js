'use strict';
'require baseclass';
'require truba.common as common';
'require truba.ui.app as app';

// Схема потоков «Устройства → Роутер → Туннель / Напрямую». Толщина ветки — по скорости,
// бегущий пунктир — направление. Две раскладки: широкая и узкая для телефона — одна SVG на 600 точек
// в ширину телефона сжала бы подписи до нечитаемых; какая видна, решает контейнерный запрос в style.css.

// Толщина линии: корень доли от самой быстрой ветки (тонкие ветки остаются видны), от 2 до 14.
// Масштаб не меньше 1 Мбит/с: фоновые DNS и keepalive не выглядят полной загрузкой.
function width(rate, top) {
	return (rate > 0) ? 2 + 12 * Math.min(1, Math.sqrt(rate / Math.max(top, 125000))) : 0;
}

// Узлы — [x, y, ширина, высота], ветки — пути SVG.
const LAYOUTS = {
	wide: {
		box: '0 0 600 200',
		dev: [ 18, 72, 110, 56 ], router: [ 238, 67, 100, 66 ], tun: [ 462, 12, 126, 66 ], dir: [ 462, 122, 126, 66 ],
		in: 'M128 100 C180 100 190 100 238 100', ltun: 'M338 92 C400 92 400 45 462 45', ldir: 'M338 108 C400 108 400 155 462 155'
	},
	narrow: {
		box: '0 0 320 250',
		dev: [ 100, 4, 120, 46 ], router: [ 110, 86, 100, 50 ], tun: [ 4, 176, 150, 66 ], dir: [ 166, 176, 150, 66 ],
		in: 'M160 50 L160 86', ltun: 'M145 136 C145 160 79 156 79 176', ldir: 'M175 136 C175 160 241 156 241 176'
	}
};

const LINE = 17;   // шаг строк подписи узла

function node(html, [ x, y, w, h ], cls, rx, title, titleCls, lines) {
	const n = 1 + lines.length, cx = x + w / 2, top = y + h / 2 - (n - 1) * LINE / 2 + 4;
	return html`
		<rect x=${x} y=${y} width=${w} height=${h} rx=${rx} class=${cls} />
		<text x=${cx} y=${top} text-anchor="middle" font-size="13" class=${titleCls}>${title}</text>
		${lines.map(([ text, c ], i) => html`<text x=${cx} y=${top + (i + 1) * LINE} text-anchor="middle" font-size="12" class=${c || ''}>${text}</text>`)}`;
}

function branch(html, d, cls, w) {
	if (!w)
		return html`<path d=${d} class=${'base ' + cls} stroke-width="1" />`;
	return html`<path d=${d} class=${'base ' + cls} stroke-width=${w.toFixed(1)} /><path d=${d} class=${'an ' + cls} />`;
}

// devices — число активных устройств или null (пока его нет), block — сумма отброшенных пакетов и DNS-блокировок,
// tunnel и direct — [ к устройствам, от устройств ] в байт/с или null, caption — подпись под схемой.
function Flow({ devices, block, tunnel, direct, caption }) {
	const { html } = app.lib;
	const sum = (p) => p ? (p[0] || 0) + (p[1] || 0) : 0;
	const t = sum(tunnel), d = sum(direct), top = Math.max(t, d, 125000);
	const w = { in: width(t + d, t + d), tun: width(t, top), dir: width(d, top) };
	const rates = (p) => p ? [ [ '↓ ' + common.fmtRate(p[0]) ], [ '↑ ' + common.fmtRate(p[1]) ] ] : [ [ '—', 't-mu' ] ];
	const svg = (name) => {
		const L = LAYOUTS[name];
		return html`<svg class=${'flow ' + name} viewBox=${L.box} role="img" aria-label=${_('Where traffic goes')}>
			${branch(html, L.in, 'l-in', w.in)}
			${branch(html, L.ltun, 'l-tun', w.tun)}
			${branch(html, L.ldir, 'l-dir', w.dir)}
			${node(html, L.dev, 'node', 10, _('Devices'), '', (devices != null) ? [ [ _('%d active').format(devices), 't-mu' ] ] : [])}
			${node(html, L.router, 'router', 12, _('Router'), '', [ [ _('block: %s').format(common.fmtNum(block)), 't-blk' ] ])}
			${node(html, L.tun, 'n-tun', 10, _('Tunnel'), 't-tun', rates(tunnel))}
			${node(html, L.dir, 'n-dir', 10, _('Direct'), 't-dir', rates(direct))}
		</svg>`;
	};
	return html`<div class="flow-box">${svg('wide')}${svg('narrow')}<div class="mu flow-cap">${caption}</div></div>`;
}

return baseclass.extend({ width, Flow });
