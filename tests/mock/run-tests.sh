#!/bin/sh
# Mock tests for the wanguard WAN watchdog (issue #23: N-of-M probe anchors;
# #6 failover state machine on top of them; #24 targeted conntrack flush
# on egress switches).
#
# Runs the REAL router/wanguard against stubbed uci/ubus/ip/nft/curl/
# jsonfilter/date/conntrack (tests/mock/bin). POSIX sh only (busybox ash /
# dash); developed under WSL:  wsl -e sh tests/mock/run-tests.sh
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
UBUS_ADDRS=$TMP/ubus.addrs
CURLMAP=$TMP/curl.map
DATE_COUNT=$TMP/date.count
CONNTRACKLOG=$TMP/conntrack.log
export UCI_STATE UCI_SECTIONS UBUS_IFACES UBUS_ADDRS CURLMAP DATE_COUNT CONNTRACKLOG

cleanup() { rm -rf "$TMP" "$WAND"; }
trap cleanup EXIT

reset_router() {
	rm -rf "$WAND"
	mkdir -p "$WAND"
	: > "$UCI_STATE"
	: > "$UCI_SECTIONS"
	: > "$UBUS_IFACES"
	: > "$UBUS_ADDRS"
	: > "$CURLMAP"
	: > "$CONNTRACKLOG"
	echo 1000000000 > "$DATE_COUNT"
}

# --- fixture helpers (all names generic: no network-identifying data) ---
add_group()      { echo "$1=group" >> "$UCI_SECTIONS"; }
uci_set()        { uci set "wanguard.$1=$2"; }
add_iface_dev()  { echo "$1=$2" >> "$UBUS_IFACES"; }
add_iface_addr() { echo "$1=$2" >> "$UBUS_ADDRS"; }
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

setup_three_wans() { # three direct groups on three ifaces (a=vpn, b=wan2, c=wan3)
	add_group a
	add_group b
	add_group c
	uci_set a.type direct
	uci_set a.iface vpn
	uci_set b.type direct
	uci_set b.iface wan2
	uci_set c.type direct
	uci_set c.iface wan3
	add_iface_dev vpn pptp-freedom
	add_iface_dev wan2 pppoe-wan2
	add_iface_dev wan3 pppoe-wan3
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
echo "== #24: conntrack flush on egress switches =="

# --- T11: failover writes a pending flush; wan-flush deletes via old WAN IP ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
tick >/dev/null # seed a.home=vpn, b.home=wan2
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # vpn down x3 -> failover a>wan2
[ -f "$WAND/a.flush" ] && ok "T11 pending flush written on failover" || bad "T11 pending flush written on failover" "absent" "$WAND/a.flush"
assert_eq "T11 pending flush names the old egress" "$(cat "$WAND/a.flush" 2>/dev/null)" "vpn"
: > "$CONNTRACKLOG"
out=$(sh "$WG" wan-flush)
assert_contains "T11 wan-flush logs the event" "$out" "flush:a>vpn(198.51.100.10)"
assert_contains "T11 conntrack got -D -q old-WAN-IP" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.10"
[ -f "$WAND/a.flush" ] && bad "T11 pending file consumed" "still there" "removed" || ok "T11 pending file consumed"
out=$(sh "$WG" wan-flush) # nothing pending -> silence
assert_eq "T11 idle wan-flush is silent" "$out" ""

# --- T12: idle tick -> no flush requests, no conntrack calls ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null # seed + 3 quiet
assert_eq "T12 no pending flushes in idle cycle" "$(ls "$WAND"/*.flush 2>/dev/null || echo none)" "none"
assert_eq "T12 no conntrack calls in idle cycle" "$(cat "$CONNTRACKLOG")" ""

# --- T13: failback writes a pending flush of the backup being left ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # failover a>wan2
sh "$WG" wan-flush >/dev/null # consume the failover flush
rm -f "$WAND/vpn.force"
echo fail > "$WAND/wan2.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null
out=$(tick) # vpn up again (6 oks) + wan2 down -> failback in the same tick
assert_contains "T13 failback happened" "$out" "failback:a>vpn"
assert_eq "T13 pending flush names the left backup" "$(cat "$WAND/a.flush" 2>/dev/null)" "wan2"
: > "$CONNTRACKLOG"
out=$(sh "$WG" wan-flush)
assert_contains "T13 conntrack got -D -q backup-IP" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.20"

# --- T14: wanset flushes the old egress; same-iface wanset does not ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
tick >/dev/null # seed
: > "$CONNTRACKLOG"
out=$(sh "$WG" wanset a wan2 2>&1)
assert_contains "T14 wanset re-pins the group" "$out" "pinned to 'wan2'"
assert_contains "T14 wanset flushed the old egress" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.10"
: > "$CONNTRACKLOG"
out=$(sh "$WG" wanset a wan2 2>&1) # same iface: no switch, no flush
assert_eq "T14 same-iface wanset: no conntrack call" "$(cat "$CONNTRACKLOG")" ""

# --- T15: conntrack tool absent -> switch still works, no crash ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
tick >/dev/null # seed
NOCT="$TMP/bin-noct" # mocks without conntrack: tool-not-installed simulation
mkdir -p "$NOCT"
for b in uci ubus jsonfilter curl date ip nft; do ln -s "$MOCKBIN/$b" "$NOCT/$b"; done
echo fail > "$WAND/vpn.force"
# NB: plain prepending is not enough — PATH already contains MOCKBIN from the
# header, so build the PATH explicitly: stubs minus conntrack + system bins.
PATH="$NOCT:/usr/bin:/bin" sh "$WG" wand-tick >/dev/null
PATH="$NOCT:/usr/bin:/bin" sh "$WG" wand-tick >/dev/null
out=$(PATH="$NOCT:/usr/bin:/bin" sh "$WG" wand-tick)
assert_contains "T15 failover still fires without conntrack" "$out" "failover:a>wan2"
out=$(PATH="$NOCT:/usr/bin:/bin" sh "$WG" wan-flush)
assert_eq "T15 wan-flush without conntrack: silent, rc=0" "$out" ""

# --- T16: dead old iface -> remembered addr is used for the flush ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
tick >/dev/null # seed; caches $WAND/vpn.addr
tmpf="$UBUS_IFACES.new"
grep -v '^vpn=' "$UBUS_IFACES" > "$tmpf" 2>/dev/null || : > "$tmpf" # ifdown:
echo 'vpn=' >> "$tmpf" # netifd object stays, the device is gone
mv "$tmpf" "$UBUS_IFACES"
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # failover; live resolve impossible
: > "$CONNTRACKLOG"
out=$(sh "$WG" wan-flush)
assert_contains "T16 remembered addr used" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.10"
assert_contains "T16 event still logged" "$out" "flush:a>vpn(198.51.100.10)"

# --- T17: conntrack tool error -> tick and wan-flush survive ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null
out=$(CONNTRACK_FAILS=1 sh "$WG" wan-flush)
assert_contains "T17 conntrack failure tolerated, event logged" "$out" "flush:a>vpn(198.51.100.10)"

echo
echo "== #26: per-group backup priority (list backup_iface) =="

# --- T18: explicit order wins: first UP in the list, not alphabetical ---
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
sh "$WG" backupset a wan3 wan2 # wan3 FIRST though alphabetically last
tick >/dev/null # seed a.home=vpn
echo fail > "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick) # vpn down x3 -> failover
assert_contains "T18 failover follows the explicit order" "$out" "failover:a>wan3"
assert_eq "T18 a.iface = wan3" "$(uci -q get wanguard.a.iface)" "wan3"

# --- T19: head of the list dead -> next in order ---
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
sh "$WG" backupset a wan2 wan3
echo fail > "$WAND/wan2.force" # first in the list dead from the start
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick)
assert_contains "T19 dead head of list skipped" "$out" "failover:a>wan3"
assert_eq "T19 a.iface = wan3" "$(uci -q get wanguard.a.iface)" "wan3"

# --- T20: conflict-check: home inside backup_iface is warned + dropped ---
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
out=$(sh "$WG" backupset a vpn wan3 2>&1)
assert_contains "T20 own-iface entry warned" "$out" "note: 'vpn' is the group's own iface"
assert_eq "T20 home entry dropped from list" "$(uci -q get wanguard.a.backup_iface)" "wan3"
out=$(sh "$WG" backupset b wan3 wan3 2>&1) # duplicate (wan3 is not b's own)
assert_eq "T20 duplicate kept once" "$(uci -q get wanguard.b.backup_iface)" "wan3"
# hand-edited UCI bypassing the CLI: the runtime filter drops home as well
uci add_list wanguard.a.backup_iface=vpn # list now: wan3 vpn
assert_eq "T20 raw add_list stored" "$(uci -q get wanguard.a.backup_iface)" "wan3 vpn"
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # vpn down x3
assert_eq "T20 runtime filter: home never selected" "$(uci -q get wanguard.a.iface)" "wan3"

# --- T21: no list -> default alphabetical (pre-#26 semantics intact) ---
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick)
assert_contains "T21 default order is alphabetical" "$out" "failover:a>wan2"

# --- T22: re-failover: sitting backup dies, home still down -> next in list ---
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
sh "$WG" backupset a wan2 wan3
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # failover a>wan2
echo fail > "$WAND/wan2.force" # the backup dies too, home still down
out=$(tick); out=$(tick); out=$(tick)
assert_contains "T22 re-failover to next backup" "$out" "failover:a>wan3"
assert_eq "T22 a.iface = wan3" "$(uci -q get wanguard.a.iface)" "wan3"
assert_eq "T22 flush names the dead backup" "$(cat "$WAND/a.flush" 2>/dev/null)" "wan2"
rm -f "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick) # vpn 6 oks
assert_contains "T22 failback from second backup" "$out" "failback:a>vpn"
assert_eq "T22 a.iface back home" "$(uci -q get wanguard.a.iface)" "vpn"

# --- T23: backupset validation ---
reset_router
setup_three_wans
add_iface_dev wan4 pppoe-wan4 # in netifd, but no group sits on it
add_group p
uci_set p.type proxy
out=$(sh "$WG" backupset a nosuch 2>&1)
assert_contains "T23 unknown iface rejected" "$out" "unknown netifd iface: 'nosuch'"
out=$(sh "$WG" backupset p wan2 2>&1)
assert_contains "T23 proxy group rejected" "$out" "backups are a direct-group feature"
out=$(sh "$WG" backupset b 2>&1)
assert_contains "T23 empty list usage" "$out" "usage: wanguard backupset"
out=$(sh "$WG" backupset a wan4 2>&1)
assert_contains "T23 unwatched iface warned" "$out" "not watched by the watchdog"
assert_eq "T23 unwatched iface still listed" "$(uci -q get wanguard.a.backup_iface)" "wan4"
out=$(sh "$WG" backupset a wan2 wan3 2>&1) # re-set: replaces, not appends
assert_contains "T23 order echoed" "$out" "backup order:wan2 wan3"
assert_eq "T23 re-set replaces the list" "$(uci -q get wanguard.a.backup_iface)" "wan2 wan3"

# --- T24: wanstatus shows the backup order per group ---
reset_router
setup_three_wans
sh "$WG" backupset a wan3 wan2 >/dev/null
out=$(sh "$WG" wanstatus 2>&1)
row=$(echo "$out" | grep '^a ')
assert_eq "T24 wanstatus shows the order" "$(echo "$row" | awk '{print $5, $6}')" "wan3 wan2"
rowb=$(echo "$out" | grep '^b ')
assert_eq "T24 default order shown as *" "$(echo "$rowb" | awk '{print $5}')" "*"

echo
echo "passed: $PASS, failed: $FAIL (ticks: $T)"
[ "$FAIL" -eq 0 ]
