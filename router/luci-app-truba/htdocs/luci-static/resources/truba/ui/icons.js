'use strict';
'require baseclass';

// Иконки: lucide-static 1.55.0 (ISC, текст — lib/LICENSES/lucide.txt), только нужные интерфейсу.
// Внутренняя разметка SVG 24×24 с обводкой currentColor — её оборачивает kit.Icon.
return baseclass.extend({
	'circle-check': '<circle cx="12" cy="12" r="10" /><path d="m16 9-5.5 5.5L8 12" />',
	'triangle-alert': '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3" /><path d="M12 9v4" /><path d="M12 17h.01" />',
	'circle-x': '<circle cx="12" cy="12" r="10" /><path d="m15 9-6 6" /><path d="m9 9 6 6" />',
	'arrow-right': '<path d="M5 12h14" /><path d="m12 5 7 7-7 7" />',
	'wifi-off': '<path d="M12 20h.01" /><path d="M8.5 16.429a5 5 0 0 1 7 0" /><path d="M5 12.859a10 10 0 0 1 5.17-2.69" /><path d="M19 12.859a10 10 0 0 0-2.007-1.523" /><path d="M2 8.82a15 15 0 0 1 4.177-2.643" /><path d="M22 8.82a15 15 0 0 0-11.288-3.764" /><path d="m2 2 20 20" />',
	'pencil': '<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z" /><path d="m15 5 4 4" />'
});
