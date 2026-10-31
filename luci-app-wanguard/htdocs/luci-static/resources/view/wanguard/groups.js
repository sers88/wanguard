/* WAN Guard groups & routes page (issue #46) — the groups grid with the
 * allocation preview, the direct-lb member/weight modal (#40) and the
 * non-empty-group delete guard, on its own URL-deep-linkable page.
 * load() fetches `wanguard grouplist` so _alloc shows authoritative
 * device state for direct-lb slots. All logic lives in the shared
 * wanguard.core module. */
'use strict';
'require view';
'require poll';
'require wanguard.core as wg';

return view.extend({
	load: function() {
		return wg.load();
	},

	render: function() {
		var self = this;

		var statusNode = E('div', { 'style': 'margin-bottom:1em' });
		wg.updateStatusNode(statusNode);
		wg.state.statusNode = statusNode;
		this._statusNode = statusNode;

		this._map = wg.buildGroupsGrid().map;

		return this._map.render().then(function(mapNode) {
			poll.add(function() {
				return wg.refreshStatus(self._statusNode);
			}, 15);

			return E([
				statusNode,
				E('div', {}, [ mapNode ])
			]);
		});
	},

	/* Save & Apply: commit UCI via the stock flow, then reconcile with
	 * `wanguard apply` */
	handleSaveApply: function(ev, mode) {
		return wg.handleSaveApply(this, ev, mode);
	}
});
