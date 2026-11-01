/* WAN Guard overview (issues #46/#47) — the board-first page: compact
 * sync pill in the header, toolbar (search / "Online only" switch /
 * Board|List / "+ Add"), the kanban board (#14) with per-column
 * add buttons and a "New group" tile, and the honest footer
 * (totals + pending pill). The former in-page Table mode is gone (#20):
 * List opens the devices page, group editing lives on Groups & Routes.
 * All logic lives in the shared wanguard.core module. */
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

		/* compact sync pill (#47): the counters moved to the footer */
		wg.state.statusCompact = true;
		var statusNode = E('div', {});
		wg.updateStatusNode(statusNode);
		wg.state.statusNode = statusNode;

		var header = E('div', { 'class': 'wg-header' }, [
			E('h2', { 'style': 'margin:0; display:inline' }, [ _('Wanguard') ]),
			E('span', { 'class': 'wg-subtitle' }, [ _('Device routing') ]),
			statusNode
		]);

		/* toolbar (#47): search / Online only / Board|List / + Add */
		this._search = E('input', {
			'type': 'search',
			'class': 'wg-search',
			'placeholder': _('Search devices, IP or MAC'),
			'aria-label': _('Search devices, IP or MAC')
		});
		this._search.addEventListener('input', function(ev) {
			clearTimeout(self._searchTimer);
			self._searchTimer = setTimeout(function() {
				wg.setFilter(ev.target.value);
				wg.rebuildBoard();
			}, 200);
		});

		var sw = E('input', { 'type': 'checkbox' });
		sw.checked = wg.hideOfflineMode();
		sw.addEventListener('change', function(ev) {
			try {
				localStorage.setItem('wanguard-hide-offline', ev.target.checked ? '1' : '0');
			}
			catch (e) { /* storage unavailable */ }
			wg.rebuildBoard();
		});
		this._sw = sw;

		this._btnBoard = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function() { wg.rebuildBoard(); })
		}, [ _('Board') ]);
		this._btnList = E('button', {
			'class': 'btn cbi-button',
			'title': _('Bulk edits live on the devices page'),
			'click': ui.createHandlerFn(this, function() {
				location.href = L.url('admin/network/wanguard/devices');
			})
		}, [ _('List') ]);

		this._btnAdd = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function() { self.showAddMenu(); })
		}, [ '+ ' + _('Add') + ' \u25be' ]);

		wg.state.boardWrap = E('div');
		wg.state.saveHost = this;

		var root = E([
			E('style', { 'type': 'text/css' }, [ wg.BOARD_CSS ]),
			header,
			wg.state.leasePanel = wg.buildLeasePanel(),
			E('div', { 'class': 'wg-toolbar' }, [
				this._search,
				E('label', { 'class': 'wg-switch' }, [
					sw,
					E('span', { 'class': 'wg-switch-track' }, []),
					_('Online only')
				]),
				E('span', { 'class': 'wg-viewtoggle' }, [ this._btnBoard, this._btnList ]),
				this._btnAdd
			]),
			E('div', { 'class': 'wg-hint' }, [
				_('Drag devices between groups, or tap a card for the move menu.')
			]),
			wg.state.boardWrap,
			wg.buildBoardFooter()
		]);

		poll.add(function() {
			if (wg.state.busy)
				return;
			return wg.load();
		}, 15);

		wg.rebuildBoard();
		return root;
	},

	/* "+ Add" dropdown (#47): lease-add focus or the groups page */
	showAddMenu: function() {
		ui.showModal(_('Add device or group'), E('div', { 'class': 'wg-menu' }, [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(null, function() {
					ui.hideModal();
					wg.leaseFocus('');
				})
			}, [ _('Add device') ]),
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(null, function() {
					ui.hideModal();
					location.href = L.url('admin/network/wanguard/groups');
				})
			}, [ _('New group') ])
		]));
	},

	/* Save & Apply (footer button + lease-add): stock commit flow, then
	 * `wanguard apply` renders nft/routes instantly */
	handleSaveApply: function(ev, mode) {
		return wg.handleSaveApply(this, ev, mode);
	}
});
