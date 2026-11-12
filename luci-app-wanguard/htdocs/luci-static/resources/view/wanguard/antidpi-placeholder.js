/* WAN Guard Anti-DPI placeholder (issue #79) — the stub tab rendered when
 * luci-app-wanguard is installed WITHOUT the wanguard-antidpi add-on. The
 * real page comes from the add-on package: its menu.d file
 * (wanguard-antidpi.json) sorts AFTER this package's luci-app-wanguard.json,
 * so its node merges over this stub per field and this view is only
 * reachable while the add-on is absent. Self-contained by contract: no
 * rpcd calls, no poll, no data — an honest inactive tab. */
'use strict';
'require view';

return view.extend({
	render: function() {
		return E('div', { 'class': 'wg-antidpi-placeholder' }, [
			E('h2', {}, [ _('Anti-DPI') ]),
			E('div', { 'class': 'alert-message warning' }, [
				E('p', {}, [
					_('The Anti-DPI tab is inactive: the wanguard-antidpi package is not installed.')
				]),
				E('p', {}, [
					_('Install it from the wanguard apk feed: '),
					E('code', {}, [ 'apk update && apk add wanguard-antidpi' ]),
					'.'
				]),
				E('p', {}, [
					E('a', {
						'href': 'https://github.com/sers88/wanguard-antidpi#readme',
						'target': '_blank',
						'rel': 'noreferrer'
					}, [ _('wanguard-antidpi README') ])
				])
			])
		]);
	}
});
