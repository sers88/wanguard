/* WAN Guard Diagnostics page (issue #50, prototype
 * designe/generated-image (4).png) — the four status cards
 * (Configuration / Routing rules / Mihomo / Last successful sync), the
 * Routing state tabs (Summary / IP rules / Routing tables / nftables),
 * the #44 event feed, Service health, the #45 inspect-device search and
 * the diag-report download. Read-only over `wanguard syncstatus/events/
 * diag/inspect/diag-report` — the same single /usr/bin/wanguard exec the
 * ACL already grants, no new rpcd surface. Old CLIs degrade to
 * "unavailable" panels without exceptions. All logic lives in the shared
 * wanguard.core module. */
'use strict';
'require view';
'require poll';
'require wanguard.core as wg';

return view.extend({
	load: function() {
		return Promise.all([ wg.load(), wg.diagnosticsLoad() ]);
	},

	render: function() {
		var self = this;

		var statusNode = E('div', { 'style': 'margin-bottom:1em' });
		wg.updateStatusNode(statusNode);
		wg.state.statusNode = statusNode;
		this._statusNode = statusNode;

		var page = wg.buildDiagnosticsPage();

		/* the light poll: status cards + event feed + service health
		 * (one exec each). The heavy dumps (rules/tables/nft) stay the
		 * snapshots loaded on tab open / Refresh — a 15 s refetch would
		 * reset the reader's scroll and selection for no new
		 * information; the Summary plate says exactly that. The header
		 * pill keeps its `wanguard list` contract (parseStatus). */
		poll.add(function() {
			return Promise.all([
				wg.refreshStatus(self._statusNode),
				wg.diagnosticsLoad()
			]).then(wg.rebuildDiagnosticsPage);
		}, 15);

		return E('div', {}, [
			E('style', { 'type': 'text/css' }, [ wg.BOARD_CSS ]),
			statusNode,
			page
		]);
	}
});
