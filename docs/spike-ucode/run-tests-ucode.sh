#!/bin/sh
# run-tests-ucode.sh — ucode test runner (issue #29 Phase 2; #32 stage 2):
# ports a representative subset of tests/mock/run-tests.sh T-tests to the
# ucode wand-tick/wan-flush port and runs them against the REAL uci
# (/etc/config) and the SAME PATH stubs (curl/date/conntrack) as the sh
# suite; only ubus is intercepted differently (docs/spike-ucode/mock/
# ubus.uc via `ucode -L`, reading the same UBUS_IFACES/UBUS_ADDRS
# fixtures). F9 additionally diffs the native wan-flush against the stock
# sh CLI on identical state (byte-parity acceptance of #32).
#
# Runs INSIDE the OpenWrt container (ucode is absent in WSL):
#   docker run --rm -v <repo>:/repo:ro openwrt/rootfs:x86_64-25.12.5 \
#     sh /repo/docs/spike-ucode/run-tests-ucode.sh
set -u

ROOT=/repo
UC=$ROOT/docs/spike-ucode/wand.uc
SH=$ROOT/router/wanguard # stock sh CLI: differential-parity reference (F9)
MOCK=$ROOT/docs/spike-ucode/mock
MOCKBIN=$ROOT/tests/mock/bin

TMP=/tmp/wanguard-mock.$$
WAND=/tmp/wanguard
rm -rf "$WAND" "$TMP"
mkdir -p "$TMP" "$WAND"

# stubs: curl/date/conntrack are intercepted (ucode spawns them as
# children, so PATH shims work); ubus/jsonfilter are additionally shimmed
# for the SH differential (F9) — the ucode side never runs them (ubus is
# mocked via -L, not PATH); uci stays REAL (both the runner and the ucode
# cursor read/write /etc/config)
rm -rf /tmp/ucsuite-shim
mkdir -p /tmp/ucsuite-shim
for b in curl date conntrack ubus jsonfilter; do cp "$MOCKBIN/$b" /tmp/ucsuite-shim/$b; chmod +x /tmp/ucsuite-shim/$b; done
PATH="/tmp/ucsuite-shim:$PATH"
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
	rm -rf "$WAND" /tmp/.uci # /tmp/.uci: stray deltas would leak across
	mkdir -p "$WAND"         # test configs (seen once in the scenarios)
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
flush()    { ucode -L "$MOCK" "$UC" wan-flush 2>&1; } # native since stage 2
wanstate() { cat "$WAND/$1.state" 2>/dev/null || echo up; }
field()    { cat "$WAND/$1" 2>/dev/null || echo "${2-}"; }
flist()    { ls "$WAND"/*.flush 2>/dev/null || echo none; }

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
echo "== ucode port: #24 conntrack flush (stage 2: wan-flush is native) =="

# --- F1 (sh T11): failover writes a pending flush; wan-flush resolves the
# old egress IP, calls conntrack, consumes the file, then is silent ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
tick >/dev/null # seed a.home=vpn, b.home=wan2
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # vpn down x3 -> failover a>wan2
[ -f "$WAND/a.flush" ] && ok "F1 pending flush written on failover" || bad "F1 pending flush written on failover" "absent" "$WAND/a.flush"
assert_eq "F1 pending flush names the old egress" "$(cat "$WAND/a.flush" 2>/dev/null)" "vpn"
: > "$CONNTRACKLOG"
out=$(flush)
assert_eq "F1 event byte-exact" "$out" "wand:flush:a>vpn(198.51.100.10)"
assert_contains "F1 conntrack got -D -q old-WAN-IP" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.10"
[ -f "$WAND/a.flush" ] && bad "F1 pending file consumed" "still there" "removed" || ok "F1 pending file consumed"
out=$(flush) # nothing pending -> silence
assert_eq "F1 idle wan-flush is silent" "$out" ""

# --- F2 (sh T12): idle tick -> no flush requests, no conntrack calls ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null # seed + 3 quiet
assert_eq "F2 no pending flushes in idle cycle" "$(flist)" "none"
assert_eq "F2 no conntrack calls in idle cycle" "$(cat "$CONNTRACKLOG")" ""

# --- F3 (sh T13): failback writes a pending flush of the backup being left.
# Single group: sh T13 tolerates group b's own failover noise (contains),
# the byte-exact assertion here must not. NB: the sh suite's mock date
# advances +60/call so dwell always passes there; ucode uses real time(),
# hence the T9-style lastswitch bypass. ---
reset_router
add_group a
uci_set a.type direct
uci_set a.iface vpn
add_group b
uci_set b.type direct
uci_set b.iface wan2
uci_set b.wan_home wan2
uci_set b.wanmode override # keeps wan2 watched, never switches (C5 trick)
add_iface_dev vpn pptp-freedom
add_iface_dev wan2 pppoe-wan2
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
uci_set globals.wan_anchors 'http://a1.example/ping'
tick >/dev/null # seed a.home=vpn
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # failover a>wan2
assert_eq "F3 failover flush names the old home" "$(cat "$WAND/a.flush" 2>/dev/null)" "vpn"
flush >/dev/null # consume the failover flush
rm -f "$WAND/vpn.force"
echo fail > "$WAND/wan2.force"
echo 0 > "$WAND/a.lastswitch" # bypass dwell deterministically (see above)
out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick)
out=$(tick) # vpn up again (6 oks) + failback in the same tick
assert_contains "F3 failback happened" "$out" "failback:a>vpn"
assert_eq "F3 pending flush names the left backup" "$(cat "$WAND/a.flush" 2>/dev/null)" "wan2"
: > "$CONNTRACKLOG"
out=$(flush)
assert_eq "F3 event byte-exact" "$out" "wand:flush:a>wan2(198.51.100.20)"
assert_contains "F3 conntrack got -D -q backup-IP" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.20"

# --- F4 (sh T15): no conntrack in PATH -> failover still fires; wan-flush
# is silent with rc=0 and the pending file is consumed anyway ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
tick >/dev/null # seed
NOCT="$TMP/noct" # the ucode children minus conntrack (ubus is the -L mock,
mkdir -p "$NOCT" # uci is native: curl+date are all it spawns via PATH)
ln -s "$MOCKBIN/curl" "$NOCT/curl"; ln -s "$MOCKBIN/date" "$NOCT/date"
noct_tick()  { PATH="$NOCT:/usr/bin:/bin" ucode -L "$MOCK" "$UC" wand-tick 2>&1; }
noct_flush() { PATH="$NOCT:/usr/bin:/bin" ucode -L "$MOCK" "$UC" wan-flush 2>&1; }
echo fail > "$WAND/vpn.force"
noct_tick >/dev/null; noct_tick >/dev/null
out=$(noct_tick)
assert_contains "F4 failover still fires without conntrack" "$out" "failover:a>wan2"
[ -f "$WAND/a.flush" ] && ok "F4 tick still writes the pending file" || bad "F4 tick still writes the pending file" "absent" "$WAND/a.flush"
out=$(noct_flush); rc=$?
assert_eq "F4 wan-flush without conntrack: silent" "$out" ""
assert_eq "F4 wan-flush without conntrack: rc=0" "$rc" "0"
[ -f "$WAND/a.flush" ] && bad "F4 pending file consumed anyway" "still there" "removed" || ok "F4 pending file consumed anyway"

# --- F5 (sh T16): dead old iface -> the remembered .addr is used ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
tick >/dev/null # seed; probe phase caches $WAND/vpn.addr
tmpf="$UBUS_IFACES.new"
grep -v '^vpn=' "$UBUS_IFACES" > "$tmpf" 2>/dev/null || : > "$tmpf" # ifdown:
echo 'vpn=' >> "$tmpf" # netifd object stays, the device is gone
mv "$tmpf" "$UBUS_IFACES"
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # failover; live resolve impossible
: > "$CONNTRACKLOG"
out=$(flush)
assert_eq "F5 event uses the remembered addr" "$out" "wand:flush:a>vpn(198.51.100.10)"
assert_contains "F5 conntrack got -D -q remembered-IP" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.10"

# --- F6 (sh T17): conntrack tool error -> tick and wan-flush survive ---
echo vpn > "$WAND/a.flush" # re-seed a pending request directly
: > "$CONNTRACKLOG"
out=$(CONNTRACK_FAILS=1 ucode -L "$MOCK" "$UC" wan-flush 2>&1)
assert_eq "F6 conntrack failure tolerated, event logged" "$out" "wand:flush:a>vpn(198.51.100.10)"

# --- F7: several pending requests -> ONE line, sh glob (A-Z) order ---
reset_router
setup_two_wans
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
echo wan2 > "$WAND/a.flush"
echo vpn  > "$WAND/b.flush"
: > "$CONNTRACKLOG"
out=$(flush)
assert_eq "F7 two pending -> one line, glob order" "$out" "wand:flush:a>wan2(198.51.100.20) flush:b>vpn(198.51.100.10)"
assert_eq "F7 both files consumed" "$(flist)" "none"
assert_eq "F7 both deletes executed" "$(cat "$CONNTRACKLOG")" "conntrack -D -q 198.51.100.20
conntrack -D -q 198.51.100.10"

# --- F8: empty pending file -> consumed silently, no event, no conntrack ---
echo "" > "$WAND/a.flush"
: > "$CONNTRACKLOG"
out=$(flush)
assert_eq "F8 empty pending file: silent" "$out" ""
assert_eq "F8 empty pending file: consumed" "$(flist)" "none"
assert_eq "F8 empty pending file: no conntrack call" "$(cat "$CONNTRACKLOG")" ""

# --- F11: a DIRECTORY named *.flush is left alone (sh `[ -f ]` parity) ---
reset_router
setup_two_wans
add_iface_addr vpn 198.51.100.10
mkdir -p "$WAND/a.flush"
echo vpn > "$WAND/b.flush"
out=$(flush)
assert_eq "F11 dir skipped, regular file flushed" "$out" "wand:flush:b>vpn(198.51.100.10)"
[ -d "$WAND/a.flush" ] && ok "F11 directory left untouched" || bad "F11 directory left untouched" "gone" "still there"

# --- F9: differential byte-parity vs the stock sh CLI on identical state
# (the #32 acceptance: flush events byte-identical to the sh run) ---
reset_router
setup_two_wans
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
echo wan2 > "$WAND/a.flush"; echo vpn > "$WAND/b.flush"
: > "$CONNTRACKLOG"
out_uc=$(flush)
log_uc=$(cat "$CONNTRACKLOG")
echo wan2 > "$WAND/a.flush"; echo vpn > "$WAND/b.flush" # identical re-seed
: > "$CONNTRACKLOG"
out_sh=$(sh "$SH" wan-flush 2>&1)
log_sh=$(cat "$CONNTRACKLOG")
assert_eq "F9 byte-parity vs sh (events)" "$out_uc" "$out_sh"
assert_eq "F9 byte-parity vs sh (conntrack calls)" "$log_uc" "$log_sh"
assert_contains "F9 sanity: sh actually flushed" "$out_sh" "flush:a>wan2(198.51.100.20)"
out_uc=$(flush); out_sh=$(sh "$SH" wan-flush 2>&1) # idle rerun: both silent
assert_eq "F9 idle rerun parity" "$out_uc$out_sh" ""

# --- F10: no /tmp/wanguard at all (fresh boot) -> silent, rc=0 ---
rm -rf "$WAND"
out=$(flush); rc=$?
assert_eq "F10 missing wand dir: silent" "$out" ""
assert_eq "F10 missing wand dir: rc=0" "$rc" "0"

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$TMP" "$WAND"
[ "$FAIL" = 0 ]
