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
 * Everything else (apply, ...) is passed through to the stock sh CLI so
 * the keepalive contract keeps working end to end.
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

function wand_wans() { // distinct CURRENT+HOME of direct groups, sorted:
	// homes MUST be probed — else a failed-over group's dead home could
	// never be seen recovering (live bug 2026-10-13)
	let wans = [];
	for (let g in direct_ids()) {
		let ifc = group_opt(g, 'iface');
		if (ifc != '') push(wans, ifc);
		let home = group_opt(g, 'wan_home');
		if (home != '') push(wans, home);
	}
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
		if (ev != '')
			push(events, ev);
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

function passthrough(args) { // stock sh CLI handles the rest of the contract
	// default matches the spike package layout (both shipped side by
	// side); on a stock router export WANGUARD_SH=/usr/bin/wanguard
	let sh = getenv('WANGUARD_SH') ?? '/usr/bin/wanguard-sh';
	let p = fs.popen(`${sh} ${join(' ', args)} 2>&1`, 'r');
	let out = p.read('all') ?? '';
	let rc = p.close();
	print(out);
	exit(rc);
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
	return out;
}

function desired_rules(alloc, redir) { // [{chain, tag, body}] (sh DRF)
	let out = [];
	for (let a in alloc) {
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

function apply() {
	migrate_legacy();

	for (let g in group_ids()) {
		let t = group_opt(g, 'type');
		if (t != 'direct' && t != 'proxy')
			msg(`warning: group '${g}' has no valid type (direct|proxy) — ignored`);
	}

	if (!ensure_table())
		fail(`cannot create nft table (see ${NFT_FILE})`);

	let redir = globals_opt('redir_port');
	if (redir == '')
		redir = '7892';

	let alloc = alloc_entries();
	let want = desired_rules(alloc, redir);
	let have = live_rule_tags();
	let batch = [];

	// sets: create the wanted ones that are missing
	let have_sets = live_set_names();
	let have_set = {};
	for (let s in have_sets)
		have_set[s] = 1;
	for (let a in alloc)
		if (!(`mac_${a.g}` in have_set))
			push(batch, `add set ${TABLE} mac_${a.g} { type ether_addr; flags interval; }`);

	// rule deletions: live tags no longer desired (incl. changed marks)
	let want_tags = {};
	for (let w in want)
		want_tags[`${w.chain} ${w.tag}`] = 1;
	for (let h in have)
		if (!(`${h.chain} ${h.tag}` in want_tags))
			push(batch, `delete rule ${TABLE} ${h.chain} handle ${h.handle}`);

	// rule additions: desired tags not live
	let have_tags = {};
	for (let h in have)
		have_tags[`${h.chain} ${h.tag}`] = 1;
	for (let w in want)
		if (!(`${w.chain} ${w.tag}` in have_tags))
			push(batch, `add rule ${TABLE} ${w.chain} ${w.body} comment "${w.tag}"`);

	// element diffs, per group in alloc order, then no_mark
	for (let a in alloc)
		render_diff(`mac_${a.g}`, desired_group(a.g),
			sort(current_elements(`mac_${a.g}`)), batch);
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
			fail('nft check failed, nothing applied');
		}
		if (sh_rc(`nft -f ${tf}`) != 0) {
			fs.unlink(tf);
			fail('nft apply failed');
		}
		fs.unlink(tf);
		changed = 1;
	}

	let n = reconcile_rules(alloc);
	if (n > 0)
		changed = 1;
	n = reconcile_routes(alloc);
	if (n > 0)
		changed = 1;

	print((changed == 1) ? 'applied\n' : 'in-sync\n'); // literal keepalive contract
}

// ---------- dispatch ----------

let cmd = ARGV[0] ?? '';
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
		apply();   // stage3/apply-parity.sh (165 checks)
		break;
	default:
		passthrough(ARGV);
}
