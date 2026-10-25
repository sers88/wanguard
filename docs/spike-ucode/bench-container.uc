// bench-container.uc — wall-time probe for the container (issue #29):
// times N ticks of each runner with clock() (ms), reports median/p95.
// NOT a router number — the HITL-window bench (bench-sh.sh) remains the
// source for the verdict's timing row.
//   ucode /repo/docs/spike-ucode/bench-container.uc [N]

import * as fs from 'fs';

const N = (ARGV[0] != null) ? int(ARGV[0]) : 30;

// environment: same shape as scenario.sh (ubus mock via -L for ucode,
// PATH stub for sh — same fixture files; force=ok probes), so the
// measured path is the steady-state forced-probe tick on both runners
system('mkdir -p /etc/config /var/run');
fs.writefile('/var/run/ubus.sock', '');
fs.writefile('/tmp/ubus.ifaces', 'wan1=eth0\nwan2=eth1\n');
system('rm -rf /tmp/bench-shim; mkdir -p /tmp/bench-shim; ' +
	'cp /repo/tests/mock/bin/ubus /tmp/bench-shim/ubus; chmod +x /tmp/bench-shim/ubus');
fs.writefile('/etc/config/wanguard',
	"config group 'a'\n\toption type 'direct'\n\toption iface 'wan1'\n\toption wan_home 'wan1'\n\n" +
	"config group 'b'\n\toption type 'direct'\n\toption iface 'wan2'\n\toption wan_home 'wan2'\n");

function ms_since(t0) { // clock() returns [sec, nsec]
	return (clock()[0] - t0[0]) * 1000 + (clock()[1] - t0[1]) / 1e6;
}

function sh_bench(label, cmd) {
	// reset state so every tick is a steady-state no-op (force=ok both)
	system(`rm -rf /tmp/wanguard; mkdir -p /tmp/wanguard; ` +
		`echo ok > /tmp/wanguard/wan1.force; echo ok > /tmp/wanguard/wan2.force`);
	let samples = [];
	for (let i = 0; i < N; i++) {
		let t0 = clock();
		system(`${cmd} >/dev/null 2>&1`);
		push(samples, ms_since(t0));
	}
	let sorted = sort(samples);
	let med = sorted[int(length(sorted) / 2)];
	let p95 = sorted[int(length(sorted) * 0.95)];
	let sum = 0;
	for (let v in samples) sum += v;
	printf('%s: n=%d median=%.1fms p95=%.1fms mean=%.1fms\n',
		label, N, med, p95, sum / N);
}

sh_bench('sh   ', 'PATH=/tmp/bench-shim:$PATH sh /repo/router/wanguard wand-tick');
sh_bench('ucode', 'ucode -L /repo/docs/spike-ucode/mock /repo/docs/spike-ucode/wand.uc wand-tick');
sh_bench('sh#2 ', 'PATH=/tmp/bench-shim:$PATH sh /repo/router/wanguard wand-tick');   // cache warm
sh_bench('ucode#2', 'ucode -L /repo/docs/spike-ucode/mock /repo/docs/spike-ucode/wand.uc wand-tick');
