/* WAN Guard overview (issue #46) — the former monolithic view page:
 * status header (sync pill), DHCP lease panel, Board/Table toggle,
 * "Hide offline" filter, kanban board (#14) and, in Table mode, BOTH
 * grids (groups + devices) in one Map — the exact pre-refactor layout
 * (decision D2). All logic lives in the shared wanguard.core module.
 */
'use strict';
'require view';
'require poll';
'require ui';
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

		this._map = wg.buildMap();

		return this._map.render().then(L.bind(function(mapNode) {
			poll.add(L.bind(function() {
				if (wg.state.busy)
					return;
				return wg.reloadState();
			}, this), 15);

			this._boardWrap = E('div');
			this._mapWrap = E('div', {}, [ mapNode ]);

			this._btnBoard = E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, function() { self.setViewMode(true); })
			}, [ _('Board') ]);
			this._btnTable = E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, function() { self.setViewMode(false); })
			}, [ _('Table') ]);

			var chkOffline = E('input', { 'type': 'checkbox', 'style': 'vertical-align:middle; margin:0 .35em' });
			chkOffline.checked = wg.hideOfflineMode();
			chkOffline.addEventListener('change', function(ev) {
				try {
					localStorage.setItem('wanguard-hide-offline', ev.target.checked ? '1' : '0');
				}
				catch (e) {}
				wg.rebuildBoard();
			});
			this._chkWrap = E('label', { 'style': 'margin-left:1em; white-space:nowrap' },
				[ chkOffline, _('Hide offline devices') ]);

			wg.state.boardWrap = this._boardWrap;
			wg.state.saveHost = this;

			var root = E([
				E('style', { 'type': 'text/css' }, [ wg.BOARD_CSS ]),
				statusNode,
				wg.buildLeasePanel(),
				E('div', { 'style': 'margin-bottom:1em' }, [
					this._btnBoard, ' ',
					this._btnTable, ' ',
					this._chkWrap, ' ',
					E('span', { 'style': 'opacity:.6; font-size:.85em' },
						[ _('Board: drag cards between columns or tap a card for the move menu.') ])
				]),
				this._boardWrap,
				this._mapWrap
			]);

			this.applyViewMode();
			return root;
		}, this));
	},

	/* ---------- view mode toggle: Board / Table (localStorage) ---------- */

	viewMode: function() {
		try {
			return (localStorage.getItem('wanguard-view') || 'board') == 'board';
		}
		catch (e) {
			return true;
		}
	},

	setViewMode: function(board) {
		try {
			localStorage.setItem('wanguard-view', board ? 'board' : 'table');
		}
		catch (e) {}
		this.applyViewMode();
	},

	applyViewMode: function() {
		var board = this.viewMode();
		this._btnBoard.className = 'btn cbi-button' + (board ? ' cbi-button-action' : '');
		this._btnTable.className = 'btn cbi-button' + (board ? '' : ' cbi-button-action');
		this._chkWrap.style.display = board ? '' : 'none'; /* filter only affects the board */
		this._boardWrap.style.display = board ? '' : 'none';
		this._mapWrap.style.display = board ? 'none' : '';
		if (board)
			wg.rebuildBoard();
		else
			this.rerenderMap();
	},

	rerenderMap: function() {
		var self = this;
		/* grid rows may be stale after board drops — render the Map fresh */
		return this._map.render().then(function(node) {
			self._mapWrap.innerHTML = '';
			self._mapWrap.appendChild(node);
		});
	},

	/* Save & Apply (footer button and lease-add): commit UCI via the stock
	 * flow, then instantly reconcile nft/routes with `wanguard apply` */
	handleSaveApply: function(ev, mode) {
		return wg.handleSaveApply(this, ev, mode);
	}
});
