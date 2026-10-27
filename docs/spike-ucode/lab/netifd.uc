// netifd.uc — fake netifd for the Docker lab (issue #29 acceptance):
// publishes REAL network.interface objects into the REAL ubusd so both
// runners (sh CLI and the ucode port) run unmocked against the bus.
//
// Fixture file /tmp/netifd.json (rewritten by the test battery):
//   { "wan1": { "up": true,  "device": "eth0", "address": "172.30.10.2" },
//     "wan2": { "up": false } }
//
// Polls the fixture mtime every 200 ms and re-renders. Publishes:
//   network.interface            -> dump() (aggregate, netifd shape)
//   network.interface.<name>     -> status() for each known name
// (fixed name set: status of an unknown-to-fixture name answers up:false,
//  which the sh CLI reads as down — same as the real netifd's dump would
//  imply for the tick's purposes)
//
//   ucode /repo/docs/spike-ucode/lab/netifd.uc &

import * as ubus from 'ubus';
import * as uloop from 'uloop';
import * as fs from 'fs';

const FIXTURE = '/tmp/netifd.json';
const NAMES = [ 'wan1', 'wan2', 'wan3' ];

let state = {};

function load() {
	let raw = fs.readfile(FIXTURE);
	if (raw == null)
		return {};
	let j = json(raw);
	return (type(j) == 'object') ? j : {};
}

function render(name) { // fixture entry -> netifd status shape
	let e = state[name];
	if (e == null || !e.up)
		return { interface: name, up: false, pending: false };
	return {
		interface: name,
		up: true,
		pending: false,
		l3_device: e.device,
		device: e.device,
		'ipv4-address': (e.address != null && e.address != '') ?
			[ { address: e.address, mask: 24 } ] : []
	};
}

let conn = ubus.connect();
if (conn == null)
	die('netifd.uc: cannot connect to ubusd\n');

// publish ONCE: call handlers re-read the fixture file on every call, so
// fixture changes take effect immediately without re-publishing
let n = 0;
state = load();
let objs = {};
objs['network.interface'] = {
	dump: {
		call: function(req) {
			state = load();
			let out = [];
			let seen = {};
			// REAL netifd lists every CONFIGURED interface in dump(),
			// up or down — the fixed NAMES set is the configured set;
			// fixture-only names are appended (stage-4 finding: the
			// ucode CLI's wanset/backupset existence checks read the
			// dump, so a fixture-omitted name must still be known)
			for (let name in NAMES) {
				push(out, render(name));
				seen[name] = 1;
			}
			for (let name in keys(state))
				if (!(name in seen))
					push(out, render(name));
			return { interface: out };
		},
		args: {}
	}
};
for (let name in NAMES) {
	let nm = name;
	objs[`network.interface.${nm}`] = {
		status: {
			call: function(req) {
				state = load();
				return render(nm);
			},
			args: {}
		}
	};
}
for (let path in keys(objs)) {
	let rv = conn.publish(path, objs[path]);
	if (!rv)
		warn(`netifd.uc: publish ${path} failed: ${ubus.error()}\n`);
	else
		n++;
}
printf('netifd.uc: published %d objects; fixtures hot-reload on every call\n', n);

// keep the uloop loop alive: run() exits when nothing is registered, and
// a dead publisher leaves zombie objects on the bus
function keepalive() {
	uloop.timer(10000, keepalive);
}
uloop.timer(10000, keepalive);
uloop.run();
