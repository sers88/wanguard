/* WAN Guard diagnostics page (issue #46) — read-only summary built from
 * the data the other pages already load (in-sync/DRIFT from `wanguard
 * list`, registered/group/unclassified counts from UCI + `wanguard
 * devices`). No new CLI calls, no editing. All logic lives in the shared
 * wanguard.core module. */
'use strict';
'require view';
'require poll';
'require uci';
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

		this._info = E('div', { 'class': 'cbi-map' });
		this.updateInfo();

		poll.add(function() {
			return wg.refreshStatus(self._statusNode).then(function() {
				self.updateInfo();
			});
		}, 15);

		return E([
			statusNode,
			this._info
		]);
	},

	/* summary rows from already-loaded state (no extra RPC) */
	updateInfo: function() {
		var members = (uci.sections('wanguard', 'member') || []);
		var known = wg.knownMacMap();
		var unclassified = (wg.state.inventory || []).filter(function(d) {
			return !known[d.mac];
		}).length;

		var rows = [
			[ _('Sync state'), (wg.state.statusOk === false)
				? _('DRIFT — keepalive repairs this automatically within ~10 s')
				: (wg.state.statusOk === true ? _('in-sync') : _('unknown')) ],
			[ _('Registered devices'), String(members.length) ],
			[ _('Groups'), String((uci.sections('wanguard', 'group') || []).length) ],
			[ _('Unclassified devices'), String(unclassified) ]
		];

		this._info.innerHTML = '';
		this._info.appendChild(E('div', { 'class': 'cbi-map-descr' },
			rows.map(function(r) {
				return E('div', {}, [ E('strong', {}, [ r[0] + ': ' ]), r[1] ]);
			})));
	}
});
