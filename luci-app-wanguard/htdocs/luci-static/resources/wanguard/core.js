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
 * the monolith had.
 *
 * Group/device metadata (#42/#43): groupColor() now reads the UCI
 * `option color` (prototype palette) instead of stubbing; board columns
 * show `option label` + a color dot and carry `option description` as
 * the header tooltip; `wanguard devices` TYPE (5th column since the
 * #43 CLI) feeds outline SVG icons on the cards — a 4-column (old CLI)
 * output degrades to the pre-#43 card, no exceptions. The Groups grid
 * edits label/color/description, the Devices grid edits the member
 * `option devtype` override — all plain UCI, Save&Apply as everywhere.
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
	ifaceProto: {},      /* netifd iface -> proto (wireguard = VPN chip, #47) */
	filter: '',          /* board search substring (#47) */
	LB_GROUPLIST: {},   /* `wanguard grouplist` rows for direct-lb groups (#40) */
	busy: false,
	statusNode: null,   /* header pill node, set by each view's render() */
	boardWrap: null,    /* board container, set by the overview view */
	footerNode: null,    /* overview footer bar node (#47) */
	leasePanel: null,    /* DHCP lease-add panel node (#47) */
	statusCompact: false, /* overview header shows the short sync pill (#47) */
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

/* group color palette (#42): keys are the CLI-validated UCI values
 * (`wanguard groupset <name> -color <key>` / the ListValue below), hexes
 * from the UI prototypes (designe/). Missing option = no marker (the
 * pre-#42 look). */
var GROUP_COLORS = {
	blue: '#2563EB',
	green: '#22C55E',
	purple: '#7C3AED',
	orange: '#EA580C',
	gray: '#6B7280'
};

function groupColor(name) {
	var g = (uci.sections('wanguard', 'group') || []).filter(function(s) {
		return s['.name'] == name;
	})[0];
	return (g && GROUP_COLORS[g.color]) || '';
}

/* TYPE icons (#43): outline SVG matching the prototype style, one per
 * `wanguard devices` column-5 value. Rendered via innerHTML — static
 * strings from THIS table only, never user data. An unknown/empty type
 * (old 4-column CLI) paints nothing. */
var TYPE_SVG = {
	watch: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="6.5" width="10" height="11" rx="3"/><path d="M9.5 6.5 10 3h4l.5 3.5M9.5 17.5 10 21h4l.5-3.5"/><path d="M12 10.5V13l1.5 1"/></svg>',
	tv: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="12" rx="2"/><path d="M8.5 21h7M12 17v4"/></svg>',
	pc: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="5" width="16" height="10" rx="1.5"/><path d="M2.5 18.5h19l-1.5-3h-16z"/></svg>',
	printer: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M7 8V4h10v4"/><rect x="4" y="8" width="16" height="8" rx="1.5"/><path d="M7 14h10v6H7z"/></svg>',
	phone: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="3.5" width="8" height="17" rx="2"/><path d="M11 18h2"/></svg>',
	tablet: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="3.5" width="13" height="17" rx="2"/><path d="M10.5 18h3"/></svg>',
	generic: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M8.5 12h7M12 8.5v7"/></svg>'
};

function typeIcon(type) {
	var t = (type && TYPE_SVG[type]) ? type : '';
	var el = E('span', {
		'class': 'wg-type' + (t ? ' wg-type-' + t : ''),
		'title': t ? _('type: %s').format(t) : ''
	});
	el.innerHTML = TYPE_SVG[t || 'generic'];
	return el;
}

var BOARD_CSS = [
	".wg-board { display:flex; gap:12px; align-items:flex-start; overflow-x:auto; padding-bottom:8px; }",
	".wg-col { flex:1 0 15em; min-width:15em; max-width:24em; background:rgba(128,128,128,.07);",
	"\tborder:1px solid rgba(128,128,128,.25); border-radius:6px; }",
	".wg-col-h { padding:8px 10px; border-bottom:1px solid rgba(128,128,128,.25); }",
	".wg-col-title { font-weight:bold; display:flex; align-items:center; gap:.4em; }",
	".wg-col-sub { font-size:.82em; opacity:.65; }",
	".wg-col-chip { font-size:.78em; opacity:.75; margin-top:2px; cursor:default; }",
	".wg-cards { padding:8px; display:flex; flex-direction:column; gap:6px; min-height:3.2em; }",
	".wg-card { background:rgba(128,128,128,.06); border:1px solid rgba(128,128,128,.35);",
	"\tborder-radius:4px; padding:6px 8px; cursor:pointer; user-select:none; }",
	".wg-card[draggable=\"true\"] { cursor:grab; }",
	".wg-card.wg-busy { opacity:.5; pointer-events:none; }",
	".wg-card-row { display:flex; gap:.6em; align-items:flex-start; }",
	".wg-card-main { flex:1; min-width:0; }",
	".wg-card .wg-ip { font-size:.78em; opacity:.65; }",
	".wg-card .wg-status { font-size:.78em; margin-top:2px; }",
	".wg-card-menu { background:none; border:none; cursor:pointer; opacity:.6; padding:0 .3em; font-size:1em; line-height:1.2; }",
	".wg-card-menu:hover { opacity:1; }",
	".wg-on { color:#5cb85c; }",
	".wg-off { color:#999; }",
	".wg-dot { display:inline-block; width:.65em; height:.65em; border-radius:50%; margin-right:.4em; vertical-align:.05em; }",
	".wg-type { opacity:.75; line-height:1; margin-top:.15em; }",
	".wg-type svg { display:inline; vertical-align:-.12em; }",
	".wg-col.wg-drop { outline:2px dashed #4a90d9; outline-offset:-3px; background:rgba(74,144,217,.10); }",
	".wg-menu button { display:block; width:100%; margin:.25em 0; }",
	"/* #47: toolbar (search, Online-only switch, Board|List, + Add) */",
	".wg-toolbar { display:flex; flex-wrap:wrap; gap:.75em; align-items:center; margin:1em 0; }",
	".wg-search { flex:1 1 14em; min-width:10em; }",
	".wg-switch { display:inline-flex; align-items:center; gap:.45em; cursor:pointer; white-space:nowrap; }",
	".wg-switch input { position:absolute; opacity:0; width:0; height:0; }",
	".wg-switch-track { display:inline-block; width:2.1em; height:1.15em; border-radius:.6em;",
	"\tbackground:rgba(128,128,128,.4); position:relative; transition:background .15s; }",
	".wg-switch-track::after { content:''; position:absolute; top:.12em; left:.12em; width:.9em; height:.9em;",
	"\tborder-radius:50%; background:#fff; transition:left .15s; }",
	".wg-switch input:checked ~ .wg-switch-track { background:#2563eb; }",
	".wg-switch input:checked ~ .wg-switch-track::after { left:1.05em; }",
	".wg-switch input:focus-visible ~ .wg-switch-track { outline:2px solid #4a90d9; outline-offset:1px; }",
	".wg-viewtoggle { display:inline-flex; }",
	".wg-viewtoggle .btn { margin:0; }",
	".wg-viewtoggle .btn + .btn { margin-left:-1px; }",
	".wg-viewtoggle .btn:first-child { border-radius:4px 0 0 4px; }",
	".wg-viewtoggle .btn:last-child { border-radius:0 4px 4px 0; }",
	"/* #47: per-column add + New group tile */",
	".wg-col-add { border-top:1px solid rgba(128,128,128,.25); text-align:center; padding:2px; }",
	".wg-add-devices { background:none; border:none; color:#2563eb; cursor:pointer; padding:4px; }",
	".wg-add-devices:hover { text-decoration:underline; }",
	".wg-newgroup { flex:0 0 9em; min-width:9em; max-width:11em; min-height:6em; display:flex;",
	"\talign-items:center; justify-content:center; background:transparent; border-style:dashed; }",
	".wg-newgroup-btn { background:none; border:none; color:#2563eb; cursor:pointer; }",
	".wg-newgroup-btn:hover { text-decoration:underline; }",
	"/* #47: header + footer */",
	".wg-header { display:flex; align-items:baseline; gap:1em; flex-wrap:wrap; }",
	".wg-subtitle { opacity:.6; }",
	".wg-footer { display:flex; justify-content:space-between; align-items:center; gap:1em; flex-wrap:wrap; margin-top:1em; opacity:.85; }",
	".wg-pill .wg-dot { margin-right:.2em; }",
	".wg-pill-ok .wg-dot { background:#22c55e; }",
	".wg-pill-pending .wg-dot { background:#ea580c; }",
	".wg-pill-drift .wg-dot { background:#d9534f; }",
	".wg-lease-flash { outline:2px solid #4a90d9; outline-offset:2px; }",
	".wg-hint { opacity:.55; font-size:.85em; margin-bottom:.5em; }",
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
	/* `wanguard devices` (issue #14): mac<TAB>ip<TAB>name<TAB>online
	 * [<TAB>type since the #43 CLI], merged leases+ARP — includes
	 * static-IP clients. type stays '' on the old 4-column CLI
	 * (degradation: no icon, current behavior otherwise). */
	return (out || '').split('\n').map(function(line) {
		var f = line.split('\t');
		if (f.length < 4)
			return null;
		return { mac: f[0], ip: (f[1] == '-' ? '' : f[1]), name: (f[2] == '-' ? '' : f[2]), online: (f[3] == '1'), type: (f.length >= 5) ? f[4] : '' };
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
	var label;
	if (state.statusCompact) /* #47: overview header pill, counters moved to the footer */
		label = (state.statusOk === true) ? _('Rules synchronized')
			: (state.statusOk === false ? 'DRIFT: %s'.format(state.statusText) : state.statusText);
	else
		label = '%d device(s) · %d group(s) · %s%s'.format(
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
				if (dump && dump.interface)
					dump.interface.forEach(function(i) {
						if (i && i.interface)
							state.ifaceProto[i.interface] = i.proto || '';
					});
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
		updateBoardFooter();
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
	/* columns: direct groups alphabetically, then proxy, then Unclassified.
	 * #42: `label` keeps the technical "name — target" form (golden),
	 * `title` prefers the UCI display label; color/descr decorate the
	 * column header (dot + tooltip). */
	var gs = (uci.sections('wanguard', 'group') || []).map(function(g) {
		return { name: g['.name'], type: g.type || 'direct', iface: g.iface || '',
			metaLabel: g.label || '', color: GROUP_COLORS[g.color] || '', descr: g.description || '' };
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
		return { name: g.name, type: g.type, iface: g.iface, label: lbl, title: g.metaLabel || lbl,
			color: g.color, descr: g.descr };
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
		'title': it.mac + ' — ' + (inGroup
			? _('Drag to move, click for the menu')
			: _('Drag into a group to add, click for the menu'))
	}, [
		E('div', { 'class': 'wg-card-row' }, [
			it.type ? typeIcon(it.type) : E([]), /* #43: board icon */
			E('div', { 'class': 'wg-card-main' }, [
				E('div', { 'class': 'wg-name' }, [ it.name || it.ip || it.mac ]),
				E('div', { 'class': 'wg-ip' }, [ it.ip || '—' ]),
				E('div', { 'class': 'wg-status ' + (it.online ? 'wg-on' : 'wg-off') },
					[ (it.online ? '● ' : '○ ') + (it.online ? _('Online') : _('Offline')) ])
			]),
			E('button', {
				'class': 'wg-card-menu',
				'title': _('Move to another group'),
				'aria-label': _('Move to another group'),
				'click': function(ev) {
					if (ev && ev.stopPropagation)
						ev.stopPropagation();
					if (!state.busy)
						showCardMenu(it.mac, inGroup);
				}
			}, [ '⋯' ])
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

/* ---------- board 2.0 helpers (#47) ---------- */

/* toolbar search: substring over name/IP/MAC, case-insensitive */
function deviceMatches(it) {
	var q = (state.filter || '').toLowerCase().replace(/^\s+|\s+$/g, '');
	if (!q)
		return true;
	return (it.name || '').toLowerCase().indexOf(q) !== -1 ||
		(it.ip || '').toLowerCase().indexOf(q) !== -1 ||
		(it.mac || '').toLowerCase().indexOf(q) !== -1;
}

function setFilter(q) {
	state.filter = (q == null) ? '' : String(q);
}

/* column route chip: "iface · WAN" / "iface · VPN" / "Proxy" /
 * direct-lb: "wan1+wan2 · LB". Degrades to UCI-only (WAN) when the
 * netifd dump is unavailable (no VPN detection). title keeps the full
 * allocation preview so the board stays clean without losing it. */
function routeChip(g) {
	if (g.type == 'proxy')
		return { text: _('Proxy'), title: allocPreview(g.name) };
	if (g.type == 'direct-lb') {
		var mem = lbMembers(g.name);
		return {
			text: (mem.length ? mem.join('+') : (g.iface || 'lb')) + ' · ' + _('LB'),
			title: allocPreview(g.name)
		};
	}
	var proto = state.ifaceProto[g.iface] || '';
	return {
		text: (g.iface || '?') + ' · ' + (proto == 'wireguard' ? 'VPN' : 'WAN'),
		title: allocPreview(g.name)
	};
}

/* pending staged-UCI changes (honest footer pill, #47): LuCI stages
 * client-side, uci.changes() is the same source the "Unsaved Changes"
 * badge uses; 0 when the API is unavailable (degraded/old LuCI) */
function pendingCount() {
	try {
		if (typeof uci.changes == 'function') {
			var c = uci.changes('wanguard');
			return (c && c.length) ? c.length : 0;
		}
	}
	catch (e) {}
	return 0;
}

/* footer bar: "N devices · M groups" + pending pill (#47); global
 * totals (the column counters are the filtered ones). DRIFT keeps
 * the pill red and honest. */
function buildBoardFooter() {
	var node = E('div', { 'class': 'wg-footer' });
	state.footerNode = node;
	updateBoardFooter();
	return node;
}

function updateBoardFooter() {
	var node = state.footerNode;
	if (!node)
		return;
	var pend = pendingCount();
	var drift = (state.statusOk === false);
	var pill = drift
		? { cls: 'wg-pill wg-pill-drift', label: _('DRIFT — read-only') }
		: (pend > 0
			? { cls: 'wg-pill wg-pill-pending',
				label: '%d pending change(s) — Save & Apply'.format(pend) }
			: { cls: 'wg-pill wg-pill-ok', label: _('No pending changes') });
	node.innerHTML = '';
	node.appendChild(E('span', { 'class': 'wg-footer-counts' }, [
		'%d %s · %d %s'.format(state.memberCount, _('devices'),
			(uci.sections('wanguard', 'group') || []).length, _('groups'))
	]));
	node.appendChild(E('span', { 'class': pill.cls,
		'title': drift ? state.statusText : '' }, [
		E('span', { 'class': 'wg-dot' }, []), ' ', pill.label
	]));
}

/* focus the lease-add panel with a group preselected (#47); the
 * Unassigned column and the toolbar menu pass '' = just focus */
function leaseFocus(group) {
	var panel = state.leasePanel;
	if (!panel)
		return;
	if (typeof panel.scrollIntoView == 'function') {
		try { panel.scrollIntoView({ behavior: 'smooth', block: 'center' }); } catch (e) {}
	}
	var sel = null;
	(function walk(n) {
		if (sel || !n || !n.children)
			return;
		n.children.forEach(function(c) {
			if (!sel && c.attrs && c.attrs['data-wg'] == 'lease-group')
				sel = c;
			walk(c);
		});
	})(panel);
	if (sel && group)
		sel.value = group;
	panel.classList.add('wg-lease-flash');
	if (typeof setTimeout == 'function')
		setTimeout(function() { panel.classList.remove('wg-lease-flash'); }, 1600);
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

	var mkColumn = function(key, title, sub, chip, cards, color, descr) {
		var headAttrs = { 'class': 'wg-col-h' };
		if (descr) /* #42: the description is the column tooltip */
			headAttrs['title'] = descr;
		var titleContent = [];
		if (color) /* #42: palette marker dot */
			titleContent.push(E('span', { 'class': 'wg-dot', 'style': 'background:%s'.format(color) }, []));
		titleContent.push(title);
		var col = E('div', { 'class': 'wg-col', 'data-group': key }, [
			E('div', headAttrs, [
				E('div', { 'class': 'wg-col-title' }, titleContent),
				E('div', { 'class': 'wg-col-sub' }, [ sub ]),
				chip ? E('div', { 'class': 'wg-col-chip', 'title': chip.title || '' },
					[ chip.text ]) : E([])
			]),
			E('div', { 'class': 'wg-cards' }, cards),
			E('div', { 'class': 'wg-col-add' }, [
				E('button', {
					'class': 'wg-add-devices',
					'title': _('Pick a DHCP lease for this group'),
					'click': function() { leaseFocus(key || ''); }
				}, [ '+ ' + _('Add devices') ])
			])
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

	var visible = function(items) {
		if (hideOfflineMode())
			items = items.filter(function(it) { return it.online; });
		return items.filter(deviceMatches);
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
					online: !!d.online,
					type: d.type || ''
				};
			})
			.sort(function(a, b) {
				return (a.online == b.online)
					? (a.name || a.mac).localeCompare(b.name || b.mac)
					: (a.online ? -1 : 1);
			});

		var total = items.length;
		var vis = visible(items);
		board.appendChild(mkColumn(g.name, g.title,
			'%s %s'.format(colCount(vis.length, total), total == 1 ? _('device') : _('devices')),
			routeChip(g), vis.map(function(it) { return buildCard(it, true); }),
			g.color, g.descr));
	});

	/* Unassigned: seen devices that are not members of any group (#47 rename) */
	var uitems = (state.inventory || [])
		.filter(function(d) { return !known[d.mac]; })
		.sort(function(a, b) {
			return (a.online == b.online)
				? (a.name || a.mac).localeCompare(b.name || b.mac)
				: (a.online ? -1 : 1);
		});
	var utotal = uitems.length;
	uitems = visible(uitems);

	board.appendChild(mkColumn('', _('Unassigned'),
		'%s %s'.format(colCount(uitems.length, utotal), utotal == 1 ? _('device') : _('devices')),
		null, uitems.map(function(d) { return buildCard(d, false); }), '', ''));

	/* New group tile (#47): dashed shortcut to Groups & Routes */
	board.appendChild(E('div', { 'class': 'wg-col wg-newgroup' }, [
		E('button', {
			'class': 'wg-newgroup-btn',
			'title': _('Create and decorate groups on the Groups & Routes page'),
			'click': function() {
				var u = (typeof L != 'undefined' && L.url) ? L.url('admin/network/wanguard/groups') : '';
				if (u && typeof location != 'undefined')
					location.href = u;
			}
		}, [ '+ ' + _('New group') ])
	]));

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

	return doApply(mac, target);
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
		}, [ _('Move to %s').format(g.title || g.label) ]));
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

	ui.showModal(macLabel(mac) + (curGroup ? ' (' + curGroup + ')' : ' (' + _('unassigned') + ')'), menu);
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

	/* metadata (#42): UI-only options — the allocator, nft and the CLI
	 * commands never read them; label/color/description decorate the
	 * board and this grid (rmempty: absent option = the pre-#42 look) */
	o = groups.option(form.Value, 'label', _('Label'));
	o.rmempty = true;
	o.description = _('Display name for the board and grids (empty = the section name). UI-only: allocation, nft tags and the CLI keep using the section name.');

	o = groups.option(form.ListValue, 'color', _('Color'));
	o.value('', _('(none)'));
	Object.keys(GROUP_COLORS).forEach(function(k) { o.value(k, k); });
	o.rmempty = true;
	o.description = _('Marker color on the board (prototype palette). CLI equivalent: wanguard groupset %s -color <key>.');

	o = groups.option(form.Value, 'description', _('Description'));
	o.rmempty = true;
	o.description = _('Free-form note (shown as the board column tooltip).');

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

	/* device type (#43): the manual override that beats the CLI hostname
	 * heuristic; the value shows up as the board icon via `wanguard
	 * devices` column 5. Empty = auto (heuristic decides). */
	o = grid.option(form.ListValue, 'devtype', _('Device type'));
	o.value('', _('(auto — hostname heuristic)'));
	[ 'watch', 'tv', 'pc', 'printer', 'phone', 'tablet', 'generic' ].forEach(function(t) {
		o.value(t, t);
	});
	o.rmempty = true;
	o.description = _('Overrides the type guessed from the hostname (board icon). Reset: empty, or wanguard devset <mac> -.');

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

	var leaseSel = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:24em', 'data-wg': 'lease' });
	state.leases.sort(function(a, b) { return (a.name || '').localeCompare(b.name || ''); });
	state.leases.forEach(function(l, i) {
		var inGroup = known[l.mac];
		var label = '%s (%s, %s)%s'.format(
			l.name || 'unnamed', l.mac, l.ip,
			inGroup ? ' — in group ' + inGroup : '');
		leaseSel.appendChild(E('option', { 'value': String(i) }, [ label ]));
	});

	var groupSel = E('select', { 'class': 'cbi-input-select', 'data-wg': 'lease-group' });
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

/* The LuCI module loader requires every module factory to yield a CLASS
 * (Class.isSubclass check) and instantiates it: `require wanguard.core as
 * wg` binds the INSTANCE — all logic lives in closures above, so the
 * instance is a stateless facade over `state`. */
return L.Class.extend({
	__name__: 'LuCI.wanguard.core',

	__init__() {},

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
	GROUP_COLORS: GROUP_COLORS,
	TYPE_SVG: TYPE_SVG,
	typeIcon: typeIcon,
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
	deviceMatches: deviceMatches,
	setFilter: setFilter,
	routeChip: routeChip,
	pendingCount: pendingCount,
	buildBoardFooter: buildBoardFooter,
	updateBoardFooter: updateBoardFooter,
	leaseFocus: leaseFocus,
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
});
