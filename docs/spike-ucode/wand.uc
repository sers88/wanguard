#!/usr/bin/ucode
/*
 * wand.uc — ucode spike port of the wanguard wand-tick path (issue #29).
 *
 * Ported 1:1 from router/wanguard (939-line POSIX sh):
 *   - UCI reading via native uci.so   (kills uci|grep|cut|sort pipelines)
 *   - iface status via native ubus.so (kills ubus|jsonfilter|grep|awk; the
 *     ONE `network.interface dump` call replaces per-iface status calls and
 *     the whole quoted-key jsonfilter dance — the hyphen-key bug class)
 *   - anchor probe: EXTERNAL curl, kept deliberately — see PROBE NOTE
 *   - wand_backups() selection (#26) and the failover/failback state
 *     machine (3 fails down / 6 oks up / 60 s dwell / UCI-flip + deferred
 *     conntrack flush protocol via /tmp/wanguard/<group>.flush)
 *   - wan-flush (#24, stage 2): the consumer of that protocol — resolves
 *     the old egress IPv4 (live via ubus, else <old>.addr), external
 *     `conntrack -D -q <ip>`, byte-identical flush:<g>><old>(<ip>) events
 *
 * Stage 2 (#30/#32): the keepalive's whole tick->apply->flush cycle no
 * longer descends into sh for the flush leg (`conntrack` itself stays an
 * external call — fork reduction is not the goal there, leaving sh is).
 *
 * Stage 3 (#30/#33): apply native (full cmd_apply port; render parity
 * gated by stage3/apply-parity.sh, 165 checks).
 *
 * Stage 4 (#30/#34): ALL remaining subcommands native (list/add/move/
 * remove/grouplist/devices/groupadd/groupset/groupdel/wanstatus/wanset/
 * wanauto/backupset/help) — the sh passthrough is GONE; dispatch default
 * is the sh `unknown command` error.
 *
 * Stage 5 (#30/#35): the sh CLI is RETIRED from the package —
 * /usr/bin/wanguard is the pure ucode CLI, there is no wanguard-sh
 * companion anymore; the offline rollback is reinstalling the previous
 * feed tag's apk (single mechanism, same UCI/state). The sh source stays
 * in the repo (router/wanguard) purely as the lab's differential
 * reference. Byte-parity gated by stage4/cli-parity.sh (method C4) and,
 * after the retirement, by stage5/contract-gate.sh (golden bytes vs the
 * frozen contract, no sh involved).
 *
 * direct-lb (#27 adopt -> #38 impl): load balancing between WANs for
 * direct groups — the mwan3 idea (weights + per-flow stickiness via
 * conntrack), lab-proven in spike/lb (docs/spike-lb/, LAB-ALL-GREEN,
 * VERDICT.md ADOPT 2026-10-29). Delta vs the stage-5 renderer above,
 * everything else byte-identical:
 *
 *   - new group type 'direct-lb': option type 'direct-lb',
 *     list member_iface (sorted members; slot = sorted position),
 *     option weight_<iface> (absent/garbage/0 -> 50; normalized to
 *     buckets mod 100, remainder to the last member).
 *
 *   - alloc_entries(): a direct-lb group expands into N slots (one per
 *     member), each slot = an ordinary (mark, table, prio) from the SAME
 *     allocator — so reconcile_rules/reconcile_routes, the metric-200
 *     fallback and orphan cleanup work unchanged. Slots are keyed by
 *     SORTED member name: marks/tables are STABLE across weight edits
 *     and re-renders (established flows keep their mark; only member
 *     add/remove re-keys a member — a deliberate restructure, class #24).
 *
 *   - desired_rules(): per LB group 1+N rules instead of per-slot marks.
 *     stick (tag wg:<g>:stick): restore ct mark + return — established
 *     flows keep their egress. members (tag wg:<g>:s<cut>@<mark>): a
 *     numgen-random CASCADE — rule i takes `numgen random mod 100 < cut`
 *     of the remaining share, the LAST member is the unconditional
 *     remainder (no draw; also sidesteps nft's rejection of `< 100`).
 *     Each new flow's first packet draws once, the conntrack pin keeps
 *     it there. TWO LIVE LAB FINDINGS (spike sessions 1-2, nft 1.1.6 +
 *     the 25.12 kernel) shape this code:
 *       1. every member rule MUST end with `return` — a rule without a
 *          verdict does NOT stop traversal; the unconditional last rule
 *          overwrote all earlier marks and 100% of flows funneled into
 *          the last member. jhash was REJECTED entirely: its concat
 *          input registers are clobbered by any preceding expression
 *          (set lookups, iifname, meta mark match) — interval maps,
 *          range forms and gated relationals all degenerate on this
 *          nft/kernel; numgen draws from prandom and is immune (owner
 *          confirmed the jhash withdrawal, 2026-10-29).
 *       2. LB member cascades are ORDER-SENSITIVE: `add rule` APPENDS at
 *          the chain end, so a tag-diff swap of ONE member rule (weight
 *          flip) placed the draw rule AFTER the unconditional remainder
 *          and every flow funneled into the last member. If ANY member
 *          tag of a group changes, apply() re-renders that group's
 *          WHOLE cascade: appending the members back in slot order
 *          rebuilds the order (stick never moves — its tag/body are
 *          constant; disjoint MAC sets make cross-group order inert).
 *
 *   - apply(): type validation accepts 'direct-lb'; set creation and
 *     element diffs dedupe by group (N slots share ONE mac_<g> set).
 *
 *   - tick(): the LB failover phase (#39). wand_wans() watches the LB
 *     members (the probe hysteresis is the debounce — NO dwell); a dead
 *     member's slot is inherited by the first ALIVE member in sorted
 *     order (event `lbover:<g>:<member>><live>` + `list member_live`
 *     written to UCI), a recovered member ALWAYS takes its slot back,
 *     zero alive = slots stand declared (fail-open, same as every
 *     group's table). The dead egress gets the #24 conntrack flush:
 *     tick writes `<g>.flush`, the keepalive executes it AFTER apply —
 *     the order tick -> apply -> wan-flush is unchanged. The render
 *     path honors member_live: the inherited slot's table re-targets
 *     to the alive member's device, pinned sessions survive on the ct
 *     mark. override/wanauto semantics do NOT extend to LB groups
 *     (weights are the owner's manual decision).
 *
 * Group/device metadata (#42/#43, v1.4.0): pure UCI options that the
 * data plane NEVER reads — labels/colors/descriptions decorate the LuCI
 * pages, devtype feeds the board icons. Additive CLI on top:
 *   - groupset <name> -label V -color V -description V (empty value =
 *     clear; color validated against the prototype palette; NO apply —
 *     render does not depend on metadata). The legacy target form
 *     `groupset <name> <iface|proxy>` stays byte-frozen (stages 10-11).
 *   - groupmeta [name]: machine-readable name/label/color/description
 *     TAB rows ('-' = unset). Appending columns to `grouplist` would
 *     have broken the frozen contract — that is why this is a separate
 *     subcommand.
 *   - devices gained an ADDITIVE 5th TAB column TYPE (hostname
 *     heuristic, member `option devtype` overrides it; the frozen
 *     contract is the 4-column prefix, gated byte-wise by cli-parity +
 *     the stage5 D.out golden).
 *   - devset <mac> <type|-> writes that override (whitelist of types,
 *     err on unregistered MACs; no apply for the same reason).
 *
 * Lab: docs/spike-lb/lab/ (topology of spike-ucode #30 + a lan bridge
 * with a client container; L1 render battery runs against THIS file —
 * the #38 acceptance vehicle `lab-up.sh up-prod`).
 *
 * PROBE NOTE (spike finding, Step 1.3): uclient.so exposes
 * new(url,auth,cb)/set_timeout/request/status but libuclient has NO
 * interface/device binding (no SO_BINDTODEVICE anywhere, uclient-fetch
 * has no --interface either) — the probe's `curl --interface <l3_device>`
 * semantics cannot be reproduced in-process. The probe therefore stays a
 * curl child; fork win #3 shrinks accordingly (documented in the issue).
 */

import * as uci from 'uci';
import * as ubus from 'ubus';
import * as fs from 'fs';

const CONF = 'wanguard';
const WAND_DIR = '/tmp/wanguard';
const MIN_DWELL = 60;    // s between group switches
const FAILS_DOWN = 3;    // consecutive probe fails -> down
const OKS_UP = 6;        // consecutive oks -> up again
const DEF_ANCHORS = [
	'http://www.gstatic.com/generate_204',
	'http://detectportal.firefox.com/success.txt',
];

// ---------- #42/#43 metadata (UCI-only; the data plane never reads it) ----------

// group color palette (#42): the prototype's CSS hexes live in luci
// core.js — the CLI validates the KEY only
const GROUP_COLORS = { blue: 1, green: 1, purple: 1, orange: 1, gray: 1 };

// device types (#43): the whitelist of `devset` / member `option devtype`
const DEV_TYPES = { watch: 1, tv: 1, pc: 1, printer: 1, phone: 1, tablet: 1, generic: 1 };

// ---------- state file helpers ----------

function state_read(name, dflt) {
	let s = fs.readfile(`${WAND_DIR}/${name}`);
	s = s ? trim(s) : '';
	return (s != '') ? s : dflt;
}

function state_write(name, val) { fs.writefile(`${WAND_DIR}/${name}`, `${val}\n`); } // sh parity: `echo val > file`

function state_int(name) {
	let s = state_read(name, '0');
	return int(match(s, /^[0-9]+$/) ? s : '0');
}

// ---------- diagnostics data plane: wand state + event ring (#44) ----------
//
// tmpfs UI feed for the LuCI status badge / Diagnostics page (issue #44):
// a bounded event ring and the last-successful-apply stamp, next to the
// existing wand state files. NOT a syslog replacement (#21) — the ring
// lives in WAND_DIR and is lost on reboot by design; keepalive's logger
// pipe stays the durable record. Every write is BEST-EFFORT: a ring
// failure must never break the tick -> apply -> flush path, hence the
// catch-all and the atomic tmp+rename persist.
// NB: declared here, BEFORE tick()/apply()/wanflush() — ucode does not
// hoist function declarations, the whole file is define-before-use.

const EVENTS_MAX = 200; // ring clamp (lines; ~weeks of incident events,
let ev_seq = 0;         // one heartbeat line per apply-outcome change)

function state_dir() { // WAND_DIR may not exist before the first tick
	if (!fs.access(WAND_DIR))
		fs.mkdir(WAND_DIR);
}

function events_append(code, detail) { // one `ts<TAB>code<TAB>detail` row
	try {
		state_dir();
		let d = replace(replace('' + (detail ?? ''), /\t/g, ' '), /\n/g, ' ');
		let path = `${WAND_DIR}/events`;
		let cur = fs.readfile(path);
		let lines = ((cur != null) && (trim(cur) != '')) ? split(trim(cur), /\n/) : [];
		push(lines, `${time()}\t${code}\t${d}`);
		while (length(lines) > EVENTS_MAX)
			shift(lines);
		// unique tmp (same-second appends within one process), then
		// atomic rename: a crash mid-write never truncates the ring
		let tmp = `${WAND_DIR}/.evtmp.${time()}.${ev_seq++}`;
		fs.writefile(tmp, join('\n', lines) + '\n');
		fs.rename(tmp, path);
	} catch (e) { /* best-effort: the caller's path is sacred */ }
}

function events_apply_ok(changed) { // the `in-sync` heartbeat repeats every
	// 10 s keepalive cycle — recording each one would fill the 200-line
	// ring in ~33 quiet minutes and scroll the real events out. Write the
	// FIRST of a run only (dedupe by the ring's last row); every `applied`
	// outcome is a real render and is always recorded.
	if (changed == 1) {
		events_append('apply_ok', 'applied');
		return;
	}
	let cur = fs.readfile(`${WAND_DIR}/events`);
	if (cur != null) {
		let lines = split(trim(cur), /\n/);
		let last = (length(lines) > 0) ? lines[length(lines) - 1] : '';
		if (match(last, /\tapply_ok\tin-sync$/) != null)
			return; // heartbeat continuation — the ring already says it
	}
	events_append('apply_ok', 'in-sync');
}

function desired_signature(alloc, want) { // desired-side fingerprint (rule
	let s = [];                            // tags + set memberships). Drift
	for (let w in want)                    // (#44) = a live diff while THIS
		push(s, `${w.chain} ${w.tag}`);    // is unchanged since the last
	for (let a in alloc)                   // successful apply — i.e. UCI did
		push(s, join(',', desired_group(a.g))); // not change, live did (a
	return join('|', s);                   // manual nft edit, a foreign tool)
}
// ---------- UCI (single cursor snapshot; tick never re-reads what it set) ----------

let cursor = uci.cursor();

function group_ids(type) { // sorted section ids of type group, filtered by kind
	let ids = [];
	cursor.foreach(CONF, 'group', (s) => {
		if (type == null || s.type == type) push(ids, s['.name']);
	});
	return sort(ids);
}

function direct_ids() { return group_ids('direct'); }

function group_opt(g, opt) {
	let v = cursor.get(CONF, g, opt);
	return (v == null) ? '' : v;
}

function globals_opt(opt) {
	let v = cursor.get(CONF, 'globals', opt);
	return (v == null) ? '' : v;
}

// ---------- ubus iface status (ONE dump call for all ifaces) ----------

function ubus_conn() { // absent ubusd == "all ifaces down", same as sh `|| exit`
	// NB: no socket-path pre-check — the socket path is the ubus module's
	// business (this build uses /var/run/ubus/ubus.sock, the hardcoded
	// /var/run/ubus.sock check silently disabled the whole map)
	try {
		let conn = ubus.connect(); // raises when ubusd is absent/dead
		for (let o in conn.list()) // conn.list() = object names
			if (o == 'network.interface')
				return conn;
		conn.disconnect();
	}
	catch (e) {
		return null; // keepalive just re-runs the tick in 10 s
	}
	return null;
}

function iface_map() { // netifd name -> { device, addr } for UP ifaces
	let conn = ubus_conn();
	let map = {};
	if (!conn)
		return map;
	let dump = conn.call('network.interface', 'dump', {});
	conn.disconnect();
	for (let rec in (dump?.interface ?? [])) {
		if (!rec.up)
			continue;
		let dev = rec.l3_device ?? rec.device ?? '';
		let addr = '';
		for (let a in (rec['ipv4-address'] ?? []))
			if (a.address) { addr = a.address; break; }
		map[rec.interface] = { device: dev, addr: addr };
	}
	return map;
}

// ---------- probe anchors (#23) ----------

function anchors() { // list wins > legacy anchor1/2 > 2 defaults
	let l = cursor.get(CONF, 'globals', 'wan_anchors');
	if (l) {
		if (type(l) == 'array')
			return l;
		// string form (`uci set ...='u1 u2 u3'`): sh word-split parity
		return filter(split(l, /\s+/), function(s) { return s != ''; });
	}
	let out = [];
	for (let legacy in [ 'wan_anchor1', 'wan_anchor2' ]) {
		let v = globals_opt(legacy);
		if (v != '') push(out, v);
	}
	return length(out) ? out : DEF_ANCHORS;
}

function reliability() { // N of M anchors must answer, clamped to [1..M]
	let n = int(globals_opt('wan_reliability') || '1') || 1;
	let m = length(anchors());
	return (n > m) ? m : n;
}

function probe(wan, dev, map) { // >= reliability anchors answered?
	let force = fs.readfile(`${WAND_DIR}/${wan}.force`);
	if (force != null) { // test hook (#6): whole-probe ok|fail semantics
		force = trim(force);
		if (force == 'ok') {
			state_write(`${wan}.alive`, length(anchors()));
			state_write(`${wan}.rtt`, 0);
			return true;
		}
		state_write(`${wan}.alive`, 0);
		return false;
	}
	let alive = 0, minrtt = null;
	for (let url in anchors()) {
		// exact curl contract: bind to l3_device, 5 s timeout, fail on
		// HTTP error, RTT of the full exchange; rc != 0 = anchor dead
		let p = fs.popen(`curl --interface ${dev} -m 5 -sf -o /dev/null -w '%{time_total}' ${url} 2>/dev/null`, 'r');
		let out = trim(p.read('all') ?? '');
		let rc = p.close();
		if (rc != 0 || out == '')
			continue;
		alive++;
		// keep curl's ORIGINAL string (0.050, not 0.05 — wanstatus shows
		// it verbatim); compare numerically, store as-is (sh parity)
		if (minrtt == null || +out < +minrtt)
			minrtt = out;
	}
	state_write(`${wan}.alive`, alive);
	if (minrtt != null)
		state_write(`${wan}.rtt`, minrtt);
	return alive >= reliability();
}

// ---------- watched WANs + backup selection (#26) ----------

function lb_member_ifcs(g) { // sorted member iface names of an LB group
	// EARLY helper: ucode does not hoist declarations here, so callers
	// that execute before lb_members()'s line use this one (the apply
	// path via lb_members; the tick LB phase of #39 will do the same —
	// weights are irrelevant on those paths)
	let raw = cursor.get(CONF, g, 'member_iface');
	if (type(raw) == 'string') // single-element list tolerance
		raw = (trim(raw) != '') ? [ raw ] : null;
	if (type(raw) != 'array')
		return [];
	return sort(raw);
}

function wand_wans() { // distinct CURRENT+HOME of direct groups + LB
	// members, sorted: homes MUST be probed — else a failed-over group's
	// dead home could never be seen recovering (live bug 2026-10-13);
	// LB members MUST be probed too (#27/#39: an unwatched member's
	// slot could neither fail over nor fail back)
	let wans = [];
	for (let g in direct_ids()) {
		let ifc = group_opt(g, 'iface');
		if (ifc != '') push(wans, ifc);
		let home = group_opt(g, 'wan_home');
		if (home != '') push(wans, home);
	}
	for (let g in group_ids('direct-lb'))
		for (let m in lb_member_ifcs(g))
			push(wans, m);
	return uniq(sort(wans));
}

function backups(g, home) { // ordered candidates (#26, mwan3 semantics):
	// explicit `list backup_iface` wins: first UP in that order is the
	// failover target; home, duplicates and unwatched names are dropped
	// (unwatched would look optimistic-up and get picked blindly). No
	// usable list => every other watched WAN A-Z (pre-#26 default).
	let watched = {}; // object set: `x in array` tests indices, not values
	for (let w in wand_wans()) watched[w] = 1;
	let raw = cursor.get(CONF, g, 'backup_iface') ?? [];
	if (type(raw) == 'string') raw = split(raw, /\s+/);
	let out = [], listed = {};
	for (let e in raw) {
		if (e == home || e == '' || !(e in watched) || listed[e])
			continue;
		listed[e] = 1;
		push(out, e);
	}
	if (length(out))
		return out;
	for (let e in watched)
		if (e != home)
			push(out, e);
	return out;
}

function wan_state(wan) { return state_read(`${wan}.state`, 'up'); }

// ---------- conntrack flush on egress switch (issue #24, stage 2) ----------

// Forwarded client traffic is masqueraded: the NAT binding lives in the
// conntrack entry, so after a group moves to another WAN long-lived
// sessions keep flowing out the OLD egress until the entries expire
// (the classic mwan3 problem). Targeted fix: delete only entries whose
// reply-dst is the old egress IPv4 — exactly the mappings made through
// it. Connections TO the router (SSH/LuCI/DNS) and LAN<->LAN traffic
// are never NAT'ed (reply-dst is a LAN address) and can never match.
// Router-own flows (probes, NTP) are short-lived; a hit one re-keys on
// the next packet. Proxy groups are never switched, hence never flushed
// (mihomo re-dials itself). `conntrack` stays an EXTERNAL call (fork
// reduction is not the goal on this leg — leaving sh for the whole
// tick->apply->flush cycle is); without the tool the flush degrades to
// a no-op: failover still works, sessions heal the old way.

function conntrack_available() { // sh parity: `command -v conntrack`
	return system('command -v conntrack >/dev/null 2>&1') == 0;
}

function conntrack_flush(g, old, map) { // event string; '' = nothing to do
	if (old == '')
		return '';
	if (!conntrack_available())
		return '';
	let ip = map[old]?.addr ?? ''; // live address (wanset/groupset: the
	if (ip == '')                  // old iface is still up for those)
		ip = state_read(`${old}.addr`, ''); // remembered by the probe
	if (ip == '')                  // phase (#24: by flip time the dead
		return '';             // iface has no address left to resolve)
	// rc ignored: a tool error must not eat the event — sessions heal
	// the old way, the event is what the operator sees in the log
	let p = fs.popen(`conntrack -D -q ${ip} >/dev/null 2>&1`, 'r');
	p.read('all');
	p.close();
	return `flush:${g}>${old}(${ip})`;
}

function wanflush() { // process pending flush requests written by tick (#24):
	// tick runs BEFORE the keepalive's apply, the flush must run AFTER
	// it (otherwise sessions created in between re-grab the old NAT
	// binding). Files are consumed BEFORE processing: the handling is
	// idempotent, a mid-way crash must not re-flush.
	let map = iface_map(); // ONE dump for the whole batch (sh resolves per
			       // iface) — events and their order are identical
	let events = [];
	// sh glob expands alphabetically; no dir / no matches => nothing
	for (let f in sort(fs.glob(`${WAND_DIR}/*.flush`) ?? [])) {
		if (fs.stat(f)?.type != 'file') // sh `[ -f ]` parity: non-regular
			continue;               // glob hits are left untouched
		let m = match(f, /\/([^\/]+)\.flush$/); // basename minus suffix
		let old = trim(fs.readfile(f) ?? '');
		fs.unlink(f); // errors ignored (rm -f parity)
		let ev = conntrack_flush((m != null) ? m[1] : '', old, map);
		if (ev != '') {
			push(events, ev);
			events_append('flush', ev); // #44 ring: detail = flush:<g>><old>(<ip>)
		}
	}
	if (length(events))
		print(`wand:${join(' ', events)}\n`); // byte-identical to sh
}

// ---------- wand-tick: one watchdog step ----------

function tick() {
	if (system('command -v curl >/dev/null 2>&1') != 0)
		return; // sh parity: no curl -> the whole tick is a no-op
	if (!fs.access(WAND_DIR))
		fs.mkdir(WAND_DIR); // fresh boot: state dir may not exist yet
	let now = time();
	let map = iface_map();
	let events = [];

	// --- probe phase: per-wan oks/fails state files ---
	for (let wan in wand_wans()) {
		let rec = map[wan] ?? { device: '', addr: '' };
		if (rec.device != '') // remember live IPv4 (#24): by flip time the
			if (rec.addr != '') // dead iface has no address left to resolve
				state_write(`${wan}.addr`, rec.addr);
		let ok = (rec.device != '') && probe(wan, rec.device);
		if (ok) {
			let oks = state_int(`${wan}.oks`) + 1;
			state_write(`${wan}.fails`, 0);
			state_write(`${wan}.oks`, oks);
			if (wan_state(wan) == 'down' && oks >= OKS_UP) {
				state_write(`${wan}.state`, 'up');
				state_write(`${wan}.since`, now);
				push(events, `up:${wan}`);
			}
		} else {
			let fails = state_int(`${wan}.fails`) + 1;
			state_write(`${wan}.fails`, fails);
			state_write(`${wan}.oks`, 0);
			if (wan_state(wan) == 'up' && fails >= FAILS_DOWN) {
				state_write(`${wan}.state`, 'down');
				state_write(`${wan}.since`, now);
				push(events, `down:${wan}`);
			}
		}
	}

	// --- group phase: failover/failback through UCI (rendered by apply) ---
	let dirty = false;
	for (let g in direct_ids()) {
		if (group_opt(g, 'wanmode') == 'override')
			continue;
		let home = group_opt(g, 'wan_home');
		let cur = group_opt(g, 'iface');
		if (home == '') { // seed once: where the group sits becomes home
			if (cur == '')
				continue;
			cursor.set(CONF, g, 'wan_home', cur);
			dirty = true;
			push(events, `seed:${g}>${cur}`);
			continue;
		}
		if (now - state_int(`${g}.lastswitch`) < MIN_DWELL)
			continue;
		if (cur != home && wan_state(home) == 'up') { // failback: home recovered
			cursor.set(CONF, g, 'iface', home);
			dirty = true;
			state_write(`${g}.lastswitch`, now);
			state_write(`${g}.flush`, cur); // backup being left gets flushed
			push(events, `failback:${g}>${home}`);
			events_append('failback', `${g}>${home}`); // #44 ring
			continue;
		}
		// home down: failover — or re-failover when the backup died too
		// (#26: selection walks the priority list; before, the group sat
		// dead until home returned)
		if (wan_state(cur) == 'up')
			continue; // current egress alive — hold
		let backup = '';
		for (let w in backups(g, home)) {
			if (w == cur)
				continue;
			if (wan_state(w) == 'up') { backup = w; break; }
		}
		if (backup == '')
			continue;
		cursor.set(CONF, g, 'iface', backup);
		dirty = true;
		state_write(`${g}.lastswitch`, now);
		state_write(`${g}.flush`, cur); // deferred conntrack flush (#24):
		push(events, `failover:${g}>${backup}`); // processed after apply by wan-flush
		events_append('failover', `${g}>${backup}`); // #44 ring
	}

	// --- LB phase (#27/#39): member_live = the effective iface per slot ---
	// A healthy member always takes its slot BACK (failback); a dead
	// member's slot is inherited by the first ALIVE member in sorted
	// order (no dwell: the probe hysteresis already debounces the
	// flap). Zero alive members: slots stand declared (fail-open, the
	// same behavior as every group's table). The dead egress gets the
	// #24 conntrack flush: its NAT bindings are the only thing keeping
	// pinned sessions on a dead path. override/wanauto semantics do NOT
	// extend to LB groups (weights are the owner's manual decision).
	for (let g in group_ids('direct-lb')) {
		let mem = lb_member_ifcs(g);
		if (length(mem) == 0)
			continue;
		let live = cursor.get(CONF, g, 'member_live');
		if (type(live) != 'array' || length(live) != length(mem))
			live = slice(mem, 0); // declared: every slot on its member
		let want = [], dirty_lb = false;
		for (let i = 0; i < length(mem); i++) {
			let cur = live[i] ?? mem[i];
			let alt = '';
			if (wan_state(mem[i]) == 'up') {
				alt = mem[i];
			} else {
				for (let m in mem)
					if (wan_state(m) == 'up') { alt = m; break; }
				if (alt == '')
					alt = mem[i]; // nobody alive: hold declared
			}
			push(want, alt);
			if (cur != alt) {
				push(events, `lbover:${g}:${mem[i]}>${alt}`);
				events_append('lbover', `${g}:${mem[i]}>${alt}`); // #44 ring
				dirty_lb = true;
				if (alt != mem[i])
					state_write(`${g}.flush`, mem[i]); // #24, see wanflush
			}
		}
		if (dirty_lb) {
			cursor.set(CONF, g, 'member_live', want);
			dirty = true;
		}
	}
	if (dirty) {
		cursor.save(CONF);
		cursor.commit(CONF);
	}

	if (length(events))
		print(`wand: ${join(' ', events)}\n`); // byte-identical to sh
}

// ---------- extras ----------

function probe_selftest() { // router window evidence (runbook window 2)
	let map = iface_map();
	printf('ubus map: %J\n', map);
	for (let wan in wand_wans()) {
		let rec = map[wan] ?? { device: '', addr: '' };
		printf('%s: dev=%s addr=%s anchors=%d reliability=%d\n',
			wan, rec.device, rec.addr, length(anchors()), reliability());
		for (let url in anchors())
			printf('  %s -> alive=%s rtt=%s\n', url,
				state_read(`${wan}.alive`, '-'), state_read(`${wan}.rtt`, '-'));
	}
}


// ---------- apply: UCI -> nft + ip rules + routes (stage 3, #33) ----------
//
// 1:1 port of cmd_apply (router/wanguard): render model, single source of
// truth. External calls stay external (nft/ip — fork reduction is not the
// goal on these legs, same precedent as conntrack in stage 2); what the
// port removes is the grep/sed/awk pipeline around them:
//   - alloc: deterministic from sorted group names (ARCHITECTURE.md §2)
//   - nft diff by `wg:<group>:*` comment tags (bodies never compared —
//     nft normalizes marks to 0x..., the tag fully determines the rule)
//   - batch = sets -> orphan-rule deletes -> rule adds -> element diffs
//     -> orphan-set flush/delete; THAT ORDER IS LOAD-BEARING on real nft
//     (`delete set` on a still-referenced set = "Resource busy", NOTES.md
//     §A4) — do not reorder
//   - `nft -c` gate: any reject aborts BEFORE anything applies (err, rc 1)
//   - ip rules + per-group tables, metric-200 fallback, orphan cleanup
//     (allocator range 400-500 only)
// Parse surfaces mirror the sh greps/seds exactly (transcripts + port
// notes: stage3/NOTES.md §E) — including the route greps' trailing space.

const TABLE = 'inet wanguard';
const NFT_FILE = '/usr/share/wanguard/wanguard.nft';
const BR = 'br-lan';

function msg(s) { print(s + '\n'); } // sh msg(): stdout

function fail(s) { // sh err(): stderr + exit 1
	warn(`wanguard: ${s}\n`);
	exit(1);
}

function sh_read(cmd) { // captured stdout of an external command, '' on error
	let p = fs.popen(cmd, 'r');
	let out = p.read('all') ?? '';
	p.close();
	return out;
}

function sh_rc(cmd) { // exit code of an external command, output dropped
	let p = fs.popen(cmd, 'r');
	p.read('all');
	return p.close();
}

function migrate_legacy() { // create a/b/c from the legacy layout, once
	if (length(group_ids()) > 0)
		return;
	let wa = cursor.get(CONF, 'wan', 'group_a');
	// NB: named sections are created by the THREE-argument set(conf,
	// sid, type) form — a four-argument set(conf, sid, '.type', val)
	// silently fails (NOTFOUND: the section does not exist yet)
	cursor.set(CONF, 'a', 'group');
	cursor.set(CONF, 'a', 'type', 'direct');
	cursor.set(CONF, 'a', 'iface', (wa == 'pppoe') ? 'wan2' : 'vpn');
	cursor.set(CONF, 'b', 'group');
	cursor.set(CONF, 'b', 'type', 'direct');
	cursor.set(CONF, 'b', 'iface', 'wan2');
	cursor.set(CONF, 'c', 'group');
	cursor.set(CONF, 'c', 'type', 'proxy');
	cursor.save(CONF);
	cursor.commit(CONF);
	// the cursor is a SNAPSHOT: sections set after its creation are
	// invisible to foreach. sh never has this problem (every `uci` call
	// is a fresh subprocess), so re-read like sh would.
	cursor = uci.cursor();
	msg('migrated legacy layout: groups a(vpn) b(wan2) c(proxy) created (config wan left as-is)');
}

function ensure_table() { // skeleton hallmark: the local_v4 set
	if (sh_rc(`nft list set ${TABLE} local_v4 >/dev/null 2>&1`) == 0)
		return true;
	sh_rc(`nft delete table ${TABLE} >/dev/null 2>&1`);
	return sh_rc(`nft -f ${NFT_FILE}`) == 0;
}

// ---------- direct-lb helpers (#27/#38) ----------

function lb_members(g) { // sorted members [{ ifc, w }]; weights default 50
	let out = [];
	for (let ifc in lb_member_ifcs(g)) {
		let v = group_opt(g, `weight_${ifc}`);
		let w = int(match(v, /^[0-9]+$/) ? v : '50');
		push(out, { ifc: ifc, w: (w > 0) ? w : 50 });
	}
	return out;
}

function lb_buckets(w) { // weights -> buckets summing to 100 (floor +
	let out = [], sum = 0, acc = 0; // remainder to the LAST member)
	for (let x in w)
		sum += x;
	if (sum == 0)
		sum = 1;
	for (let i = 0; i < length(w); i++) {
		if (i == length(w) - 1) {
			push(out, 100 - acc);
			break;
		}
		let b = (100 * w[i]) / sum; // ucode int division (operands int)
		push(out, int(b));
		acc += int(b);
	}
	return out;
}

function alloc_entries() { // [{g, typ, m, t, p, ifc}] (sh alloc_lines)
	let out = [], nproxy = 0, k = 0;
	for (let g in group_ids('proxy')) {
		if (nproxy == 0)
			push(out, { g: g, typ: 'proxy', m: 300, t: 500, p: 8000, ifc: '' });
		nproxy++;
	}
	if (nproxy > 1)
		warn(`wanguard: ${nproxy} proxy groups defined; mihomo is a singleton — rendering only the first\n`);
	for (let g in group_ids('direct')) {
		k++;
		if (k > 99) {
			warn(`wanguard: too many direct groups (>99), ignoring '${g}'\n`);
			continue;
		}
		let m = 100 * k;
		if (m >= 300) // 300 = mihomo
			m += 100;
		push(out, { g: g, typ: 'direct', m: m, t: 400 + k - 1, p: 8100 + k - 1,
			ifc: group_opt(g, 'iface') });
	}
	for (let g in group_ids('direct-lb')) {
		// #27/#38: one slot per member, keyed by SORTED member name
		// (marks/tables stable across weight edits — see header)
		let mem = lb_members(g);
		if (length(mem) == 0) {
			warn(`wanguard: lb group '${g}' has no member_iface — ignoring\n`);
			continue;
		}
		if (length(mem) > 20) {
			warn(`wanguard: lb group '${g}': >20 members — ignoring\n`);
			continue;
		}
		// tick-owned effective iface per slot (#39 starts writing it;
		// until then slots render the declared member — a hand-set
		// value is honored)
		let live = cursor.get(CONF, g, 'member_live');
		if (type(live) != 'array')
			live = null;
		for (let i = 0; i < length(mem); i++) {
			k++;
			if (k > 99) {
				warn(`wanguard: too many group slots (>99), ignoring '${g}' member '${mem[i].ifc}'\n`);
				break;
			}
			let m = 100 * k;
			if (m >= 300) // 300 = mihomo
				m += 100;
			let live_ifc = (live != null && type(live[i]) == 'string' && trim(live[i]) != '') ?
				live[i] : mem[i].ifc;
			push(out, { g: g, typ: 'direct-lb', m: m, t: 400 + k - 1, p: 8100 + k - 1,
				ifc: live_ifc, mi: mem[i].ifc });
		}
	}
	return out;
}

function desired_rules(alloc, redir) { // [{chain, tag, body}] (sh DRF)
	let out = [];
	// #27/#38: collect LB groups (marks by sorted member name) while
	// walking the alloc; per-slot marking rules are NOT emitted for them
	let lbg = {};
	for (let a in alloc) {
		if (a.typ == 'direct-lb') {
			let mem = lbg[a.g] ?? [];
			let w = 50;
			for (let m in lb_members(a.g))
				if (m.ifc == a.mi) { w = m.w; break; }
			push(mem, { ifc: a.mi, m: a.m, w: w });
			lbg[a.g] = mem;
			continue;
		}
		if (a.typ == 'proxy') {
			// TCP is handled by the redirect rule and MUST NOT be marked —
			// after DNAT-to-local a marked packet would be policy-routed
			// into the TUN (postmortem issue #5)
			push(out, { chain: 'marking', tag: `wg:${a.g}:m${a.m}`,
				body: `iifname "${BR}" ether saddr @mac_${a.g} meta l4proto != tcp ip daddr != @local_v4 ip daddr != @no_mark meta mark set ${a.m}` });
			push(out, { chain: 'redir', tag: `wg:${a.g}:r${redir}`,
				body: `iifname "${BR}" ether saddr @mac_${a.g} ip daddr != @local_v4 ip daddr != @no_mark meta l4proto tcp redirect to :${redir}` });
		} else {
			push(out, { chain: 'marking', tag: `wg:${a.g}:m${a.m}`,
				body: `iifname "${BR}" ether saddr @mac_${a.g} ip daddr != @local_v4 ip daddr != @no_mark meta mark set ${a.m}` });
		}
	}
	// #27/#38: one stick + N member rules per LB group, in group order.
	// stick MUST precede its member rules (restore wins for established
	// flows); on any re-render the stick tag never changes, so its
	// position survives, and the member rules re-added by the tag-diff
	// append AFTER it — order is preserved by construction (mac sets
	// partition traffic, so cross-group chain order is irrelevant).
	for (let g in sort(keys(lbg))) {
		let mem = lbg[g]; // sorted member name order (alloc order)
		let b = lb_buckets((map(mem, (m) => m.w)));
		// stick: established flows follow their ct mark and skip the
		// rest of the chain (base chain return = policy accept);
		// counter BEFORE return (return ends the rule)
		push(out, { chain: 'marking', tag: `wg:${g}:stick`,
			body: `iifname "${BR}" ether saddr @mac_${g} ip daddr != @local_v4 ip daddr != @no_mark ct mark != 0 counter meta mark set ct mark return` });
		// member selection: NUMGEN RANDOM cascade (mwan3's own approach:
		// statistic random on NEW + connmark restore). LIVE LAB FINDING
		// (spike session 1, nft 1.1.6 + the 25.12 kernel): jhash is
		// UNUSABLE here — its concat input registers are clobbered by
		// ANY prior expression in the same rule (set lookups, iifname,
		// meta mark match) AND by lookups executed in earlier rules of
		// the packet's traversal (a bare jhash in a jump sub-chain still
		// reads garbage). Manifestations: the anonymous interval map
		// degenerated to the first bucket, the normalized range form
		// never matched, the gated relational form always bucket 0.
		// numgen draws from prandom instead of packet registers — the
		// full prefix + numgen rules behave honestly (70/30 observed).
		// CASCADE: rule i takes `numgen random mod 100 < cum_i` of the
		// REMAINING share, the LAST member needs no draw (it gets the
		// remainder — also avoids `< 100`, which nft rejects: "Value
		// 100 exceeds valid range 0-99"). Independent draws are safe
		// exactly because each rule fires only on the not-yet-taken
		// remainder. Established flows never reach these rules (stick
		// above returns them); each new flow's FIRST packet draws once,
		// the conntrack pin makes the flow stick.
		// NB (spike session 2, LIVE FINDING): every member rule MUST end
		// with `return` — a rule without a verdict does NOT stop
		// traversal, so the packet fell through to the unconditional
		// LAST rule and its mark OVERWROTE all earlier ones: 100% of
		// flows funneled into the last member ("numgen random is not
		// uniform" of the session-1 notes was THIS bug, not the draw).
		// Lab proof: 40/40 flows mark=400 while rule 1 had drawn <70 on
		// 29/40 first SYNs (72.5% ≈ the honest 70%) — the draws were
		// always fine.
		let acc = 0;
		for (let i = 0; i < length(mem); i++) {
			let cut = acc + b[i];
			let body = `iifname "${BR}" ether saddr @mac_${g} ip daddr != @local_v4 ip daddr != @no_mark `;
			if (i < length(mem) - 1)
				body += `numgen random mod 100 < ${cut} `;
			body += `counter meta mark set ${mem[i].m} ct mark set meta mark return`;
			push(out, { chain: 'marking', tag: `wg:${g}:s${cut}@${mem[i].m}`,
				body: body });
			acc = cut;
		}
	}
	return out;
}

function live_rule_tags() { // [{chain, tag, handle}] (sh HRF; sh sed parity)
	let out = [];
	for (let ch in [ 'marking', 'redir' ]) {
		for (let line in split(sh_read(`nft -a list chain ${TABLE} ${ch} 2>/dev/null`), /\n/)) {
			let m = match(line, /comment "(wg:[^"]*)".*# handle ([^ ]*)/);
			if (m != null)
				push(out, { chain: ch, tag: m[1], handle: m[2] });
		}
	}
	return out;
}

function live_set_names() { // set names from `nft list table` (sh have_sets)
	let out = [];
	for (let line in split(sh_read(`nft list table ${TABLE} 2>/dev/null`), /\n/)) {
		let m = match(line, /^[ \t]*set ([A-Za-z0-9_]*)/);
		if (m != null)
			push(out, m[1]);
	}
	return out;
}

function desired_group(g) { // raw member MACs, sorted; render path does NOT
	let out = [];  // normalize (only `wanguard add` does) — sh parity
	cursor.foreach(CONF, 'member', (s) => {
		if (s.group == g && s.mac)
			push(out, s.mac);
	});
	return sort(out);
}

function current_elements(setname) { // sh current_elements: whitespace-
	let out = [];  // insensitive parse (real nft wraps element lists)
	let raw = sh_read(`nft list set ${TABLE} ${setname} 2>/dev/null`);
	// NB: ucode index() returns -1 (not null) when not found
	if (index(raw, 'elements') == -1)
		return out;
	// token walk, NOT a /\s+/->' ' flatten: ucode replace() is FIRST-only
	// (live lesson — the flattened string stays multiline and the match
	// dies). Tokens are whitespace-split, so wrapped renders parse the
	// same as single-line ones; elements never contain braces.
	let toks = filter(split(raw, /[ \t\n]+/), (t) => t != '');
	for (let i = 0; i < length(toks); i++) {
		if (toks[i] == 'elements' && toks[i + 1] == '=' && toks[i + 2] == '{') {
			let inner = [];
			for (let j = i + 3; j < length(toks) && toks[j] != '}'; j++)
				push(inner, toks[j]);
			// commas may stick to tokens (`aa:bb:..:ff,`) — sh splits ','
			// after the strip, so join and re-split for byte parity
			for (let e in split(join(' ', inner), ','))
				if (trim(e) != '')
					push(out, trim(e));
			break;
		}
	}
	return out;
}

function render_diff(setname, wantl, havel, batch) { // sh render_diff: adds
	let have_set = {}, want_set = {};  // first (want order), then deletes
	for (let e in havel)               // (have order); space-membership
		have_set[e] = 1;               // equals exact-match: elements have
	for (let e in wantl)               // no embedded whitespace
		want_set[e] = 1;
	for (let e in wantl)
		if (!(e in have_set))
			push(batch, `add element ${TABLE} ${setname} { ${e} }`);
	for (let e in havel)
		if (!(e in want_set))
			push(batch, `delete element ${TABLE} ${setname} { ${e} }`);
}

function rule_has_prio(lines, prio) { // sh grep -Eq "^[[:space:]]*$prio:"
	for (let line in lines) {
		let l = replace(line, /^[ \t]+/, '');
		if (substr(l, 0, length(prio) + 1) == prio + ':')
			return true;
	}
	return false;
}

function reconcile_rules(alloc) { // -> change count (sh reconcile_rules)
	let n = 0;
	let lines = split(sh_read('ip rule show 2>/dev/null'), /\n/);
	let wanted = {};
	for (let a in alloc) {
		wanted[`${a.p}`] = 1;
		if (!rule_has_prio(lines, `${a.p}`)) {
			if (sh_rc(`ip rule add prio ${a.p} fwmark ${a.m} table ${a.t}`) == 0)
				n++;
		}
	}
	for (let line in lines) { // orphan scan, kernel dump order (sh sed order)
		let m = match(line, /^[ \t]*([0-9]+):/);
		if (m == null)
			continue;
		let P = m[1];
		if (int(P) < 8000 || int(P) > 8199 || (`${P}` in wanted))
			continue;
		while (sh_rc(`ip rule del prio ${P} >/dev/null 2>&1`) == 0) // rc 2 stops
			n++;
	}
	return n;
}

function reconcile_routes(alloc) { // -> change count (sh reconcile_routes)
	let n = 0;
	let mainline = '';
	for (let line in split(sh_read('ip route show table main 2>/dev/null'), /\n/))
		if (substr(line, 0, 8) == 'default ') { mainline = line; break; }
	let map = iface_map(); // ONE dump for the whole pass (sh resolves per iface)
	for (let a in alloc) {
		let dev = '';
		if (a.typ == 'proxy') {
			if (sh_rc('ip link show Meta >/dev/null 2>&1') == 0)
				dev = 'Meta';
		} else {
			dev = map[a.ifc]?.device ?? '';
		}
		if (dev != '') {
			let out = sh_read(`ip route show table ${a.t} 2>/dev/null`);
			// sh grep: `default dev <dev> ` — the trailing space is the
			// contract (real ip-full renders `default dev X scope link `,
			// NOTES.md §B3). NB: ucode index() is -1 when not found.
			if (index(out, `default dev ${dev} `) == -1) {
				if (sh_rc(`ip route replace default dev ${dev} table ${a.t}`) == 0)
					n++;
			}
		} else {
			// warn only when someone actually depends on the group
			let members = 0;
			cursor.foreach(CONF, 'member', (s) => {
				if (s.group == a.g)
					members++;
			});
			if (members > 0) {
				if (a.typ == 'proxy')
					warn(`wanguard: group ${a.g}: mihomo TUN Meta is down — routes skipped (keepalive will retry)\n`);
				else
					warn(`wanguard: group ${a.g}: iface '${(a.ifc != '') ? a.ifc : '?'}' down or missing — routes skipped (keepalive will retry)\n`);
			}
		}
		// fallback: main default at metric 200 (idempotent; matches the
		// legacy UCI-installed route byte-for-byte, so both sources coexist)
		if (mainline != '') {
			let has200 = false;
			for (let line in split(sh_read(`ip route show table ${a.t} 2>/dev/null`), /\n/))
				if (match(line, / metric 200($| )/) != null) { has200 = true; break; }
			if (!has200) {
				// sh passes $mainline unquoted: word-splitting collapses the
				// trailing render space — trim() is the same collapse
				if (sh_rc(`ip route replace ${trim(mainline)} metric 200 table ${a.t}`) == 0)
					n++;
			}
		}
	}
	// flush orphan tables of removed groups (allocator range only)
	let alloc_t = {};
	for (let a in alloc)
		alloc_t[`${a.t}`] = 1;
	let inuse = [];
	for (let line in split(sh_read('ip route show table all 2>/dev/null'), /\n/)) {
		let m = match(line, /.* table ([0-9]+)/); // greedy: LAST ` table N`
		if (m != null)
			push(inuse, m[1]);
	}
	for (let T in uniq(sort(inuse))) { // sh `sort -u`: lexicographic
		if (int(T) >= 400 && int(T) <= 500 && !(`${T}` in alloc_t)) {
			if (sh_rc(`ip route flush table ${T} >/dev/null 2>&1`) == 0)
				n++;
		}
	}
	return n;
}

function lb_cascade_group(tag) { // 'wg:<g>:s<cut>@<mark>' -> <g> | null
	// #27/#38: identifies LB member-cascade rules, whose relative ORDER
	// in the chain is load-bearing (see the reconcile below).
	// 'wg:lb:stick' must NOT match (the ':s' tail must be <cut>@<mark>).
	if (substr(tag, 0, 3) != 'wg:')
		return null;
	let rest = substr(tag, 3);
	let p = index(rest, ':s');
	if (p == -1)
		return null;
	if (match(substr(rest, p + 2), /^[0-9]+@[0-9]+$/) == null)
		return null;
	return substr(rest, 0, p);
}

function config_warnings() { // the apply pipeline's validation pass, made
	// reusable with no side effects (#45 `diag health` reports it; apply
	// prints the same bytes as before)
	let out = [];
	for (let g in group_ids()) {
		let t = group_opt(g, 'type');
		if (t != 'direct' && t != 'proxy' && t != 'direct-lb') // #38: lb
			push(out, `group '${g}' has no valid type (direct|direct-lb|proxy) — ignored`);
	}
	return out;
}

function desired_signature(alloc, want) { // desired-side fingerprint (rule
	let s = [];                            // tags + set memberships). Drift
	for (let w in want)                    // (#44) = a live diff while THIS
		push(s, `${w.chain} ${w.tag}`);    // is unchanged since the last
	for (let a in alloc)                   // successful apply — i.e. UCI did
		push(s, join(',', desired_group(a.g))); // not change, live did (a
	return join('|', s);                   // manual nft edit, a foreign tool)
	// NB: lives HERE, not with the other #44 helpers — ucode has no
	// hoisting, and this needs desired_group (declared above)
}

function apply() {
	migrate_legacy();

	let cfgwarn = config_warnings(); // #44: the ring hears about anomalies
	for (let w in cfgwarn)           // only (a healthy pass is already
		msg(`warning: ${w}`);        // told by the apply_ok heartbeat)
	if (length(cfgwarn))
		events_append('config_validated', join('; ', cfgwarn));

	if (!ensure_table()) {
		events_append('apply_err', 'cannot create nft table');
		fail(`cannot create nft table (see ${NFT_FILE})`);
	}

	let redir = globals_opt('redir_port');
	if (redir == '')
		redir = '7892';

	let alloc = alloc_entries();
	let want = desired_rules(alloc, redir);
	let have = live_rule_tags();
	let batch = [];

	// sets: create the wanted ones that are missing (dedupe by group —
	// #38: a direct-lb group owns N alloc slots but ONE mac_<g> set)
	let have_sets = live_set_names();
	let have_set = {};
	for (let s in have_sets)
		have_set[s] = 1;
	let seen_g = {};
	for (let a in alloc) {
		if (seen_g[a.g])
			continue;
		seen_g[a.g] = 1;
		if (!(`mac_${a.g}` in have_set))
			push(batch, `add set ${TABLE} mac_${a.g} { type ether_addr; flags interval; }`);
	}

	// rule deletions: live tags no longer desired (incl. changed marks)
	let want_tags = {};
	for (let w in want)
		want_tags[`${w.chain} ${w.tag}`] = 1;
	let have_tags = {};
	for (let h in have)
		have_tags[`${h.chain} ${h.tag}`] = 1;
	// #27 (spike session 2, LIVE FINDING): LB member cascades are
	// ORDER-SENSITIVE — the fall-through only balances while stick
	// precedes the member rules and the members follow in slot order.
	// `add rule` APPENDS at the chain end, so a tag-diff swap of ONE
	// member rule (weight flip) moved the draw rule AFTER the
	// unconditional remainder rule and every flow funneled into the
	// last member (lab: 60/60 draws mark=400, draw rule 0 packets).
	// If ANY member rule of a group changes, re-render that group's
	// WHOLE cascade: appending the members back in slot order rebuilds
	// the order (stick never moves — its tag/body are constant).
	let casc = {};
	for (let w in want) {
		let g = lb_cascade_group(w.tag);
		if (g != null && !(`${w.chain} ${w.tag}` in have_tags))
			casc[g] = 1;
	}
	for (let h in have) {
		let g = lb_cascade_group(h.tag);
		if (g != null && !(`${h.chain} ${h.tag}` in want_tags))
			casc[g] = 1;
	}
	for (let h in have) {
		let g = lb_cascade_group(h.tag);
		if ((g != null && (g in casc)) || !(`${h.chain} ${h.tag}` in want_tags))
			push(batch, `delete rule ${TABLE} ${h.chain} handle ${h.handle}`);
	}

	// rule additions: desired tags not live; cascades re-added whole,
	// in slot order (append preserves the cascade internally, and the
	// member rules stay after stick — disjoint MAC sets make their
	// position relative to OTHER groups irrelevant)
	for (let w in want) {
		let g = lb_cascade_group(w.tag);
		if ((g != null && (g in casc)) || !(`${w.chain} ${w.tag}` in have_tags))
			push(batch, `add rule ${TABLE} ${w.chain} ${w.body} comment "${w.tag}"`);
	}

	// element diffs, per group in alloc order, then no_mark (#38: dedupe)
	let seen_g2 = {};
	for (let a in alloc) {
		if (!seen_g2[a.g]) {
			seen_g2[a.g] = 1;
			render_diff(`mac_${a.g}`, desired_group(a.g),
				sort(current_elements(`mac_${a.g}`)), batch);
		}
	}
	let nm_want = [];
	{
		let v = cursor.get(CONF, 'globals', 'no_mark');
		if (type(v) == 'array')
			nm_want = v;
		else if (v != null && v != '')
			nm_want = filter(split(v, /\s+/), (s) => s != '');
	}
	render_diff('no_mark', sort(nm_want), sort(current_elements('no_mark')), batch);

	// orphan sets: groups deleted from UCI
	let wantsets = { no_mark: 1, local_v4: 1 };
	for (let a in alloc)
		wantsets[`mac_${a.g}`] = 1;
	for (let s in have_sets) {
		if (substr(s, 0, 4) != 'mac_' || (s in wantsets))
			continue;
		push(batch, `flush set ${TABLE} ${s}`);
		push(batch, `delete set ${TABLE} ${s}`);
	}

	let changed = 0;
	if (length(batch) > 0) {
		if (getenv('WANGUARD_DEBUG') != null) {
			warn('--- nft diff:\n'); // NB: ucode warn() adds NO newline
			for (let b in batch)
				warn(b + '\n');
		}
		// unique temp name: $PPID from a shell child == the ucode pid,
		// i.e. exactly the sh `$$` of the original
		let tf = `/tmp/wanguard.apply.${trim(sh_read('echo $PPID'))}`;
		// NB: ucode join(sep, arr) — separator FIRST (live lesson: the
		// reversed order returns null, which writefile happily persists)
		fs.writefile(tf, join('\n', batch) + '\n');
		// check-then-apply: any `-c` reject aborts BEFORE anything applies
		if (sh_rc(`nft -c -f ${tf} 2>/tmp/wanguard.apply.err`) != 0) {
			let e = fs.popen('cat /tmp/wanguard.apply.err >&2', 'r'); // byte-exact
			e.read('all');                                           // stderr passthrough
			e.close();
			fs.unlink(tf);
			events_append('apply_err', 'nft check failed, nothing applied');
			fail('nft check failed, nothing applied');
		}
		if (sh_rc(`nft -f ${tf}`) != 0) {
			fs.unlink(tf);
			events_append('apply_err', 'nft apply failed');
			fail('nft apply failed');
		}
		fs.unlink(tf);
		changed = 1;
	}

	let n_rules = reconcile_rules(alloc);
	if (n_rules > 0)
		changed = 1;
	let n_routes = reconcile_routes(alloc);
	if (n_routes > 0)
		changed = 1;

	// --- diagnostics events (#44): drift/restore detection AFTER the ---
	// diff is known, BEFORE the contract print (stdout stays byte-frozen;
	// `last-apply` stamps BOTH outcomes — the badge wants the age of the
	// last successful pass, quiet or not)
	let is_drift = false;
	state_dir(); // the stamps need the dir even before the first tick
	             // (init.d apply on a fresh boot: no wand state yet)
	if (changed == 1) {
		let sig = desired_signature(alloc, want);
		let prev = state_read('last-render', '');
		is_drift = (prev != '' && prev == sig); // desired unchanged but
		if (is_drift)                           // live differed: drift
			events_append('drift',
				`live differs from UCI (nft:${length(batch)} rules:${n_rules} routes:${n_routes})`);
		state_write('last-render', sig);
	}
	state_write('last-apply', time());
	events_apply_ok(changed);
	if (is_drift)
		events_append('restored', 'apply repaired the drift');

	print((changed == 1) ? 'applied\n' : 'in-sync\n'); // literal keepalive contract
}

// ---------- stage 4: CLI CRUD + view (issue #34) ----------
//
// 1:1 port of the remaining sh subcommands (router/wanguard lines
// 649-1014): list/add/move/remove/grouplist/devices/groupadd/groupset/
// groupdel/wanstatus/wanset/wanauto/backupset + help. With this the
// passthrough is GONE — dispatch default is the sh `unknown command`
// error, and every contract surface (stdout bytes, stderr bytes, exit
// codes, committed UCI bytes) is gated by stage4/cli-parity.sh.
//
// Port notes (stage4/NOTES.md, probed live in the 25.12.5 container):
//   - ucode printf width/flags are sh-printf byte-identical (probe P1)
//   - ucode split(line, /[ \t]+/) reproduces awk field splitting
//     including leading/trailing empty fields (probe P6) — the devices
//     port is field-index-equal to the sh awk (ucode f[0] = awk f[1])
//   - fs.readfile() works on size-0 /proc files (probe P5)
//   - ucode uci has NO add_list: `set(conf, sid, opt, [array])` writes
//     the same committed `list x 'y'` lines as sh `uci add_list`
//     (probe P3/P4 — committed bytes identical to the sh edit)
//   - 2-arg cursor.get(conf, sid) returns the section TYPE (the
//     `uci -q get conf.sid` existence-check parity), null when absent
//   - cursor.delete of a missing option/section is silent (sh -q parity)
//   - after every mutation the cursor is REFRESHED (uci.cursor()):
//     sh runs every uci call as a fresh process — the snapshot cursor
//     must not leak stale reads into the trailing native apply()

function normalize_mac(raw) { // prints MAC as aa:bb:cc:dd:ee:ff, null if invalid
	let s = replace(lc('' + (raw ?? '')), /-/g, ':');
	s = replace(s, /[:.]/g, '');
	if (match(s, /^[0-9a-f]{12}$/) == null)
		return null;
	let out = '';
	for (let i = 0; i < 12; i += 2)
		out += ((i > 0) ? ':' : '') + substr(s, i, 2);
	return out;
}

function member_ids() { // UCI sections of type member, in FILE order
	// (sh: `uci show | grep '=member$'` — no sort; LuCI/board order)
	let ids = [];
	cursor.foreach(CONF, 'member', (s) => push(ids, s['.name']));
	return ids;
}

function get_member_opt(sid, opt) {
	let v = cursor.get(CONF, sid, opt);
	return (v == null) ? '' : '' + v;
}

function group_exists(g) { // any section with this id (sh: `uci -q get` loop)
	return (cursor.get(CONF, g) != null);
}

function proxy_ids() { return group_ids('proxy'); }

function group_members(g) { // member count for group g
	let n = 0;
	cursor.foreach(CONF, 'member', (s) => {
		if (s.group == g)
			n++;
	});
	return n;
}

function find_by_mac(mac) { // first member section with this MAC (file order)
	for (let sid in member_ids())
		if (normalize_mac(get_member_opt(sid, 'mac')) == mac)
			return sid;
	return null;
}

function section_id_for_mac(mac) { // m_d8bbc1cc1771
	return 'm_' + replace(mac, /:/g, '');
}

function valid_group_name(name) { // [A-Za-z0-9_]{1,15}, not globals/wan
	if (name == 'globals' || name == 'wan')
		return false;
	return (match('' + name, /^[A-Za-z0-9_]{1,15}$/) != null);
}

function iface_known(name) { // sh `ubus call network.interface.X status` rc==0:
	// netifd KNOWS the iface (up or down) — unlike iface_map(), which
	// carries only UP ifaces
	let conn = ubus_conn();
	if (!conn)
		return false;
	let dump = conn.call('network.interface', 'dump', {});
	conn.disconnect();
	for (let rec in (dump?.interface ?? []))
		if (rec.interface == name)
			return true;
	return false;
}

function uci_commit() { // sh `uci commit "$CONF" || err "uci commit failed"`
	// + the snapshot refresh (see the port notes above)
	try {
		cursor.save(CONF);
		cursor.commit(CONF);
	}
	catch (e) {
		fail('uci commit failed');
	}
	cursor = uci.cursor();
}

// ---------- commands ----------

function cmd_list() {
	let bad = [], drift = false;
	printf('%-16s %-20s %-8s\n', 'NAME', 'MAC', 'GROUP');
	for (let sid in member_ids()) {
		let name = get_member_opt(sid, 'name');
		if (name == '')
			name = '-';
		let mac = get_member_opt(sid, 'mac');
		let grp = get_member_opt(sid, 'group');
		if (group_exists(grp))
			printf('%-16s %-20s %-8s\n', name, mac, grp);
		else {
			printf('%-16s %-20s %-8s\n', name, mac, `${grp} (??)`);
			push(bad, grp);
		}
	}
	if (length(bad))
		msg(`warning: members reference unknown group(s): ${join(' ', bad)} (fail-safe: main table)`);
	for (let a in alloc_entries()) {
		if (join('\n', sort(desired_group(a.g))) !=
		    join('\n', sort(current_elements(`mac_${a.g}`))))
			drift = true;
	}
	if (drift) {
		msg('nft: DRIFT (UCI != nft sets; run: wanguard apply)');
		exit(1);
	}
	msg('nft: in-sync');
}

function cmd_grouplist() {
	printf('%-10s %-7s %-10s %-5s %-5s %-14s %s\n',
		'GROUP', 'TYPE', 'IFACE', 'MARK', 'TABLE', 'DEVICE', 'MEMBERS');
	for (let a in alloc_entries()) {
		let ifc, dev;
		if (a.typ == 'proxy') {
			ifc = '-';
			dev = (sh_rc(`ip link show Meta >/dev/null 2>&1`) == 0) ? 'Meta' : 'down';
		}
		else {
			ifc = a.ifc;
			dev = iface_map()[ifc]?.device ?? '';
			if (dev == '')
				dev = 'down';
		}
		printf('%-10s %-7s %-10s %-5s %-5s %-14s %s\n',
			a.g, a.typ, ifc, a.m, a.t, dev, group_members(a.g));
	}
}

function cmd_groupmeta(name) { // #42: machine-readable metadata, one TAB
	// row per group: name<TAB>label<TAB>color<TAB>description, '-' = unset
	// (no header — the devices precedent; `grouplist` stays byte-frozen,
	// that is why metadata output is a separate subcommand at all).
	// All groups (direct/direct-lb/proxy) in sorted order, or one row.
	let ids = (name != '') ? [ name ] : group_ids();
	for (let g in ids) {
		if (!group_exists(g))
			fail(`no such group: '${g}' (see: wanguard grouplist)`);
		let label = group_opt(g, 'label');
		let color = group_opt(g, 'color');
		let descr = group_opt(g, 'description');
		printf('%s\t%s\t%s\t%s\n', g,
			(label != '') ? label : '-',
			(color != '') ? color : '-',
			(descr != '') ? descr : '-');
	}
}

// ---------- #43: device type (hostname heuristic + devtype override) ----------

function devtype_heuristic(name) { // hostname -> type, FIRST match wins.
	// Extend the table here (issue #43: rules must stay a table). Pure
	// string matching on data we already have (leases/ARP inventory) —
	// never a network probe. Patterns are anchored where a bare substring
	// would misfire ("watchdog-pc" is a pc, not a watch); case-insensitive.
	const RULES = [
		[ /^watch([-_]|$)/, 'watch' ],
		[ /(^|[-_])(tv|dune|bosch)/, 'tv' ], // dune-*, bosch-*, tv-livingroom
		[ /^ac-/, 'tv' ],                    // ac-livingroom (media box)
		[ /(^|[-_])(laptop|pc)/, 'pc' ],
		[ /print/, 'printer' ],
		[ /phone/, 'phone' ],                // guest-phone, iphone-*
		[ /^buddy-/, 'phone' ],
		[ /(ipad|tablet)/, 'tablet' ],
	];
	let s = lc('' + name);
	for (let r in RULES)
		if (match(s, r[0]) != null)
			return r[1];
	return 'generic';
}

function member_devtypes() { // mac -> manual `option devtype` override (#43):
	// the owner's explicit fix always beats the hostname heuristic
	let out = {};
	for (let sid in member_ids()) {
		let mac = normalize_mac(get_member_opt(sid, 'mac'));
		let t = get_member_opt(sid, 'devtype');
		if (mac != null && t != '')
			out[mac] = t;
	}
	return out;
}

function cmd_devset(mac_raw, t) { // #43: write/clear the devtype override
	let mac = normalize_mac(mac_raw);
	if (mac == null)
		fail(`invalid mac: ${mac_raw}`);
	let sid = find_by_mac(mac);
	if (sid == null)
		fail(`${mac} not registered (use: wanguard add ${mac} <group> [name])`);
	if (t == '-') { // reset: the hostname heuristic applies again
		cursor.delete(CONF, sid, 'devtype');
		uci_commit();
		msg(`device ${mac} devtype cleared (hostname heuristic applies)`);
		return;
	}
	if (!(t in DEV_TYPES))
		fail(`unknown device type: '${t}' (types: ${join(' ', sort(keys(DEV_TYPES)))}; '-' clears)`);
	cursor.set(CONF, sid, 'devtype', t);
	uci_commit();
	msg(`device ${mac} devtype set: ${t}`);
	// no apply: devtype is board-decoration only, the render never reads it
}

function lan_inventory() { // leases + ARP merge -> { order, ip, name,
	// online } maps keyed by MAC (the cmd_devices source, shared with
	// `inspect` #45). leases give name/ip, ARP gives online (complete
	// entry); ARP-only devices (static IPs) show name "-". Field-index
	// parity with the sh awk: ucode f[0] = awk f[1] (probe P6: split()
	// reproduces awk leading/trailing empty fields).
	const order = [], seen = {}, ipm = {}, nm = {}, onm = {};
	function add(rawmac, ip, name, on) {
		let mac = lc('' + rawmac);
		if (match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) == null)
			return;
		if (!(mac in seen)) {
			push(order, mac);
			seen[mac] = 1;
		}
		if (!(mac in ipm) || ipm[mac] == '-')
			ipm[mac] = ip;
		if (!(mac in nm) || nm[mac] == '-')
			nm[mac] = name;
		if (on)
			onm[mac] = 1;
	}
	let leases = fs.readfile('/tmp/dhcp.leases'); // awk getline: missing file
	if (leases != null)                           // = no iterations
		for (let line in split(leases, /\n/)) {
			let f = split(line, /[ \t]+/);
			if (length(f) >= 4)
				add(f[1], f[2], (f[3] == '*') ? '-' : f[3], false);
		}
	let arp = fs.readfile('/proc/net/arp');
	if (arp != null)
		for (let line in split(arp, /\n/)) {
			let f = split(line, /[ \t]+/);
			// "IP address HW type Flags HW address Mask Device"; 0x2 = complete
			if (length(f) >= 6 && f[2] == '0x2' && f[5] == BR)
				add(f[3], f[0], '-', true);
		}
	return { order: order, ip: ipm, name: nm, online: onm };
}

function cmd_devices() { // LAN clients for the LuCI board (issue #14)
	// prints: mac<TAB>ip<TAB>name<TAB>online<TAB>type. TYPE (#43) is
	// ADDITIVE: the frozen contract is the 4-column prefix; type = member
	// `option devtype` override > hostname heuristic > generic (ARP-only
	// has no name).
	let inv = lan_inventory();
	let dv = member_devtypes(); // override > heuristic > generic (#43)
	for (let mac in inv.order)
		printf('%s\t%s\t%s\t%d\t%s\n', mac,
			(mac in inv.ip) ? inv.ip[mac] : '-',
			(mac in inv.name) ? inv.name[mac] : '-',
			(mac in inv.online) ? 1 : 0,
			dv[mac] ?? devtype_heuristic((mac in inv.name) ? inv.name[mac] : '-'));
}

function cmd_groupadd(name, val) {
	if (!valid_group_name(name))
		fail(`invalid group name: '${name}' ([A-Za-z0-9_], <=15, not globals/wan)`);
	if (group_exists(name))
		fail(`section '${name}' already exists in ${CONF}`);
	if (val == 'proxy') {
		let p = proxy_ids();
		if (length(p))
			fail(`proxy group already exists: ${join(' ', p)} (mihomo is a singleton)`);
		cursor.set(CONF, name, 'group');
		cursor.set(CONF, name, 'type', 'proxy');
	}
	else {
		if (val == '')
			fail('usage: wanguard groupadd <name> <iface|proxy>');
		if (val == 'direct')
			fail(`'direct' alone is not an interface name — pass a netifd iface (e.g. vpn, wan2; see: wanguard grouplist)`);
		cursor.set(CONF, name, 'group');
		cursor.set(CONF, name, 'type', 'direct');
		cursor.set(CONF, name, 'iface', val);
		if ((iface_map()[val]?.device ?? '') == '')
			msg(`note: iface '${val}' is down or missing in netifd — routes will follow once it is up`);
	}
	uci_commit();
	msg(`group '${name}' created (${(val == 'proxy') ? 'proxy' : `direct -> ${val}`})`);
	apply();
}

function cmd_groupset(name, rest) { // rest = args after <name> (issue #42:
	if (!group_exists(name))        // the metadata form lives here too)
		fail(`no such group: '${name}' (see: wanguard grouplist)`);
	// #42 metadata mode: `groupset <name> -label V -color V -description V`.
	// Empty value clears the option (cursor.delete of a missing option is
	// silent — sh -q parity); a repeated flag means the last value wins.
	// NO apply: the render never reads metadata, so this is pure UCI.
	if (substr(rest[0], 0, 1) == '-') {
		let palette = join(' ', sort(keys(GROUP_COLORS)));
		let usage = `usage: wanguard groupset <name> [-label V] [-color V] [-description V] (palette: ${palette})`;
		let touched = [];
		for (let i = 0; i < length(rest); i += 2) {
			let flag = rest[i];
			let val = rest[i + 1] ?? null;
			let opt = (flag == '-label') ? 'label'
				: (flag == '-color') ? 'color'
				: (flag == '-description') ? 'description'
				: '';
			if (opt == '')
				fail(`unknown option: '${flag}' (${usage})`);
			if (val == null)
				fail(`missing value for '${flag}' (${usage})`);
			if (opt == 'color' && val != '' && !(val in GROUP_COLORS))
				fail(`unknown color: '${val}' (palette: ${palette})`);
			if (val == '')
				cursor.delete(CONF, name, opt);
			else
				cursor.set(CONF, name, opt, val);
			push(touched, (val == '') ? `${opt} cleared` : opt);
		}
		uci_commit();
		msg(`group '${name}' metadata updated (${join(', ', touched)})`);
		return;
	}
	let val = rest[0];
	let cur = group_opt(name, 'iface');
	let old = '';
	if (val == 'proxy') {
		for (let other in proxy_ids())
			if (other != name)
				fail(`proxy group already exists: ${other} (mihomo is a singleton)`);
		cursor.set(CONF, name, 'type', 'proxy');
		cursor.delete(CONF, name, 'iface');
		// stale watchdog options must not survive a direct->proxy retarget
		cursor.delete(CONF, name, 'wan_home');
		cursor.delete(CONF, name, 'wanmode');
	}
	else {
		if (val == '')
			fail('usage: wanguard groupset <name> <iface|proxy>');
		if (val == 'direct')
			fail(`'direct' alone is not an interface name — pass a netifd iface (e.g. vpn, wan2; see: wanguard grouplist)`);
		cursor.set(CONF, name, 'type', 'direct');
		if (cur != '')
			old = cur; // direct->direct retarget flushes old (#24)
		cursor.set(CONF, name, 'iface', val);
		// permanent retarget redefines the watchdog home (issue #6)
		cursor.set(CONF, name, 'wan_home', val);
		cursor.set(CONF, name, 'wanmode', 'auto');
		if ((iface_map()[val]?.device ?? '') == '')
			msg(`note: iface '${val}' is down or missing in netifd — routes will follow once it is up`);
	}
	uci_commit();
	msg(`group '${name}' updated (${(val == 'proxy') ? 'proxy' : `direct -> ${val}`})`);
	apply();
	if (old != '' && old != val) // re-route long sessions from the old
		msg(`wand: ${conntrack_flush(name, old, iface_map())}`); // egress (#24)
}

function cmd_groupdel(name) {
	if (!group_exists(name))
		fail(`no such group: '${name}' (see: wanguard grouplist)`);
	let members = '';
	for (let sid in member_ids())
		if (get_member_opt(sid, 'group') == name)
			members += ` ${get_member_opt(sid, 'mac')}`;
	if (members != '')
		fail(`group '${name}' still has members:${members} (move them first: wanguard move <mac> <group>)`);
	cursor.delete(CONF, name);
	uci_commit();
	msg(`group '${name}' deleted`);
	apply();
}

function cmd_add(mac_raw, grp, name) {
	let mac = normalize_mac(mac_raw);
	if (mac == null)
		fail(`invalid mac: ${mac_raw}`);
	if (!group_exists(grp))
		fail(`no such group: '${grp}' (see: wanguard grouplist)`);
	if (name == '')
		name = `mac-${substr(mac, index(mac, ':') + 1)}`;
	let sid = find_by_mac(mac);
	if (sid != null)
		fail(`${mac} already registered as '${get_member_opt(sid, 'name')}' in group ${get_member_opt(sid, 'group')} (use: wanguard move ${mac} ${grp})`);
	sid = section_id_for_mac(mac);
	try {
		cursor.set(CONF, sid, 'member');
	}
	catch (e) {
		fail('uci set failed');
	}
	cursor.set(CONF, sid, 'name', name);
	cursor.set(CONF, sid, 'mac', mac);
	cursor.set(CONF, sid, 'group', grp);
	uci_commit();
	msg(`added ${mac} -> group ${grp} (${name})`);
	apply();
}

function cmd_move(mac_raw, grp) {
	let mac = normalize_mac(mac_raw);
	if (mac == null)
		fail(`invalid mac: ${mac_raw}`);
	if (!group_exists(grp))
		fail(`no such group: '${grp}' (see: wanguard grouplist)`);
	let sid = find_by_mac(mac);
	if (sid == null)
		fail(`${mac} not registered (use: wanguard add ${mac} <group> [name])`);
	let cur = get_member_opt(sid, 'group');
	if (cur == grp) {
		msg(`${mac} already in group ${grp}`);
		return;
	}
	cursor.set(CONF, sid, 'group', grp);
	uci_commit();
	msg(`moved ${mac}: ${cur} -> ${grp}`);
	apply();
}

function cmd_remove(mac_raw) {
	let mac = normalize_mac(mac_raw);
	if (mac == null)
		fail(`invalid mac: ${mac_raw}`);
	let sid = find_by_mac(mac);
	if (sid == null)
		fail(`${mac} not registered`);
	let name = get_member_opt(sid, 'name');
	cursor.delete(CONF, sid);
	uci_commit();
	msg(`removed ${mac} (${name})`);
	apply();
}

function cmd_wanstatus() {
	printf('%-8s %-14s %-12s %-9s %-9s %s\n', 'WAN', 'DEVICE', 'STATE', 'RTT(s)', 'ANCHORS', 'SINCE');
	let total = length(anchors());
	let map = iface_map(); // ONE dump for the whole table (sh resolves per
			       // wan — rendered rows are identical, stage-2
			       // precedent in wanflush)
	for (let wan in wand_wans()) {
		let dev = map[wan]?.device ?? '-';
		let st = wan_state(wan);
		if (fs.stat(`${WAND_DIR}/${wan}.force`)?.type == 'file')
			st = `${st}/forced`;
		let rtt = state_read(`${wan}.rtt`, '-');
		let alive = state_read(`${wan}.alive`, '-');
		let since = trim(fs.readfile(`${WAND_DIR}/${wan}.since`) ?? '');
		if (since != '') {
			// NB: rtrim — sh $(date) strips trailing newlines only
			let d = rtrim(sh_read(`date -d @${since} +'%d.%m %H:%M:%S' 2>/dev/null`));
			if (d != '')
				since = d;
		}
		else {
			since = '-';
		}
		printf('%-8s %-14s %-12s %-9s %-9s %s\n', wan, dev, st, rtt, `${alive}/${total}`, since);
	}
	msg('');
	printf('%-8s %-8s %-8s %-9s %-20s %s\n', 'GROUP', 'HOME', 'CURRENT', 'MODE', 'BACKUP', 'MEMBERS');
	for (let g in direct_ids()) {
		let home = group_opt(g, 'wan_home');
		if (home == '')
			home = '-';
		let cur = group_opt(g, 'iface');
		let mode = group_opt(g, 'wanmode');
		if (mode == '')
			mode = 'auto';
		let bk = group_opt(g, 'backup_iface');
		if (type(bk) == 'array') // list option: sh `uci get` prints the
			bk = join(' ', bk); // elements space-joined
		if (bk == '')           // '*' = all watched WANs A-Z
			bk = '*';
		printf('%-8s %-8s %-8s %-9s %-20s %s\n', g, home, cur, mode, bk, group_members(g));
	}
	if (system('command -v curl >/dev/null 2>&1') != 0)
		msg('note: curl missing — watchdog probes disabled');
}

function cmd_wanset(g, ifc) {
	if (!group_exists(g))
		fail(`no such group: '${g}' (see: wanguard grouplist)`);
	if (group_opt(g, 'type') != 'direct')
		fail(`group '${g}' is proxy — it follows mihomo, wanset does not apply`);
	if (!iface_known(ifc))
		fail(`unknown netifd iface: '${ifc}'`);
	let old = group_opt(g, 'iface');
	cursor.set(CONF, g, 'iface', ifc);
	cursor.set(CONF, g, 'wanmode', 'override');
	uci_commit();
	msg(`group '${g}' pinned to '${ifc}' (manual override; watchdog skips it; resume: wanguard wanauto ${g})`);
	apply();
	if (old != '' && old != ifc) // re-route long sessions pinned away
		msg(`wand: ${conntrack_flush(g, old, iface_map())}`); // from old (#24)
}

function cmd_wanauto(g) {
	if (!group_exists(g))
		fail(`no such group: '${g}' (see: wanguard grouplist)`);
	if (group_opt(g, 'type') != 'direct')
		fail(`group '${g}' is proxy - nothing to automate`);
	cursor.set(CONF, g, 'wanmode', 'auto');
	uci_commit();
	msg(`group '${g}' back in auto mode (home: ${group_opt(g, 'wan_home')}; watchdog fails back once home is up)`);
}

function cmd_backupset(g, ifaces) { // explicit backup priority (#26):
	// watchdog fails over to the first UP iface in this order; ifaces
	// outside the list are NOT eligible. Reset to the default (all
	// watched WANs, alphabetical): uci -q delete wanguard.<g>.backup_iface
	if (!group_exists(g))
		fail(`no such group: '${g}' (see: wanguard grouplist)`);
	if (group_opt(g, 'type') != 'direct')
		fail(`group '${g}' is proxy — backups are a direct-group feature`);
	let home = group_opt(g, 'wan_home');
	let cur = group_opt(g, 'iface');
	let watched = {}; // NB: `x in obj` tests keys (sh case *" $e "* parity)
	for (let w in wand_wans())
		watched[w] = 1;
	let out = [];
	for (let ifc in ifaces) {
		if (ifc == home || ifc == cur) { // conflict-check
			msg(`note: '${ifc}' is the group's own iface — ignored (never its own backup)`);
			continue;
		}
		if (!iface_known(ifc))
			fail(`unknown netifd iface: '${ifc}'`);
		let dup = false;
		for (let o in out)
			if (o == ifc)
				dup = true;
		if (dup)
			continue; // duplicate: first wins
		if (!(ifc in watched))
			msg(`note: '${ifc}' is not watched by the watchdog (no direct group sits on it) — it is skipped until it becomes some group's iface/wan_home`);
		push(out, ifc);
	}
	if (length(out) == 0)
		fail('nothing left after conflict-checks — backup list not changed');
	cursor.delete(CONF, g, 'backup_iface');
	cursor.set(CONF, g, 'backup_iface', out); // list write (no add_list in
						  // ucode uci — probe P3/P4)
	uci_commit();
	// NB: no space after the colon — sh strips it with ${out# } (#26)
	msg(`group '${g}' backup order:${join(' ', out)} (first UP wins; see: wanguard wanstatus)`);
}

const HELP = `usage: wanguard <command> [args]
  list                          members + drift status
  add <mac> <group> [name]      register + apply
  move <mac> <group>            change group + apply
  remove <mac>                  unregister + apply
  apply                         reconcile UCI -> nft + ip rules + routes (idempotent)
  grouplist                     groups: type, iface, mark/table, device, members
  devices                       LAN clients: mac, ip, name, online (board data)
  groupadd <name> <iface|proxy> create group: direct on netifd iface, or proxy (mihomo, max 1)
  groupset <name> <iface|proxy> change group target
  groupdel <name>               delete an empty group
  wanstatus                     WAN probe states + group home/current/mode (issue #6)
  wanset <group> <iface>        pin group to iface manually (override; watchdog skips it)
  wanauto <group>               resume watchdog auto failover/failback
  backupset <group> <iface>...  backup priority order (#26): first UP wins;
                                no list = all watched WANs, alphabetical

group names: [A-Za-z0-9_], <=15 chars. marks/tables are allocated
automatically: proxy = 300/500 fixed; direct (sorted by name) =
100,200,400,... / tables 400+ (see docs/ARCHITECTURE.md §2).

#42/#43 metadata (UCI-only decoration; the data plane never reads it):
  groupmeta [name]              group rows: name, label, color, description (TAB)
  groupset <name> -label V      set/clear metadata: -label/-color/-description;
      [-color V] ...            '' clears; color: blue green purple orange gray
  devset <mac> <type|->         device type override (board icons):
                                watch|tv|pc|printer|phone|tablet|generic; '-' clears

#44/#45 diagnostics (read-only, ucode-only; data plane for the LuCI
Diagnostics page and the header status badge):
  events [N]                    event ring tail (default 20): ts, code, detail
  syncstatus                    status=|last_apply=|age= (live drift probe)
  diag [all|rules|tables|nft|health]
                                read-only diagnostics sections
  inspect <mac|ip|hostname>     one device: configured vs live
  diag-report                   full secrets-free report (LuCI download)
`;

// ---------- diagnostics commands (#44/#45, ucode-only) ----------
//
// Read-only data plane for the LuCI Diagnostics page and the status
// badge. Precedent: groupmeta (#42) — ucode-only, no cli-parity pairs,
// pinned by stage-5 goldens instead. Sources are ONLY read verbs the
// apply/diff paths already use (`nft list`, `ip rule show`, `ip route
// show table N`, ubus netifd dump + procd service list, leases/ARP,
// UCI wanguard, the ring) — NEVER /etc/config/network or any other
// secret-bearing config (PPPoE/WG secrets); the diag-report gate greps
// the output for secret markers (run-tests DR-secrets).
//
// Output grammar: TAB-separated rows, no decorations; long dumps
// (rules/nft) are grouped under `section<TAB><name>` headers so a
// parser can split the report without knowing the dumps' shapes.

const VERSION_FILE = '/usr/share/wanguard/version'; // stamped by apk/build.sh

function svc_status(name) { // procd state via ubus `service list`:
	let conn = ubus.connect(); // running | stopped | absent | unknown
	if (conn == null)          // (unknown: no ubus at all — say so)
		return 'unknown';
	let st = conn.call('service', 'list');
	conn.disconnect();
	if (st == null)
		return 'unknown';
	if (!(name in st))
		return 'absent';
	let inst = st[name]?.instances ?? {};
	for (let k in keys(inst))
		if (inst[k]?.running)
			return 'running';
	return 'stopped';
}

function pkg_version() { // build stamp; missing file (dev/lab runs) -> '-'
	return trim(fs.readfile(VERSION_FILE) ?? '') || '-';
}

function diag_rules() { // FULL `ip rule show`: a foreign/stale rule (prio
	msg('section\trules'); // 1000 in front of our 8000+) is exactly what
	let out = sh_read('ip rule show 2>/dev/null'); // debugging needs to see
	for (let line in split(trim(out), /\n/))
		if (trim(line) != '')
			msg(line);
}

function diag_tables() { // per-slot: device + the table's routes verbatim
	msg('section\ttables');
	let map = iface_map();
	for (let a in alloc_entries()) {
		let dev = (a.typ == 'proxy')
			? ((sh_rc('ip link show Meta >/dev/null 2>&1') == 0) ? 'Meta' : 'down')
			: (map[a.ifc]?.device ?? '');
		msg(`slot\t${a.g}\t${a.typ}\t${(dev != '') ? dev : 'down'}\tmark=${a.m}\ttable=${a.t}\tprio=${a.p}`);
		for (let line in split(trim(sh_read(`ip route show table ${a.t} 2>/dev/null`)), /\n/))
			if (trim(line) != '')
				msg(`route\t${a.g}\t${line}`);
	}
}

function diag_nft() { // the whole table verbatim (the applied state)
	msg('section\tnft');
	let out = sh_read(`nft list table ${TABLE} 2>/dev/null`);
	if (trim(out) != '')
		print(out); // dump already ends with \n — print it untouched
}

function diag_health() { // procd services, config validity, build stamp
	msg('section\thealth');
	msg(`service\twanguard\t${svc_status('wanguard')}`);
	msg(`service\tmihomo\t${svc_status('mihomo')}`);
	let w = config_warnings();
	msg(`config\t${(length(w) == 0) ? 'valid' : 'invalid'}`);
	for (let x in w)
		msg(`warning\t${x}`);
	msg(`version\t${pkg_version()}`);
}

function cmd_diag(sec) { // all|rules|tables|nft|health
	if (sec == 'rules') { diag_rules(); return; }
	if (sec == 'tables') { diag_tables(); return; }
	if (sec == 'nft') { diag_nft(); return; }
	if (sec == 'health') { diag_health(); return; }
	if (sec == 'all') { diag_rules(); diag_tables(); diag_nft(); diag_health(); return; }
	fail(`unknown diag section: '${sec}' (sections: all|rules|tables|nft|health)`);
}

function sync_rows() { // [status, last_apply, age] — the drift HALF is live
	let drift = false;    // (the same sets-diff `list` uses), NOT ring-fed:
	for (let a in alloc_entries())   // the ring tells the story, the probe
		if (join('\n', sort(desired_group(a.g))) != // tells the NOW
		    join('\n', sort(current_elements(`mac_${a.g}`))))
			drift = true;
	let ts = state_read('last-apply', '');
	return [ drift ? 'drift' : 'in-sync',
		(ts != '') ? ts : '-',
		(ts != '') ? `${time() - int(ts)}` : '-' ];
}

function cmd_syncstatus() { // machine probe, exit 0 always (#44): LuCI
	let r = sync_rows();       // reads it on every header render — DRIFT
	printf('status=%s\nlast_apply=%s\nage=%s\n', r[0], r[1], r[2]); // verdict
}                            // semantics stay exclusive to `list`

function cmd_events(n) { // ring tail (#44): last N rows (default 20),
	if (n != '')          // unix-ts<TAB>code<TAB>detail, no header
		(match('' + n, /^[0-9]+$/) != null) || fail('usage: wanguard events [N]');
	let k = (n != '') ? int(n) : 20;
	let cur = fs.readfile(`${WAND_DIR}/events`);
	if (cur == null || trim(cur) == '')
		return; // empty ring: silence (the machine reader sees nothing)
	let lines = split(trim(cur), /\n/);
	let start = (length(lines) > k) ? length(lines) - k : 0;
	for (let i = start; i < length(lines); i++)
		msg(lines[i]);
}

function cmd_inspect(q) { // one device: configured vs live (#45)
	// resolve: MAC literal > lease/ARP ip or hostname > member name.
	// Unresolvable = the contract error path (stderr, rc 1); resolvable
	// but unregistered is a VALID answer (group '-') — the "outside the
	// groups" case. Every row names its fact: a divergence between the
	// configured and live worlds is visible row by row.
	let t = lc('' + q);
	let mac = null;
	if ((match(t, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) != null) ||
	    (match(replace(t, /[-.]/g, ''), /^[0-9a-f]{12}$/) != null)) {
		mac = normalize_mac(t);
		if (mac == null)
			fail(`invalid mac: ${q}`);
	}
	let inv = lan_inventory();
	if (mac == null)
		for (let m in inv.order)
			if (inv.ip[m] == q || lc(inv.name[m]) == t) { mac = m; break; }
	if (mac == null) // registered but never leased: member name match
		for (let sid in member_ids()) {
			let nm = get_member_opt(sid, 'name');
			if (nm != '' && lc(nm) == t) {
				mac = normalize_mac(get_member_opt(sid, 'mac'));
				break;
			}
		}
	if (mac == null)
		fail(`cannot resolve: '${q}' (not a MAC, and no lease/ARP/inventory match)`);
	msg(`device\t${q}`);
	msg(`mac\t${mac}`);
	msg(`name\t${(mac in inv.name) ? inv.name[mac] : '-'}`);
	msg(`ip\t${(mac in inv.ip) ? inv.ip[mac] : '-'}`);
	msg(`online\t${(mac in inv.online) ? 1 : 0}`);
	let sid = find_by_mac(mac);
	if (sid == null) { // known to the LAN, outside the groups
		msg('group\t-');
		msg('note\tnot registered (use: wanguard add <mac> <group>)');
		return;
	}
	let g = get_member_opt(sid, 'group');
	msg(`group\t${g}`);
	if (!group_exists(g)) {
		msg('note\tmember references an unknown group (fail-safe: main table)');
		return;
	}
	let map = iface_map();
	let slots = filter(alloc_entries(), (a) => a.g == g);
	if (length(slots) == 0) { // e.g. invalid type: apply warned, render skipped
		msg('note\tgroup has no allocation slot (invalid type?)');
		return;
	}
	for (let a in slots) {
		let dev = (a.typ == 'proxy')
			? ((sh_rc('ip link show Meta >/dev/null 2>&1') == 0) ? 'Meta' : 'down')
			: (map[a.ifc]?.device ?? '');
		msg(`slot\t${a.typ}\tmark=${a.m}\ttable=${a.t}\tprio=${a.p}\tconfigured=${(a.typ == 'proxy') ? 'proxy' : a.ifc}\t${(a.mi != null) ? `member=${a.mi}\t` : ''}live=${(dev != '') ? dev : 'down'}`);
	}
	let in_set = filter(current_elements(`mac_${g}`), (e) => lc(e) == mac);
	msg(`set\tmac_${g}\t${(length(in_set) > 0) ? 'member' : 'absent'}`);
	for (let h in live_rule_tags()) // applied rules of this group
		if (substr(h.tag, 0, length(`wg:${g}:`)) == `wg:${g}:`)
			msg(`rule\t${h.chain}\t${h.tag}\thandle=${h.handle}`);
}

function cmd_diag_report() { // the LuCI "Download report" one-liner (#45):
	// sync + every diag section + the registered members' configured-vs-
	// live lines + the event ring. Secrets-free BY CONSTRUCTION (see the
	// section header above) and test-gated (DR-secrets greps the output
	// against markers planted in /etc/config/network).
	msg('# wanguard diag-report');
	msg(`generated\t${trim(sh_read(`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`))} (${time()})`);
	let r = sync_rows();
	msg(`sync\t${r[0]}\tlast_apply=${r[1]}\tage=${r[2]}`);
	diag_rules();
	diag_tables();
	diag_nft();
	diag_health();
	msg('section\tdevices');
	let map = iface_map();
	for (let sid in member_ids()) { // configured vs live, one line each
		let mac = get_member_opt(sid, 'mac');
		let g = get_member_opt(sid, 'group');
		let name = get_member_opt(sid, 'name');
		let live = '-';
		if (group_exists(g)) {
			let slots = filter(alloc_entries(), (a) => a.g == g);
			if (length(slots) > 0) {
				let a = slots[0];
				let dev = (a.typ == 'proxy')
					? ((sh_rc('ip link show Meta >/dev/null 2>&1') == 0) ? 'Meta' : 'down')
					: (map[a.ifc]?.device ?? '');
				if (dev != '')
					live = dev;
			}
		}
		msg(`member\t${(mac != '') ? mac : '-'}\t${(name != '') ? name : '-'}\t${(g != '') ? g : '-'}\t${live}`);
	}
	msg('section\tevents');
	let ev = fs.readfile(`${WAND_DIR}/events`);
	if (ev != null && trim(ev) != '')
		print(ev); // the ring verbatim (bounded by EVENTS_MAX)
}

function cmd_help() {
	print(HELP);
}

// ---------- dispatch ----------
//
// Stage 4 (#34): the passthrough is gone — every subcommand is native
// here. Stage 5 (#35): wanguard-sh is retired from the package entirely;
// the standalone ucode CLI is the only /usr/bin/wanguard.

let cmd = ARGV[0] ?? '';
let args = [];
for (let i = 1; i < length(ARGV); i++)
	push(args, ARGV[i]);
switch (cmd) {
	case 'wand-tick':
		tick();
		break;
	case 'wan-flush':
		wanflush();
		break;
	case 'probe-selftest':
		probe_selftest();
		break;
	case 'apply': // native since stage 3 (#33); sh parity gated by
		apply();  // stage3/apply-parity.sh (165 checks)
		break;
	case 'list': // native since stage 4 (#34); parity gated by
		cmd_list();     // stage4/cli-parity.sh
		break;
	case 'add':
		(length(args) >= 2) || fail('usage: wanguard add <mac> <group> [name]');
		cmd_add(args[0], args[1], args[2] ?? '');
		break;
	case 'move':
		(length(args) >= 2) || fail('usage: wanguard move <mac> <group>');
		cmd_move(args[0], args[1]);
		break;
	case 'remove':
		(length(args) >= 1) || fail('usage: wanguard remove <mac>');
		cmd_remove(args[0]);
		break;
	case 'grouplist':
		cmd_grouplist();
		break;
	case 'groupmeta': // #42
		cmd_groupmeta(args[0] ?? '');
		break;
	case 'devices':
		cmd_devices();
		break;
	case 'groupadd':
		(length(args) >= 2) || fail('usage: wanguard groupadd <name> <iface|proxy>');
		cmd_groupadd(args[0], args[1]);
		break;
	case 'groupset':
		(length(args) >= 2) || fail('usage: wanguard groupset <name> <iface|proxy>');
		cmd_groupset(args[0], slice(args, 1));
		break;
	case 'groupdel':
		(length(args) >= 1) || fail('usage: wanguard groupdel <name>');
		cmd_groupdel(args[0]);
		break;
	case 'devset': // #43
		(length(args) >= 2) || fail('usage: wanguard devset <mac> <type|->');
		cmd_devset(args[0], args[1]);
		break;
	case 'wanstatus':
		cmd_wanstatus();
		break;
	case 'wanset':
		(length(args) >= 2) || fail('usage: wanguard wanset <group> <iface>');
		cmd_wanset(args[0], args[1]);
		break;
	case 'wanauto':
		(length(args) >= 1) || fail('usage: wanguard wanauto <group>');
		cmd_wanauto(args[0]);
		break;
	case 'backupset':
		(length(args) >= 2) || fail('usage: wanguard backupset <group> <iface>...');
		cmd_backupset(args[0], slice(args, 1));
		break;
	case 'events': // #44
		cmd_events(args[0] ?? '');
		break;
	case 'syncstatus': // #44
		cmd_syncstatus();
		break;
	case 'diag': // #45
		cmd_diag(args[0] ?? 'all');
		break;
	case 'inspect': // #45
		(length(args) >= 1) || fail('usage: wanguard inspect <mac|ip|hostname>');
		cmd_inspect(args[0]);
		break;
	case 'diag-report': // #45
		cmd_diag_report();
		break;
	case '':
	case 'help':
	case '-h':
	case '--help':
		cmd_help();
		break;
	default:
		fail(`unknown command: ${cmd} (try: wanguard help)`);
}
