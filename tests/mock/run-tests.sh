#!/bin/sh
# Mock tests for the wanguard WAN watchdog (issue #23: N-of-M probe anchors;
# #6 failover state machine on top of them).
#
# Runs the REAL router/wanguard against stubbed uci/ubus/ip/nft/curl/
# jsonfilter/date (tests/mock/bin). POSIX sh only (busybox ash / dash);
# developed under WSL:  wsl -e sh tests/mock/run-tests.sh
#
# WARNING: wipes /tmp/wanguard (the wand state dir) — never run on a router.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WG=$ROOT/router/wanguard
MOCKBIN=$ROOT/tests/mock/bin

TMP=${TMPDIR:-/tmp}/wanguard-mock.$$
WAND=/tmp/wanguard          # hardcoded in the script under test
rm -rf "$WAND" "$TMP"
mkdir -p "$TMP"
PATH="$MOCKBIN:$PATH"
export PATH

PASS=0
FAIL=0
T=0 # test counter

UCI_STATE=$TMP/uci.state
UCI_SECTIONS=$TMP/uci.sections
UBUS_IFACES=$TMP/ubus.ifaces
CURLMAP=$TMP/curl.map
DATE_COUNT=$TMP/date.count
export UCI_STATE UCI_SECTIONS UBUS_IFACES CURLMAP DATE_COUNT

cleanup() { rm -rf "$TMP" "$WAND"; }
trap cleanup EXIT

reset_router() {
	rm -rf "$WAND"
	mkdir -p "$WAND"
	: > "$UCI_STATE"
	: > "$UCI_SECTIONS"
	: > "$UBUS_IFACES"
	: > "$CURLMAP"
	echo 1000000000 > "$DATE_COUNT"
}

# --- fixture helpers (all names generic: no network-identifying data) ---
add_group()      { echo "$1=group" >> "$UCI_SECTIONS"; }
uci_set()        { uci set "wanguard.$1=$2"; }
add_iface_dev()  { echo "$1=$2" >> "$UBUS_IFACES"; }
map_anchor()     { echo "$1" >> "$CURLMAP"; }
remap_anchor()   { # change an existing mapping (stub: first match wins)
	p="$1"; v="$2"
	tmp="$CURLMAP.new"
	{ grep -v "^$p=" "$CURLMAP" 2>/dev/null || :; printf '%s=%s\n' "$p" "$v"; } > "$tmp"
	mv "$tmp" "$CURLMAP"
}
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

tick()     { T=$((T + 1)); sh "$WG" wand-tick 2>&1; }
wanstate() { cat "$WAND/$1.state" 2>/dev/null || echo up; }
field()    { cat "$WAND/$1" 2>/dev/null || echo "${2-}"; }

ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1 (got: '$2', want: '$3')"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "*$3*" ;; esac; }

echo "== #23: probe anchors N-of-M =="

# --- T1: built-in defaults, no UCI anchors: 1 of 2 answering = probe OK ---
reset_router
setup_two_wans
map_anchor 'gstatic=ok'
map_anchor 'detectportal=fail'
tick >/dev/null # seed wan_home
tick >/dev/null
assert_eq "T1 alive=1/2 (N=1 default: any anchor)" "$(field vpn.alive)" "1"
assert_eq "T1 rtt recorded" "$(field vpn.rtt)" "0.050"
case $(sh "$WG" wanstatus 2>&1) in
	*1/2*) ok  "T1 wanstatus shows alive/total" ;;
	*)	bad "T1 wanstatus shows alive/total" "$(sh "$WG" wanstatus 2>&1)" "*1/2*" ;;
esac

# --- T2: defaults, ALL anchors fail x3 -> down; all ok x6 -> up ---
reset_router
setup_two_wans
map_anchor 'gstatic=fail'
map_anchor 'detectportal=fail'
tick >/dev/null; tick >/dev/null
tick >/dev/null; tick >/dev/null; tick >/dev/null # fails 1..3 -> down
assert_eq "T2 down after 3 failed probes" "$(wanstate vpn)" "down"
: > "$CURLMAP" # all anchors ok again
tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "T2 still down at 5 oks" "$(wanstate vpn)" "down"
tick >/dev/null # oks 6 -> up
assert_eq "T2 up after 6 ok probes" "$(wanstate vpn)" "up"

# --- T3: legacy wan_anchor1/2 still read when list absent ---
reset_router
setup_two_wans
uci_set globals.wan_anchor1 'http://legacy-one.example/anchor1'
uci_set globals.wan_anchor2 'http://legacy-two.example/anchor2'
map_anchor 'legacy-one=fail'
map_anchor 'legacy-two=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T3 legacy anchors: alive=1/2" "$(field vpn.alive)" "1"

# --- T4: list M=3, N=2: one dead anchor must NOT drop the channel ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping http://a3.example/ping'
uci_set globals.wan_reliability 2
map_anchor 'a1=fail'
map_anchor 'a2=ok'
map_anchor 'a3=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T4 alive=2/3 passes (N=2)" "$(field vpn.alive)" "2"
assert_eq "T4 state stays up (no false trip)" "$(wanstate vpn)" "up"
# now a2 dies too: alive=1 < 2 -> 3 failed probes -> down
remap_anchor 'a2' 'fail'
tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "T4 down when alive < N (x3)" "$(wanstate vpn)" "down"
# recovery: a2 returns, N satisfied again, 6 oks -> up
remap_anchor 'a2' 'ok'
tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "T4 still down at 5 good probes" "$(wanstate vpn)" "down"
tick >/dev/null
assert_eq "T4 up after 6 good probes" "$(wanstate vpn)" "up"

# --- T5: N > M is clamped to M ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
uci_set globals.wan_reliability 5
map_anchor 'a1=fail'
map_anchor 'a2=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T5 alive=1 < clamped N=2 -> probe fails" "$(field vpn.alive)" "1"
assert_eq "T5 no crash, state still optimistic-up" "$(wanstate vpn)" "up"

# --- T6: garbage / zero reliability is treated as 1 ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
uci_set globals.wan_reliability abc
map_anchor 'a1=fail'
map_anchor 'a2=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T6 reliability=abc -> N=1, alive=1 passes" "$(wanstate vpn)" "up"
uci_set globals.wan_reliability 0
tick >/dev/null; tick >/dev/null
assert_eq "T6 reliability=0 -> N=1, still passes" "$(field vpn.alive)" "1"

# --- T7: min rtt of the answering anchors ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
map_anchor 'a1=ok:0.300'
map_anchor 'a2=ok:0.100'
tick >/dev/null; tick >/dev/null
assert_eq "T7 rtt = min(0.300, 0.100)" "$(field vpn.rtt)" "0.100"

# --- T8: #6 force hook keeps whole-probe semantics ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
map_anchor 'a1=fail'
map_anchor 'a2=fail'
echo ok > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null
assert_eq "T8 force=ok -> alive=M (ignores map)" "$(field vpn.alive)" "2"
echo fail > "$WAND/vpn.force"
rm -f "$WAND/wan2.force" 2>/dev/null
: > "$CURLMAP"
tick >/dev/null; tick >/dev/null
assert_eq "T8 force=fail -> alive=0" "$(field vpn.alive)" "0"

# --- T9: failover/failback (#6 machine) on top of the new probe ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
out=$(tick) # seed: a.home=vpn, b.home=wan2
echo fail > "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick) # vpn fails x3 -> down -> a flips
assert_contains "T9 failover event" "$out" "failover:a>wan2"
assert_eq "T9 a.iface flipped via UCI" "$(uci -q get wanguard.a.iface)" "wan2"
rm -f "$WAND/vpn.force"
echo fail > "$WAND/wan2.force"
out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick) # vpn recovers (6 oks)
assert_contains "T9 failback event" "$out" "failback:a>vpn"
assert_eq "T9 a.iface back home" "$(uci -q get wanguard.a.iface)" "vpn"

# --- T10: list wins over legacy when both set ---
reset_router
setup_two_wans
uci_set globals.wan_anchor1 'http://legacy.example/anchor'
uci_set globals.wan_anchors 'http://fresh.example/ping'
map_anchor 'legacy=fail'
map_anchor 'fresh=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T10 list wins: alive=1, not 0" "$(field vpn.alive)" "1"

echo
echo "passed: $PASS, failed: $FAIL (ticks: $T)"
[ "$FAIL" -eq 0 ]
