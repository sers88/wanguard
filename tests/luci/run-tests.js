#!/usr/bin/env node
'use strict';
/*
 * luci-app-wanguard harness (issue #40): runs the REAL view code from
 * luci-app-wanguard/htdocs/luci-static/resources/view/wanguard.js inside
 * node with stubbed LuCI globals (view/form/poll/rpc/uci/ui/E/L/_), so
 * no router, LuCI or prod backend is involved — the UCI side is loaded
 * from the handwritten fixtures/ configs (the same lab-shaped configs
 * as the ucode mock suite: witness + lb members 70/30).
 *
 * What is pinned here:
 *   - UCI slot derivation parity with the CLI allocator (wand.uc
 *     alloc_entries LB branch): witness 100/400, lb slots 200/401 and
 *     400/402 (mark 300 skipped), two lb groups continuing one cascade,
 *     buckets floor + remainder-to-last (33/33/34 for 50/50/50),
 *     weights 0/garbage/absent -> 50, member_live failover display,
 *     >20 members / no members degrade — numbers match the ucode mock
 *     suite (LB2/LB4) and the lab.
 *   - direct/proxy behavior unchanged: golden preview strings and board
 *     labels for a legacy direct/proxy config (J9).
 *   - parseGrouplist: direct-lb rows carry the authoritative device
 *     state; old CLIs (no rows) degrade to UCI-only display (J1/J13).
 *   - group modal (#40): addModalOptions adds member_iface (MultiValue)
 *     + one weight_<iface> field per candidate iface with
 *     depends({type:'direct-lb', member_iface:'<ifc>', '!contains':
 *     true}) — the weight field appears when the member is staged and
 *     its stray option is removed by form.js parse semantics when the
 *     membership is dropped; direct/proxy modals gain nothing (J11).
 *   - edit persistence: staged UCI member/weight changes are reflected
 *     by the same display code path (Save&Apply = staged UCI + commit).
 *
 * Run: node tests/luci/run-tests.js
 */

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const VIEW = path.join(REPO, 'luci-app-wanguard', 'htdocs', 'luci-static', 'resources', 'view', 'wanguard.js');
const FIX = path.join(__dirname, 'fixtures');

const VIEW_SRC = fs.readFileSync(VIEW, 'utf8');
const fixture = (name) => fs.readFileSync(path.join(FIX, name), 'utf8');

/* ---------- LuCI polyfills ---------- */

/* String.format: only %s and %d are used by the view */
if (!String.prototype.format) {
	String.prototype.format = function() {
		const args = arguments;
		let i = 0;
		return this.replace(/%(-?\d*)\.?\d*[sd%]/g, function(m) {
			if (m === '%%')
				return '%';
			let v = args[i++];
			if (v == null)
				return '';
			if (m.endsWith('d'))
				v = parseInt(v, 10) || 0;
			return '' + v;
		});
	};
}

/* minimal DOM stub: enough structure for board/render assertions */
function E(spec, attrs, children) {
	const node = {
		tag: '#frag', attrs: {}, style: {}, children: [],
		listeners: {},
		classList: {
			_s: {},
			add(c) { this._s[c] = 1; },
			remove(c) { delete this._s[c]; },
			contains(c) { return !!this._s[c]; }
		},
		addEventListener(ev, fn) { (this.listeners[ev] = this.listeners[ev] || []).push(fn); },
		appendChild(c) { this.children.push(c); return c; },
		insertBefore(n) { this.children.push(n); return n; },
		setAttribute(k, v) { this.attrs[k] = '' + v; },
		getAttribute(k) { return (k in this.attrs) ? this.attrs[k] : null; },
		querySelector() { return null; },
		querySelectorAll() { return []; },
		innerHTML: ''
	};
	if (Array.isArray(spec)) {
		spec.forEach((c) => node.appendChild(c));
		return node;
	}
	node.tag = spec || '#frag';
	if (attrs) {
		for (const k in attrs) {
			if (k === 'style') {
				/* style stays an object (DOM allows style.display=… later) */
				if (typeof attrs[k] === 'object')
					node.style = attrs[k];
				else
					node.styleStr = attrs[k];
			}
			else if (typeof attrs[k] === 'function')
				node.addEventListener(k, attrs[k]);
			else {
				node.attrs[k] = attrs[k];
				if (k === 'class')
					node.className = attrs[k];
			}
		}
	}
	if (children == null) {
		/* none */
	}
	else if (Array.isArray(children)) {
		children.forEach((c) => node.appendChild(c));
	}
	else {
		node.appendChild(E('#text', null, [ '' + children ]));
	}
	return node;
}

function flat(node) {
	if (typeof node === 'string')
		return node;
	if (node.tag === '#text')
		return node.children.map(flat).join('');
	return (node.children || []).map(flat).join('');
}

function findCol(root, group) {
	let out = null;
	(function walk(n) {
		if (out)
			return;
		if (n.tag === 'div' && n.attrs['data-group'] === group && (n.attrs.class || '').includes('wg-col')) {
			out = n;
			return;
		}
		(n.children || []).forEach(walk);
	})(root);
	return out;
}

function colParts(col) {
	const head = col.children[0];
	const titleEl = head.children.find((c) => (c.attrs.class || '').includes('wg-col-title'));
	const subEl = head.children.find((c) => (c.attrs.class || '').includes('wg-col-sub'));
	return {
		title: titleEl ? flat(titleEl) : '',
		sub: subEl ? flat(subEl) : '',
		cards: col.children[1].children
	};
}

/* ---------- stubbed LuCI globals ---------- */

const UCI = {
	data: {}, staged: {}, _n: 0,
	reset(text) {
		this.data = text ? parseUci(text, 'wanguard') : { wanguard: {} };
		this.staged = {};
	},
	load() { return Promise.resolve(); },
	sections(conf, type) {
		const vals = this.data[conf] || {};
		const out = [];
		for (const sid in vals) {
			const s = vals[sid];
			const st = (this.staged[conf] || {})[sid];
			const merged = Object.assign({}, s);
			if (st)
				for (const k in st)
					if (st[k] != null)
						merged[k] = st[k];
			if (!type || merged['.type'] === type)
				out.push(merged);
		}
		return out;
	},
	get(conf, sid, opt) {
		const s = (this.data[conf] || {})[sid];
		if (!s)
			return null;
		const st = (this.staged[conf] || {})[sid];
		if (opt == null) {
			const merged = Object.assign({}, s);
			if (st)
				for (const k in st)
					if (st[k] != null)
						merged[k] = st[k];
			return merged;
		}
		if (st && opt in st)
			return st[opt];
		return (opt in s) ? s[opt] : null;
	},
	set(conf, sid, opt, val) {
		this.staged[conf] = this.staged[conf] || {};
		this.staged[conf][sid] = this.staged[conf][sid] || {};
		this.staged[conf][sid][opt] = val;
	},
	remove(conf, sid, opt) { this.set(conf, sid, opt, null); },
	add(conf, type) {
		const sid = 'new_' + type + '_' + (++this._n);
		this.data[conf] = this.data[conf] || {};
		this.data[conf][sid] = { '.name': sid, '.type': type, '.anonymous': true };
		return sid;
	},
	commit() { /* simulated apply: fold staged changes into the base */
		for (const conf in this.staged) {
			this.data[conf] = this.data[conf] || {};
			for (const sid in this.staged[conf]) {
				this.data[conf][sid] = this.data[conf][sid] || {};
				for (const opt in this.staged[conf][sid]) {
					const v = this.staged[conf][sid][opt];
					if (v == null)
						delete this.data[conf][sid][opt];
					else
						this.data[conf][sid][opt] = v;
				}
			}
		}
		this.staged = {};
	}
};

function parseUci(text, conf) {
	const data = {};
	data[conf] = {};
	let cur = null;
	let anon = 0;
	text.split('\n').forEach((raw) => {
		const line = raw.trim();
		if (!line || line.startsWith('#'))
			return;
		let m = line.match(/^config\s+(\S+)(?:\s+'([^']*)')?$/);
		if (m) {
			const sid = m[2] || ('anon_' + m[1] + '_' + (++anon));
			cur = { '.name': sid, '.type': m[1], '.anonymous': !m[2] };
			data[conf][sid] = cur;
			return;
		}
		m = line.match(/^(option|list)\s+(\S+)\s+'(.*)'$/);
		if (m && cur) {
			if (m[1] === 'option')
				cur[m[2]] = m[3];
			else
				(cur[m[2]] = cur[m[2]] || []).push(m[3]);
		}
	});
	return data;
}

const RPC = {
	canned: {},
	declare(desc) {
		return function() {
			const a = arguments;
			return new Promise(function(resolve) {
				if (desc.object === 'file' && desc.method === 'exec')
					resolve(RPC.canned['exec:' + a[0] + ':' + a[1].join(' ')] || { stdout: '', stderr: '', code: 0 });
				else if (desc.object === 'file' && desc.method === 'read')
					resolve(RPC.canned['read:' + a[0]] != null ? RPC.canned['read:' + a[0]] : '');
				else if (desc.object === 'network.interface')
					resolve(RPC.canned['dump'] || { interface: [] });
				else
					resolve({});
			});
		};
	}
};

const cannedExec = (cmd, args, stdout) => { RPC.canned['exec:' + cmd + ':' + args.join(' ')] = { stdout }; };

function mkOption(cls, name, title, desc) {
	return {
		__cls: cls, option: name, title, description: desc,
		deps: [], values: [],
		rmempty: undefined, modalonly: undefined, datatype: undefined,
		placeholder: undefined, default: undefined, validate: undefined,
		depends(field, value) {
			if (typeof field === 'string') {
				const d = {};
				d[field] = value;
				this.deps.push(d);
			}
			else {
				this.deps.push(field);
			}
		},
		value(v, l) { this.values.push([v, l]); }
	};
}

function mkSection(cls, type, title) {
	const s = {
		__cls: cls, sectiontype: type, title,
		children: [],
		addremove: false, anonymous: true, sortable: false, modalonly: undefined,
		option(c, name, t, d) {
			const o = mkOption(c, name, t, d);
			s.children.push(o);
			return o;
		}
	};
	return s;
}

const form = {
	Map: function(config, title, desc) {
		this.config = config;
		this.title = title;
		this.description = desc;
		this.children = [];
		this.render = () => Promise.resolve(E('div', { class: 'cbi-map' }));
	},
	GridSection: { __name__: 'GridSection', prototype: { handleRemove() { return Promise.resolve(); } } },
	DummyValue: { __name__: 'DummyValue' },
	ListValue: { __name__: 'ListValue' },
	MultiValue: { __name__: 'MultiValue' },
	Value: { __name__: 'Value' }
};
form.Map.prototype.section = function(cls, type, title) {
	const s = mkSection(cls, type, title);
	this.children.push(s);
	return s;
};

const view = { extend(o) { return o; } };
const poll = { add() {} };
const ui = {
	addNotification() {}, showModal() {}, hideModal() {},
	createHandlerFn(scope, fn) { return function() { return fn.apply(scope, arguments); }; },
	changes: { init() { return Promise.resolve(); } }
};
const L = {
	bind(fn, scope) {
		const pre = Array.prototype.slice.call(arguments, 2);
		return function() { return fn.apply(scope, pre.concat(Array.prototype.slice.call(arguments))); };
	},
	isArray: Array.isArray,
	isObject: (o) => !!o && typeof o === 'object'
};
const _ = (s) => s;
const documentStub = { querySelector() { return null; }, querySelectorAll() { return []; } };
const windowStub = {};
const localStorageStub = { getItem() { return null; }, setItem() {} };

/* load the REAL view code: top-level return is legal in a Function body */
function loadView() {
	const fn = new Function(
		'view', 'form', 'poll', 'rpc', 'uci', 'ui', 'E', 'L', '_', 'document', 'window', 'localStorage',
		VIEW_SRC);
	return fn(view, form, poll, RPC, UCI, ui, E, L, _, documentStub, windowStub, localStorageStub);
}

/* ---------- check harness ---------- */

let pass = 0, fail = 0;
const failures = [];

function ok(name, cond, extra) {
	if (cond) {
		pass++;
		console.log('ok - ' + name);
	}
	else {
		fail++;
		failures.push(name);
		console.log('NOT OK - ' + name + (extra !== undefined ? ' :: ' + JSON.stringify(extra) : ''));
	}
}

function assertEq(name, got, want) {
	ok(name, got === want, { got, want });
}

const GLB = fixture('grouplist.txt');

/* canned router-side outputs for load()/render() against the lb2 fixture */
function cannedLb2() {
	RPC.canned = {
		'read:/tmp/dhcp.leases': '',
		'exec:/usr/bin/wanguard:list': { stdout: 'members: 1\n\naa:bb:cc:dd:ee:55 lb\nnft: in-sync' },
		'exec:/usr/bin/wanguard:devices': { stdout: 'aa:bb:cc:dd:ee:55\t192.168.1.55\tclient\t1' },
		'exec:/usr/bin/wanguard:grouplist': { stdout: GLB },
		'dump': { interface: [
			{ interface: 'lan', up: true },
			{ interface: 'wan1', up: true },
			{ interface: 'wan2', up: true },
			{ interface: 'wan3', up: true }
		] }
	};
}

/* each scenario gets a fresh UCI + a fresh view closure (fresh LB_GROUPLIST) */
const scenarios = [];

function scenario(name, fixtureName, fn) {
	scenarios.push({ name, run: async () => {
		UCI.reset(fixtureName ? fixture(fixtureName) : null);
		RPC.canned = {};
		const v = loadView();
		await fn(v, name);
	} });
}

/* ============================ tests ============================ */

/* --- J1: parseGrouplist --- */
scenario('J1 parseGrouplist', 'lb2.uci', async (v, tag) => {
	const rows = v.parseGrouplist(GLB);
	ok(tag + ' direct-lb rows only, group keyed',
		rows.a === undefined && Array.isArray(rows.lb) && rows.lb.length === 2, rows);
	assertEq(tag + ' slot 1 iface/mark', [rows.lb[0].iface, rows.lb[0].mark].join('/'), 'wan1/200');
	assertEq(tag + ' slot 1 device', rows.lb[0].device, 'eth0');
	assertEq(tag + ' slot 2 mark/table', [rows.lb[1].mark, rows.lb[1].table].join('/'), '400/402');
	assertEq(tag + ' slot 2 device', rows.lb[1].device, 'eth1');
	ok(tag + ' old CLI (no output) degrades to {}',
		Object.keys(v.parseGrouplist('')).length === 0);
	ok(tag + ' garbage header skipped',
		Object.keys(v.parseGrouplist('garbage line here')).length === 0);
});

/* --- J2: conf_lb2 parity with the ucode mock numbers (LB2/LB4) --- */
scenario('J2 conf_lb2 slot parity', 'lb2.uci', async (v, tag) => {
	assertEq(tag + ' witness unchanged', v.allocPreview('a'), 'fwmark 100 → table 400');
	assertEq(tag + ' lb slots (UCI only)',
		v.allocPreview('lb'), 'wan1 70% 200/401 · wan2 30% 400/402');
});

/* --- J3: conf_lb3 — three members, no weights -> buckets 33/33/34 --- */
scenario('J3 conf_lb3 buckets', 'lb3.uci', async (v, tag) => {
	assertEq(tag + ' 50/50/50 -> 33/33/34, cascade continues',
		v.allocPreview('lb'), 'wan1 33% 200/401 · wan2 33% 400/402 · wan3 34% 500/403');
});

/* --- J4: conf_lbpx — proxy present must not shift anything --- */
scenario('J4 conf_lbpx boundary', 'lbpx.uci', async (v, tag) => {
	assertEq(tag + ' proxy fixed', v.allocPreview('p'), 'fwmark 300 → table 500 (fixed)');
	assertEq(tag + ' witness not shifted by proxy', v.allocPreview('a'), 'fwmark 100 → table 400');
	assertEq(tag + ' lb marks unchanged', v.allocPreview('lb'), 'wan1 70% 200/401 · wan2 30% 400/402');
});

/* --- J5: weight normalization (0 / garbage / absent -> 50) --- */
scenario('J5 weight normalization', 'lbw.uci', async (v, tag) => {
	assertEq(tag + ' 0/abc/absent -> 50 each, same buckets as defaults',
		v.allocPreview('lb'), 'wan1 33% 200/401 · wan2 33% 400/402 · wan3 34% 500/403');
});

/* --- J6: member_live failover display (#39 tick-owned) --- */
scenario('J6 member_live display', 'lbz.uci', async (v, tag) => {
	assertEq(tag + ' slot 0 failed over to wan2',
		v.allocPreview('lb'), 'wan1→wan2 70% 200/401 · wan2 30% 400/402');
});

/* --- J7: member-count edges (same behavior as the CLI) --- */
scenario('J7 member-count edges', null, async (v, tag) => {
	const mem = [];
	for (let i = 1; i <= 21; i++)
		mem.push('wan' + (i < 10 ? '0' + i : i));
	UCI.data.wanguard.lbbig = {
		'.name': 'lbbig', '.type': 'group', '.anonymous': false,
		type: 'direct-lb', member_iface: mem
	};
	assertEq(tag + ' >20 members — ignored', v.allocPreview('lbbig'), '— (>20 members — ignored)');

	UCI.data.wanguard.lb0 = {
		'.name': 'lb0', '.type': 'group', '.anonymous': false, type: 'direct-lb'
	};
	assertEq(tag + ' no members — ignored', v.allocPreview('lb0'), '— (no members — ignored)');
});

/* --- J8: two lb groups continue one cascade --- */
scenario('J8 two lb groups', 'lb2g.uci', async (v, tag) => {
	assertEq(tag + ' lb', v.allocPreview('lb'), 'wan1 70% 200/401 · wan2 30% 400/402');
	assertEq(tag + ' lb2 continues the cascade',
		v.allocPreview('lb2'), 'wan1 60% 500/403 · wan3 40% 600/404');
});

/* --- J9: legacy direct/proxy config — golden behavior unchanged --- */
scenario('J9 legacy golden', 'legacy.uci', async (v, tag) => {
	assertEq(tag + ' a', v.allocPreview('a'), 'fwmark 100 → table 400');
	assertEq(tag + ' b', v.allocPreview('b'), 'fwmark 200 → table 401');
	assertEq(tag + ' c (mark 300 skipped)', v.allocPreview('c'), 'fwmark 400 → table 402');
	assertEq(tag + ' p', v.allocPreview('p'), 'fwmark 300 → table 500 (fixed)');
	assertEq(tag + ' unknown group renders empty', v.allocPreview('nope'), '');
	const bg = v.boardGroups();
	assertEq(tag + ' board order', bg.map((g) => g.name).join(','), 'a,b,c,p');
	assertEq(tag + ' labels', bg.map((g) => g.label).join('|'), 'a — wan3|b — wan1|c — wan2|p — mihomo');
});

/* --- J10: board structure + device enrichment via load() --- */
scenario('J10 board build', 'lb2.uci', async (v, tag) => {
	cannedLb2();
	await v.load();
	const root = await v.render();

	const lb = colParts(findCol(root, 'lb'));
	assertEq(tag + ' lb title', lb.title, 'lb — LB');
	assertEq(tag + ' lb sub (slots + devices + count)',
		lb.sub, 'wan1 70% 200/401 (eth0) · wan2 30% 400/402 (eth1) · 1');
	assertEq(tag + ' lb card mac', lb.cards[0] && lb.cards[0].attrs['data-mac'], 'aa:bb:cc:dd:ee:55');

	const a = colParts(findCol(root, 'a'));
	assertEq(tag + ' direct column title unchanged', a.title, 'a — wan3');
	assertEq(tag + ' direct column sub unchanged', a.sub, 'fwmark 100 → table 400 · 0');

	const u = colParts(findCol(root, ''));
	assertEq(tag + ' unclassified column present', u.title, 'Unclassified');

	/* board column order: direct first, lb inside the non-proxy block */
	const order = [ 'a', 'lb', '' ].map((g) => findCol(root, g) ? 1 : 0).join('');
	assertEq(tag + ' all columns built', order, '111');
});

/* --- J11: group modal — member/weight options (#40) --- */
scenario('J11 modal options', 'lb2.uci', async (v, tag) => {
	v.ifaces = [ 'lan', 'wan1', 'wan2', 'wan3' ];
	await v.render();

	const groups = v._map.children[0];
	assertEq(tag + ' groups section found', groups.sectiontype, 'group');

	const typeOpt = groups.children.find((c) => c.option === 'type');
	ok(tag + ' type choice direct-lb added', typeOpt.values.some((x) => x[0] === 'direct-lb'), typeOpt.values);
	ok(tag + ' type choice direct kept', typeOpt.values.some((x) => x[0] === 'direct'));
	ok(tag + ' type choice proxy kept', typeOpt.values.some((x) => x[0] === 'proxy'));

	const ifaceOpt = groups.children.find((c) => c.option === 'iface');
	ok(tag + ' iface option depends type=direct only',
		JSON.stringify(ifaceOpt.deps) === JSON.stringify([ { type: 'direct' } ]), ifaceOpt.deps);
	ok(tag + ' no static member_iface/weight columns',
		!groups.children.some((c) => c.option === 'member_iface' || String(c.option).startsWith('weight_')));

	/* lb group modal */
	const mlb = mkSection('modal', 'group', 'Group');
	groups.addModalOptions(mlb, 'lb');
	const mem = mlb.children.find((c) => c.option === 'member_iface');
	ok(tag + ' member_iface added (MultiValue)', !!mem && mem.__cls === form.MultiValue);
	assertEq(tag + ' member_iface rmempty=false', mem.rmempty, false);
	assertEq(tag + ' member_iface modalonly', mem.modalonly, true);
	assertEq(tag + ' member choices = sorted up ifaces + members',
		JSON.stringify(mem.values.map((x) => x[0])),
		JSON.stringify([ 'lan', 'wan1', 'wan2', 'wan3' ]));

	for (const ifc of [ 'wan1', 'wan2', 'wan3' ]) {
		const w = mlb.children.find((c) => c.option === 'weight_' + ifc);
		ok(tag + ' weight_' + ifc + ' added', !!w);
		ok(tag + ' weight_' + ifc + ' depends {type, member_iface !contains}',
			JSON.stringify(w.deps) === JSON.stringify([ { type: 'direct-lb', member_iface: ifc, '!contains': true } ]),
			w.deps);
		assertEq(tag + ' weight_' + ifc + ' placeholder 50', w.placeholder, '50');
		assertEq(tag + ' weight_' + ifc + ' rmempty', w.rmempty, true);
		assertEq(tag + ' weight_' + ifc + ' modalonly', w.modalonly, true);
	}
	ok(tag + ' weight_lan exists too (hidden until staged as member — ' +
		'a NEW member gets its weight in the same modal session)',
		!!mlb.children.find((c) => c.option === 'weight_lan'));

	/* direct group modal gains nothing */
	const md = mkSection('modal', 'group', 'Group');
	groups.addModalOptions(md, 'a');
	assertEq(tag + ' direct modal untouched', md.children.length, 0);

	/* proxy group modal gains nothing */
	UCI.data.wanguard.g_p = { '.name': 'g_p', '.type': 'group', type: 'proxy' };
	const mp = mkSection('modal', 'group', 'Group');
	groups.addModalOptions(mp, 'g_p');
	assertEq(tag + ' proxy modal untouched', mp.children.length, 0);
});

/* --- J12: edit simulation — staged UCI survives "Save&Apply" --- */
scenario('J12 edit persistence', 'lb2.uci', async (v, tag) => {
	/* modal save stages: member wan3 added with weight 20 */
	UCI.set('wanguard', 'lb', 'member_iface', [ 'wan1', 'wan2', 'wan3' ]);
	UCI.set('wanguard', 'lb', 'weight_wan3', '20');

	/* already visible from staged UCI — display derives from UCI only */
	assertEq(tag + ' staged visible pre-apply (buckets 58/25/17)',
		v.allocPreview('lb'), 'wan1 58% 200/401 · wan2 25% 400/402 · wan3 17% 500/403');

	UCI.commit(); /* simulated uci apply */

	assertEq(tag + ' committed (survives Save&Apply)',
		v.allocPreview('lb'), 'wan1 58% 200/401 · wan2 25% 400/402 · wan3 17% 500/403');

	/* member removal: down to wan1 only — single-member remainder form */
	UCI.set('wanguard', 'lb', 'member_iface', [ 'wan1' ]);
	UCI.commit();
	assertEq(tag + ' shrink to one member', v.allocPreview('lb'), 'wan1 100% 200/401');
	ok(tag + ' dropped member weight invisible',
		!v.allocPreview('lb').includes('30'));
});

/* --- J13: degraded environments --- */
scenario('J13 degraded', 'lb2.uci', async (v, tag) => {
	/* no grouplist output (old CLI / ACL lost): board still renders slots */
	await v.load();
	const root = await v.render();
	const p = colParts(findCol(root, 'lb'));
	assertEq(tag + ' no device suffix without grouplist',
		p.sub, 'wan1 70% 200/401 · wan2 30% 400/402 · 1');
});

/* ============================ demo ============================ */

async function demo() {
	console.log('\n=== DEMO — board on handwritten UCI (fixtures/lb2.uci, no prod backend) ===');
	UCI.reset(fixture('lb2.uci'));
	cannedLb2();
	const v = loadView();
	await v.load();
	const root = await v.render();
	for (const g of [ 'a', 'lb', '' ]) {
		const p = colParts(findCol(root, g));
		console.log('  [' + p.title + ']  {' + p.sub + '}');
		p.cards.forEach((c) => console.log('      card ' + c.attrs['data-mac']));
	}
	console.log('  group modal (lb): member_iface=' +
		JSON.stringify(UCI.get('wanguard', 'lb', 'member_iface')) +
		' weight_wan1=70 weight_wan2=30');

	console.log('\n=== DEMO — after edit (wan3 added, weight 20) + Save&Apply ===');
	UCI.set('wanguard', 'lb', 'member_iface', [ 'wan1', 'wan2', 'wan3' ]);
	UCI.set('wanguard', 'lb', 'weight_wan3', '20');
	UCI.commit();
	console.log('  [lb — LB]  {' + v.allocPreview('lb') + '}  (board rebuilds from UCI)');

	console.log('\n=== DEMO — tick failover (member_live wan2, fixture lbz.uci) ===');
	UCI.reset(fixture('lbz.uci'));
	console.log('  [lb — LB]  {' + v.allocPreview('lb') + '}');
}

/* ============================ main ============================ */

(async () => {
	for (const s of scenarios) {
		try {
			await s.run();
		}
		catch (e) {
			fail++;
			failures.push(s.name);
			console.log('NOT OK - ' + s.name + ' :: threw ' + (e && e.stack || e));
		}
	}

	await demo();

	console.log('\n=== RESULTS: ' + pass + ' pass, ' + fail + ' fail ===');
	if (failures.length) {
		failures.forEach((f) => console.log('FAILED: ' + f));
		process.exit(1);
	}
	process.exit(0);
})();
