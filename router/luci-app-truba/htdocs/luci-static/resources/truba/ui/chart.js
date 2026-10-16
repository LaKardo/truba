'use strict';
'require baseclass';
'require truba.common as common';
'require truba.ui.app as app';

// Графики на uPlot (ADR 0017): скорость за срок и мини-график задержки. uPlot рисует на холсте —
// цвета берутся из токенов стиля при создании, а при смене светлого и тёмного режима график
// создаётся заново (app.scheme).

// Верх шкалы — круглое число бит/с (1, 2, 5 × 10ⁿ), не меньше 1 Мбит/с. Вход и выход — байт/с.
function scaleTop(peak) {
	const bits = Math.max(peak * 8, 1e6);
	const p = Math.pow(10, Math.floor(Math.log10(bits)));
	return [ 1, 2, 5, 10 ].find((k) => bits <= k * p) * p / 8;
}

// Строка-разрыв [t] там, где точек нет дольше трёх шагов (служба стояла, процесс stats не писал):
// uPlot рвёт линию только на null, а в поминутных средних отметки разрыва нет — только пропуск
// по времени. Без этого график провёл бы прямую через время, когда скорость не записывалась.
function gaps(points, step) {
	const out = [];
	for (let p of points) {
		const prev = out[out.length - 1];
		if (prev && p[0] - prev[0] > 3 * step)
			out.push([ prev[0] + step ]);
		out.push(p);
	}
	return out;
}

// Токен стиля (--tun, --mu…) с корня страницы: переменные наследуются внутрь Shadow DOM.
function token(el, name) {
	return getComputedStyle(el).getPropertyValue('--' + name).trim();
}

// uPlot спрашивает цвет легенды ещё до вычисления области графика.
function areaFill(u, rgb) {
	if (!Number.isFinite(u.bbox.top) || !Number.isFinite(u.bbox.height))
		return `rgba(${rgb},0.14)`;
	const g = u.ctx.createLinearGradient(0, u.bbox.top, 0, u.bbox.top + u.bbox.height);
	g.addColorStop(0, `rgba(${rgb},0.22)`);
	g.addColorStop(1, `rgba(${rgb},0.02)`);
	return g;
}

// uPlot в своём блоке: создаётся при монтировании и при смене режима (deps), данные — на каждую отрисовку.
function usePlot(make, data, deps) {
	const { useRef, useEffect } = app.lib;
	const box = useRef(null), plot = useRef(null);
	useEffect(() => {
		const el = box.current;
		plot.current = new app.lib.uPlot(make(el), data, el);
		// Ширина — по блоку: на телефоне и при смене колонок сетки.
		const ro = new ResizeObserver(() => {
			if (plot.current && el.clientWidth)
				plot.current.setSize({ width: el.clientWidth, height: plot.current.height });
		});
		ro.observe(el);
		return () => {
			ro.disconnect();
			plot.current.destroy();
			plot.current = null;
		};
	}, deps);
	useEffect(() => {
		if (plot.current)
			plot.current.setData(data);
	});
	return box;
}

// Временной ряд: series — [{ label, color: 'tun'|'dir', dash }], data — [ время, с; ряды, байт/с ],
// null — разрыв линии. Ось X — [from, to]: время Роутера, а не компьютера. Значения в точке под
// курсором — в легенде uPlot под графиком.
function TimeChart({ series, data, from, to, height }) {
	const { html, useRef } = app.lib;
	const { scheme } = app.use(app.scheme);
	const lim = useRef();
	lim.current = { from, to };
	const h = height || 140;
	const box = usePlot((el) => {
		const mu = token(el, 'mu'), bd = token(el, 'bd'), font = '11px system-ui, sans-serif';
		return {
			width: el.clientWidth || 300,
			height: h,
			cursor: { points: { show: false }, drag: { x: false, y: false } },
			select: { show: false },
			legend: { show: true, live: true },
			scales: {
				x: { time: true, range: () => [ lim.current.from, lim.current.to ] },
				y: { range: (u, min, max) => [ 0, scaleTop(max || 0) ] }
			},
			axes: [
				// Время — часы и минуты, не чаще чем через 70 точек: подписи uPlot по умолчанию с секундами
				// и датой для графика на 10 минут слишком часты.
				{ stroke: mu, font, space: 70, grid: { show: false }, ticks: { show: false },
					values: (u, vals) => vals.map((v) => new Date(v * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })) },
				{ stroke: mu, font, size: 76, grid: { stroke: bd, width: 1, dash: [ 2, 4 ] }, ticks: { show: false },
					values: (u, vals) => vals.map((v) => common.fmtRate(v)) }
			],
			series: [
				{ label: '', value: (u, v) => (v == null) ? '—' : new Date(v * 1000).toLocaleTimeString() },
				...series.map((s) => {
					const c = token(el, s.color);
					// Canvas поддерживает CSS Color 4 не во всех версиях браузеров LuCI.
					const sample = document.createElement('canvas').getContext('2d');
					sample.fillStyle = c;
					sample.fillRect(0, 0, 1, 1);
					const rgb = Array.from(sample.getImageData(0, 0, 1, 1).data).slice(0, 3).join(',');
					return {
						label: s.label, stroke: c, width: 1.75, dash: s.dash ? [ 5, 3 ] : undefined,
						// Заливка — только под линией «к устройствам»: две заливки одного цвета сливаются.
						fill: s.dash ? undefined : (u) => areaFill(u, rgb),
						value: (u, v) => (v == null) ? '—' : common.fmtRate(v)
					};
				})
			]
		};
	}, data, [ scheme, series.length, h ]);
	return html`<div class="chart-box" ref=${box}></div>`;
}

// Мини-график без осей: values — числа или null (разрыв).
function Spark({ values, color, height }) {
	const { html } = app.lib;
	const { scheme } = app.use(app.scheme);
	const h = height || 40;
	const data = [ values.map((v, i) => i), values ];
	const box = usePlot((el) => ({
		width: el.clientWidth || 200,
		height: h,
		legend: { show: false },
		cursor: { show: false },
		select: { show: false },
		axes: [ { show: false }, { show: false } ],
		scales: {
			x: { time: false },
			y: { range: (u, min, max) => [ Math.max(0, (min || 0) * 0.8), ((max || 0) * 1.2) || 1 ] }
		},
		series: [ {}, { stroke: token(el, color || 'tun'), width: 1.5 } ]
	}), data, [ scheme, h ]);
	return html`<div class="spark" ref=${box}></div>`;
}

return baseclass.extend({ scaleTop, gaps, areaFill, TimeChart, Spark });
