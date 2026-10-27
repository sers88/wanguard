#!/bin/sh
# C6-metrics.sh — resource metrics in the live lab (issue #29 VERDICT,
# extended for stage 3 / #33 with per-apply spawn counts):
# 1) external spawns per tick AND per apply: PATH shims wrap every
#    external the CLI can touch; each shim counts one invocation then
#    execs the REAL tool, so the bus stays REAL (ubus counted, not
#    mocked) and probes stay REAL curl. 5 settled runs per CLI per
#    subcommand on identical fresh state.
#    NB shell-internal subshell forks (command substitution) are NOT
#    counted — the metric is external tool invocations, the same family
#    the VERDICT's mock-env 58->4 came from.
# 2) wall-time: 40 live ticks per CLI (real curl probes; fast-fail rules
#    turn only the lab's wrong-path artifact into instant rejects),
#    ucode clock() [s,ns] around the loop.
# 3) VmHWM (main-process peak RSS, children excluded on BOTH sides):
#    ucode self-reports after include()'ing the real wand.uc; sh
#    self-reports after sourcing the real wanguard-sh (its dispatch is a
#    plain case at EOF — sources cleanly; children excluded equally).
set -u

UG=/usr/bin/wanguard
SHG=/usr/bin/wanguard-sh
A=172.30.10.10
B=172.30.20.10

fail() { echo "C6 FAIL: $1"; exit 1; }
delrule() { while iptables -D OUTPUT "$@" 2>/dev/null; do :; done; }
FF="eth0:$B eth1:$A"
for p in $FF; do
	iptables -I OUTPUT -o ${p%%:*} -d ${p##*:} -j REJECT || fail "fast-fail $p"
done
trap 'for p in $FF; do delrule -o ${p%%:*} -d ${p##*:} -j REJECT; done' EXIT

reset_lab() {
	rm -rf /tmp/wanguard /tmp/.uci # .uci deltas: грабля 7
	cat > /tmp/netifd.json <<'EOF'
{ "wan1": { "up": true, "device": "eth0", "address": "172.30.10.2" },
  "wan2": { "up": true, "device": "eth1", "address": "172.30.20.2" } }
EOF
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://172.30.10.10/anchor'
	list wan_anchors 'http://172.30.20.10/anchor'

config group 'a'
	option type 'direct'
	option iface 'wan1'

config group 'b'
	option type 'direct'
	option iface 'wan2'
EOF
}

echo "== C6: fork/wall-time/VmHWM in the live lab"

# ---------- 1) external spawns per tick ----------
SHIMS="uci awk grep jsonfilter sort cut sed date tr ubus ip nft conntrack curl"
shim_on() {
	rm -rf /tmp/shim /tmp/cnt; mkdir -p /tmp/shim /tmp/cnt
	for t in $SHIMS; do
		real=$(command -v $t) || fail "no $t on PATH"
		printf '#!/bin/sh\necho x >> /tmp/cnt/%s\nexec %s "$@"\n' "$t" "$real" > /tmp/shim/$t
		chmod +x /tmp/shim/$t
	done
}
shim_off() { rm -rf /tmp/shim; } # counters live in /tmp/cnt — survive

forks_of() { # $1=cli $2=subcommand -> "total uci curl" external spawns / 5 runs
	local cli=$1 sub=${2:-wand-tick} t n total=0 uci=0 curl=0
	reset_lab
	shim_on
	PATH=/tmp/shim:$PATH
	$cli $sub >/dev/null 2>&1 # seed run: settles state (uncounted)
	rm -f /tmp/cnt/*
	n=0; while [ $n -lt 5 ]; do $cli $sub >/dev/null 2>&1; n=$(( n + 1 )); done
	PATH=${PATH#"/tmp/shim:"}
	shim_off # counters readable with the REAL grep only
	for f in /tmp/cnt/*; do
		[ -f "$f" ] || continue
		t=${f##*/}; n=$(grep -c . "$f"); total=$(( total + n ))
		[ "$t" = uci ] && uci=$n
		[ "$t" = curl ] && curl=$n
	done
	echo "$total $uci $curl"
}
f_uc=$(forks_of $UG)
f_sh=$(forks_of $SHG)
printf '  ucode tick: %s external spawns / 5 ticks = %.1f per tick (uci=%s, curl=%.1f, rest=%.1f)\n' \
	"$(echo $f_uc | cut -d' ' -f1)" \
	"$(echo $f_uc | awk '{print $1/5}')" \
	"$(echo $f_uc | cut -d' ' -f2)" \
	"$(echo $f_uc | awk '{print $3/5}')" \
	"$(echo $f_uc | awk '{print ($1-$3)/5}')"
printf '  sh    tick: %s external spawns / 5 ticks = %.1f per tick (uci=%s, curl=%.1f, rest=%.1f)\n' \
	"$(echo $f_sh | cut -d' ' -f1)" \
	"$(echo $f_sh | awk '{print $1/5}')" \
	"$(echo $f_sh | cut -d' ' -f2)" \
	"$(echo $f_sh | awk '{print $3/5}')" \
	"$(echo $f_sh | awk '{print ($1-$3)/5}')"

# ---------- 1b) external spawns per APPLY (stage-3 #33 verdict: the
# ucode apply is native — no sh child, no grep/sed/awk pipeline; nft/ip
# stay external BY DESIGN, so the honest floor is nonzero) ----------
f_uc=$(forks_of $UG apply)
f_sh=$(forks_of $SHG apply)
printf '  ucode apply: %s external spawns / 5 applies = %.1f per apply\n' \
	"$(echo $f_uc | cut -d' ' -f1)" \
	"$(echo $f_uc | awk '{print $1/5}')"
printf '  sh    apply: %s external spawns / 5 applies = %.1f per apply\n' \
	"$(echo $f_sh | cut -d' ' -f1)" \
	"$(echo $f_sh | awk '{print $1/5}')"

# ---------- 2) wall-time: 40 live ticks per CLI ----------
cat > /tmp/wall.uc <<'EOF'
import * as fs from 'fs';
let cli = getenv('CLI');
let n = 40;
let t0 = clock();
for (let i = 0; i < n; i++)
	system(`${cli} wand-tick >/dev/null 2>&1`);
let t1 = clock();
printf('%.2f\n', ((t1[0]-t0[0])*1000 + (t1[1]-t0[1])/1e6) / n);
EOF
reset_lab; $UG wand-tick >/dev/null 2>&1 # seed
ms_uc=$(CLI=$UG ucode /tmp/wall.uc)
reset_lab; $SHG wand-tick >/dev/null 2>&1 # seed
ms_sh=$(CLI=$SHG ucode /tmp/wall.uc)
ratio=$(awk -v a="$ms_sh" -v b="$ms_uc" 'BEGIN { printf "%.1f", a / b }')
printf '  wall-time / tick (40 live ticks, real curl): ucode %s ms, sh %s ms -> %sx\n' \
	"$ms_uc" "$ms_sh" "$ratio"

# ---------- 3) VmHWM: main-process peak RSS ----------
cat > /tmp/vm.uc <<'EOF'
import * as fs from 'fs';
ARGV = ['wand-tick'];
include('/repo/docs/spike-ucode/wand.uc'); // the tick runs during include
for (let l in split(fs.readfile('/proc/self/status'), '\n'))
	if (match(l, /^VmHWM/))
		printf('%s\n', match(l, /([0-9]+)/)[0]);
EOF
reset_lab
kb_uc=$(ucode /tmp/vm.uc | tail -1) # last line: the tick's events may precede
reset_lab
kb_sh=$(sh -c ". $SHG wand-tick; grep VmHWM /proc/self/status" | tail -1 | awk '{print $2}')
printf '  VmHWM (main process, children excluded both sides): ucode %s kB, sh %s kB\n' \
	"$kb_uc" "$kb_sh"
echo "C6-OK (forks + wall-time + VmHWM measured on identical lab states)"
