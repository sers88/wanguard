#!/usr/bin/env node
'use strict';
/*
 * luci-app-wanguard harness (#40, re-laid out for #46): runs the REAL
 * code from luci-app-wanguard/htdocs/luci-static/resources — the shared
 * core module (wanguard/core.js) and the file views
 * (view/wanguard/{overview,devices,groups,diagnostics,antidpi-placeholder}.js)
 * — inside node with stubbed LuCI globals (view/form/poll/rpc/uci/ui/E/L/_),
 * so no router, LuCI or prod backend is involved — the UCI side is loaded
 * from the handwritten fixtures/ configs (the same lab-shaped configs as
 * the ucode mock suite: witness + lb members 70/30).
 *
 * What is pinned here:
 *   - UCI slot derivation parity with the CLI allocator (wand.uc
 *     alloc_entries LB branch): witness 100/400, lb slots 200/401 and
 *     400/402 (mark 300 skipped), two lb groups continuing one cascade,
 *     buckets floor + remainder-to-last (33/33/34 for 50/50/50),
 *     weights 0/garbage/absent -> 50, member_live failover display,
 *     >20 members / no members degrade — numbers match the ucode mock
 *     suite (LB2/LB4) and the lab (J1–J8/J12/J14 against wg.*).
 *   - direct/proxy behavior unchanged: golden preview strings and board
 *     labels for a legacy direct/proxy config (J9 -> wg.boardGroups).
 *   - board structure and device enrichment via the overview view's
 *     load()/render() (J10/J13) — the same DOM the monolith produced.
 *   - group modal (#40): addModalOptions adds member_iface (MultiValue)
 *     + one weight_<iface> field per candidate iface with
 *     depends({type:'direct-lb', member_iface:'<ifc>', '!contains':
 *     true}) — the weight field appears when the member is staged and
 *     its stray option is removed by form.js parse semantics when the
 *     membership is dropped; direct/proxy modals gain nothing
 *     (J11 against the groups view).
 *   - edit persistence: staged UCI member/weight changes are reflected
 *     by the same display code path (Save&Apply = staged UCI + commit).
 *   - #46 layout (additive L1–L7): menu.d category + 4 deep-linkable
 *     children, acl.d golden (unchanged), apk/build.sh + CI feed-test +
 *     deploy-luci.ps1 ship the five new files (and NOT the deleted
 *     monolith), and decision D2 — overview Table mode shows BOTH grids
 *     (groups+devices) while the devices/groups pages get single-grid
 *     Maps.
 *
 * Run: node tests/luci/run-tests.js
 */

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const LUCI = path.join(REPO, 'luci-app-wanguard');
const CORE = path.join(LUCI, 'htdocs', 'luci-static', 'resources', 'wanguard', 'core.js');
const VIEW_DIR = path.join(LUCI, 'htdocs', 'luci-static', 'resources', 'view', 'wanguard');
const VIEW_MONOLITH = path.join(LUCI, 'htdocs', 'luci-static', 'resources', 'view', 'wanguard.js');
const FIX = path.join(__dirname, 'fixtures');

const CORE_SRC = fs.readFileSync(CORE, 'utf8');
const VIEW_SRC = {
	overview: fs.readFileSync(path.join(VIEW_DIR, 'overview.js'), 'utf8'),
	devices: fs.readFileSync(path.join(VIEW_DIR, 'devices.js'), 'utf8'),
	groups: fs.readFileSync(path.join(VIEW_DIR, 'groups.js'), 'utf8'),
	diagnostics: fs.readFileSync(path.join(VIEW_DIR, 'diagnostics.js'), 'utf8'),
	'antidpi-placeholder': fs.readFileSync(path.join(VIEW_DIR, 'antidpi-placeholder.js'), 'utf8')
};
const fixture = (name) => fs.readFileSync(path.join(FIX, name), 'utf8');

/* ---------- LuCI polyfills ---------- */

/* String.format: only %s and %d are used by the views */
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
		get innerHTML() { return this._h || ''; },
		set innerHTML(v) { this._h = v; if (v === '') this.children.length = 0; },
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
	const pick = function(cls) {
		return head.children.find(function(c) {
			return c.attrs && (c.attrs.class || '') === cls;
		});
	};
	const t = pick('wg-col-title');
	const s = pick('wg-col-sub');
	const ch = pick('wg-col-chip');
	return {
		title: t ? flat(t) : '',
		sub: s ? flat(s) : '',
		chip: ch ? flat(ch) : '',
		cards: col.children[1].children
	};
}

/* ---------- stubbed LuCI globals ---------- */

const UCI = {
	data: {}, staged: {}, _n: 0, _src: null, _base: null,
	reset(text) {
		this._src = text || null;
		this.data = text ? parseUci(text, 'wanguard') : { wanguard: {} };
		this._base = JSON.parse(JSON.stringify(this.data));
		this.staged = {};
	},
	load() {
		/* re-read the "server" config after unload() (panel Cancel, #49):
		 * _base = whatever the last commit left there, so committed
		 * changes survive while client-side adds are discarded */
		if (!this.data.wanguard || !Object.keys(this.data.wanguard).length)
			this.data = this._base ? JSON.parse(JSON.stringify(this._base)) : (this._src ? parseUci(this._src, 'wanguard') : { wanguard: {} });
		return Promise.resolve();
	},
	unload(conf) {
		/* real LuCI drops the whole client-side config state incl. the
		 * staged changes (panel/drawer Cancel, #49/#48) */
		delete this.data[conf];
		delete this.staged[conf];
	},
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
		const m = /^@(\w+)\[-1\]$/.exec(sid);
		if (m) {
			const ty = m[1];
			const ks = Object.keys(this.data[conf] || {}).filter(function(k) {
				return (this.data[conf][k] || {})['.type'] === ty;
			}, this);
			sid = ks.length ? ks[ks.length - 1] : sid;
		}
		this.staged[conf] = this.staged[conf] || {};
		this.staged[conf][sid] = this.staged[conf][sid] || {};
		this.staged[conf][sid][opt] = val;
	},
	remove(conf, sid, opt) {
		/* whole-section removal (doApply / #49 delete + rename): drops
		 * the section from the in-memory config; option-level removal
		 * stays the staged-null fold */
		if (opt == null) {
			delete this.data[conf][sid];
			if (this.staged[conf])
				delete this.staged[conf][sid];
			return;
		}
		this.set(conf, sid, opt, null);
	},
	changes(conf) {
		const c = this.staged[conf] || {};
		return Object.keys(c).map(function(sid) { return [ sid, Object.keys(c[sid]).sort().join(',') ]; });
	},
	save() { this._saves = (this._saves || 0) + 1; return Promise.resolve(); },
	apply() { this.commit(); return Promise.resolve(); },
	add(conf, type, name) {
		/* #49: the third argument names the section (uci.add named
		 * semantics — the group name IS the section id) */
		const sid = name || ('new_' + type + '_' + (++this._n));
		this.data[conf] = this.data[conf] || {};
		this.data[conf][sid] = { '.name': sid, '.type': type, '.anonymous': !name };
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
		this._base = JSON.parse(JSON.stringify(this.data));
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

/* canned diagnostics outputs (#50): the #44/#45 CLI answers on top of
 * the lb2 fixture set (list/devices/grouplist/dump/leases already there) */
function cannedDiag() {
	cannedLb2();
	RPC.canned['exec:/usr/bin/wanguard:syncstatus'] = { stdout: fixture('syncstatus.txt') };
	RPC.canned['exec:/usr/bin/wanguard:events 20'] = { stdout: fixture('events.txt') };
	RPC.canned['exec:/usr/bin/wanguard:diag health'] = { stdout: fixture('diag-health.txt') };
	RPC.canned['exec:/usr/bin/wanguard:diag rules'] = { stdout: fixture('diag-rules.txt') };
	RPC.canned['exec:/usr/bin/wanguard:diag tables'] = { stdout: fixture('diag-tables.txt') };
	RPC.canned['exec:/usr/bin/wanguard:diag nft'] = { stdout: fixture('diag-nft.txt') };
}

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
/* #74: the recorded callbacks let tests fire poll ticks (views register
 * through render; take the LAST entry = the most recent render) */
const poll = { add(fn, iv) { poll._cbs.push(fn); }, _cbs: [] };
const ui = {
	_notes: [],
	addNotification(ctx, node, sev) { this._notes.push([sev || '', flat(node)]); },
	showModal(title, body) { ui._modal = [title, body]; },
	hideModal() { ui._modal = null; },
	createHandlerFn(scope, fn) { return function() { return fn.apply(scope, arguments); }; },
	changes: { init() { return Promise.resolve(); } }
};
/* minimal stand-in for LuCI's Class: core.js ends with
 * L.Class.extend({...}) because the real loader (Class.isSubclass)
 * rejects plain-object modules and instantiates the class itself */
const Class = function() {};
Class.prototype = {};
Class.extend = function(properties) {
	const F = function() {};
	F.prototype = Object.assign(Object.create(this.prototype), properties);
	F.extend = Class.extend;
	return F;
};
const L = {
	Class: Class,
	bind(fn, scope) {
		const pre = Array.prototype.slice.call(arguments, 2);
		return function() { return fn.apply(scope, pre.concat(Array.prototype.slice.call(arguments))); };
	},
	/* NB: deliberately MINIMAL — the real luci.js exposes no isArray
	 * (only the builtin Array.isArray), so the stub must not either;
	 * stub-API divergence is exactly what live window findings are
	 * made of (L.isArray hit the router, 2026-10-30). */
	isObject: (o) => !!o && typeof o === 'object'
};
L.url = function(p) { return '/' + p; };
global.location = { href: '' };
const _ = (s) => s;
/* document stub (#50): createElement + a backed body for the diag-report
 * download (diagSaveFile) and the copy fallback; _downloads records the
 * synthetic <a download> clicks for assertions. The stub elements have
 * no select() and document has no execCommand, so the degraded copy
 * path still reports an honest failure (D11 semantics unchanged). */
const documentStub = {
	querySelector() { return null; }, querySelectorAll() { return []; },
	_downloads: [],
	createElement(tag) {
		const el = E(tag);
		el.click = function() {
			documentStub._downloads.push({
				href: el.href != null ? el.href : (el.attrs.href || ''),
				download: el.download != null ? el.download : (el.attrs.download || '')
			});
		};
		return el;
	},
	body: { appendChild() {}, removeChild() {} }
};
const windowStub = {};
/* URL stub (#50): diagSaveFile downloads via Blob + createObjectURL;
 * the recorded calls back the download assertions */
const URLStub = {
	_objects: [],
	_revoked: [],
	createObjectURL(blob) { this._objects.push(blob); return 'blob:fake-' + this._objects.length; },
	revokeObjectURL(u) { this._revoked.push(u); },
	reset() { this._objects.length = 0; this._revoked.length = 0; }
};
/* navigator stub (#48 D11): copyText reads navigator.clipboard — empty
 * by default (the http:// router case), filled per test for the
 * secure-context path */
const NAV = {};
const localStorageStub = {
	_s: {},
	getItem(k) { return (k in this._s) ? this._s[k] : null; },
	setItem(k, v) { this._s[k] = String(v); }
};

/* load the REAL code: top-level return is legal in a Function body.
 * core.js declares 'require rpc/uci/ui/form' -> those are the wrapper's
 * params; the views declare 'require view/poll[/ui][/uci]' plus
 * 'require wanguard.core as wg' -> wg is passed explicitly. Like the
 * real loader, core.js must yield a LuCI class -> return the INSTANCE. */
function loadCore() {
	const fn = new Function(
		'rpc', 'uci', 'ui', 'form', 'poll', 'E', 'L', '_', 'document', 'window', 'localStorage', 'navigator', 'URL',
		CORE_SRC);
	const C = fn(RPC, UCI, ui, form, poll, E, L, _, documentStub, windowStub, localStorageStub, NAV, URLStub);
	if (typeof C !== 'function')
		throw new Error('core.js must yield a LuCI class (L.Class.extend)');
	return new C();
}

function loadView(name, wg) {
	const fn = new Function(
		'view', 'form', 'poll', 'rpc', 'uci', 'ui', 'E', 'L', '_', 'document', 'window', 'localStorage', 'wg', 'URL',
		VIEW_SRC[name]);
	return fn(view, form, poll, RPC, UCI, ui, E, L, _, documentStub, windowStub, localStorageStub, wg, URLStub);
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

/* each scenario gets a fresh UCI + a fresh core closure (fresh
 * LB_GROUPLIST/status state), exactly like the monolith harness */
const scenarios = [];

function scenario(name, fixtureName, fn) {
	scenarios.push({ name, run: async () => {
		UCI.reset(fixtureName ? fixture(fixtureName) : null);
		UCI._saves = 0; /* per-scenario counter (D8 counts the bulk saves) */
		RPC.canned = {};
		localStorageStub._s = {};
		global.location.href = '';
		ui._modal = null;
		ui._notes = [];
		documentStub._downloads.length = 0; /* #50 download assertions */
		URLStub.reset();
		for (const k in NAV)
			delete NAV[k];
		const wg = loadCore();
		await fn(wg, name);
	} });
}

/* ============================ tests ============================ */

/* --- J1: parseGrouplist --- */
scenario('J1 parseGrouplist', 'lb2.uci', async (wg, tag) => {
	const rows = wg.parseGrouplist(GLB);
	ok(tag + ' direct-lb rows only, group keyed',
		rows.a === undefined && Array.isArray(rows.lb) && rows.lb.length === 2, rows);
	assertEq(tag + ' slot 1 iface/mark', [rows.lb[0].iface, rows.lb[0].mark].join('/'), 'wan1/200');
	assertEq(tag + ' slot 1 device', rows.lb[0].device, 'eth0');
	assertEq(tag + ' slot 2 mark/table', [rows.lb[1].mark, rows.lb[1].table].join('/'), '400/402');
	assertEq(tag + ' slot 2 device', rows.lb[1].device, 'eth1');
	ok(tag + ' old CLI (no output) degrades to {}',
		Object.keys(wg.parseGrouplist('')).length === 0);
	ok(tag + ' garbage header skipped',
		Object.keys(wg.parseGrouplist('garbage line here')).length === 0);
});

/* --- J2: conf_lb2 parity with the ucode mock numbers (LB2/LB4) --- */
scenario('J2 conf_lb2 slot parity', 'lb2.uci', async (wg, tag) => {
	assertEq(tag + ' witness unchanged', wg.allocPreview('a'), 'fwmark 100 → table 400');
	assertEq(tag + ' lb slots (UCI only)',
		wg.allocPreview('lb'), 'wan1 70% 200/401 · wan2 30% 400/402');
});

/* --- J3: conf_lb3 — three members, no weights -> buckets 33/33/34 --- */
scenario('J3 conf_lb3 buckets', 'lb3.uci', async (wg, tag) => {
	assertEq(tag + ' 50/50/50 -> 33/33/34, cascade continues',
		wg.allocPreview('lb'), 'wan1 33% 200/401 · wan2 33% 400/402 · wan3 34% 500/403');
});

/* --- J4: conf_lbpx — proxy present must not shift anything --- */
scenario('J4 conf_lbpx boundary', 'lbpx.uci', async (wg, tag) => {
	assertEq(tag + ' proxy fixed', wg.allocPreview('p'), 'fwmark 300 → table 500 (fixed)');
	assertEq(tag + ' witness not shifted by proxy', wg.allocPreview('a'), 'fwmark 100 → table 400');
	assertEq(tag + ' lb marks unchanged', wg.allocPreview('lb'), 'wan1 70% 200/401 · wan2 30% 400/402');
});

/* --- J5: weight normalization (0 / garbage / absent -> 50) --- */
scenario('J5 weight normalization', 'lbw.uci', async (wg, tag) => {
	assertEq(tag + ' 0/abc/absent -> 50 each, same buckets as defaults',
		wg.allocPreview('lb'), 'wan1 33% 200/401 · wan2 33% 400/402 · wan3 34% 500/403');
});

/* --- J6: member_live failover display (#39 tick-owned) --- */
scenario('J6 member_live display', 'lbz.uci', async (wg, tag) => {
	assertEq(tag + ' slot 0 failed over to wan2',
		wg.allocPreview('lb'), 'wan1→wan2 70% 200/401 · wan2 30% 400/402');
});

/* --- J7: member-count edges (same behavior as the CLI) --- */
scenario('J7 member-count edges', null, async (wg, tag) => {
	const mem = [];
	for (let i = 1; i <= 21; i++)
		mem.push('wan' + (i < 10 ? '0' + i : i));
	UCI.data.wanguard.lbbig = {
		'.name': 'lbbig', '.type': 'group', '.anonymous': false,
		type: 'direct-lb', member_iface: mem
	};
	assertEq(tag + ' >20 members — ignored', wg.allocPreview('lbbig'), '— (>20 members — ignored)');

	UCI.data.wanguard.lb0 = {
		'.name': 'lb0', '.type': 'group', '.anonymous': false, type: 'direct-lb'
	};
	assertEq(tag + ' no members — ignored', wg.allocPreview('lb0'), '— (no members — ignored)');
});

/* --- J8: two lb groups continue one cascade --- */
scenario('J8 two lb groups', 'lb2g.uci', async (wg, tag) => {
	assertEq(tag + ' lb', wg.allocPreview('lb'), 'wan1 70% 200/401 · wan2 30% 400/402');
	assertEq(tag + ' lb2 continues the cascade',
		wg.allocPreview('lb2'), 'wan1 60% 500/403 · wan3 40% 600/404');
});

/* --- J9: legacy direct/proxy config — golden behavior unchanged --- */
scenario('J9 legacy golden', 'legacy.uci', async (wg, tag) => {
	assertEq(tag + ' a', wg.allocPreview('a'), 'fwmark 100 → table 400');
	assertEq(tag + ' b', wg.allocPreview('b'), 'fwmark 200 → table 401');
	assertEq(tag + ' c (mark 300 skipped)', wg.allocPreview('c'), 'fwmark 400 → table 402');
	assertEq(tag + ' p', wg.allocPreview('p'), 'fwmark 300 → table 500 (fixed)');
	assertEq(tag + ' unknown group renders empty', wg.allocPreview('nope'), '');
	const bg = wg.boardGroups();
	assertEq(tag + ' board order', bg.map((g) => g.name).join(','), 'a,b,c,p');
	assertEq(tag + ' labels', bg.map((g) => g.label).join('|'), 'a — wan3|b — wan1|c — wan2|p — mihomo');
});

/* --- J10: board structure + device enrichment via the overview view --- */
scenario('J10 board build (#47 layout)', 'lb2.uci', async (wg, tag) => {
	cannedLb2();
	const ov = loadView('overview', wg);
	await ov.load();
	const root = await ov.render();

	const lb = colParts(findCol(root, 'lb'));
	assertEq(tag + ' lb title', lb.title, 'lb — LB');
	assertEq(tag + ' lb sub (device count)', lb.sub, '1 device');
	assertEq(tag + ' lb chip (member summary)', lb.chip, 'wan1+wan2 · LB');
	assertEq(tag + ' lb card mac', lb.cards[0] && lb.cards[0].attrs['data-mac'], 'aa:bb:cc:dd:ee:55');

	const a = colParts(findCol(root, 'a'));
	assertEq(tag + ' direct column title unchanged', a.title, 'a — wan3');
	assertEq(tag + ' direct sub (device count)', a.sub, '0 devices');
	assertEq(tag + ' direct chip (iface · WAN)', a.chip, 'wan3 · WAN');

	const u = colParts(findCol(root, ''));
	assertEq(tag + ' column renamed', u.title, 'Unassigned');
	assertEq(tag + ' unassigned has no chip', u.chip, '');

	const order = [ 'a', 'lb', '' ].map(function(g) { return findCol(root, g) ? 1 : 0; }).join('');
	assertEq(tag + ' all columns built', order, '111');
});


/* --- J11: group modal — member/weight options (#40, groups view) ---
 * #49 moved the groups page to the custom panel; the GridSection engine
 * itself is unchanged and is pinned through the core factory now. */
scenario('J11 modal options', 'lb2.uci', async (wg, tag) => {
	wg.state.ifaces = [ 'lan', 'wan1', 'wan2', 'wan3' ];
	const groups = wg.buildGroupsGrid().map.children[0];
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
scenario('J12 edit persistence', 'lb2.uci', async (wg, tag) => {
	/* modal save stages: member wan3 added with weight 20 */
	UCI.set('wanguard', 'lb', 'member_iface', [ 'wan1', 'wan2', 'wan3' ]);
	UCI.set('wanguard', 'lb', 'weight_wan3', '20');

	/* already visible from staged UCI — display derives from UCI only */
	assertEq(tag + ' staged visible pre-apply (buckets 58/25/17)',
		wg.allocPreview('lb'), 'wan1 58% 200/401 · wan2 25% 400/402 · wan3 17% 500/403');

	UCI.commit(); /* simulated uci apply */

	assertEq(tag + ' committed (survives Save&Apply)',
		wg.allocPreview('lb'), 'wan1 58% 200/401 · wan2 25% 400/402 · wan3 17% 500/403');

	/* member removal: down to wan1 only — single-member remainder form */
	UCI.set('wanguard', 'lb', 'member_iface', [ 'wan1' ]);
	UCI.commit();
	assertEq(tag + ' shrink to one member', wg.allocPreview('lb'), 'wan1 100% 200/401');
	ok(tag + ' dropped member weight invisible',
		!wg.allocPreview('lb').includes('30'));
});

/* --- J13: degraded environments (overview view, no canned RPC) --- */
scenario('J13 degraded', 'lb2.uci', async (wg, tag) => {
	/* old CLI / lost ACL: board still renders counts + UCI-only chip */
	const ov = loadView('overview', wg);
	await ov.load();
	const root = await ov.render();
	const p = colParts(findCol(root, 'lb'));
	assertEq(tag + ' count survives without grouplist', p.sub, '1 device');
	assertEq(tag + ' chip degrades to UCI-only', p.chip, 'wan1+wan2 · LB');
});


/* --- J14: the shipped config template stays allocator-consistent --- */
scenario('J14 config template', null, async (wg, tag) => {
	UCI.reset(fs.readFileSync(path.join(REPO, 'router', 'etc.config.wanguard.example'), 'utf8'));
	assertEq(tag + ' a', wg.allocPreview('a'), 'fwmark 100 → table 400');
	assertEq(tag + ' b', wg.allocPreview('b'), 'fwmark 200 → table 401');
	assertEq(tag + ' lb (slots continue the cascade, 300 skipped)',
		wg.allocPreview('lb'), 'wan1 70% 400/402 · wan3 30% 500/403');
	assertEq(tag + ' c', wg.allocPreview('c'), 'fwmark 300 → table 500 (fixed)');
});

/* ======== #42/#43 metadata + TYPE checks (additive M1–M7; everything
 * above must stay byte-identical — the meta options are UI-only) ======== */

const META = fixture('meta.uci');

/* 5-column devices output (the #43 CLI): client is a phone (override),
 * the ARP-only row is generic */
const DEV5 = [
	'aa:bb:cc:dd:ee:55\t192.168.1.55\tclient\t1\tphone',
	'aa:bb:cc:dd:ee:99\t192.168.1.99\t-\t1\tgeneric'
].join('\n');

function cannedMeta() {
	RPC.canned = {
		'read:/tmp/dhcp.leases': '',
		'exec:/usr/bin/wanguard:list': { stdout: 'nft: in-sync' },
		'exec:/usr/bin/wanguard:devices': { stdout: DEV5 },
		'exec:/usr/bin/wanguard:grouplist': { stdout: '' },
		'dump': { interface: [ { interface: 'lan', up: true } ] }
	};
}

/* --- M1: parseDevices reads the 5th column; 4-column legacy degrades --- */
scenario('M1 parseDevices TYPE (#43)', 'lb2.uci', async (wg, tag) => {
	const five = wg.parseDevices(DEV5);
	assertEq(tag + ' 5-col: type parsed', five[0].type, 'phone');
	assertEq(tag + ' 5-col: generic row', five[1].type, 'generic');
	const four = wg.parseDevices('aa:bb:cc:dd:ee:55\t192.168.1.55\tclient\t1');
	assertEq(tag + ' 4-col legacy: type empty (no exception)', four[0].type, '');
	assertEq(tag + ' 4-col legacy: fields intact',
		[ four[0].mac, four[0].ip, four[0].name, four[0].online ? '1' : '0' ].join('|'),
		'aa:bb:cc:dd:ee:55|192.168.1.55|client|1');
	ok(tag + ' garbage lines skipped', wg.parseDevices('x\ty\n').length === 0);
});

/* --- M2: groupColor reads the UCI palette key --- */
scenario('M2 groupColor (#42)', 'meta.uci', async (wg, tag) => {
	assertEq(tag + ' blue hex', wg.groupColor('a'), '#2563EB');
	assertEq(tag + ' purple hex', wg.groupColor('lb'), '#7C3AED');
	assertEq(tag + ' no color option -> ""', wg.groupColor('p'), '');
	ok(tag + ' unknown key falls back to ""', !wg.groupColor('nope'));
});

/* --- M2b: legacy fixture (no metadata) keeps the pre-#42 look --- */
scenario('M2b groupColor legacy unchanged', 'legacy.uci', async (wg, tag) => {
	assertEq(tag + ' no metadata anywhere -> all ""',
		wg.boardGroups().map((g) => wg.groupColor(g.name)).join(','), ',,,');
	assertEq(tag + ' titles fall back to technical labels',
		wg.boardGroups().map((g) => g.title).join('|'),
		'a — wan3|b — wan1|c — wan2|p — mihomo');
});

/* --- M3: board column — UCI label as title, color dot, descr tooltip --- */
scenario('M3 board label/color/descr (#42)', 'meta.uci', async (wg, tag) => {
	cannedMeta();
	const ov = loadView('overview', wg);
	await ov.load();
	const root = await ov.render();

	const col = findCol(root, 'a');
	assertEq(tag + ' title uses UCI label', colParts(col).title, 'Дом');
	const head = col.children[0];
	const titleEl = head.children[0];
	const dot = titleEl.children[0];
	ok(tag + ' color dot present', !!dot && (dot.attrs.class || '').indexOf('wg-dot') !== -1, dot.attrs);
	assertEq(tag + ' dot painted with the palette hex', dot.styleStr, 'background:#2563EB');
	assertEq(tag + ' description is the header tooltip', head.attrs.title, 'Main home LAN');

	const lb = colParts(findCol(root, 'lb'));
	assertEq(tag + ' no label -> technical title', lb.title, 'lb — LB');
	const lbdot = findCol(root, 'lb').children[0].children[0].children[0];
	ok(tag + ' lb dot present (color without label)', (lbdot.attrs.class || '').indexOf('wg-dot') !== -1);
	assertEq(tag + ' lb dot hex', lbdot.styleStr, 'background:#7C3AED');

	const phead = findCol(root, 'p').children[0];
	assertEq(tag + ' descr-only group still gets the tooltip', phead.attrs.title, 'mihomo egress');
	ok(tag + ' no dot without color', !(phead.children[0].children[0].attrs || {}).class);

	const uhead = findCol(root, '').children[0];
	ok(tag + ' Unclassified stays undecorated',
		uhead.attrs.title === undefined &&
		!(uhead.children[0].children[0].attrs || {}).class);
});

/* --- M4: card TYPE icon from the 5th devices column --- */
scenario('M4 board card TYPE icon (#43)', 'meta.uci', async (wg, tag) => {
	cannedMeta();
	const ov = loadView('overview', wg);
	await ov.load();
	const root = await ov.render();

	const card = findCol(root, 'lb').children[1].children[0];
	const row = card.children[0];
	const icon = row.children[0];
	ok(tag + ' icon span present', !!icon && (icon.attrs.class || '') === 'wg-type wg-type-phone', icon && icon.attrs);
	ok(tag + ' icon carries the svg markup', (icon.innerHTML || '').indexOf('<svg') === 0, icon.innerHTML);
	assertEq(tag + ' icon tooltip names the type', icon.attrs.title, ('type: %s').replace('%s', 'phone'));

	const ucard = findCol(root, '').children[1].children[0];
	const uicon = ucard.children[0].children[0];
	ok(tag + ' generic icon for the unassigned device',
		(uicon.attrs.class || '').indexOf('wg-type-generic') !== -1, uicon.attrs);
});


/* --- M4b: old 4-column CLI -> no icon nodes (the pre-#43 card) --- */
scenario('M4b no TYPE column -> no icons', 'lb2.uci', async (wg, tag) => {
	cannedLb2();
	const ov = loadView('overview', wg);
	await ov.load();
	const root = await ov.render();
	const card = findCol(root, 'lb').children[1].children[0];
	const row = card.children[0];
	ok(tag + ' no icon node in the card row',
		!row.children.some(function(c) { return c.attrs && (c.attrs.class || '').indexOf('wg-type') !== -1; }));
	ok(tag + ' MAC lives in the card tooltip (#47)',
		(card.attrs.title || '').indexOf('aa:bb:cc:dd:ee:55') !== -1, card.attrs.title);
});


/* --- M5: groups grid gains label/color/description (#42) ---
 * pinned through the core factory since #49 (see J11) */
scenario('M5 groups grid metadata options', 'meta.uci', async (wg, tag) => {
	wg.state.ifaces = [ 'lan', 'wan1', 'wan2' ];
	const groups = wg.buildGroupsGrid().map.children[0];

	const label = groups.children.find((c) => c.option === 'label');
	ok(tag + ' label option (Value)', !!label && label.__cls === form.Value);
	assertEq(tag + ' label rmempty', label.rmempty, true);

	const color = groups.children.find((c) => c.option === 'color');
	ok(tag + ' color option (ListValue)', !!color && color.__cls === form.ListValue);
	assertEq(tag + ' color: none + 5 palette keys',
		JSON.stringify(color.values.map((v) => v[0])),
		JSON.stringify([ '', 'blue', 'green', 'purple', 'orange', 'gray' ]));
	assertEq(tag + ' color rmempty', color.rmempty, true);

	const descr = groups.children.find((c) => c.option === 'description');
	ok(tag + ' description option (Value)', !!descr && descr.__cls === form.Value);
	assertEq(tag + ' description rmempty', descr.rmempty, true);
});

/* --- M6: devices grid gains the devtype override (#43) --- */
scenario('M6 devices grid devtype (core factory; the #48 page no longer mounts the grid)', 'legacy.uci', async (wg, tag) => {
	const grid = wg.buildDevicesGrid().devices;
	const dt = grid.children.find((c) => c.option === 'devtype');
	ok(tag + ' devtype option (ListValue)', !!dt && dt.__cls === form.ListValue);
	assertEq(tag + ' auto + the 7 whitelisted types',
		JSON.stringify(dt.values.map((v) => v[0])),
		JSON.stringify([ '', 'watch', 'tv', 'pc', 'printer', 'phone', 'tablet', 'generic' ]));
	assertEq(tag + ' devtype rmempty', dt.rmempty, true);
});

/* --- M7: staged metadata edits show up through the same display path --- */
scenario('M7 metadata edit persistence', 'meta.uci', async (wg, tag) => {
	UCI.set('wanguard', 'a', 'color', 'green');
	UCI.commit();
	assertEq(tag + ' color survives Save&Apply', wg.groupColor('a'), '#22C55E');
	UCI.set('wanguard', 'a', 'color', null); /* rmempty semantics */
	UCI.commit();
	assertEq(tag + ' cleared color -> "" (no dot)', wg.groupColor('a'), '');
	UCI.set('wanguard', 'a', 'label', 'Work');
	UCI.commit();
	assertEq(tag + ' label edit reaches the board title',
		wg.boardGroups().filter((g) => g.name == 'a')[0].title, 'Work');
});

/* ======== #46 layout checks (additive; behavior above is untouched) ======== */

/* --- L1: menu.d — category + four deep-linkable children --- */
scenario('L1 menu.d', null, async (wg, tag) => {
	const menu = JSON.parse(fs.readFileSync(
		path.join(LUCI, 'usr', 'share', 'luci', 'menu.d', 'luci-app-wanguard.json'), 'utf8'));
	const parent = menu['admin/network/wanguard'];
	ok(tag + ' parent is an ACL-gated category (firstchild action)',
		!!parent && parent.action && parent.action.type === 'firstchild' &&
		JSON.stringify(parent.depends && parent.depends.acl) === JSON.stringify([ 'luci-app-wanguard' ]));
	ok(tag + ' overview child (view wanguard/overview, order 10)',
		menu['admin/network/wanguard/overview'] &&
		menu['admin/network/wanguard/overview'].action &&
		menu['admin/network/wanguard/overview'].action.type === 'view' &&
		menu['admin/network/wanguard/overview'].action.path === 'wanguard/overview' &&
		menu['admin/network/wanguard/overview'].order === 10);
	ok(tag + ' devices child (view wanguard/devices, order 20)',
		menu['admin/network/wanguard/devices'] &&
		menu['admin/network/wanguard/devices'].action &&
		menu['admin/network/wanguard/devices'].action.path === 'wanguard/devices' &&
		menu['admin/network/wanguard/devices'].order === 20);
	ok(tag + ' groups child (view wanguard/groups, order 30)',
		menu['admin/network/wanguard/groups'] &&
		menu['admin/network/wanguard/groups'].action &&
		menu['admin/network/wanguard/groups'].action.path === 'wanguard/groups' &&
		menu['admin/network/wanguard/groups'].order === 30);
	ok(tag + ' diagnostics child (view wanguard/diagnostics, order 40)',
		menu['admin/network/wanguard/diagnostics'] &&
		menu['admin/network/wanguard/diagnostics'].action &&
		menu['admin/network/wanguard/diagnostics'].action.path === 'wanguard/diagnostics' &&
		menu['admin/network/wanguard/diagnostics'].order === 40);
});

/* --- L2: acl.d golden — #46 must not widen the ACL --- */
scenario('L2 acl.d golden', null, async (wg, tag) => {
	const acl = JSON.parse(fs.readFileSync(
		path.join(LUCI, 'usr', 'share', 'rpcd', 'acl.d', 'luci-app-wanguard.json'), 'utf8'));
	const golden = {
		'luci-app-wanguard': {
			'description': 'Grant access to WAN Guard device groups',
			'read': {
				'ubus': {
					'file': [ 'read', 'exec' ],
					'network.interface': [ 'dump' ]
				},
				'file': {
					'/tmp/dhcp.leases': [ 'read' ],
					'/usr/bin/wanguard': [ 'exec' ]
				},
				'uci': [ 'wanguard' ]
			},
			'write': {
				'ubus': {
					'file': [ 'exec' ]
				},
				'file': {
					'/usr/bin/wanguard': [ 'exec' ]
				},
				'uci': [ 'wanguard' ]
			}
		}
	};
	assertEq(tag + ' ACL grants unchanged (golden)', JSON.stringify(acl), JSON.stringify(golden));
});

/* --- L3: apk/build.sh stages the five new files, not the monolith --- */
scenario('L3 build.sh files', null, async (wg, tag) => {
	const build = fs.readFileSync(path.join(REPO, 'apk', 'build.sh'), 'utf8');
	const want = [
		'resources/view/wanguard/overview.js',
		'resources/view/wanguard/devices.js',
		'resources/view/wanguard/groups.js',
		'resources/view/wanguard/diagnostics.js',
		'resources/view/wanguard/antidpi-placeholder.js',
		'resources/wanguard/core.js'
	];
	ok(tag + ' packages the 6 new files, monolith gone',
		want.every((p) => build.includes(p)) && !/resources\/view\/wanguard\.js/.test(build),
		want.filter((p) => !build.includes(p)));
});

/* --- L4: CI feed-test verifies the new paths + monolith absence --- */
scenario('L4 CI feed-test paths', null, async (wg, tag) => {
	const ci = fs.readFileSync(path.join(REPO, '.github', 'workflows', 'feed.yml'), 'utf8');
	const want = [
		'test -f /www/luci-static/resources/view/wanguard/overview.js',
		'test -f /www/luci-static/resources/view/wanguard/devices.js',
		'test -f /www/luci-static/resources/view/wanguard/groups.js',
		'test -f /www/luci-static/resources/view/wanguard/diagnostics.js',
		'test -f /www/luci-static/resources/view/wanguard/antidpi-placeholder.js',
		'test -f /www/luci-static/resources/wanguard/core.js',
		'test ! -e /www/luci-static/resources/view/wanguard.js'
	];
	ok(tag + ' install-test checks the 6 files + monolith absence',
		want.every((p) => ci.includes(p)),
		want.filter((p) => !ci.includes(p)));
});

/* --- L5: deploy-luci.ps1 ships the new files, removes the stale monolith --- */
scenario('L5 deploy script', null, async (wg, tag) => {
	const deploy = fs.readFileSync(path.join(REPO, 'scripts', 'deploy-luci.ps1'), 'utf8');
	const want = [
		'resources\\view\\wanguard\\overview.js',
		'resources\\view\\wanguard\\devices.js',
		'resources\\view\\wanguard\\groups.js',
		'resources\\view\\wanguard\\diagnostics.js',
		'resources\\view\\wanguard\\antidpi-placeholder.js',
		'resources\\wanguard\\core.js',
		'rm -f /www/luci-static/resources/view/wanguard.js'
	];
	ok(tag + ' uploads the 6 files + removes the stale monolith on the router',
		want.every((p) => deploy.includes(p)),
		want.filter((p) => !deploy.includes(p)));
});

/* --- L6: the monolith is gone --- */
scenario('L6 monolith deleted', null, async (wg, tag) => {
	ok(tag + ' view/wanguard.js no longer exists', !fs.existsSync(VIEW_MONOLITH));
});

/* --- L7: D2 — overview Table = both grids; per-page Maps are single-grid --- */
scenario('L7 page grids (D2, amended by #47/#48)', 'lb2.uci', async (wg, tag) => {
	cannedLb2();
	const ov = loadView('overview', wg);
	await ov.render();
	ok(tag + ' overview dropped the in-page table (#20/#47)', ov._map === undefined);
	ok(tag + ' single Devices link present (#48)', !!ov._btnDevices);
	ok(tag + ' Board|List toggle collapsed (#48)',
		ov._btnBoard === undefined && ov._btnList === undefined);

	/* #48: the devices page mounts the custom table (no grid Map); the
	 * single-grid devices Map lives on in the core factory */
	const dm = wg.buildDevicesGrid();
	assertEq(tag + ' devices map (core factory) = member section only',
		dm.map.children.map(function(s) { return s.sectiontype; }).join(','), 'member');
	const dv = loadView('devices', wg);
	await dv.load();
	await dv.render();
	ok(tag + ' devices page = custom #48 build (no grid Map)', dv._map === undefined);
	ok(tag + ' devices page mounts the table container', !!wg.state.devWrap);

	/* #49: the groups page mounts the custom panel page (no grid Map);
	 * the single-grid groups Map lives on in the core factory */
	const gm = wg.buildGroupsGrid();
	assertEq(tag + ' groups map (core factory) = group section only',
		gm.map.children.map(function(s) { return s.sectiontype; }).join(','), 'group');
	const gv49 = loadView('groups', wg);
	await gv49.load();
	await gv49.render();
	ok(tag + ' groups page = custom #49 build (no grid Map)', gv49._map === undefined);
	ok(tag + ' groups page mounts the tab container', !!wg.state.groupsRoot);
});

/* --- L8: #79 — Anti-DPI placeholder stub (menu merge-order contract) --- */
scenario('L8 antidpi placeholder (#79)', null, async (wg, tag) => {
	const menu = JSON.parse(fs.readFileSync(
		path.join(LUCI, 'usr', 'share', 'luci', 'menu.d', 'luci-app-wanguard.json'), 'utf8'));
	const stub = menu['admin/network/wanguard/antidpi'];

	/* the stub carries its OWN acl group: dispatcher apply_tree_acls() gates
	 * per session-ACL, and while the add-on is absent ONLY luci-app-wanguard
	 * exists — a foreign group would hide the tab entirely (#78 discovery) */
	ok(tag + ' stub node (view wanguard/antidpi-placeholder, order 10, own ACL group)',
		!!stub && stub.action && stub.action.type === 'view' &&
		stub.action.path === 'wanguard/antidpi-placeholder' &&
		stub.order === 10 &&
		stub.title === 'Anti-DPI placeholder' &&
		JSON.stringify(stub.depends && stub.depends.acl) === JSON.stringify([ 'luci-app-wanguard' ]));

	/* merge order = sorted menu.d FILE names; the real node lives in the
	 * add-on's wanguard-antidpi.json which must load AFTER this package's
	 * file so its keys win wholesale (executable probes live in the
	 * wanguard-antidpi repo matrix; here the sort contract is pinned) */
	ok(tag + ' file sort order: luci-app-wanguard.json < wanguard-antidpi.json (real node wins)',
		'luci-app-wanguard.json' < 'wanguard-antidpi.json');

	/* merged-menu smoke, both combinations — the add-on's real menu file as
	 * a byte-snapshot fixture (full cross-repo guard = the #79 parity issue) */
	const mergeFiles = function(files) {
		const tree = {};
		files.forEach(function(f) {
			Object.keys(f).forEach(function(p) {
				const spec = f[p];
				const node = (tree[p] = tree[p] || {});
				[ 'title', 'order', 'action', 'depends' ].forEach(function(k) {
					if (spec[k] !== undefined)
						node[k] = spec[k];
				});
			});
		});
		return tree;
	};
	const addonMenu = JSON.parse(fixture('wanguard-antidpi.menu.json'));

	const only = mergeFiles([ menu ]);
	ok(tag + ' merged w/o add-on: the tab is the placeholder',
		only['admin/network/wanguard/antidpi'] &&
		only['admin/network/wanguard/antidpi'].title === 'Anti-DPI placeholder' &&
		only['admin/network/wanguard/antidpi'].order === 10 &&
		only['admin/network/wanguard/antidpi'].action.path === 'wanguard/antidpi-placeholder');

	const both = mergeFiles([ menu, addonMenu ]);
	const real = both['admin/network/wanguard/antidpi'];
	ok(tag + ' merged with add-on: the real node wins every contract key',
		real.title === 'Anti-DPI' && real.order === 35 &&
		real.action.path === 'wanguard/antidpi' &&
		JSON.stringify(real.depends.acl) === JSON.stringify([ 'luci-app-wanguard-antidpi' ]));
	ok(tag + ' merged with add-on: parent title/order/action still match the fixture (parentguard holds)',
		both['admin/network/wanguard'].title === 'WAN Guard' &&
		both['admin/network/wanguard'].order === 60 &&
		both['admin/network/wanguard'].action.type === 'firstchild');

	/* the placeholder view must never collide with the add-on's real view
	 * file (two packages cannot own one path — apk would refuse) */
	ok(tag + ' no view file collision (placeholder ships, antidpi.js does not)',
		fs.existsSync(path.join(VIEW_DIR, 'antidpi-placeholder.js')) &&
		!fs.existsSync(path.join(VIEW_DIR, 'antidpi.js')));

	/* render smoke: the stub is self-contained (no core module, no poll, no
	 * rpcd) and renders the honest inactive-tab message + README link */
	ok(tag + ' placeholder view is self-contained (no wanguard.core, no poll)',
		VIEW_SRC['antidpi-placeholder'].indexOf('wanguard.core') === -1 &&
		VIEW_SRC['antidpi-placeholder'].indexOf("'require poll'") === -1);
	const ph = loadView('antidpi-placeholder', wg);
	const proot = await ph.render();
	const findHref = function(n) {
		if (n.attrs && n.attrs.href)
			return n.attrs.href;
		for (let i = 0; n.children && i < n.children.length; i++) {
			const h = findHref(n.children[i]);
			if (h)
				return h;
		}
		return null;
	};
	ok(tag + ' placeholder renders the inactive-tab alert + install hint + README link',
		proot.children.length === 2 &&
		proot.children[1].className === 'alert-message warning' &&
		flat(proot).indexOf('apk add wanguard-antidpi') !== -1 &&
		findHref(proot) === 'https://github.com/sers88/wanguard-antidpi#readme');
});


/* ============================ demo ============================ */

/* ======== #47 board 2.0 — toolbar search/switch, chips, card layout,
 * Unassigned, footer pending pill, List/add/new-group nav (B1–B9) ======== */

function cannedBoard47() {
	RPC.canned = {
		'read:': '',
		'exec:/usr/bin/wanguard:list': { stdout: 'members: 2\n\naa:bb:cc:dd:ee:01 home\naa:bb:cc:dd:ee:02 work\nnft: in-sync' },
		'exec:/usr/bin/wanguard:devices': { stdout: [
			'aa:bb:cc:dd:ee:01\t192.168.88.79\talice-phone\t1\tphone',
			'aa:bb:cc:dd:ee:02\t192.168.88.58\twork-pc\t1\tpc',
			'aa:bb:cc:dd:ee:99\t192.168.88.201\tguest-phone\t0\tphone'
		].join('\n') },
		'exec:/usr/bin/wanguard:grouplist': { stdout: '' },
		'dump': { interface: [
			{ interface: 'freedom', up: true },
			{ interface: 'wg_moscow', up: true, proto: 'wireguard' },
			{ interface: 'wan1', up: true },
			{ interface: 'wan2', up: true },
			{ interface: 'lan', up: true }
		] }
	};
}

async function renderBoard47(wg) {
	const ov = loadView('overview', wg);
	await ov.load();
	const root = await ov.render();
	return { ov: ov, root: root };
}
function refilter47(wg) {
	wg.state.boardWrap.children.length = 0;
	wg.rebuildBoard();
}
scenario('B1 search filter (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	ok(tag + ' matches by name substring', wg.deviceMatches({ name: 'work-pc', ip: '', mac: '' }));
	ok(tag + ' matches by IP substring', wg.deviceMatches({ name: '', ip: '192.168.88.58', mac: '' }));
	ok(tag + ' matches by MAC substring', wg.deviceMatches({ name: '', ip: '', mac: 'aa:bb:cc:dd:ee:02' }));
	ok(tag + ' case-insensitive', wg.deviceMatches({ name: 'WORK-PC', ip: '', mac: '' }));
	wg.setFilter('192.168.88.58');
	ok(tag + ' rejects non-matching', !wg.deviceMatches({ name: 'x', ip: '10.9.9.9', mac: 'aa:bb:cc:dd:ee:02' }));
	refilter47(wg);
	assertEq(tag + ' target column filtered count', colParts(findCol(wg.state.boardWrap, 'work')).sub, '1 device');
	assertEq(tag + ' other column shows filtered/total', colParts(findCol(wg.state.boardWrap, 'home')).sub, '0/1 device');
	wg.setFilter('alice');
	refilter47(wg);
	assertEq(tag + ' search by name restores the card', colParts(findCol(wg.state.boardWrap, 'home')).sub, '1 device');
	wg.setFilter('');
});

scenario('B2 Online-only switch (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	ok(tag + ' switch input present', !!r.ov._sw);
	ok(tag + ' off by default', r.ov._sw.checked === false);
	r.ov._sw.listeners['change'][0]({ target: { checked: true } });
	assertEq(tag + ' checked persists', localStorageStub.getItem('wanguard-hide-offline'), '1');
	assertEq(tag + ' offline guest hidden', colParts(findCol(wg.state.boardWrap, '')).sub, '0/1 device');
	r.ov._sw.listeners['change'][0]({ target: { checked: false } });
	assertEq(tag + ' unchecked persists', localStorageStub.getItem('wanguard-hide-offline'), '0');
	assertEq(tag + ' offline guest visible again', colParts(findCol(wg.state.boardWrap, '')).sub, '1 device');
});

scenario('B3 route chips (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	assertEq(tag + ' direct -> WAN', wg.routeChip({ name: 'home', type: 'direct', iface: 'freedom' }).text, 'freedom · WAN');
	assertEq(tag + ' wireguard -> VPN', wg.routeChip({ name: 'work', type: 'direct', iface: 'wg_moscow' }).text, 'wg_moscow · VPN');
	assertEq(tag + ' wireguard chip keeps the allocation', wg.routeChip({ name: 'work', type: 'direct', iface: 'wg_moscow' }).title, 'fwmark 200 → table 401');
	assertEq(tag + ' proxy chip', wg.routeChip({ name: 'media', type: 'proxy', iface: '' }).text, 'Proxy');
	const lbc = wg.routeChip({ name: 'lbx', type: 'direct-lb', iface: '' });
	assertEq(tag + ' direct-lb chip = member summary', lbc.text, 'wan1+wan2 · LB');
	ok(tag + ' direct-lb chip keeps the slot plan', lbc.title.indexOf('400/402') !== -1, lbc.title);
	assertEq(tag + ' unknown iface -> WAN (UCI-only degradation)', wg.routeChip({ name: 'zz', type: 'direct', iface: 'nosuch' }).text, 'nosuch · WAN');
	assertEq(tag + ' rendered home chip', colParts(findCol(r.root, 'home')).chip, 'freedom · WAN');
	assertEq(tag + ' rendered work chip', colParts(findCol(r.root, 'work')).chip, 'wg_moscow · VPN');
});

scenario('B4 card layout (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	const card = findCol(r.root, 'work').children[1].children[0];
	const row = card.children[0];
	ok(tag + ' row = icon | main | menu', row.children.length === 3, row.children.length);
	const main = row.children[1];
	assertEq(tag + ' name line', flat(main.children[0]), 'work-pc');
	assertEq(tag + ' ip line', flat(main.children[1]), '192.168.88.58');
	ok(tag + ' online marker', flat(main.children[2]).indexOf('Online') !== -1, flat(main.children[2]));
	ok(tag + ' MAC only in the tooltip',
		(card.attrs.title || '').indexOf('aa:bb:cc:dd:ee:02') !== -1 && flat(card).indexOf('aa:bb:cc:dd:ee:02') === -1, card.attrs.title);
	const menuBtn = row.children[2];
	ok(tag + ' menu button class', (menuBtn.attrs.class || '').indexOf('wg-card-menu') !== -1);
	menuBtn.listeners['click'][0]({ stopPropagation: function() {} });
	ok(tag + ' menu opens with the device', (ui._modal || [''])[0].indexOf('work-pc') !== -1, ui._modal && ui._modal[0]);
	ui.hideModal();
	ok(tag + ' draggable when in sync', card.attrs.draggable === 'true');
});

scenario('B5 Unassigned column (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	const u = colParts(findCol(r.root, ''));
	assertEq(tag + ' renamed', u.title, 'Unassigned');
	assertEq(tag + ' count', u.sub, '1 device');
	assertEq(tag + ' no route chip', u.chip, '');
	const board = (function walk(nod) {
		if (nod.attrs && (nod.attrs.class || '') === 'wg-board') return nod;
		const kids = nod.children || [];
		for (let i = 0; i < kids.length; i++) {
			const x = walk(kids[i]);
			if (x) return x;
		}
		return null;
	})(r.root);
	ok(tag + ' board node found', !!board);
	assertEq(tag + ' column order (groups, Unassigned, tile)',
		board.children.map(function(c) {
			return (c.attrs && c.attrs['data-group'] != null) ? c.attrs['data-group'] : '<new>';
		}).join('|'),
		'home|lbx|work|media||<new>');
});

scenario('B6 footer totals + pending pill (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	const foot = wg.state.footerNode;
	ok(tag + ' footer exists', !!foot);
	assertEq(tag + ' totals line', flat(foot.children[0]), '1 devices · 4 groups');
	ok(tag + ' green when clean', flat(foot.children[1]).indexOf('No pending changes') !== -1, flat(foot.children[1]));
	const hd = E('div', {});
	wg.state.statusCompact = true;
	wg.updateStatusNode(hd);
	ok(tag + ' compact header pill', flat(hd).indexOf('Rules synchronized') !== -1, flat(hd));
	wg.state.statusCompact = false;
	wg.updateStatusNode(hd);
	ok(tag + ' plain header keeps counters', flat(hd).indexOf('device(s)') !== -1, flat(hd));
	UCI.set('wanguard', 'anon_member_1', 'group', 'media');
	wg.updateBoardFooter();
	ok(tag + ' staged edit -> pending pill', flat(foot.children[1]).indexOf('pending') !== -1, flat(foot.children[1]));
	UCI.commit();
	wg.updateBoardFooter();
	ok(tag + ' applied -> clean again', flat(foot.children[1]).indexOf('No pending changes') !== -1, flat(foot.children[1]));
	wg.state.statusOk = false;
	wg.updateBoardFooter();
	ok(tag + ' drift -> read-only pill', flat(foot.children[1]).indexOf('DRIFT — read-only') !== -1, flat(foot.children[1]));
	wg.state.statusOk = true;
	wg.updateBoardFooter();
});

scenario('B7 pending pill honesty through apply (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	const pill = function() { return flat(wg.state.footerNode.children[1]); };
	const inCol = function(grp, mac) {
		const col = findCol(wg.state.boardWrap, grp);
		return !!col && col.children[1].children.some(function(c) { return c.attrs['data-mac'] === mac; });
	};
	ok(tag + ' clean start', pill().indexOf('No pending changes') !== -1);
	UCI.apply = function() { return Promise.reject(new Error('apply down')); };
	await wg.applyMove('aa:bb:cc:dd:ee:99', 'home');
	ok(tag + ' failed apply keeps the change staged (honest pill)', pill().indexOf('pending') !== -1, pill());
	UCI.apply = function() { UCI.commit(); return Promise.resolve(); };
	await wg.applyMove('aa:bb:cc:dd:ee:99', 'work');
	ok(tag + ' successful apply clears the pill', pill().indexOf('No pending changes') !== -1, pill());
	ok(tag + ' device landed in the target group', inCol('work', 'aa:bb:cc:dd:ee:99'));
	ok(tag + ' left the unassigned column', !inCol('', 'aa:bb:cc:dd:ee:99'));
});

scenario('B8 column add -> lease preselect (#47)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	RPC.canned['read:'] = '1699900000 aa:bb:cc:dd:ee:77 192.168.88.77 new-guest 01:22:33:44:55:66';
	const r = await renderBoard47(wg);
	ok(tag + ' lease panel present', !!wg.state.leasePanel);
	const col = findCol(r.root, 'work');
	const addBtn = col.children[2].children[0];
	ok(tag + ' add button class', (addBtn.attrs.class || '') === 'wg-add-devices', addBtn.attrs.class);
	addBtn.listeners['click'][0]();
	const sel = (function walk(nod) {
		if (nod.attrs && nod.attrs['data-wg'] === 'lease-group') return nod;
		const kids = nod.children || [];
		for (let i = 0; i < kids.length; i++) {
			const x = walk(kids[i]);
			if (x) return x;
		}
		return null;
	})(wg.state.leasePanel);
	ok(tag + ' group select found', !!sel);
	assertEq(tag + ' group preselected from the column', sel && sel.value, 'work');
	ok(tag + ' panel flashed for attention', wg.state.leasePanel.classList.contains('wg-lease-flash'));
});

scenario('B9 Devices link / +Add / New group navigation (#20/#47/#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderBoard47(wg);
	ok(tag + ' view toggle removed', r.ov._btnBoard === undefined && r.ov._btnList === undefined);
	ok(tag + ' single Devices link present', !!r.ov._btnDevices);
	r.ov._btnDevices.listeners['click'][0]();
	assertEq(tag + ' Devices -> devices page', global.location.href, '/admin/network/wanguard/devices');
	r.ov.showAddMenu();
	ok(tag + ' + Add opens the menu', !!ui._modal);
	const items = (ui._modal[1].children || []).filter(function(c) { return c.tag === 'button'; });
	assertEq(tag + ' menu = Add device + New group', items.length, 2);
	/* #52: the menu was inescapable - now a Close button lives in a
	 * .button-row wrapper. The wrapper class is load-bearing: stock
	 * LuCI's cancelModal (Esc on #modal_overlay, 25.12 ui.js) clicks
	 * the first '.button-row > .btn', so Esc closes the menu too;
	 * click-outside close is not a stock LuCI behavior. */
	const closeRow = (function walk(nod) {
		if (nod && nod.attrs && (nod.attrs.class || '').indexOf('button-row') !== -1)
			return nod;
		const kids = (nod && nod.children) || [];
		for (let i = 0; i < kids.length; i++) {
			const x = walk(kids[i]);
			if (x) return x;
		}
		return null;
	})(ui._modal[1]);
	ok(tag + ' #52 Close row present', !!closeRow);
	const rowBtns = (closeRow.children || []).filter(function(c) { return c && c.tag === 'button'; });
	assertEq(tag + ' #52 row holds exactly one button', rowBtns.length, 1);
	assertEq(tag + ' #52 button is Close', rowBtns[0] && flat(rowBtns[0]), 'Close');
	rowBtns[0].listeners['click'][0]();
	ok(tag + ' #52 Close closes the menu', ui._modal === null);
	assertEq(tag + ' #52 Close does not navigate', global.location.href, '/admin/network/wanguard/devices');
	items[0].listeners['click'][0]();
	ok(tag + ' Add device focuses the lease panel', !!wg.state.leasePanel);
	assertEq(tag + ' menu closed', ui._modal, null);
	items[1].listeners['click'][0]();
	assertEq(tag + ' New group -> groups page', global.location.href, '/admin/network/wanguard/groups');
	const tile = (function walk(nod) {
		if (nod.attrs && (nod.attrs.class || '').indexOf('wg-newgroup') !== -1) return nod;
		const kids = nod.children || [];
		for (let i = 0; i < kids.length; i++) {
			const x = walk(kids[i]);
			if (x) return x;
		}
		return null;
	})(r.root);
	ok(tag + ' New group tile present', !!tile);
	tile.children[0].listeners['click'][0]();
	assertEq(tag + ' tile -> groups page', global.location.href, '/admin/network/wanguard/groups');
});

/* #74: the DRIFT banner (built by buildBoard) used to be stale until a
 * full reload - the overview poll refreshed state but never re-rendered.
 * The tick now refreshes the leaf pills every time and rebuilds the
 * board only on a verdict transition (drag&drop stays alive otherwise). */
scenario('B10 DRIFT banner heals on a poll tick (#74)', 'board47.uci', async (wg, tag) => {
	const findAlert = function(root) {
		return (function walk(nod) {
			if (nod && nod.attrs && (nod.attrs.class || '') === 'alert-message warning')
				return nod;
			const kids = (nod && nod.children) || [];
			for (let i = 0; i < kids.length; i++) {
				const x = walk(kids[i]);
				if (x) return x;
			}
			return null;
		})(root);
	};
	cannedBoard47();
	poll._cbs.length = 0;
	const r = await renderBoard47(wg);
	const tick = poll._cbs[poll._cbs.length - 1];
	ok(tag + ' overview registered a poll callback', typeof tick === 'function');
	ok(tag + ' no banner while in-sync', !findAlert(r.root));
	/* drift appears -> the next tick must insert the banner */
	RPC.canned['exec:/usr/bin/wanguard:list'] = { stdout: 'members: 2\n\nnft: drift detected: applied != running' };
	const before = wg.state.boardWrap.children[0];
	await tick();
	ok(tag + ' status flipped to DRIFT', wg.state.statusOk === false);
	ok(tag + ' banner appears after the tick', !!findAlert(r.root));
	ok(tag + ' board rebuilt on the transition', wg.state.boardWrap.children[0] !== before);
	/* keepalive repairs -> the next tick must remove the banner (no F5) */
	RPC.canned['exec:/usr/bin/wanguard:list'] = { stdout: 'members: 2\n\naa:bb:cc:dd:ee:01 home\naa:bb:cc:dd:ee:02 work\nnft: in-sync' };
	await tick();
	ok(tag + ' status back in-sync', wg.state.statusOk === true);
	ok(tag + ' banner gone without a reload', !findAlert(r.root));
	/* no verdict transition -> no rebuild (an active drag survives ticks) */
	const stable = wg.state.boardWrap.children[0];
	await tick();
	ok(tag + ' no rebuild without a verdict transition', wg.state.boardWrap.children[0] === stable);
});

/* ======== #49 Groups & Routes page (G1–G10; everything above must stay
 * byte-identical — the page is a rebuild of the groups VIEW only, the
 * engine math is shared) ======== */

/* `wanguard wanstatus` sample (#6): 7-field row (SINCE with a space),
 * 6-field row with dashes, header, blank line, GROUP table, note */
const WANS = fixture('wanstatus.txt');

function findByWg(root, key) {
	let out = null;
	(function walk(n) {
		if (out || !n || typeof n !== 'object')
			return;
		if (n.attrs && n.attrs['data-wg'] === key) {
			out = n;
			return;
		}
		(n.children || []).forEach(walk);
	})(root);
	return out;
}

function findRows(root) {
	const out = [];
	(function walk(n) {
		if (!n || typeof n !== 'object')
			return;
		if (n.tag === 'tr' && n.attrs && n.attrs['data-group'])
			out.push(n);
		(n.children || []).forEach(walk);
	})(root);
	return out;
}

function findRouteCard(root, name) {
	let out = null;
	(function walk(n) {
		if (out || !n || typeof n !== 'object')
			return;
		if (n.attrs && n.attrs['data-wg'] === 'route-card' && n.attrs['data-route'] === name) {
			out = n;
			return;
		}
		(n.children || []).forEach(walk);
	})(root);
	return out;
}

/* --- G1: parseWanstatus --- */
scenario('G1 parseWanstatus (#49)', 'board47.uci', async (wg, tag) => {
	const r = wg.parseWanstatus(WANS);
	ok(tag + ' freedom row', !!r.wan.freedom && r.wan.freedom.device == 'eth0' && r.wan.freedom.state == 'up', r.wan);
	assertEq(tag + ' rtt', r.wan.freedom.rtt, '0.012');
	assertEq(tag + ' anchors', r.wan.freedom.anchors, '2/2');
	assertEq(tag + ' since keeps the inner space', r.wan.freedom.since, '01.10 12:00:00');
	ok(tag + ' forced state kept as-is', r.wan.rostelecom && r.wan.rostelecom.state == 'down/forced');
	assertEq(tag + ' dash fields survive', [ r.wan.rostelecom.rtt, r.wan.rostelecom.since ].join('|'), '-|-');
	ok(tag + ' GROUP section ignored', r.wan.GROUP === undefined && r.wan.home === undefined);
	ok(tag + ' trailing note ignored', r.wan['note:'] === undefined);
	assertEq(tag + ' old CLI (no output) degrades', Object.keys(wg.parseWanstatus('').wan).length, 0);
	assertEq(tag + ' garbage rows skipped', Object.keys(wg.parseWanstatus('x y z\n').wan).length, 0);
});

/* --- G2: routeCards — classification, mihomo, wanstatus, degradations --- */
scenario('G2 routeCards (#49)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	RPC.canned['exec:/usr/bin/wanguard:wanstatus'] = { stdout: WANS };
	await wg.load();
	const cards = wg.routeCards();
	assertEq(tag + ' dump ifaces (sorted) + wanstatus-only + mihomo last',
		cards.map((c) => c.name).join(','),
		'freedom,lan,rostelecom,wan1,wan2,wg_moscow,mihomo', cards.map((c) => c.name).join(','));
	assertEq(tag + ' wireguard -> vpn', cards.filter((c) => c.name == 'wg_moscow')[0].type, 'vpn');
	assertEq(tag + ' plain iface -> wan', cards.filter((c) => c.name == 'wan1')[0].type, 'wan');
	assertEq(tag + ' mihomo card (proxy group exists)', cards.filter((c) => c.name == 'mihomo')[0].type, 'proxy');
	const fr = cards.filter((c) => c.name == 'freedom')[0];
	ok(tag + ' wanstatus enrichment (rtt/anchors/device)',
		fr.up === true && fr.rtt == '0.012' && fr.anchors == '2/2' && fr.device == 'eth0', fr);
	const ro = cards.filter((c) => c.name == 'rostelecom')[0];
	assertEq(tag + ' wanstatus-only iface (not in dump)', ro.up, false);

	/* old CLI: no wanstatus output — dump-only cards, no liveness */
	RPC.canned['exec:/usr/bin/wanguard:wanstatus'] = { stdout: '' };
	await wg.load();
	ok(tag + ' degradation: no rtt without wanstatus',
		wg.routeCards().every((c) => !c.rtt));
	ok(tag + ' degradation: dump state kept',
		wg.routeCards().filter((c) => c.name == 'freedom')[0].up === true);

	/* no dump AND no wanstatus -> ifaces referenced by groups, unknown state */
	wg.state.allIfaces = [];
	wg.state.ifaces = [];
	wg.state.wanstatus = { wan: {} };
	const deg = wg.routeCards();
	assertEq(tag + ' degraded cards from group ifaces',
		deg.map((c) => c.name).join(','), 'freedom,wan1,wan2,wg_moscow,mihomo');
	ok(tag + ' degraded state unknown', deg[0].up === null);
});

/* --- G3: validGroupName — exact CLI valid_group_name mirror --- */
scenario('G3 validGroupName (#49)', 'legacy.uci', async (wg, tag) => {
	ok(tag + ' plain name ok', wg.validGroupName('Guest_2'));
	ok(tag + ' 15 chars ok', wg.validGroupName(new Array(16).join('x')));
	ok(tag + ' 16 chars refused', !wg.validGroupName(new Array(17).join('x')));
	ok(tag + ' dash refused', !wg.validGroupName('a-b'));
	ok(tag + ' empty refused', !wg.validGroupName(''));
	ok(tag + ' null refused', !wg.validGroupName(null));
	ok(tag + ' globals refused', !wg.validGroupName('globals'));
	ok(tag + ' wan refused', !wg.validGroupName('wan'));
});

/* --- G4: stageGroupPanel — create (groupadd semantics) + device sync --- */
scenario('G4 panel staging: create + devices (#49)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	await wg.load();
	wg.state.groupPanel = {
		origName: '', stagedNew: false, stagedName: '',
		orig: { 'aa:bb:cc:dd:ee:01': 'home', 'aa:bb:cc:dd:ee:02': 'work' }
	};

	const spec = { origName: '', name: 'guest', type: 'direct', iface: 'wan1',
		label: 'Guest', color: 'green', description: 'temp',
		devices: [ 'aa:bb:cc:dd:ee:99' ], weights: {} };
	assertEq(tag + ' staged section id', wg.stageGroupPanel(spec), 'guest');
	assertEq(tag + ' named section type', UCI.get('wanguard', 'guest', 'type'), 'direct');
	assertEq(tag + ' iface', UCI.get('wanguard', 'guest', 'iface'), 'wan1');
	assertEq(tag + ' label (#42)', UCI.get('wanguard', 'guest', 'label'), 'Guest');
	assertEq(tag + ' color (#42)', UCI.get('wanguard', 'guest', 'color'), 'green');
	assertEq(tag + ' description (#42)', UCI.get('wanguard', 'guest', 'description'), 'temp');
	ok(tag + ' new member section for the lease-only device',
		!!wg.findMember('aa:bb:cc:dd:ee:99') && wg.findMember('aa:bb:cc:dd:ee:99').group == 'guest');

	spec.devices.push('aa:bb:cc:dd:ee:01');
	wg.stageGroupPanel(spec);
	assertEq(tag + ' device moved in from home', wg.findMember('aa:bb:cc:dd:ee:01').group, 'guest');
	assertEq(tag + ' home left with no members',
		wg.groupMembersOf('home').length, 0);

	spec.devices = [ 'aa:bb:cc:dd:ee:99' ];
	wg.stageGroupPanel(spec);
	assertEq(tag + ' moved-in device returned to its original group',
		wg.findMember('aa:bb:cc:dd:ee:01').group, 'home');

	assertEq(tag + ' invalid name -> nothing staged',
		wg.stageGroupPanel({ origName: '', name: 'no-valid-name!', type: 'direct', iface: 'wan1', devices: [], weights: {} }),
		null);
	ok(tag + ' globals name -> nothing staged',
		wg.stageGroupPanel({ origName: '', name: 'globals', type: 'direct', iface: 'wan1', devices: [], weights: {} }) === null);
});

/* --- G5: stageRename — create new + copy + re-point + delete --- */
scenario('G5 panel staging: rename (#49)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	await wg.load();
	ok(tag + ' rename staged', wg.stageRename('work', 'jobs') === true);
	assertEq(tag + ' options copied', [ UCI.get('wanguard', 'jobs', 'type'), UCI.get('wanguard', 'jobs', 'iface') ].join('/'), 'direct/wg_moscow');
	assertEq(tag + ' member re-pointed', wg.findMember('aa:bb:cc:dd:ee:02').group, 'jobs');
	ok(tag + ' old section deleted', UCI.get('wanguard', 'work') === null);
	ok(tag + ' collision refused', wg.stageRename('jobs', 'home') === false);
	ok(tag + ' missing section refused', wg.stageRename('nope', 'x2') === false);
	wg.stageRename('lbx', 'lbx2');
	assertEq(tag + ' lb members copied', JSON.stringify(UCI.get('wanguard', 'lbx2', 'member_iface')), JSON.stringify([ 'wan1', 'wan2' ]));
	assertEq(tag + ' lb weights copied', UCI.get('wanguard', 'lbx2', 'weight_wan1'), '70');
	assertEq(tag + ' lb slots follow the new name',
		wg.lbSlotMap().lbx2.slots.map((s) => s.mark).join(','), '400,500');
});

/* --- G6: delete guard + modal --- */
scenario('G6 deleteGroup (#49)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	await wg.load();
	wg.state.saveHost = { handleSaveApply: function() { UCI.commit(); return Promise.resolve(); } };
	wg.deleteGroup('home');
	ok(tag + ' non-empty group refused (notification, no modal)', !ui._modal);
	ok(tag + ' group still there', !!UCI.get('wanguard', 'home'));
	wg.deleteGroup('media');
	ok(tag + ' empty group asks for confirmation', !!ui._modal);
	const del = (function walk(n) {
		if (n.tag === 'button' && flat(n) == 'Delete')
			return n;
		for (const c of (n.children || [])) {
			const r = walk(c);
			if (r)
				return r;
		}
		return null;
	})(ui._modal[1]);
	del.listeners['click'][0]();
	assertEq(tag + ' modal closed', ui._modal, null);
	ok(tag + ' empty group removed', UCI.get('wanguard', 'media') === null);
	wg.state.statusOk = false;
	wg.deleteGroup('home');
	ok(tag + ' DRIFT refuses deletion', !ui._modal && !!UCI.get('wanguard', 'home'));
	wg.state.statusOk = true;
});

/* --- G7: groups page render — tabs, table rows, chips, search --- */
scenario('G7 groups page render (#49)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	RPC.canned['exec:/usr/bin/wanguard:wanstatus'] = { stdout: WANS };
	const gv = loadView('groups', wg);
	await gv.load();
	const root = await gv.render();
	const txt = flat(root);
	ok(tag + ' tabs present', txt.indexOf('Groups') !== -1 && txt.indexOf('Routes') !== -1);
	assertEq(tag + ' active tab', (findByWg(root, 'tab-groups').attrs.class || ''), 'wg-tab wg-tab-active');
	assertEq(tag + ' row order (direct sorted, proxy last)',
		findRows(root).map((r) => r.attrs['data-group']).join(','), 'home,lbx,work,media');

	const home = findRows(root).filter((r) => r.attrs['data-group'] == 'home')[0];
	const dot = home.children[0].children[0].children[0];
	assertEq(tag + ' color dot painted (#42)', dot.styleStr, 'background:#2563EB');
	ok(tag + ' label as display name (#42)', flat(home.children[0]).indexOf('Home') !== -1, flat(home.children[0]));
	assertEq(tag + ' assigned-route chip', flat(home.children[1]), 'freedom · WAN');
	assertEq(tag + ' device counter', flat(home.children[2]), '1 device');

	const lbx = findRows(root).filter((r) => r.attrs['data-group'] == 'lbx')[0];
	ok(tag + ' lb chip', flat(lbx.children[1]).indexOf('wan1+wan2 · LB') !== -1);
	ok(tag + ' lb shown as slots (not one chip)',
		flat(lbx.children[1]).indexOf('wan1 70% 400/402') !== -1 &&
		flat(lbx.children[1]).indexOf('wan2 30% 500/403') !== -1, flat(lbx.children[1]));
	const media = findRows(root).filter((r) => r.attrs['data-group'] == 'media')[0];
	assertEq(tag + ' proxy chip names the target', flat(media.children[1]), 'mihomo · Proxy');

	/* routes strip under the table */
	const fr = findRouteCard(root, 'freedom');
	ok(tag + ' routes strip card', !!fr);
	ok(tag + ' strip card carries wanstatus', flat(fr).indexOf('RTT 0.012') !== -1, flat(fr));

	wg.setGroupFilter('wor');
	wg.rebuildGroupsPage();
	assertEq(tag + ' search narrows the table',
		findRows(wg.state.groupsRoot).map((r) => r.attrs['data-group']).join(','), 'work');
	wg.setGroupFilter('zzz');
	wg.rebuildGroupsPage();
	ok(tag + ' empty search state', flat(wg.state.groupsRoot).indexOf('No groups match') !== -1);
	wg.setGroupFilter('');
	wg.rebuildGroupsPage();

	/* tab switch persists + routes tab shows the detail lines */
	findByWg(wg.state.groupsRoot, 'tab-routes').listeners['click'][0]();
	assertEq(tag + ' tab persisted', localStorageStub.getItem('wanguard-gr-tab'), 'routes');
	const rt = findRouteCard(wg.state.groupsRoot, 'freedom');
	ok(tag + ' routes tab detail lines', flat(rt).indexOf('RTT(s): 0.012') !== -1 && flat(rt).indexOf('Since: 01.10 12:00:00') !== -1, flat(rt));
	ok(tag + ' New route button present', !!findByWg(wg.state.groupsRoot, 'route-new'));
	findByWg(wg.state.groupsRoot, 'route-new').listeners['click'][0]();
	assertEq(tag + ' New route -> Interfaces (LuCI 25.12 menu, #55)',
		global.location.href, '/admin/network/network');
	global.location.href = '';
	wg.setGrTab('groups');
});

/* --- G8: openGroupPanel create flow — live staging, plate, preview --- */
scenario('G8 panel create flow (#49)', 'lb2.uci', async (wg, tag) => {
	cannedLb2();
	await wg.load();
	const host = { saved: 0, handleSaveApply: function() { this.saved++; UCI.commit(); return Promise.resolve(); } };
	wg.state.saveHost = host;

	wg.openGroupPanel(null);
	ok(tag + ' modal open', !!ui._modal && ui._modal[0] == 'New group', ui._modal && ui._modal[0]);
	let body = ui._modal[1];
	const name = findByWg(body, 'panel-name');
	ok(tag + ' route preselected (first up iface)', findByWg(body, 'panel-route').value == 'direct:lan', findByWg(body, 'panel-route').value);
	ok(tag + ' color defaulted (blue radio)', findByWg(body, 'panel-colors').children[0].children[0].checked === true);

	name.value = 'guest';
	name.listeners['input'][0]();
	ok(tag + ' valid name stages the section (live)', !!UCI.get('wanguard', 'guest'));
	findByWg(body, 'panel-createroute').listeners['click'][0]();
	assertEq(tag + ' Create route -> Interfaces (same URL as route-new, #55)',
		global.location.href, '/admin/network/network');
	global.location.href = '';
	ok(tag + ' plate counts devices', flat(findByWg(body, 'panel-plate')).indexOf('0 devices will use lan.') !== -1,
		flat(findByWg(body, 'panel-plate')));

	/* route -> mihomo (proxy) */
	let route = findByWg(body, 'panel-route');
	route.value = 'proxy';
	route.listeners['change'][0]();
	assertEq(tag + ' staged type proxy', UCI.get('wanguard', 'guest', 'type'), 'proxy');
	ok(tag + ' live preview through allocPreview',
		flat(findByWg(body, 'panel-preview')).indexOf('fwmark 300 → table 500 (fixed)') !== -1,
		flat(findByWg(body, 'panel-preview')));

	/* check a device via the picker */
	const dev = findByWg(body, 'panel-devices').children[0].children[0];
	dev.checked = true;
	dev.listeners['change'][0]();
	ok(tag + ' plate tracks the selection', flat(findByWg(body, 'panel-plate')).indexOf('1 device will use mihomo.') !== -1,
		flat(findByWg(body, 'panel-plate')));

	findByWg(body, 'panel-save').listeners['click'][0]();
	assertEq(tag + ' modal closed on save', ui._modal, null);
	assertEq(tag + ' committed proxy group', UCI.get('wanguard', 'guest', 'type'), 'proxy');
	assertEq(tag + ' Save&Apply ran once', host.saved, 1);
	ok(tag + ' committed member', !!wg.findMember('aa:bb:cc:dd:ee:55') && wg.findMember('aa:bb:cc:dd:ee:55').group == 'guest');

	/* second proxy -> singleton validation, modal stays open */
	wg.openGroupPanel(null);
	body = ui._modal[1];
	findByWg(body, 'panel-name').value = 'guest2';
	findByWg(body, 'panel-name').listeners['input'][0]();
	route = findByWg(body, 'panel-route');
	route.value = 'proxy';
	route.listeners['change'][0]();	findByWg(body, 'panel-save').listeners['click'][0]();
	ok(tag + ' singleton error shown', flat(findByWg(body, 'panel-error')).indexOf('singleton') !== -1, flat(findByWg(body, 'panel-error')));
	ok(tag + ' modal stays open with the error', !!ui._modal);
	assertEq(tag + ' failed validation never saved', host.saved, 1);
	ok(tag + ' guest2 only staged client-side so far', UCI.get('wanguard', 'guest2') !== null);

	findByWg(body, 'panel-cancel').listeners['click'][0]();
	assertEq(tag + ' modal closed on cancel', ui._modal, null);
	ok(tag + ' cancel discards staged client state', UCI.get('wanguard', 'guest2') === null);
	ok(tag + ' committed group survives cancel', UCI.get('wanguard', 'guest', 'type') == 'proxy');
});

/* --- G9: openGroupPanel edit flow — prefill, label, device unassign --- */
scenario('G9 panel edit flow (#49)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	await wg.load();
	wg.state.saveHost = { handleSaveApply: function() { UCI.commit(); return Promise.resolve(); } };

	wg.openGroupPanel('home');
	ok(tag + ' edit modal', !!ui._modal && ui._modal[0] == 'Edit group', ui._modal && ui._modal[0]);
	const body = ui._modal[1];
	assertEq(tag + ' name prefilled', findByWg(body, 'panel-name').value, 'home');
	assertEq(tag + ' label prefilled (#42)', findByWg(body, 'panel-label').value, 'Home');
	assertEq(tag + ' route prefilled', findByWg(body, 'panel-route').value, 'direct:freedom');
	ok(tag + ' member prechecked', findByWg(body, 'panel-devices').children[0].children[0].checked === true);

	findByWg(body, 'panel-label').value = 'Home net';
	findByWg(body, 'panel-label').listeners['input'][0]();
	const homeCb = findByWg(body, 'panel-devices').children[0].children[0];
	homeCb.checked = false; /* the stub does not toggle before the event */
	homeCb.listeners['change'][0]();
	findByWg(body, 'panel-save').listeners['click'][0]();
	assertEq(tag + ' label staged + committed', UCI.get('wanguard', 'home', 'label'), 'Home net');
	ok(tag + ' unchecked member unregistered', wg.findMember('aa:bb:cc:dd:ee:01') === null);

	/* lb group edit: weight fields follow the member checkboxes (#40) */
	wg.openGroupPanel('lbx');
	const body2 = ui._modal[1];
	ok(tag + ' lb member rows visible', findByWg(body2, 'panel-lb').style.display !== 'none');
	const lbRows = findByWg(body2, 'panel-lb').children[0].children[1];
	const wan1row = lbRows.children.filter(function(r) {
		return flat(r).indexOf('wan1') !== -1;
	})[0];
	const wan1cb = wan1row.children[0];
	ok(tag + ' wan1 row checked', !!wan1cb && wan1cb.checked === true);
	wan1cb.checked = false;
	wan1cb.listeners['change'][0]();
	assertEq(tag + ' unchecked member weight dropped (stray-weight rule)',
		UCI.get('wanguard', 'lbx', 'weight_wan1'), null);
	ui.hideModal();
	try { UCI.unload('wanguard'); UCI.load(); } catch (e) { /* fine */ }
});

/* --- G10: DRIFT gating on the page and the panel --- */
scenario('G10 DRIFT read-only (#49)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	wg.state.statusOk = false;
	const p = wg.buildGroupsPage();
	ok(tag + ' drift banner', flat(p).indexOf('DRIFT') !== -1);
	wg.openGroupPanel(null);
	ok(tag + ' panel refused in DRIFT', !ui._modal);
	wg.openGroupPanel('home');
	ok(tag + ' edit refused in DRIFT', !ui._modal);
	wg.state.statusOk = true;
	wg.openGroupPanel(null);
	ok(tag + ' panel opens back in sync', !!ui._modal);
	ui.hideModal();
});

/* ======== #48 devices table page (D1–D13; everything above must stay
 * green — the page reuses the board's filters/chips/footer and the #49
 * panel staging semantics; the drawer poll guard lives in the view) ==== */

async function renderDevices47(wg) {
	const dv = loadView('devices', wg);
	await dv.load();
	const root = await dv.render();
	return { dv: dv, root: root };
}

function findDevRows(root) {
	const t = findByWg(root, 'dev-table');
	const out = [];
	(t ? t.children : []).forEach(function(c) {
		if (c.tag === 'tr' && c.attrs && c.attrs['data-mac'])
			out.push(c);
	});
	return out;
}

function iconsIn(tr) {
	const out = [];
	(function walk(n) {
		if (!n || typeof n !== 'object')
			return;
		if (n.attrs && (n.attrs.class || '').indexOf('wg-type-') !== -1)
			out.push(n.attrs.class);
		(n.children || []).forEach(walk);
	})(tr);
	return out;
}

function modalButtons() {
	const out = [];
	(function walk(n) {
		if (!n || typeof n !== 'object')
			return;
		if (n.tag === 'button') {
			out.push(n);
			return;
		}
		(n.children || []).forEach(walk);
	})(ui._modal ? ui._modal[1] : null);
	return out;
}

/* fire a checkbox change (the row checkboxes stopPropagation on click,
 * the change handler drives the selection) */
function devCheck(root, mac, on) {
	const tr = findDevRows(root).filter(function(x) { return x.attrs['data-mac'] === mac; })[0];
	const cb = tr.children[0].children[0];
	cb.checked = !!on;
	cb.listeners['change'][0]({ stopPropagation() {} });
}

function devRowByMac(root, mac) {
	return findDevRows(root).filter(function(x) { return x.attrs['data-mac'] === mac; })[0];
}

function openDrawer(root, mac) {
	devRowByMac(root, mac).listeners['click'][0]();
}

scenario('D1 devices table build (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	ok(tag + ' toolbar search present', !!findByWg(r.root, 'dev-search'));
	ok(tag + ' group filter present', !!findByWg(r.root, 'dev-group-filter'));
	ok(tag + ' add button present', !!findByWg(r.root, 'dev-add'));
	ok(tag + ' honest footer present', !!wg.state.footerNode);
	assertEq(tag + ' footer totals', flat(wg.state.footerNode.children[0]), '1 devices · 4 groups');
	const rows = findDevRows(r.root);
	assertEq(tag + ' three inventory rows', rows.length, 3);
	assertEq(tag + ' default name asc',
		rows.map(function(tr) { return tr.attrs['data-mac']; }).join(','),
		'aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:99,aa:bb:cc:dd:ee:02');
	const m01 = devRowByMac(r.root, 'aa:bb:cc:dd:ee:01');
	const m02 = devRowByMac(r.root, 'aa:bb:cc:dd:ee:02');
	const m99 = devRowByMac(r.root, 'aa:bb:cc:dd:ee:99');
	assertEq(tag + ' home row shows the UCI label', flat(m01.children[3]), 'Home');
	assertEq(tag + ' unassigned row labels itself', flat(m99.children[3]), 'Unassigned');
	assertEq(tag + ' work route chip', flat(m02.children[4]), 'wg_moscow · VPN');
	assertEq(tag + ' unassigned route dash', flat(m99.children[4]), '—');
	assertEq(tag + ' IP cell', flat(m01.children[2]), '192.168.88.79');
	ok(tag + ' online marker', flat(m01.children[5]).indexOf('Online') !== -1, flat(m01.children[5]));
	ok(tag + ' offline marker', flat(m99.children[5]).indexOf('Offline') !== -1);
	assertEq(tag + ' phone icon (43)', iconsIn(m01).join(' '), 'wg-type wg-type-phone');
	assertEq(tag + ' pc icon (43)', iconsIn(m02).join(' '), 'wg-type wg-type-pc');
	assertEq(tag + ' unassigned guest keeps its CLI icon', iconsIn(m99).join(' '), 'wg-type wg-type-phone');
	ok(tag + ' type icons are size-constrained in CSS (an unsized svg fills the td)',
		wg.BOARD_CSS.indexOf('.wg-type svg { display:inline; vertical-align:-.12em; width:1.2em; height:1.2em; }') !== -1);
});

scenario('D2 sorting (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	const macs = () => findDevRows(r.root).map(function(tr) { return tr.attrs['data-mac']; }).join(',');
	const click = (key) => findByWg(r.root, 'sort-' + key).listeners['click'][0]();
	ok(tag + ' name indicator active', flat(findByWg(r.root, 'sort-name')).indexOf('▲') !== -1);
	click('ip');
	assertEq(tag + ' IP asc is octet-wise (58 < 79 < 201)', macs(),
		'aa:bb:cc:dd:ee:02,aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:99');
	click('ip');
	assertEq(tag + ' IP desc', macs(),
		'aa:bb:cc:dd:ee:99,aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02');
	click('group');
	assertEq(tag + ' group asc = Home < Unassigned < work', macs(),
		'aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:99,aa:bb:cc:dd:ee:02');
	click('group');
	assertEq(tag + ' group desc (work first — NOT the name order)', macs(),
		'aa:bb:cc:dd:ee:02,aa:bb:cc:dd:ee:99,aa:bb:cc:dd:ee:01');
	click('route');
	assertEq(tag + ' route asc: unassigned first, then WAN, VPN', macs(),
		'aa:bb:cc:dd:ee:99,aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02');
	click('route');
	assertEq(tag + ' route desc', macs(),
		'aa:bb:cc:dd:ee:02,aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:99');
	click('status');
	assertEq(tag + ' status asc: Offline first', macs(),
		'aa:bb:cc:dd:ee:99,aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02');
	click('status');
	assertEq(tag + ' status desc: Online first (name tiebreak reverses)', macs(),
		'aa:bb:cc:dd:ee:02,aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:99');
	ok(tag + ' previous indicator idle', flat(findByWg(r.root, 'sort-ip')).indexOf('↕') !== -1);
	ok(tag + ' active indicator desc', flat(findByWg(r.root, 'sort-status')).indexOf('▼') !== -1);
});

scenario('D3 filter combination (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	const cnt = () => findDevRows(r.root).length;
	wg.setFilter('work');
	wg.rebuildDevicesPage();
	assertEq(tag + ' search narrows', cnt(), 1);
	let gs = findByWg(r.root, 'dev-group-filter');
	gs.value = 'home';
	gs.listeners['change'][0]();
	assertEq(tag + ' search + group AND-combine to zero', cnt(), 0);
	wg.setFilter('');
	wg.rebuildDevicesPage();
	assertEq(tag + ' group filter alone', cnt(), 1);
	gs = findByWg(r.root, 'dev-group-filter');
	gs.value = '(unassigned)';
	gs.listeners['change'][0]();
	assertEq(tag + ' unassigned sentinel shows the unassigned only', cnt(), 1);
	assertEq(tag + ' and it is the guest',
		findDevRows(r.root)[0].attrs['data-mac'], 'aa:bb:cc:dd:ee:99');
	localStorageStub.setItem('wanguard-hide-offline', '1');
	wg.state.devTable.groupFilter = 'home';
	wg.rebuildDevicesPage();
	assertEq(tag + ' online-only keeps the online member', cnt(), 1);
	wg.state.devTable.groupFilter = '(unassigned)';
	wg.rebuildDevicesPage();
	assertEq(tag + ' online-only + unassigned hides the offline guest', cnt(), 0);
	localStorageStub.setItem('wanguard-hide-offline', '0');
	wg.state.devTable.groupFilter = '';
	wg.rebuildDevicesPage();
	assertEq(tag + ' filters reset', cnt(), 3);
});

scenario('D4 device drawer (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	openDrawer(r.root, 'aa:bb:cc:dd:ee:99');
	assertEq(tag + ' drawer mac registered', wg.state.devTable.drawerMac, 'aa:bb:cc:dd:ee:99');
	const dr = findByWg(r.root, 'drawer');
	ok(tag + ' drawer node present', !!dr);
	assertEq(tag + ' hostname line', flat(findByWg(r.root, 'drawer-host')), 'guest-phone');
	assertEq(tag + ' group = Unassigned', findByWg(r.root, 'drawer-group').value, '');
	assertEq(tag + ' route line dash', flat(findByWg(r.root, 'drawer-route')), '—');
	ok(tag + ' MAC in the drawer', flat(dr).indexOf('aa:bb:cc:dd:ee:99') !== -1);
	ok(tag + ' IP in the drawer', flat(dr).indexOf('192.168.88.201') !== -1);
	ok(tag + ' info plate', flat(dr).indexOf('Assignment reflects configuration') !== -1);
	findByWg(r.root, 'drawer-close').listeners['click'][0]();
	assertEq(tag + ' × closes', wg.state.devTable.drawerMac, null);
	openDrawer(r.root, 'aa:bb:cc:dd:ee:99');
	findByWg(r.root, 'drawer-cancel').listeners['click'][0]();
	assertEq(tag + ' Cancel closes', wg.state.devTable.drawerMac, null);
});

scenario('D5 drawer assignment staging -> Save (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	let applied = 0;
	wg.state.saveHost = { handleSaveApply: function() {
		applied++;
		return UCI.save().then(function() { return UCI.apply(); });
	} };
	openDrawer(r.root, 'aa:bb:cc:dd:ee:99');
	const sel = findByWg(r.root, 'drawer-group');
	sel.value = 'home';
	sel.listeners['change'][0]();
	ok(tag + ' drawer dirty after staging', wg.state.devTable.drawerDirty);
	assertEq(tag + ' staged member section', (wg.findMember('aa:bb:cc:dd:ee:99') || {}).group, 'home');
	assertEq(tag + ' pending pill counts the staged change', wg.pendingCount(), 1);
	assertEq(tag + ' select keeps the staged value', findByWg(r.root, 'drawer-group').value, 'home');
	assertEq(tag + ' route line follows the staged group', flat(findByWg(r.root, 'drawer-route')), 'freedom · WAN');
	assertEq(tag + ' table shows the staged assignment already',
		flat(devRowByMac(r.root, 'aa:bb:cc:dd:ee:99').children[3]), 'Home');
	await findByWg(r.root, 'drawer-save').listeners['click'][0]();
	assertEq(tag + ' one Save&Apply', applied, 1);
	assertEq(tag + ' drawer stays open', wg.state.devTable.drawerMac, 'aa:bb:cc:dd:ee:99');
	ok(tag + ' drawer not dirty anymore', !wg.state.devTable.drawerDirty);
	assertEq(tag + ' committed member', (wg.findMember('aa:bb:cc:dd:ee:99') || {}).group, 'home');
});

scenario('D6 unassign both ways (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	wg.state.saveHost = { handleSaveApply: function() {
		return UCI.save().then(function() { return UCI.apply(); });
	} };
	/* (a) staged add fully reverted before Save */
	openDrawer(r.root, 'aa:bb:cc:dd:ee:99');
	let sel = findByWg(r.root, 'drawer-group');
	sel.value = 'home';
	sel.listeners['change'][0]();
	assertEq(tag + ' staged add', (wg.findMember('aa:bb:cc:dd:ee:99') || {}).group, 'home');
	sel = findByWg(r.root, 'drawer-group');
	sel.value = '';
	sel.listeners['change'][0]();
	ok(tag + ' staged add fully reverted', !wg.findMember('aa:bb:cc:dd:ee:99'));
	ok(tag + ' still dirty (nothing saved)', wg.state.devTable.drawerDirty);
	/* (b) a REGISTERED device saved to Unassigned (member section removed) */
	openDrawer(r.root, 'aa:bb:cc:dd:ee:01');
	sel = findByWg(r.root, 'drawer-group');
	sel.value = '';
	sel.listeners['change'][0]();
	/* NOTE: the stub UCI folds whole-section removal into the data right
	 * away (changes() stays empty) — real LuCI stages a delete and the
	 * pending pill shows it; here only the assignment can be asserted */
	await findByWg(r.root, 'drawer-save').listeners['click'][0]();
	ok(tag + ' member removed after Save', !wg.findMember('aa:bb:cc:dd:ee:01'));
	assertEq(tag + ' row shows Unassigned', flat(devRowByMac(r.root, 'aa:bb:cc:dd:ee:01').children[3]), 'Unassigned');
	/* (c) Cancel discards a staged removal (uci.unload + reload, #49) */
	openDrawer(r.root, 'aa:bb:cc:dd:ee:02');
	sel = findByWg(r.root, 'drawer-group');
	sel.value = '';
	sel.listeners['change'][0]();
	ok(tag + ' staged removal hit the client config', !wg.findMember('aa:bb:cc:dd:ee:02'));
	await findByWg(r.root, 'drawer-cancel').listeners['click'][0]();
	assertEq(tag + ' Cancel restores the member', (wg.findMember('aa:bb:cc:dd:ee:02') || {}).group, 'work');
});

scenario('D7 drawer save failure -> rollback (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	wg.state.saveHost = { handleSaveApply: function() {
		return Promise.reject(new Error('apply down'));
	} };
	openDrawer(r.root, 'aa:bb:cc:dd:ee:99');
	const sel = findByWg(r.root, 'drawer-group');
	sel.value = 'home';
	sel.listeners['change'][0]();
	assertEq(tag + ' staged before the attempt', wg.pendingCount(), 1);
	await findByWg(r.root, 'drawer-save').listeners['click'][0]();
	ok(tag + ' failure toast', (ui._notes || []).some(function(n) { return n[0] === 'error'; }));
	ok(tag + ' staged discarded (rollback)', !wg.findMember('aa:bb:cc:dd:ee:99'));
	assertEq(tag + ' pending pill clean again', wg.pendingCount(), 0);
	assertEq(tag + ' drawer still open', wg.state.devTable.drawerMac, 'aa:bb:cc:dd:ee:99');
	ok(tag + ' drawer not dirty', !wg.state.devTable.drawerDirty);
	assertEq(tag + ' select back to Unassigned', findByWg(r.root, 'drawer-group').value, '');
});

scenario('D8 bulk move + bulk unassign (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	devCheck(r.root, 'aa:bb:cc:dd:ee:99', true);
	devCheck(r.root, 'aa:bb:cc:dd:ee:01', true); /* already home — no-op skip */
	ok(tag + ' bulk bar appears', !!findByWg(r.root, 'bulk-bar'));
	findByWg(r.root, 'bulk-target').value = 'home';
	await findByWg(r.root, 'bulk-move').listeners['click'][0]();
	assertEq(tag + ' ONE save for the batch', UCI._saves, 1);
	assertEq(tag + ' guest moved', (wg.findMember('aa:bb:cc:dd:ee:99') || {}).group, 'home');
	ok(tag + ' selection cleared (bar gone)', !findByWg(r.root, 'bulk-bar'));
	devCheck(r.root, 'aa:bb:cc:dd:ee:01', true);
	devCheck(r.root, 'aa:bb:cc:dd:ee:02', true);
	findByWg(r.root, 'bulk-unassign').listeners['click'][0]();
	ok(tag + ' unassign asks for confirmation', !!ui._modal);
	const btns = modalButtons();
	assertEq(tag + ' confirm modal = Cancel + Unassign', btns.length, 2);
	await btns[1].listeners['click'][0]();
	ok(tag + ' both devices unassigned', !wg.findMember('aa:bb:cc:dd:ee:01') && !wg.findMember('aa:bb:cc:dd:ee:02'));
	assertEq(tag + ' rows show Unassigned', flat(devRowByMac(r.root, 'aa:bb:cc:dd:ee:02').children[3]), 'Unassigned');
});

scenario('D9 DRIFT read-only (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	wg.state.statusOk = false;
	wg.rebuildDevicesPage();
	ok(tag + ' page banner', flat(wg.state.devWrap).indexOf('DRIFT') !== -1);
	openDrawer(r.root, 'aa:bb:cc:dd:ee:99');
	ok(tag + ' drawer opens read-only', !!findByWg(r.root, 'drawer'));
	assertEq(tag + ' select disabled', findByWg(r.root, 'drawer-group').disabled, true);
	ok(tag + ' drift plate in the drawer', !!findByWg(r.root, 'drawer-drift'));
	assertEq(tag + ' save disabled', findByWg(r.root, 'drawer-save').attrs['disabled'], 'disabled');
	devCheck(r.root, 'aa:bb:cc:dd:ee:02', true);
	findByWg(r.root, 'bulk-move').listeners['click'][0]();
	ok(tag + ' bulk refused with a toast',
		(ui._notes || []).some(function(n) { return n[0] === 'error'; }));
	ok(tag + ' nothing staged (the unassigned guest is untouched)',
		!wg.findMember('aa:bb:cc:dd:ee:99'));
	assertEq(tag + ' pending pill clean', wg.pendingCount(), 0);
	wg.state.statusOk = true;
	wg.rebuildDevicesPage();
	assertEq(tag + ' back in sync: select enabled', findByWg(r.root, 'drawer-group').disabled, false);
	assertEq(tag + ' back in sync: save enabled', findByWg(r.root, 'drawer-save').attrs['disabled'], undefined);
});

scenario('D10 + Add device -> lease panel (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	ok(tag + ' no lease panel until asked', !wg.state.leasePanel);
	findByWg(r.root, 'dev-add').listeners['click'][0]();
	ok(tag + ' lease panel mounted', !!wg.state.leasePanel);
	ok(tag + ' flashed for attention', wg.state.leasePanel.classList.contains('wg-lease-flash'));
	assertEq(tag + ' mounted outside the table rebuild', wg.state.devLeaseHolder.children.length, 1);
	wg.rebuildDevicesPage();
	ok(tag + ' panel survives the table rebuild', !!wg.state.leasePanel);
});

scenario('D11 copy buttons (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	openDrawer(r.root, 'aa:bb:cc:dd:ee:99');
	const dr = findByWg(r.root, 'drawer');
	const copyBtns = [];
	(function walk(n) {
		if (!n || typeof n !== 'object')
			return;
		if (n.attrs && n.attrs['data-wg'] === 'copy') {
			copyBtns.push(n);
			return;
		}
		(n.children || []).forEach(walk);
	})(dr);
	assertEq(tag + ' IP + MAC copy rows', copyBtns.length, 2);
	/* no navigator.clipboard (the http:// router case) -> the execCommand
	 * fallback runs, but the stub has no select()/execCommand -> an
	 * honest failure toast, never an exception */
	copyBtns[0].listeners['click'][0]();
	ok(tag + ' degraded copy reports failure',
		(ui._notes || []).some(function(n) { return n[1].indexOf('Copy failed') !== -1; }));
	/* the secure-context path */
	NAV.clipboard = { writeText: function(t) { NAV.wrote = t; return Promise.resolve(); } };
	copyBtns[0].listeners['click'][0]();
	await new Promise(function(res) { setTimeout(res, 0); });
	assertEq(tag + ' clipboard got the IP', NAV.wrote, '192.168.88.201');
	ok(tag + ' success toast',
		(ui._notes || []).some(function(n) { return n[1].indexOf('Copied: 192.168.88.201') !== -1; }));
});

scenario('D12 old 4-column CLI degrades (#48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	RPC.canned['exec:/usr/bin/wanguard:devices'] = { stdout: [
		'aa:bb:cc:dd:ee:01\t192.168.88.79\talice-phone\t1',
		'aa:bb:cc:dd:ee:02\t192.168.88.58\twork-pc\t1',
		'aa:bb:cc:dd:ee:99\t192.168.88.201\tguest-phone\t0'
	].join('\n') };
	const r = await renderDevices47(wg);
	assertEq(tag + ' table still renders', findDevRows(r.root).length, 3);
	ok(tag + ' no icons without the TYPE column',
		!findDevRows(r.root).some(function(tr) { return iconsIn(tr).length; }));
});

scenario('D13 60-device render (pagination probe, #48)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const lines = [];
	for (let i = 1; i <= 60; i++) {
		const nn = (i < 10 ? '0' : '') + i;
		lines.push('aa:bb:cc:dd:' + nn + ':' + nn + '\t192.168.88.' + i + '\td' + i + '\t1\tgeneric');
	}
	RPC.canned['exec:/usr/bin/wanguard:devices'] = { stdout: lines.join('\n') };
	const r = await renderDevices47(wg);
	/* 60 inventory rows + the 2 member sections the (replaced) inventory
	 * no longer knows about */
	assertEq(tag + ' all rows rendered fully', findDevRows(r.root).length, 62);
	ok(tag + ' rows complete (6 cells each)',
		findDevRows(r.root).every(function(tr) { return tr.children.length === 6; }));
	wg.setFilter('dd:07:07');
	wg.rebuildDevicesPage();
	assertEq(tag + ' MAC search still works at scale', findDevRows(r.root).length, 1);
	wg.setFilter('');
});

scenario('D14 search keeps focus across rebuilds (#48 fix)', 'board47.uci', async (wg, tag) => {
	cannedBoard47();
	const r = await renderDevices47(wg);
	/* the toolbar lives OUTSIDE the rebuilt container: replacing the
	 * input on every debounced keystroke dropped the focus after the
	 * first character (owner report, v1.8.0) */
	const search = findByWg(r.root, 'dev-search');
	ok(tag + ' toolbar outside the table rebuild', wg.state.devToolbarHolder && wg.state.devToolbarHolder.children.length === 1);
	search.value = 'work';
	search.listeners['input'][0]();
	await new Promise(function(res) { setTimeout(res, 250); }); /* the 200ms debounce */
	assertEq(tag + ' filter applied after the debounce', wg.state.filter, 'work');
	assertEq(tag + ' table narrowed', findDevRows(r.root).length, 1);
	ok(tag + ' the SAME input node is still mounted (focus intact)',
		findByWg(r.root, 'dev-search') === search);
	wg.setFilter('');
	wg.rebuildDevicesPage();
});

/* ======== #50 Diagnostics page (GN1–GN23; parsers over the #44/#45 TAB
 * grammar, the four status cards + DRIFT coloring, old-CLI degradation,
 * the lazy dump tabs + copy + highlight, the event feed, service health,
 * the inspect flow and the diag-report download) ==== */

async function renderDiag(wg) {
	const dv = loadView('diagnostics', wg);
	await dv.load();
	const root = await dv.render();
	return { dv: dv, root: root };
}

function diagCards(wg) {
	return wg.state.diagHolders.cards.children;
}

function cardPill(card) {
	let out = null;
	(function walk(n) {
		if (out || !n || typeof n !== 'object')
			return;
		if (n.attrs && n.attrs['data-pill']) {
			out = n;
			return;
		}
		(n.children || []).forEach(walk);
	})(card);
	return out;
}

function collectHl(root) {
	const out = [];
	(function walk(n) {
		if (!n || typeof n !== 'object')
			return;
		if (n.attrs && (n.attrs.class || '').indexOf('wg-hl') !== -1)
			out.push(n);
		(n.children || []).forEach(walk);
	})(root);
	return out;
}

scenario('GN1 parseSyncstatus (#50)', null, async (wg, tag) => {
	const ok1 = wg.parseSyncstatus(fixture('syncstatus.txt'));
	ok(tag + ' in-sync parsed', ok1 && ok1.status === 'in-sync');
	assertEq(tag + ' last_apply int', ok1.lastApply, 1761921600);
	assertEq(tag + ' age int', ok1.ageSec, 3);
	const dr = wg.parseSyncstatus(fixture('syncstatus-drift.txt'));
	assertEq(tag + ' drift verdict', dr.status, 'drift');
	assertEq(tag + ' old CLI / garbage -> null', wg.parseSyncstatus('nonsense'), null);
});

scenario('GN2 parseEvents (#50)', null, async (wg, tag) => {
	const evs = wg.parseEvents(fixture('events.txt'));
	assertEq(tag + ' eight rows', evs.length, 8);
	assertEq(tag + ' first row fields', JSON.stringify([ evs[0].ts, evs[0].code, evs[0].detail ]),
		JSON.stringify([ 1761921590, 'apply_ok', 'applied' ]));
	assertEq(tag + ' garbage skipped', wg.parseEvents('junk\nno\ttabs\n').length, 0);
	assertEq(tag + ' empty ring -> empty', wg.parseEvents('').length, 0);
});

scenario('GN3 eventView mapping (#50)', null, async (wg, tag) => {
	assertEq(tag + ' applied -> synchronized', wg.eventView({ ts: 1, code: 'apply_ok', detail: 'applied' }).text, 'Rules synchronized');
	assertEq(tag + ' heartbeat -> in-sync text', wg.eventView({ ts: 1, code: 'apply_ok', detail: 'in-sync' }).text, 'In-sync heartbeat');
	assertEq(tag + ' validated ok', wg.eventView({ ts: 1, code: 'config_validated', detail: '' }).icon, 'ok');
	assertEq(tag + ' drift error', wg.eventView({ ts: 1, code: 'drift', detail: 'x' }).icon, 'error');
	assertEq(tag + ' failover warn', wg.eventView({ ts: 1, code: 'failover', detail: 'm>w2' }).icon, 'warn');
	assertEq(tag + ' lbover warn', wg.eventView({ ts: 1, code: 'lbover', detail: 'lb:w2>w1' }).icon, 'warn');
	assertEq(tag + ' unknown code falls back warn', wg.eventView({ ts: 1, code: 'wat', detail: '?' }).icon, 'warn');
});

scenario('GN4 event time format (#50)', null, async (wg, tag) => {
	const d = new Date(1761921590 * 1000);
	const p2 = (n) => (n < 10 ? '0' : '') + n;
	assertEq(tag + ' local HH:MM:SS', wg.formatEventTime(1761921590),
		p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds()));
});

scenario('GN5 formatAge (#50)', null, async (wg, tag) => {
	assertEq(tag + ' seconds', wg.formatAge(3), '3 seconds ago');
	assertEq(tag + ' minutes (floor)', wg.formatAge(120), '2 minutes ago');
	assertEq(tag + ' hours', wg.formatAge(7200), '2 hours ago');
	assertEq(tag + ' unknown', wg.formatAge(null), 'unknown');
});

scenario('GN6 parseDiagHealth (#50)', null, async (wg, tag) => {
	const h = wg.parseDiagHealth(fixture('diag-health.txt'));
	ok(tag + ' parsed', !!h);
	assertEq(tag + ' wanguard running', h.wanguard, 'running');
	assertEq(tag + ' mihomo running', h.mihomo, 'running');
	assertEq(tag + ' config valid', h.config, 'valid');
	assertEq(tag + ' version stamp', h.version, '1.8.1');
	const bad = wg.parseDiagHealth(fixture('diag-health-bad.txt'));
	assertEq(tag + ' mihomo stopped', bad.mihomo, 'stopped');
	assertEq(tag + ' config invalid', bad.config, 'invalid');
	assertEq(tag + ' warning kept', bad.warnings.join('|'), 'group media references missing iface wan9');
	assertEq(tag + ' old CLI -> null', wg.parseDiagHealth(''), null);
});

scenario('GN7 parseDiag sections (#50)', null, async (wg, tag) => {
	const secs = wg.parseDiag(fixture('diag-tables.txt'));
	assertEq(tag + ' one section', Object.keys(secs).join(','), 'tables');
	assertEq(tag + ' six rows', secs.tables.length, 6);
	ok(tag + ' verbatim line shape', secs.tables[1].indexOf('route\ta\t') === 0, secs.tables[1]);
	const two = wg.parseDiag('section\trules\n0: lookup\nsection\tnft\ntable {}');
	assertEq(tag + ' two sections', Object.keys(two).sort().join(','), 'nft,rules');
});

scenario('GN8 parseGrouplistFull (#50)', null, async (wg, tag) => {
	const rows = wg.parseGrouplistFull(fixture('grouplist.txt'));
	assertEq(tag + ' three rows (header + lb-only filter gone)', rows.length, 3);
	assertEq(tag + ' direct row', JSON.stringify([ rows[0].group, rows[0].type, rows[0].iface, rows[0].mark, rows[0].table ]),
		JSON.stringify([ 'a', 'direct', 'wan3', 100, 400 ]));
	assertEq(tag + ' lb slots', rows.slice(1).map(function(r) { return r.mark; }).join(','), '200,400');
	const px = wg.parseGrouplistFull('mihomo   proxy    -          300   500   Meta           2');
	assertEq(tag + ' proxy row keeps the - iface', px[0].iface, '-');
});

scenario('GN9 parseInspect (#50)', null, async (wg, tag) => {
	const r = wg.parseInspect(fixture('inspect-lb.txt'));
	ok(tag + ' parsed', !!r);
	assertEq(tag + ' group', r.group, 'lb');
	assertEq(tag + ' two slots', r.slots.length, 2);
	assertEq(tag + ' slot0 kv fields', JSON.stringify([ r.slots[0].type, r.slots[0].mark, r.slots[0].table, r.slots[0].configured, r.slots[0].member, r.slots[0].live ]),
		JSON.stringify([ 'direct-lb', 200, 401, 'wan1', 'wan1', 'eth0' ]));
	assertEq(tag + ' slot1 live down', r.slots[1].live, 'down');
	assertEq(tag + ' set membership', JSON.stringify([ r.set.name, r.set.state ]), JSON.stringify([ 'mac_lb', 'member' ]));
	assertEq(tag + ' rule handle', r.rules[0].handle, '25');
	const u = wg.parseInspect(fixture('inspect-unreg.txt'));
	assertEq(tag + ' unregistered group -', u.group, '-');
	ok(tag + ' note kept', u.note.indexOf('not registered') !== -1);
	assertEq(tag + ' empty output -> null (cannot resolve / old CLI)', wg.parseInspect(''), null);
});

scenario('GN10 status cards in-sync (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	const r = await renderDiag(wg);
	const cards = diagCards(wg);
	assertEq(tag + ' four cards', cards.length, 4);
	let p = cardPill(cards[0]);
	assertEq(tag + ' Configuration pill', JSON.stringify([ p.attrs['data-pill'], flat(p) ]), JSON.stringify([ 'ok', 'In sync' ]));
	p = cardPill(cards[1]);
	assertEq(tag + ' Routing rules pill', flat(p), 'Applied');
	p = cardPill(cards[2]);
	assertEq(tag + ' Mihomo pill', flat(p), 'Running');
	p = cardPill(cards[3]);
	assertEq(tag + ' sync age pill', flat(p), '3 seconds ago');
	ok(tag + ' Refresh button', !!findByWg(r.root, 'diag-refresh'));
	ok(tag + ' Download report button', !!findByWg(r.root, 'diag-download'));
});

scenario('GN11 DRIFT colors the cards (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	RPC.canned['exec:/usr/bin/wanguard:syncstatus'] = { stdout: fixture('syncstatus-drift.txt') };
	await renderDiag(wg);
	const cards = diagCards(wg);
	let p = cardPill(cards[0]);
	assertEq(tag + ' Configuration DRIFT error pill', JSON.stringify([ p.attrs['data-pill'], flat(p) ]), JSON.stringify([ 'error', 'DRIFT' ]));
	ok(tag + ' card painted red', cards[0].attrs['class'].indexOf('wg-dcard-bad') !== -1);
	p = cardPill(cards[1]);
	assertEq(tag + ' Routing rules Out of sync', flat(p), 'Out of sync');
});

scenario('GN12 old CLI degrades without exceptions (#50)', 'lb2.uci', async (wg, tag) => {
	cannedLb2(); /* no syncstatus/events/diag answers — the pre-#44 CLI */
	const r = await renderDiag(wg);
	ok(tag + ' page still renders', !!findByWg(r.root, 'diag-cards'));
	assertEq(tag + ' four unavailable cards', diagCards(wg).length, 4);
	const txt = flat(wg.state.diagHolders.cards);
	assertEq(tag + ' unavailable pill count', (txt.match(/Unavailable/g) || []).length, 4);
	ok(tag + ' summary plate says update', flat(wg.state.diagHolders.routing).indexOf('update the wanguard package') !== -1);
	ok(tag + ' events panel says update', flat(wg.state.diagHolders.events).indexOf('update the wanguard package') !== -1);
	ok(tag + ' health panel says update', flat(wg.state.diagHolders.health).indexOf('update the wanguard package') !== -1);
	ok(tag + ' inspect input present (usable regardless)', !!findByWg(r.root, 'diag-inspect'));
});

scenario('GN13 summary table (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	await renderDiag(wg);
	const t = findByWg(wg.state.diagHolders.routing, 'diag-summary');
	ok(tag + ' summary table present', !!t);
	assertEq(tag + ' header + three grouplist rows', t.children.length, 4);
	const row0 = t.children[1].children;
	assertEq(tag + ' route cell', flat(row0[0]), 'a');
	assertEq(tag + ' type cell (no proto -> WAN)', flat(row0[1]), 'WAN');
	assertEq(tag + ' table cell', flat(row0[2]), '400');
	assertEq(tag + ' mark rendered hex (prototype form)', flat(row0[3]), '0x64');
	ok(tag + ' state pill Applied', flat(row0[4]).indexOf('Applied') !== -1);
	ok(tag + ' lb slot rows carry member line', flat(t.children[2]).indexOf('→ wan1') !== -1 && flat(t.children[3]).indexOf('→ wan2') !== -1);
	ok(tag + ' honesty plate', flat(wg.state.diagHolders.routing).indexOf('not a live connectivity test') !== -1);
});

scenario('GN14 event feed (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	await renderDiag(wg);
	const box = findByWg(wg.state.diagHolders.events, 'diag-events');
	ok(tag + ' feed present', !!box);
	assertEq(tag + ' eight rows', box.children.length, 8);
	assertEq(tag + ' newest first', box.children[0].children[0].children[0], wg.formatEventTime(1761922700));
	ok(tag + ' ok icon class', box.children.some(function(row) {
		return (row.children[1].attrs.class || '').indexOf('wg-ev-ok') !== -1;
	}));
	RPC.canned['exec:/usr/bin/wanguard:events 20'] = { stdout: '' };
	await wg.diagnosticsLoad();
	wg.rebuildDiagnosticsPage();
	ok(tag + ' empty ring -> empty-state', flat(wg.state.diagHolders.events).indexOf('No events yet') !== -1);
});

scenario('GN15 service health panel (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	await renderDiag(wg);
	const txt = flat(wg.state.diagHolders.health);
	ok(tag + ' wanguard row', txt.indexOf('Wanguard') !== -1 && txt.indexOf('Running') !== -1);
	ok(tag + ' config Valid', txt.indexOf('Valid') !== -1);
	ok(tag + ' package version row', txt.indexOf('Package') !== -1 && txt.indexOf('1.8.1') !== -1);
	RPC.canned['exec:/usr/bin/wanguard:diag health'] = { stdout: fixture('diag-health-bad.txt') };
	await wg.diagnosticsLoad();
	wg.rebuildDiagnosticsPage();
	const bad = flat(wg.state.diagHolders.health);
	ok(tag + ' stopped mihomo named', bad.indexOf('Stopped') !== -1);
	ok(tag + ' invalid config + warning listed', bad.indexOf('Invalid') !== -1 && bad.indexOf('missing iface wan9') !== -1);
});

scenario('GN16 dump tabs: lazy load, copy, cache (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	await renderDiag(wg);
	ok(tag + ' summary tab active by default',
		findByWg(wg.state.diagHolders.routing, 'diag-tab-summary').attrs['class'].indexOf('wg-tab-active') !== -1);
	await wg.diagSetTab('nft');
	ok(tag + ' nft pre rendered', !!findByWg(wg.state.diagHolders.routing, 'diag-pre-nft'));
	ok(tag + ' copy button present', !!findByWg(wg.state.diagHolders.routing, 'diag-copy-nft'));
	ok(tag + ' loaded once', wg.state.diag.loadedTabs.nft === true);
	delete RPC.canned['exec:/usr/bin/wanguard:diag nft'];
	await wg.diagSetTab('nft'); /* cached: no refetch, dump survives */
	ok(tag + ' cached dump survives a canned wipe', findByWg(wg.state.diagHolders.routing, 'diag-pre-nft').children.length > 0);
	await wg.diagSetTab('rules');
	ok(tag + ' rules tab renders', !!findByWg(wg.state.diagHolders.routing, 'diag-pre-rules'));
	await wg.diagSetTab('summary');
	ok(tag + ' back to summary', !!findByWg(wg.state.diagHolders.routing, 'diag-summary'));
});

scenario('GN17 View matching rules highlights (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	await renderDiag(wg);
	await wg.diagViewRules('a');
	assertEq(tag + ' switched to nft', wg.state.diag.activeTab, 'nft');
	assertEq(tag + ' highlight group set', wg.state.diag.highlightGroup, 'a');
	const hl = collectHl(wg.state.diagHolders.routing);
	assertEq(tag + ' both wg:a: lines highlighted', hl.length, 2);
	ok(tag + ' highlighted lines carry the tag', hl.every(function(n) { return flat(n).indexOf('wg:a:') !== -1; }));
});

scenario('GN18 inspect flow (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	RPC.canned['exec:/usr/bin/wanguard:inspect aa:bb:cc:dd:ee:55'] = { stdout: fixture('inspect-lb.txt') };
	await renderDiag(wg);
	ok(tag + ' hint before a query', flat(wg.state.diagHolders.inspectResults).indexOf('Type a device name') !== -1);
	await wg.diagInspect('aa:bb:cc:dd:ee:55');
	const res = flat(wg.state.diagHolders.inspectResults);
	ok(tag + ' group row', res.indexOf('Group') !== -1 && res.indexOf('lb') !== -1);
	ok(tag + ' configured vs live rows', res.indexOf('Configured route') !== -1 && res.indexOf('Interface (live)') !== -1);
	ok(tag + ' down slot divergence named', res.indexOf('configured vs live differ') !== -1);
	ok(tag + ' routing table row', res.indexOf('Routing table') !== -1 && res.indexOf('401') !== -1);
	ok(tag + ' View matching rules button', !!findByWg(wg.state.diagHolders.inspectResults, 'diag-viewrules'));
	ok(tag + ' advanced details block', !!findByWg(wg.state.diagHolders.inspectResults, 'diag-advanced'));
	ok(tag + ' raw facts in advanced', flat(findByWg(wg.state.diagHolders.inspectResults, 'diag-advanced')).indexOf('member=wan1') !== -1);
});

scenario('GN19 inspect: unregistered + not found (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	RPC.canned['exec:/usr/bin/wanguard:inspect 192.168.1.99'] = { stdout: fixture('inspect-unreg.txt') };
	RPC.canned['exec:/usr/bin/wanguard:inspect ghost'] = { stdout: '', stderr: 'cannot resolve', code: 1 };
	await renderDiag(wg);
	await wg.diagInspect('192.168.1.99');
	const res = flat(wg.state.diagHolders.inspectResults);
	ok(tag + ' outside-the-groups is a valid answer', res.indexOf('Not registered') !== -1);
	ok(tag + ' no view-rules button for the unregistered', !findByWg(wg.state.diagHolders.inspectResults, 'diag-viewrules'));
	await wg.diagInspect('ghost');
	ok(tag + ' unresolved -> inline not-found (no exception)',
		flat(wg.state.diagHolders.inspectResults).indexOf('Device not found') !== -1);
	await wg.diagInspect('');
	ok(tag + ' cleared query -> hint again', flat(wg.state.diagHolders.inspectResults).indexOf('Type a device name') !== -1);
});

scenario('GN20 download report (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	RPC.canned['exec:/usr/bin/wanguard:diag-report'] = { stdout: '# wanguard diag-report\ngenerated\t2026-11-01 12:00:00\nsync\tin-sync\n' };
	await renderDiag(wg);
	await wg.diagDownloadReport();
	assertEq(tag + ' one blob created', URLStub._objects.length, 1);
	assertEq(tag + ' download filename', /^wanguard-diag-report-.*\.txt$/.test(documentStub._downloads[0].download), true);
	assertEq(tag + ' blob href', documentStub._downloads[0].href, 'blob:fake-1');
	RPC.canned['exec:/usr/bin/wanguard:diag-report'] = { stdout: '' };
	await wg.diagDownloadReport();
	ok(tag + ' old CLI / empty report -> toast',
		(ui._notes || []).some(function(n) { return n[0] === 'error' && n[1].indexOf('Report unavailable') !== -1; }));
});

scenario('GN21 availability probe (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	await wg.diagnosticsLoad();
	assertEq(tag + ' syncstatus answered -> available', wg.state.diag.available, true);
	cannedLb2();
	await wg.diagnosticsLoad();
	assertEq(tag + ' silence -> unavailable', wg.state.diag.available, false);
});

scenario('GN22 sync age drifts forward (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	await wg.diagnosticsLoad();
	assertEq(tag + ' fresh age from the CLI', wg.diagSyncAge(), 3);
	wg.state.diag.sync.fetchedAt = Date.now() - 10500; /* polled 10.5 s ago */
	assertEq(tag + ' recomputed on the render path', wg.diagSyncAge(), 13);
});

scenario('GN23 view wiring (#50)', 'lb2.uci', async (wg, tag) => {
	cannedDiag();
	const r = await renderDiag(wg);
	ok(tag + ' BOARD_CSS mounted', r.root.children.some(function(c) {
		return c.tag === 'style' && flat(c).indexOf('.wg-dcard') !== -1;
	}));
	ok(tag + ' status pill node registered', !!wg.state.statusNode);
	ok(tag + ' page inside the view', !!findByWg(r.root, 'diag-refresh'));
	ok(tag + ' inspect input static across rebuilds', (function() {
		const input = findByWg(r.root, 'diag-inspect');
		wg.rebuildDiagnosticsPage();
		return findByWg(r.root, 'diag-inspect') === input;
	})());
});

async function demo() {
	console.log('\n=== DEMO — board on handwritten UCI (fixtures/lb2.uci, no prod backend) ===');
	UCI.reset(fixture('lb2.uci'));
	cannedLb2();
	const wg = loadCore();
	const ov = loadView('overview', wg);
	await ov.load();
	const root = await ov.render();
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
	console.log('  [lb — LB]  {' + wg.allocPreview('lb') + '}  (board rebuilds from UCI)');

	console.log('\n=== DEMO — tick failover (member_live wan2, fixture lbz.uci) ===');
	UCI.reset(fixture('lbz.uci'));
	console.log('  [lb — LB]  {' + wg.allocPreview('lb') + '}');
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
