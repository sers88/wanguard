/* WAN Guard devices page (issue #48, prototype
 * designe/generated-image (2).png) — the custom rebuild of the former
 * grid page: toolbar (search / group dropdown / Online-only / "+ Add
 * device"), the sortable 5-column table with bulk moves and the
 * "Device details" drawer. All logic lives in the shared wanguard.core
 * module; the #46 GridSection engine (buildDevicesGrid) stays in core
 * for the M6 parity test only. */
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

		/* the drawer/lease panel Save & Apply host (uci.apply +
		 * `wanguard apply`) */
		wg.state.saveHost = this;

		var page = wg.buildDevicesPage();

		poll.add(function() {
			/* a staged drawer edit must not be clobbered by a reload:
			 * while the drawer holds staged UCI (or a bulk/drawer apply
			 * is running) only the status pill refreshes (#48) */
			if (wg.state.busy || wg.state.devTable.drawerDirty)
				return wg.refreshStatus(self._statusNode);
			return wg.reloadDevicesPage();
		}, 15);

		return E('div', {}, [
			E('style', { 'type': 'text/css' }, [ wg.BOARD_CSS ]),
			statusNode,
			page
		]);
	},

	/* Save & Apply: commit UCI via the stock flow, then reconcile with
	 * `wanguard apply` */
	handleSaveApply: function(ev, mode) {
		return wg.handleSaveApply(this, ev, mode);
	}
});
