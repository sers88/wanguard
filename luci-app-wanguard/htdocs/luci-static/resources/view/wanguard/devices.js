/* WAN Guard devices page (issue #46) — the devices grid (registered
 * member MACs) on its own URL-deep-linkable page. Read-mostly: the poll
 * refreshes the status pill only. All logic lives in the shared
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

		this._map = wg.buildDevicesGrid().map;

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
