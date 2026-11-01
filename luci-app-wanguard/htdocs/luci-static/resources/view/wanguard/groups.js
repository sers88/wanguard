/* WAN Guard groups & routes page (issue #49, prototype
 * designe/generated-image (3).png) — the custom rebuild of the former
 * grid page: inner Groups/Routes tabs, the groups table (color dot +
 * label, assigned-route chip / direct-lb slot lines, device counter,
 * per-row "…" menu, search), the routes strip (egress cards from the
 * netifd dump, liveness/RTT/anchors from `wanguard wanstatus`) and the
 * New/Edit group panel with staged-UCI groupadd semantics, device
 * assignment and the live allocation preview. DRIFT keeps the page
 * read-only. All logic lives in the shared wanguard.core module; the
 * #46 GridSection engine (addGroupsSection) stays in core for the
 * parity tests and possible reuse. */
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

		/* the panel's Save & Apply host (uci.apply + `wanguard apply`) */
		wg.state.saveHost = this;

		var page = wg.buildGroupsPage();

		poll.add(function() {
			return wg.refreshStatus(self._statusNode);
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
