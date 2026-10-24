#!/bin/sh
# run-tests-ucode.sh — ucode spike test runner (issue #29, Phase 2):
# ports a representative subset of tests/mock/run-tests.sh T-tests to the
# ucode wand-tick port and runs them against the REAL uci (/etc/config)
# and the SAME PATH stubs (curl/date/conntrack) as the sh suite; only
# ubus is intercepted differently (docs/spike-ucode/mock/ubus.uc via
# `ucode -L`, reading the same UBUS_IFACES/UBUS_ADDRS fixtures).
#
# Runs INSIDE the OpenWrt container (ucode is absent in WSL):
#   docker run --rm -v <repo>:/repo:ro openwrt/rootfs:x86_64-25.12.5 \
#     sh /repo/docs/spike-ucode/run-tests-ucode.sh
set -u

ROOT=/repo
UC=$ROOT/docs/spike-ucode/wand.uc
MOCK=$ROOT/docs/spike-ucode/mock
MOCKBIN=$ROOT/tests/mock/bin

TMP=/tmp/wanguard-mock.$$
WAND=/tmp/wanguard
rm -rf "$WAND" "$TMP"
mkdir -p "$TMP" "$WAND"

# stubs: ONLY curl/date/conntrack are intercepted (ucode spawns them as
# children, so PATH shims work); uci stays REAL (both the runner and the
# ucode cursor read/write /etc/config); ubus is mocked via -L, not PATH
mkdir -p /tmp/shim
for b in curl date conntrack; do cp "$MOCKBIN/$b" /tmp/shim/$b; chmod +x /tmp/shim/$b; done
PATH="/tmp/shim:$PATH"
export PATH
UBUS_IFACES=$TMP/ubus.ifaces
UBUS_ADDRS=$TMP/ubus.addrs
CURLMAP=$TMP/curl.map
DATE_COUNT=$TMP/date.count
CONNTRACKLOG=$TMP/conntrack.log
export UBUS_IFACES UBUS_ADDRS CURLMAP DATE_COUNT CONNTRACKLOG
mkdir -p /var/run /etc/config
: > /var/run/ubus.sock

PASS=0
FAIL=0

reset_router() {
	rm -rf "$WAND"
	mkdir -p "$WAND"
	: > "$UBUS_IFACES"
	: > "$UBUS_ADDRS"
	: > "$CURLMAP"
	: > "$CONNTRACKLOG"
	echo 1000000000 > "$DATE_COUNT"
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
EOF
}

add_group()      { uci set "wanguard.$1=group"; }
uci_set()        { uci set "wanguard.$1=$2"; uci commit wanguard; }
uci_list()       { uci add_list "wanguard.$1=$2"; uci commit wanguard; } # one element per call
add_iface_dev()  { echo "$1=$2" >> "$UBUS_IFACES"; }
add_iface_addr() { echo "$1=$2" >> "$UBUS_ADDRS"; }
map_anchor()     { echo "$1" >> "$CURLMAP"; }

setup_two_wans() {
	add_group a
	add_group b
	uci_set a.type direct
	uci_set a.iface vpn
	uci_set b.type direct
	uci_set b.iface wan2
	add_iface_dev vpn pptp-freedom
	add_iface_dev wan2 pppoe-wan2
}

tick()     { ucode -L "$MOCK" "$UC" wand-tick 2>&1; }
wanstate() { cat "$WAND/$1.state" 2>/dev/null || echo up; }
field()    { cat "$WAND/$1" 2>/dev/null || echo "${2-}"; }

ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1 (got: '$2', want: '$3')"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "*$3*" ;; esac; }

echo "== ucode port: #23 probe anchors (T1,T2,T4-T8,T10) =="

# T1: built-in defaults, 1 of 2 answering = OK (N=1); rtt recorded
reset_router
setup_two_wans
map_anchor 'gstatic=ok'
map_anchor 'detectportal=fail'
tick >/dev/null; tick >/dev/null
assert_eq "T1 alive=1/2 (N=1 default: any anchor)" "$(field vpn.alive)" "1"
assert_eq "T1 rtt recorded" "$(field vpn.rtt)" "0.050"

# T2: all anchors fail x3 -> down; ok x6 -> up
reset_router
setup_two_wans
map_anchor 'gstatic=fail'
map_anchor 'detectportal=fail'
tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "T2 down after 3 failed probes" "$(wanstate vpn)" "down"
: > "$CURLMAP"
tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "T2 still down at 5 oks" "$(wanstate vpn)" "down"
tick >/dev/null
assert_eq "T2 up after 6 ok probes" "$(wanstate vpn)" "up"

# T4: M=3 N=2 — one dead anchor must not trip; two dead must
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping http://a3.example/ping'
uci_set globals.wan_reliability 2
map_anchor 'a1=fail'
map_anchor 'a2=ok'
map_anchor 'a3=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T4 alive=2/3 passes (N=2)" "$(field vpn.alive)" "2"
assert_eq "T4 state stays up" "$(wanstate vpn)" "up"

# T5: N > M clamped to M
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
uci_set globals.wan_reliability 5
map_anchor 'a1=fail'
map_anchor 'a2=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T5 alive=1 < clamped N=2 -> probe fails (fails count)" "$(field vpn.fails)" "2"

# T6: garbage reliability treated as 1
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
uci_set globals.wan_reliability abc
map_anchor 'a1=fail'
map_anchor 'a2=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T6 reliability=abc -> N=1, alive=1 passes" "$(wanstate vpn)" "up"

# T7: min rtt of the answering anchors
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
map_anchor 'a1=ok:0.300'
map_anchor 'a2=ok:0.100'
tick >/dev/null; tick >/dev/null
assert_eq "T7 rtt = min(0.300, 0.100)" "$(field vpn.rtt)" "0.100"

# T8: #6 force hook keeps whole-probe semantics
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
map_anchor 'a1=fail'
map_anchor 'a2=fail'
echo ok > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null
assert_eq "T8 force=ok -> alive=M (ignores map)" "$(field vpn.alive)" "2"
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null
assert_eq "T8 force=fail -> alive=0" "$(field vpn.alive)" "0"

# T10: list wins over legacy when both set
reset_router
setup_two_wans
uci_set globals.wan_anchor1 'http://legacy.example/anchor'
uci_set globals.wan_anchors 'http://fresh.example/ping'
map_anchor 'legacy=fail'
map_anchor 'fresh=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T10 list wins: alive=1, not 0" "$(field vpn.alive)" "1"

echo
echo "== ucode port: #6 failover/failback (T9) =="

reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
out=$(tick)
echo fail > "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick)
assert_contains "T9 failover event" "$out" "failover:a>wan2"
assert_eq "T9 a.iface flipped via UCI" "$(uci -q get wanguard.a.iface)" "wan2"
echo 0 > "$WAND/a.lastswitch" # bypass dwell deterministically (sh tests
rm -f "$WAND/vpn.force"       # rely on real date; same trick here)
out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick)
assert_contains "T9 failback event" "$out" "failback:a>vpn"
assert_eq "T9 a.iface back home" "$(uci -q get wanguard.a.iface)" "vpn"

echo
echo "== ucode port: #26 backup priority (core cases) =="

# B1: explicit list order wins — first UP in THAT order is the target
reset_router
add_group a; add_group b; add_group c
uci_set a.type direct; uci_set a.iface wan1
uci_set b.type direct; uci_set b.iface wan2
uci_set c.type direct; uci_set c.iface wan3
uci_list a.backup_iface wan3
uci_list a.backup_iface wan2
add_iface_dev wan1 eth0; add_iface_dev wan2 eth1; add_iface_dev wan3 eth2
tick >/dev/null # seed
echo fail > "$WAND/wan1.force"
out=$(tick); out=$(tick); out=$(tick)
assert_contains "B1 failover to FIRST in list (wan3, not A-Z wan2)" "$out" "failover:a>wan3"
assert_eq "B1 a.iface=wan3" "$(uci -q get wanguard.a.iface)" "wan3"

# B2: unwatched + home entries dropped; empty usable list -> A-Z default
reset_router
add_group a; add_group b; add_group c
uci_set a.type direct; uci_set a.iface wan1
uci_set b.type direct; uci_set b.iface wan2
uci_set c.type direct; uci_set c.iface wan3
uci_list a.backup_iface wan1     # home -> dropped
uci_list a.backup_iface ghost    # unwatched -> dropped
add_iface_dev wan1 eth0; add_iface_dev wan2 eth1; add_iface_dev wan3 eth2
tick >/dev/null
echo fail > "$WAND/wan1.force"
out=$(tick); out=$(tick); out=$(tick)
assert_contains "B2 unusable list -> default A-Z: failover to wan2" "$out" "failover:a>wan2"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$TMP" "$WAND"
[ "$FAIL" = 0 ]
