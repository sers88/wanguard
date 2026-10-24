/*
 * mock ubus module (issue #29 spike, Phase 2) — shadows the native
 * /usr/lib/ucode/ubus.so when the interpreter is started with
 *
 *     ucode -L <this-dir> wand.uc wand-tick
 *
 * (-L PREPENDS the search path, so ubus.uc here wins over ubus.so).
 *
 * Reads the SAME fixture files as tests/mock/bin/ubus (the sh suite):
 *   UBUS_IFACES: `name=device` lines; empty device = iface down
 *   UBUS_ADDRS:  `name=ip` lines (default 10.99.0.1)
 *
 * Semantics map onto the ONE call the ucode port makes:
 *   network.interface dump -> every fixture iface as a netifd status
 *   record. Unknown/unset ifaces are simply absent from the dump — the
 *   tick then treats them as down, same as the sh `ubus ... || exit 0`.
 *
 * This file is the Phase 2 feasibility proof: native .so calls CAN be
 * intercepted for ucode without touching wand.uc itself.
 */

import * as fs from 'fs';

function fixtures(path) { // `name=value` lines -> object map
	let map = {};
	let data = fs.readfile(path);
	if (data == null)
		return map;
	for (let line in split(trim(data), /\n/)) {
		let i = index(line, '=');
		if (i > 0)
			map[substr(line, 0, i)] = substr(line, i + 1);
	}
	return map;
}

function connect() {
	return {
		objects: function() {
			return [ [ 'network.interface', { dump: {} } ] ];
		},
		call: function(obj, method, args) {
			if (obj != 'network.interface' || method != 'dump')
				return null; // the real ubus raises; the port never does this
			let ifaces = fixtures(getenv('UBUS_IFACES') ?? '/dev/null');
			let addrs = fixtures(getenv('UBUS_ADDRS') ?? '/dev/null');
			let out = [];
			for (let name in keys(ifaces)) {
				let dev = ifaces[name];
				push(out, {
					interface: name,
					up: (dev != ''),
					l3_device: dev,
					device: dev,
					'ipv4-address': (dev != '') ? [ { address: (addrs[name] ?? '10.99.0.1'), mask: 24 } ] : []
				});
			}
			return { interface: out };
		},
		close: function() {}
	};
}

export { connect };

