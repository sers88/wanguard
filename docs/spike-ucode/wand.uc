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
 *
 * Everything else (apply, wan-flush, ...) is passed through to the stock
 * sh CLI so the keepalive contract keeps working end to end.
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

function state_write(name, val) { fs.writefile(`${WAND_DIR}/${name}`, `${val}`); }

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
	if (!fs.access('/var/run/ubus.sock'))
		return null;
	let conn;
	// nb: connect() raises when ubusd dies between access() and connect —
	// acceptable for a tick process (keepalive just re-runs it in 10 s)
	conn = ubus.connect();
	for (let o in conn.objects())
		if (o[0] == 'network.interface')
			return conn;
	conn.close();
	return null;
}

function iface_map() { // netifd name -> { device, addr } for UP ifaces
	let conn = ubus_conn();
	let map = {};
	if (!conn)
		return map;
	let dump = conn.call('network.interface', 'dump', {});
	conn.close();
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
	if (l) return (type(l) == 'array') ? l : [ l ];
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
		let rtt = +out;
		if (minrtt == null || rtt < minrtt)
			minrtt = rtt;
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
	let p = fs.popen(`/usr/bin/wanguard ${join(' ', args)} 2>&1`, 'r');
	let out = p.read('all') ?? '';
	let rc = p.close();
	print(out);
	exit(rc);
}

// ---------- dispatch ----------

let cmd = ARGV[0] ?? '';
switch (cmd) {
	case 'wand-tick':
		tick();
		break;
	case 'probe-selftest':
		probe_selftest();
		break;
	default:
		passthrough(ARGV);
}
