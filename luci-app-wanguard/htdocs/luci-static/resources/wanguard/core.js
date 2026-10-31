/* luci-app-wanguard core — the shared engine behind the four views
 * (view/wanguard/{overview,devices,groups,diagnostics}.js, issue #46).
 * Thin client over /etc/config/wanguard (same UCI the wanguard CLI uses).
 * The browser never touches nft/routes directly: Save&Apply commits UCI and
 * runs `wanguard apply` which renders everything (issue #13,
 * docs/ARCHITECTURE.md §5).
 *
 * Board (issue #14): columns = groups + Unclassified, cards = clients.
 * Drop applies instantly (uci save -> apply -> confirm, no modal); tap on a
 * card is the touch/keyboard fallback ("Move to" menu). Table view (#8)
 * stays for bulk edits — toggle on top, persisted in localStorage.
 *
 * direct-lb groups (issue #40): board columns show the UCI-derived slot
 * plan (sorted member_iface, weights, mark/table — the same cascade as
 * the CLI allocator), enriched with device state from `wanguard grouplist`
 * when the installed CLI is new enough. Member interfaces and their
 * weight_<iface> options are edited in the group modal; inactive weight
 * fields auto-remove stray options on save (form.js parse semantics).
 *
 * This is a MECHANICAL port of the former monolithic view/wanguard.js
 * (issue #46, pure refactor): methods became functions, per-view fields
 * became `state`, grid construction became factories. Page session state
 * lives in `state` (one browser page = one module instance); tests/luci
 * re-evaluates this file per scenario, providing the same fresh closure
 * the monolith had. groupColor() is a palette placeholder for the group
 * metadata follow-up (#42) — #46 deliberately paints nothing.
 */
'use strict';
'require rpc';
'require uci';
'require ui';
'require form';

var callWanguard = rpc.declare({
	object: 'file',
	method: 'exec',
	params: [ 'command', 'params' ],
	expect: { '': {} }
});

var callLeaseFile = rpc.declare({
	object: 'file',
	method: 'read',
	params: [ 'path' ],
	expect: { data: '' }
});

var callIfaceDump = rpc.declare({
	object: 'network.interface',
	method: 'dump',
	expect: { '': {} }
});

/* per-page session state (module closure; one page load = one instance) */
var state = {
	statusOk: null,
	statusText: 'loading…',
	memberCount: 0,
	leases: [],
	inventory: [],
	ifaces: [],
	LB_GROUPLIST: {},   /* `wanguard grouplist` rows for direct-lb groups (#40) */
	busy: false,
	statusNode: null,   /* header pill node, set by each view's render() */
	boardWrap: null,    /* board container, set by the overview view */
	saveHost: null      /* view providing handleSaveApply (lease panel, #46) */
};

function normalizeMac(s) {
	var h = (s || '').toUpperCase().replace(/[^0-9A-F]/g, '');
	if (h.length != 12)
		return null;
	return h.replace(/(..)(..)(..)(..)(..)(..)/, '$1:$2:$3:$4:$5:$6').toLowerCase();
}

function validateMac(sid, value) {
	if (!normalizeMac(value))
		return _('Invalid MAC address (aa:bb:cc:dd:ee:ff — dashes/dots/bare hex accepted)');
	return true;
}

function knownMacMap() {
	var known = {};
	(uci.sections('wanguard', 'member') || []).forEach(function(sec) {
		if (sec && sec.mac) {
			var m = normalizeMac(sec.mac);
			if (m)
				known[m] = sec.group || '?';
		}
	});
	return known;
}

/* only one proxy group: mihomo redir-port/TUN are singletons */
function validateSingleProxy(sid, value) {
	if (value != 'proxy')
		return true;
	var others = (uci.sections('wanguard', 'group') || []).filter(function(g) {
		return g['.name'] != sid && g.type == 'proxy';
	});
	if (others.length)
		return _('mihomo is a singleton — only one proxy group is allowed (already: %s)').format(others[0]['.name']);
	return true;
}

/* computed allocation preview: same formula as the CLI allocator */
function allocPreview(sid) {
	var g = uci.sections('wanguard', 'group').filter(function(s) { return s['.name'] == sid; })[0];
	if (!g)
		return '';
	if (g.type == 'proxy')
		return 'fwmark 300 → table 500 (fixed)';
	if (g.type == 'direct-lb')
		return lbPreview(sid);
	var names = (uci.sections('wanguard', 'group') || [])
		.filter(function(s) { return s.type == 'direct'; })
		.map(function(s) { return s['.name']; })
		.sort();
	var k = names.indexOf(sid) + 1;
	if (!k)
		return '—';
	var mark = 100 * k;
	if (mark >= 300)
		mark += 100;
	return 'fwmark %d → table %d'.format(mark, 400 + k - 1);
}

/* ---------- direct-lb helpers (issue #40) ----------
 * JS mirror of the CLI allocator (wand.uc alloc_entries, LB branch):
 * a direct-lb group expands into one slot per SORTED member_iface, the
 * numeric cascade continues after all direct groups (proxy occupies no
 * slot), marks >= 300 skip the mihomo mark, >20 members or a slot
 * number > 99 drops/truncates the group exactly like the CLI. Pinned
 * against the ucode mock numbers by tests/luci. */

/* UCI list option as array (tolerates the single-string form) */
function listOpt(sid, opt) {
	var v = uci.get('wanguard', sid, opt);
	if (Array.isArray(v))
		return v.filter(function(x) { return x != null && '' + x != ''; });
	return (v != null && '' + v != '') ? [ '' + v ] : [];
}

function lbMembers(sid) { /* sorted member iface names */
	return listOpt(sid, 'member_iface').map(function(s) { return '' + s; }).sort();
}

function lbWeight(sid, ifc) { /* CLI rule: absent/garbage/0 -> 50 */
	var v = uci.get('wanguard', sid, 'weight_' + ifc);
	v = (v != null) ? '' + v : '';
	if (!/^[0-9]+$/.test(v))
		return 50;
	var w = parseInt(v, 10);
	return (w > 0) ? w : 50;
}

function lbBuckets(w) { /* CLI lb_buckets: floor + remainder to LAST */
	var out = [], sum = 0, acc = 0;
	for (var i = 0; i < w.length; i++)
		sum += w[i];
	if (sum == 0)
		sum = 1;
	for (i = 0; i < w.length; i++) {
		if (i == w.length - 1) {
			out.push(100 - acc);
			break;
		}
		var b = Math.floor((100 * w[i]) / sum);
		out.push(b);
		acc += b;
	}
	return out;
}

function lbSlotMap() { /* { group: { slots: [...], note: '' } } */
	var secs = (uci.sections('wanguard', 'group') || []);
	var k = secs.filter(function(s) { return s.type == 'direct'; })
		.map(function(s) { return s['.name']; }).sort().length;
	var out = {};
	secs.filter(function(s) { return s.type == 'direct-lb'; })
		.map(function(s) { return s['.name']; }).sort()
		.forEach(function(name) {
			var mem = lbMembers(name);
			if (!mem.length || mem.length > 20) {
				out[name] = { slots: [], note: !mem.length ? 'no members — ignored' : '>20 members — ignored' };
				return;
			}
			var live = listOpt(name, 'member_live'); /* tick-owned (#39) */
			var slots = [];
			for (var i = 0; i < mem.length; i++) {
				k++;
				if (k > 99) {
					out[name] = { slots: slots, note: '>99 slots — truncated' };
					return;
				}
				var m = 100 * k;
				if (m >= 300) /* 300 = mihomo */
					m += 100;
				var li = (live[i] != null && '' + live[i] != '') ? '' + live[i] : mem[i];
				slots.push({ iface: li, member: mem[i], mark: m, table: 400 + k - 1, weight: lbWeight(name, mem[i]) });
			}
			/* the displayed % is the EFFECTIVE bucket (what the nft draw
			 * rules render: numgen mod 100 < bucket), not the raw weight */
			var b = lbBuckets(slots.map(function(s) { return s.weight; }));
			for (i = 0; i < slots.length; i++)
				slots[i].b = b[i];
			out[name] = { slots: slots, note: '' };
		});
	return out;
}

/* `wanguard grouplist` rows for direct-lb groups (authoritative device
 * state), refreshed in load()/reloadState(); empty on old CLIs */
function lbPreview(sid) {
	var plan = lbSlotMap()[sid] || {};
	if (!(plan.slots || []).length)
		return (plan.note) ? '— (%s)'.format(plan.note) : '—';
	var cli = state.LB_GROUPLIST[sid] || [];
	var parts = plan.slots.map(function(s) {
		/* failed-over slot: "declared→live" (member_live, tick #39) */
		var ifc = (s.iface != s.member) ? '%s→%s'.format(s.member, s.iface) : s.iface;
		var txt = '%s %d%% %d/%d'.format(ifc, s.b, s.mark, s.table);
		for (var j = 0; j < cli.length; j++)
			if (cli[j].mark == s.mark && cli[j].device) {
				txt += ' (%s)'.format(cli[j].device);
				break;
			}
		return txt;
	});
	return parts.join(' · ');
}

function groupChoices() {
	var out = [];
	(uci.sections('wanguard', 'group') || []).forEach(function(g) {
		var lbl = g['.name'];
		/* hide the target when it duplicates the group name */
		if (g.type == 'proxy') {
			if (lbl != 'mihomo')
				lbl += ' — mihomo';
		} else if (g.type == 'direct-lb')
			lbl += ' — LB';
		else if (g.iface != lbl)
			lbl += ' — ' + (g.iface || '?');
		out.push([ g['.name'], lbl ]);
	});
	return out;
}

/* groupColor(name) — palette placeholder (#42): stable per-group colors
 * belong to the prototype pages built on top of #46. Pure-refactor rule:
 * this paints nothing until that issue lands. */
function groupColor(name) {
	return '';
}

var BOARD_CSS = [
	'.wg-board { display:flex; gap:12px; align-items:flex-start; overflow-x:auto; padding-bottom:8px; }',
	'.wg-col { flex:1 0 15em; min-width:15em; max-width:24em; background:rgba(128,128,128,.07);',
	'  border:1px solid rgba(128,128,128,.25); border-radius:6px; }',
	'.wg-col-h { padding:8px 10px; border-bottom:1px solid rgba(128,128,128,.25); }',
	'.wg-col-title { font-weight:bold; }',
	'.wg-col-sub { font-size:.82em; opacity:.65; }',
	'.wg-cards { padding:8px; display:flex; flex-direction:column; gap:6px; min-height:3.2em; }',
	'.wg-card { background:rgba(128,128,128,.06); border:1px solid rgba(128,128,128,.35);',
	'  border-radius:4px; padding:6px 8px; cursor:pointer; user-select:none; }',
	'.wg-card[draggable="true"] { cursor:grab; }',
	'.wg-card.wg-busy { opacity:.5; pointer-events:none; }',
	'.wg-card .wg-mac { font-size:.78em; opacity:.6; font-family:monospace; }',
	'.wg-card .wg-meta { font-size:.78em; display:flex; justify-content:space-between; gap:1em; }',
	'.wg-on { color:#5cb85c; }',
	'.wg-off { color:#999; }',
	'.wg-col.wg-drop { outline:2px dashed #4a90d9; outline-offset:-3px; background:rgba(74,144,217,.10); }',
	'.wg-menu button { display:block; width:100%; margin:.25em 0; }'
].join('\n');

/* ---------- parsers ---------- */

/* /tmp/dhcp.leases lines: "expiry mac ip hostname clientid" */
function parseLeases(out) {
	return (out || '').split('\n').map(function(line) {
		var f = line.trim().split(/\s+/);
		if (f.length < 4)
			return null;
		return { mac: f[1].toLowerCase(), ip: f[2], name: f[3] };
	}).filter(function(l) { return l && normalizeMac(l.mac); });
}

function parseDevices(out) {
	/* `wanguard devices` (issue #14): mac<TAB>ip<TAB>name<TAB>online,
	 * merged leases+ARP — includes static-IP clients */
	return (out || '').split('\n').map(function(line) {
		var f = line.split('\t');
		if (f.length < 4)
			return null;
		return { mac: f[0], ip: (f[1] == '-' ? '' : f[1]), name: (f[2] == '-' ? '' : f[2]), online: (f[3] == '1') };
	}).filter(function(d) { return d && normalizeMac(d.mac); });
}

function parseGrouplist(out) {
	/* `wanguard grouplist` (issue #40): columns are
	 * GROUP TYPE IFACE MARK TABLE DEVICE MEMBERS(count); only the
	 * direct-lb rows are needed (direct/proxy previews are computed
	 * from UCI as before). Degrades to {} on old CLIs (no rows). */
	var rows = {};
	(out || '').split('\n').forEach(function(line) {
		var f = line.trim().split(/\s+/);
		if (f.length < 7 || f[0] == 'GROUP' || f[1] != 'direct-lb')
			return;
		(rows[f[0]] = rows[f[0]] || []).push({
			iface: f[2], mark: parseInt(f[3], 10), table: f[4], device: f[5]
		});
	});
	return rows;
}

function parseStatus(res) {
	if (res && res.stdout) {
		var lines = res.stdout.split('\n').filter(function(l) { return l.trim(); });
		var tail = lines[lines.length - 1] || '';
		var tailIsNft = (tail.indexOf('nft:') === 0);
		state.statusOk = /in-sync/.test(tail);
		state.statusText = tail.replace(/^nft:\s*/, '') || 'unknown';
		state.memberCount = Math.max(0, lines.length - 2 - (tailIsNft ? 1 : 0));
	}
	else {
		state.statusOk = null;
		state.statusText = 'wanguard list unavailable';
	}
}

/* ---------- header (sync pill + counters, issue #46) ---------- */

function updateStatusNode(node) {
	var dot = state.statusOk === true ? '#5cb85c' : (state.statusOk === false ? '#d9534f' : '#999');
	var label = '%d device(s) · %d group(s) · %s%s'.format(
		state.memberCount,
		(uci.sections('wanguard', 'group') || []).length,
		state.statusOk === false ? 'DRIFT: ' : 'nft: ',
		state.statusText);
	node.innerHTML = '';
	node.appendChild(E('span', { 'style': 'font-weight:bold' }, [
		E('span', { 'style': 'color:%s'.format(dot) }, '● '), label
	]));
}

function refreshStatus(node) {
	return callWanguard('/usr/bin/wanguard', [ 'list' ]).then(function(res) {
		parseStatus(res);
		if (node)
			updateStatusNode(node);
	});
}

/* full page load: UCI + leases + status + ifaces + devices + grouplist
 * (the exact call set of the monolith's load(); every consumer page uses
 * this one loader — no new RPC surface vs. #46's "ACL unchanged" rule) */
function load() {
	return Promise.all([
		uci.load('wanguard'),
		callLeaseFile('/tmp/dhcp.leases').catch(function() { return ''; }),
		callWanguard('/usr/bin/wanguard', [ 'list' ]).catch(function() { return null; }),
		callIfaceDump().catch(function() { return null; }),
		callWanguard('/usr/bin/wanguard', [ 'devices' ]).catch(function() { return null; }),
		callWanguard('/usr/bin/wanguard', [ 'grouplist' ]).catch(function() { return null; })
	]).then(function(data) {
		state.leases = parseLeases(data[1] || '');

		parseStatus(data[2]);

		/* `wanguard devices` (issue #14): merged leases+ARP — includes
		 * static-IP clients. Degrade to leases-only while the CLI on the
		 * router is older. */
		var inv = parseDevices((data[4] && data[4].stdout) || '');
		if (!inv.length)
			inv = state.leases.map(function(l) {
				return { mac: l.mac, ip: l.ip, name: (l.name && l.name != '*' && l.name != '-') ? l.name : '', online: false };
			});
		state.inventory = inv;

		/* netifd interfaces for the Groups grid (up ones only); degrade
		 * gracefully when ubus/ACL is unavailable */
		var dump = data[3];
		if (dump && dump.interface)
			state.ifaces = dump.interface
				.filter(function(i) { return i && i.up && i.interface; })
				.map(function(i) { return i.interface; })
				.sort();
		else
			state.ifaces = [];

		/* `wanguard grouplist` (#40): authoritative device state for
		 * direct-lb slots; empty on CLIs without direct-lb support */
		state.LB_GROUPLIST = parseGrouplist((data[5] && data[5].stdout) || '');
	});
}

/* re-read UCI + inventory + status from the router and rebuild the board */
function reloadState() {
	return Promise.all([
		uci.load('wanguard'),
		callWanguard('/usr/bin/wanguard', [ 'devices' ]).then(function(res) {
			var inv = parseDevices((res && res.stdout) || '');
			if (inv.length)
				state.inventory = inv;
		}).catch(function() {}),
		callWanguard('/usr/bin/wanguard', [ 'grouplist' ]).then(function(res) {
			state.LB_GROUPLIST = parseGrouplist((res && res.stdout) || '');
		}).catch(function() {}),
		refreshStatus(state.statusNode)
	]).then(function() {
		rebuildBoard();
	});
}

/* ---------- board helpers (issue #14) ---------- */

function findMember(mac) {
	var out = null;
	(uci.sections('wanguard', 'member') || []).some(function(mm) {
		if (normalizeMac(mm.mac) == mac) {
			out = { sid: mm['.name'], group: mm.group || '' };
			return true;
		}
		return false;
	});
	return out;
}

function inventoryOf(mac) {
	var out = null;
	(state.inventory || []).some(function(d) {
		if (d.mac == mac) {
			out = d;
			return true;
		}
		return false;
	});
	return out;
}

function macLabel(mac) {
	var mm = findMember(mac);
	if (mm) {
		var nm = uci.get('wanguard', mm.sid, 'name');
		if (nm)
			return nm;
	}
	var d = inventoryOf(mac);
	return (d && (d.name || d.ip)) || mac;
}

function boardGroups() {
	/* columns: direct groups alphabetically, then proxy, then Unclassified */
	var gs = (uci.sections('wanguard', 'group') || []).map(function(g) {
		return { name: g['.name'], type: g.type || 'direct', iface: g.iface || '' };
	});
	var dirs = gs.filter(function(g) { return g.type != 'proxy'; })
		.sort(function(a, b) { return a.name.localeCompare(b.name); });
	var prox = gs.filter(function(g) { return g.type == 'proxy'; });
	return dirs.concat(prox).map(function(g) {
		/* hide the target when it duplicates the group name */
		var lbl = g.name;
		if (g.type == 'proxy') {
			if (g.name != 'mihomo')
				lbl += ' — mihomo';
		} else if (g.type == 'direct-lb')
			lbl += ' — LB';
		else if (g.iface != g.name)
			lbl += ' — ' + (g.iface || '?');
		return { name: g.name, label: lbl };
	});
}

function dndEnabled() {
	return state.statusOk !== false && !state.busy;
}

function buildCard(it, inGroup) {
	var el = E('div', {
		'class': 'wg-card',
		'data-mac': it.mac,
		'draggable': dndEnabled() ? 'true' : 'false',
		'title': inGroup ? _('Drag to move, click for menu') : _('Drag into a group to add, click for menu')
	}, [
		E('div', { 'class': 'wg-name' }, [ it.name || it.ip || it.mac ]),
		E('div', { 'class': 'wg-mac' }, [ it.mac ]),
		E('div', { 'class': 'wg-meta' }, [
			E('span', {}, [ it.ip || '—' ]),
			E('span', { 'class': it.online ? 'wg-on' : 'wg-off' },
				[ it.online ? '● ' + _('online') : '○ ' + _('offline') ])
		])
	]);

	el.addEventListener('dragstart', function(ev) {
		if (!dndEnabled()) {
			ev.preventDefault();
			return;
		}
		ev.dataTransfer.setData('text/plain', it.mac);
		ev.dataTransfer.effectAllowed = 'move';
	});
	el.addEventListener('dragend', function() {
		clearDropHl();
	});
	el.addEventListener('click', function() {
		if (!state.busy)
			showCardMenu(it.mac, inGroup);
	});
	return el;
}

function clearDropHl() {
	document.querySelectorAll('.wg-drop').forEach(function(n) {
		n.classList.remove('wg-drop');
	});
}

/* column counter: "7" — or "5/7" when offline devices are hidden */
function colCount(visible, total) {
	return (visible == total) ? String(total) : '%d/%d'.format(visible, total);
}

function hideOfflineMode() {
	try {
		return localStorage.getItem('wanguard-hide-offline') == '1';
	}
	catch (e) {
		return false;
	}
}

function buildBoard() {
	var board = E('div', { 'class': 'wg-board' });
	var root = E('div', {});

	if (state.statusOk === false)
		root.appendChild(E('div', {
			'class': 'alert-message warning',
			'style': 'margin-bottom:1em'
		}, [ _('State is DRIFT — the board is read-only until the router re-syncs (keepalive repairs this automatically within ~10 s).') ]));

	var members = (uci.sections('wanguard', 'member') || []);
	var known = knownMacMap();

	var mkColumn = function(key, title, sub, cards) {
		var col = E('div', { 'class': 'wg-col', 'data-group': key }, [
			E('div', { 'class': 'wg-col-h' }, [
				E('div', { 'class': 'wg-col-title' }, [ title ]),
				sub ? E('div', { 'class': 'wg-col-sub' }, [ sub ]) : E([])
			]),
			E('div', { 'class': 'wg-cards' }, cards)
		]);

		col.addEventListener('dragover', function(ev) {
			if (!dndEnabled())
				return;
			ev.preventDefault();
			ev.dataTransfer.dropEffect = 'move';
			col.classList.add('wg-drop');
		});
		col.addEventListener('dragleave', function(ev) {
			if (ev.target === col)
				col.classList.remove('wg-drop');
		});
		col.addEventListener('drop', function(ev) {
			ev.preventDefault();
			col.classList.remove('wg-drop');
			var mac = normalizeMac(ev.dataTransfer.getData('text/plain'));
			if (mac)
				applyMove(mac, key);
		});
		return col;
	};

	boardGroups().forEach(function(g) {
		var items = members
			.filter(function(mm) { return (mm.group || '') == g.name; })
			.map(function(mm) {
				var mac = normalizeMac(mm.mac) || mm.mac;
				var d = inventoryOf(mac) || {};
				return {
					mac: mac,
					name: mm.name || d.name || '',
					ip: d.ip || '',
					online: !!d.online
				};
			})
			.sort(function(a, b) {
				return (a.online == b.online)
					? (a.name || a.mac).localeCompare(b.name || b.mac)
					: (a.online ? -1 : 1);
			});

		var total = items.length;
		if (hideOfflineMode())
			items = items.filter(function(it) { return it.online; });

		board.appendChild(mkColumn(g.name, g.label,
			'%s · %s'.format(allocPreview(g.name), colCount(items.length, total)),
			items.map(function(it) { return buildCard(it, true); })));
	});

	/* Unclassified: seen devices that are not members of any group */
	var uitems = (state.inventory || [])
		.filter(function(d) { return !known[d.mac]; })
		.sort(function(a, b) {
			return (a.online == b.online)
				? (a.name || a.mac).localeCompare(b.name || b.mac)
				: (a.online ? -1 : 1);
		});
	var utotal = uitems.length;
	if (hideOfflineMode())
		uitems = uitems.filter(function(it) { return it.online; });

	board.appendChild(mkColumn('', _('Unclassified'),
		'%s · %s'.format(_('DHCP/ARP devices outside all groups'),
			colCount(uitems.length, utotal)),
		uitems.map(function(d) { return buildCard(d, false); })));

	root.appendChild(board);
	return root;
}

function rebuildBoard() {
	if (!state.boardWrap || state.boardWrap.style.display == 'none')
		return;
	state.boardWrap.innerHTML = '';
	state.boardWrap.appendChild(buildBoard());
}

function markBusy(mac, on) {
	var n = document.querySelector('.wg-card[data-mac="%s"]'.format(mac));
	if (n)
		n.classList[on ? 'add' : 'remove']('wg-busy');
}

/* Move/add/remove a device via drag-drop or the card menu: silent apply
 * (no modal), spinner on the card, error -> toast + bounce-back through
 * a full rebuild from reloaded UCI. */
function applyMove(mac, target) {
	if (state.busy)
		return;
	if (state.statusOk === false) {
		ui.addNotification(null, E('p', {}, _('State is DRIFT — moves are disabled until the router re-syncs.')), 'error');
		return;
	}

	var mm = findMember(mac);
	var cur = mm ? mm.group : '';

	if (cur === target)
		return; /* same-column drop or unclassified -> unclassified */

	var label = macLabel(mac);

	if (!target) {
		/* drop into Unclassified = unregister, needs confirmation */
		ui.showModal(_('Remove device'), E('div', { 'style': 'max-width:32em' }, [
			E('p', {}, _('Remove %s from all groups? The device falls back to the main routing table.').format(label)),
			E('div', { 'style': 'display:flex; gap:.5em; justify-content:flex-end; margin-top:1em' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(null, function() { ui.hideModal(); })
				}, [ _('Cancel') ]),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative important',
					'click': ui.createHandlerFn(null, function() { ui.hideModal(); doApply(mac, ''); })
				}, [ _('Remove') ])
			])
		]));
		return;
	}

	doApply(mac, target);
}

function doApply(mac, target) {
	var mm = findMember(mac);
	var label = macLabel(mac);
	var verb;

	if (target) {
		verb = mm ? 'move' : 'add';
		if (mm)
			uci.set('wanguard', mm.sid, 'group', target);
		else {
			var nm = macLabel(mac);
			if (nm == mac)
				nm = 'dev-' + mac.replace(/:/g, '').slice(-6);
			uci.add('wanguard', 'member');
			uci.set('wanguard', '@member[-1]', 'name', nm);
			uci.set('wanguard', '@member[-1]', 'mac', mac);
			uci.set('wanguard', '@member[-1]', 'group', target);
		}
	}
	else if (mm) {
		verb = 'remove';
		uci.remove('wanguard', mm.sid);
	}
	else
		return Promise.resolve();

	state.busy = true;
	markBusy(mac, true);

	/* same path as Save&Apply, minus the modal: stage -> apply. This
	 * LuCI's uci.apply() enables the rollback window and auto-confirms
	 * ~1 s later in the background, so no manual confirm is needed */
	return uci.save().then(function() {
		return uci.apply(5);
	}).then(function() {
		state.busy = false;
		return reloadState();
	}).catch(function(e) {
		state.busy = false;
		ui.addNotification(null, E('p', {}, _('Moving %s failed — the change is rolled back (%s).').format(label, (e && e.message) || 'error')), 'error');
		return reloadState();
	}).then(function() {
		/* uci.save() lit the "Unsaved Changes" badge; the apply has
		 * committed (or failed), so re-query the server staging count
		 * and let the indicator tell the truth again */
		return ui.changes.init();
	});
}

function showCardMenu(mac, inGroup) {
	var cur = findMember(mac);
	var curGroup = cur ? cur.group : '';
	var menu = E('div', { 'class': 'wg-menu' });

	boardGroups().forEach(function(g) {
		if (g.name == curGroup)
			return;
		menu.appendChild(E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() {
				ui.hideModal();
				applyMove(mac, g.name);
			})
		}, [ _('Move to %s').format(g.label) ]));
	});

	if (curGroup)
		menu.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(null, function() {
				ui.hideModal();
				applyMove(mac, '');
			})
		}, [ _('Remove from all groups') ]));

	menu.appendChild(E('div', { 'style': 'margin-top:.75em; text-align:right' }, [
		E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(null, function() { ui.hideModal(); })
		}, [ _('Close') ])
	]));

	ui.showModal(macLabel(mac) + (curGroup ? ' (' + curGroup + ')' : ' (' + _('unclassified') + ')'), menu);
}

/* ---------- grid factories (issue #46) ---------- */

/* groups grid (named sections: the section id IS the group name);
 * shared by the overview map and the groups page */
function addGroupsSection(m) {
	var o;
	var groups = m.section(form.GridSection, 'group', _('Groups'));
	groups.addremove = true;
	groups.anonymous = false;
	groups.sortable = false;
	groups.modaltitle = _('Group');
	groups.description = _('Group names: letters/digits/underscore (members reference this name). Marks and ' +
		'routing tables are allocated automatically from the sorted direct-group names: proxy = 300/500 fixed, ' +
		'direct = 100,200,400,… → tables 400,401,…; direct-lb = one slot per SORTED member_iface, same cascade, ' +
		'weights via weight_<iface> (0/empty = 50). Renaming = create new + move members + delete.');

	o = groups.option(form.DummyValue, '_alloc', _('Allocation'));
	o.cfgvalue = function(sid) { return allocPreview(sid); };

	o = groups.option(form.ListValue, 'type', _('Type'));
	o.value('direct', _('direct — via netifd interface'));
	o.value('direct-lb', _('direct-lb — load balance across member interfaces'));
	o.value('proxy', _('proxy — via mihomo (singleton)'));
	o.rmempty = false;
	o.default = 'direct';
	o.validate = validateSingleProxy;

	o = groups.option(form.ListValue, 'iface', _('Interface'));
	o.rmempty = false;
	o.depends('type', 'direct');
	if (state.ifaces.length) {
		state.ifaces.forEach(function(i) { o.value(i, i); });
	}
	else {
		/* ACL/ubus degraded: fall back to ifaces already referenced by groups */
		var seen = {};
		(uci.sections('wanguard', 'group') || []).forEach(function(g) {
			if (g.iface && !seen[g.iface]) {
				seen[g.iface] = true;
				o.value(g.iface, g.iface + ' (?)');
			}
		});
		if (!Object.keys(seen).length)
			o.value('', _('(interface list unavailable — check ACL/ubus)'));
	}

	/* direct-lb members/weights live in the modal only (#40): the grid
	 * rows keep the direct/proxy layout unchanged, and GridSection.save
	 * skips modal-only options, so staging stays untouched until the
	 * modal itself is saved. addModalOptions is called after the modal
	 * clone — the fields are rebuilt from live UCI on every open, so a
	 * member added mid-session gets its weight field right away. */
	groups.addModalOptions = function(s, sid) {
		var sec = uci.get('wanguard', sid);
		if (!sec || sec.type != 'direct-lb')
			return;

		var cur = lbMembers(sid);
		var names = (state.ifaces || []).slice();
		if (!names.length) {
			/* ACL/ubus degraded: fall back to ifaces referenced by groups */
			(uci.sections('wanguard', 'group') || []).forEach(function(g) {
				if (g.iface && names.indexOf(g.iface) == -1)
					names.push(g.iface);
			});
		}
		cur.forEach(function(m) {
			if (names.indexOf(m) == -1)
				names.push(m);
		});
		names.sort();

		var o = s.option(form.MultiValue, 'member_iface', _('Member interfaces'));
		o.modalonly = true;
		o.rmempty = false;
		o.description = _('WAN interfaces to balance across. Slots are allocated by the SORTED list — ' +
			'adding/removing a member renumbers the group\'s slots (flush of established flows, #24).');
		names.forEach(function(n) { o.value(n, n); });

		/* one weight field per candidate iface; visible (and written)
		 * only while the iface is staged as a member of THIS group —
		 * 'direct-lb' matches via substring containment of itself, and
		 * unchecking the member makes the field inactive, which removes
		 * its stray weight option on save (form.js parse semantics) */
		names.forEach(function(n) {
			var w = s.option(form.Value, 'weight_' + n, _('Weight %s').format(n));
			w.modalonly = true;
			w.datatype = 'uinteger';
			w.placeholder = '50';
			w.rmempty = true;
			w.description = _('Relative share of this member (%). Empty or 0 = 50.');
			w.depends({ type: 'direct-lb', member_iface: n, '!contains': true });
		});
	};

	/* deleting a group that still has members would silently drop them
	 * to the main table (fail-safe, but a surprise) — the CLI refuses
	 * this in groupdel, so does the UI */
	groups.handleRemove = function(ev, section_id) {
		var used = (uci.sections('wanguard', 'member') || []).filter(function(m) {
			return (m.group || '') == section_id;
		}).map(function(m) { return m.name || m.mac; });
		if (used.length) {
			ui.addNotification(null, E('p', {}, _('Group "%s" still has members (%s) — move them to another group first').format(section_id, used.join(', '))), 'error');
			return Promise.resolve();
		}
		return form.GridSection.prototype.handleRemove.call(this, ev, section_id);
	};

	return groups;
}

/* devices grid (kept for bulk edits / copy-paste of MACs);
 * shared by the overview map and the devices page */
function addDevicesSection(m) {
	var o;
	var grid = m.section(form.GridSection, 'member', _('Devices'));
	grid.addremove = true;
	grid.anonymous = true;
	grid.sortable = false;
	grid.modaltitle = _('Device');

	o = grid.option(form.Value, 'name', _('Name'));
	o.rmempty = false;

	o = grid.option(form.Value, 'mac', _('MAC address'));
	o.rmempty = false;
	o.validate = validateMac;

	o = grid.option(form.ListValue, 'group', _('Group'));
	var gch = groupChoices();
	if (!gch.length)
		gch = [ [ '', _('(no groups defined)') ] ];
	gch.forEach(function(g) { o.value(g[0], g[1]); });
	o.rmempty = false;

	return grid;
}

/* overview Table mode: BOTH grids in one Map — exactly the monolith
 * layout (#46 decision D2: Overview shows groups+devices as today) */
function buildMap() {
	var m = new form.Map('wanguard', _('WAN Guard — named groups'),
		_('Groups route member devices through a netifd interface (direct) or through mihomo (proxy, max 1). ' +
		  'Save &amp; Apply commits UCI and instantly runs "wanguard apply", which renders nft rules, ' +
		  'ip rules and per-group routing tables.'));
	addGroupsSection(m);
	addDevicesSection(m);
	return m;
}

function buildGroupsGrid() {
	var m = new form.Map('wanguard', _('WAN Guard — groups & routes'),
		_('Groups route member devices through a netifd interface (direct) or through mihomo (proxy, max 1). ' +
		  'Save &amp; Apply commits UCI and instantly runs "wanguard apply", which renders nft rules, ' +
		  'ip rules and per-group routing tables.'));
	return { map: m, groups: addGroupsSection(m) };
}

function buildDevicesGrid() {
	var m = new form.Map('wanguard', _('WAN Guard — devices'),
		_('Registered client devices for bulk edits / copy-paste of MACs. ' +
		  'Save &amp; Apply commits UCI and instantly runs "wanguard apply".'));
	return { map: m, devices: addDevicesSection(m) };
}

/* ---------- DHCP lease panel (overview) ---------- */

function buildLeasePanel() {
	var known = knownMacMap();

	var leaseSel = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:24em' });
	state.leases.sort(function(a, b) { return (a.name || '').localeCompare(b.name || ''); });
	state.leases.forEach(function(l, i) {
		var inGroup = known[l.mac];
		var label = '%s (%s, %s)%s'.format(
			l.name || 'unnamed', l.mac, l.ip,
			inGroup ? ' — in group ' + inGroup : '');
		leaseSel.appendChild(E('option', { 'value': String(i) }, [ label ]));
	});

	var groupSel = E('select', { 'class': 'cbi-input-select' });
	var choices = groupChoices();
	if (!choices.length)
		choices = [ [ '', _('(no groups defined — create one below)') ] ];
	var proxyName = '';
	choices.forEach(function(g) {
		var sec = uci.sections('wanguard', 'group').filter(function(s) {
			return s['.name'] == g[0];
		})[0];
		groupSel.appendChild(E('option', { 'value': g[0] }, [ g[1] ]));
		if (sec && sec.type == 'proxy')
			proxyName = g[0];
	});
	groupSel.value = proxyName || choices[choices.length - 1][0];

	var btn = E('button', {
		'class': 'btn cbi-button cbi-button-add',
		'click': ui.createHandlerFn(null, function() {
			var lease = state.leases[parseInt(leaseSel.value, 10)];
			if (!lease)
				return;
			if (knownMacMap()[lease.mac]) {
				ui.addNotification(null, E('p', {}, _('%s is already registered').format(lease.mac)), 'error');
				return;
			}
			uci.add('wanguard', 'member');
			uci.set('wanguard', '@member[-1]', 'name', lease.name || ('dev-' + lease.ip));
			uci.set('wanguard', '@member[-1]', 'mac', lease.mac);
			uci.set('wanguard', '@member[-1]', 'group', groupSel.value);
			/* the hosting view's Save&Apply (uci.apply + `wanguard apply`) */
			var host = state.saveHost;
			return (host && host.handleSaveApply) ? host.handleSaveApply(null, 'apply') : undefined;
		})
	}, [ _('Add device') ]);

	return E('div', { 'class': 'cbi-map-descr', 'style': 'margin-bottom:1em' }, [
		E('label', { 'style': 'margin-right:.5em' }, [ _('Add from DHCP leases:') ]),
		leaseSel, ' ', groupSel, ' ', btn
	]);
}

/* ---------- Save & Apply (footer button and lease-add): commit UCI via
 * the stock flow, then instantly reconcile nft/routes with `wanguard apply`.
 * `self` is the hosting view — this.super() resolves the stock flow. */
function handleSaveApply(self, ev, mode) {
	return self.super('handleSaveApply', [ ev, mode ]).then(function() {
		return callWanguard('/usr/bin/wanguard', [ 'apply' ]).then(function(res) {
			var out = ((res && res.stdout) || '').trim() || 'done';
			ui.addNotification(null, E('p', {}, _('wanguard apply: %s').format(out)),
				out === 'in-sync' ? 'info' : 'notice');
			refreshStatus(state.statusNode);
		}).catch(function() {
			ui.addNotification(null, E('p', {}, _('wanguard apply failed to run (ACL?)')), 'error');
		});
	});
}

return {
	state: state,
	BOARD_CSS: BOARD_CSS,
	callWanguard: callWanguard,
	callLeaseFile: callLeaseFile,
	callIfaceDump: callIfaceDump,
	normalizeMac: normalizeMac,
	validateMac: validateMac,
	knownMacMap: knownMacMap,
	findMember: findMember,
	validateSingleProxy: validateSingleProxy,
	listOpt: listOpt,
	lbMembers: lbMembers,
	lbWeight: lbWeight,
	lbBuckets: lbBuckets,
	lbSlotMap: lbSlotMap,
	lbPreview: lbPreview,
	allocPreview: allocPreview,
	groupChoices: groupChoices,
	groupColor: groupColor,
	boardGroups: boardGroups,
	parseLeases: parseLeases,
	parseDevices: parseDevices,
	parseGrouplist: parseGrouplist,
	parseStatus: parseStatus,
	updateStatusNode: updateStatusNode,
	refreshStatus: refreshStatus,
	load: load,
	reloadState: reloadState,
	dndEnabled: dndEnabled,
	inventoryOf: inventoryOf,
	macLabel: macLabel,
	buildCard: buildCard,
	clearDropHl: clearDropHl,
	colCount: colCount,
	hideOfflineMode: hideOfflineMode,
	buildBoard: buildBoard,
	rebuildBoard: rebuildBoard,
	markBusy: markBusy,
	applyMove: applyMove,
	doApply: doApply,
	showCardMenu: showCardMenu,
	buildLeasePanel: buildLeasePanel,
	buildMap: buildMap,
	buildGroupsGrid: buildGroupsGrid,
	buildDevicesGrid: buildDevicesGrid,
	handleSaveApply: handleSaveApply
};
