#!/bin/sh
# run-tests-ucode.sh — ucode test runner (issue #29 Phase 2; #32 stage 2;
# #30 stage 5): FULL port of the tests/mock/run-tests.sh checks (67 sh
# equivalents, T1-T24) plus ucode-native extras (B1/B2, F1-F11). Runs
# against the REAL uci (/etc/config) and the SAME PATH stubs (curl/date/
# conntrack) as the sh suite; only ubus is intercepted differently
# (docs/spike-ucode/mock/ubus.uc via `ucode -L`, reading the same
# UBUS_IFACES/UBUS_ADDRS fixtures). Native CLI subcommands (wanset,
# backupset, wanstatus — stage 4) run through the same -L shadow; their
# trailing apply() works under the legacy no-op nft/ip mocks (NFT_STATE/
# IP_STATE unset). F9 additionally diffs the native wan-flush against the
# stock sh CLI (kept in the repo as the differential reference; retired
# from the PACKAGE in stage 5).
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
# cursor read/write /etc/config). nft/ip: the stage-4 CLI subcommands
# (wanset/backupset-adjacent groupset...) trail an apply() — the mocks'
# legacy no-op mode (NFT_STATE/IP_STATE unset) covers it without a
# render harness
rm -rf /tmp/ucsuite-shim
mkdir -p /tmp/ucsuite-shim
for b in curl date conntrack ubus jsonfilter nft ip; do cp "$MOCKBIN/$b" /tmp/ucsuite-shim/$b; chmod +x /tmp/ucsuite-shim/$b; done
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

tick()     { ucode -L "$MOCK" "$UC" wand-tick 2>&1; }
flush()    { ucode -L "$MOCK" "$UC" wan-flush 2>&1; } # native since stage 2
cli()      { ucode -L "$MOCK" "$UC" "$@" 2>&1; } # native CLI subcommands
wanstate() { cat "$WAND/$1.state" 2>/dev/null || echo up; }
field()    { cat "$WAND/$1" 2>/dev/null || echo "${2-}"; }
flist()    { ls "$WAND"/*.flush 2>/dev/null || echo none; }

ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1 (got: '$2', want: '$3')"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "*$3*" ;; esac; }
assert_rc()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "rc=$2" "rc=$3"; fi; }

echo "== ucode port: #23 probe anchors (T1-T8, T10) =="

# T1: built-in defaults, 1 of 2 answering = OK (N=1); rtt recorded
reset_router
setup_two_wans
map_anchor 'gstatic=ok'
map_anchor 'detectportal=fail'
tick >/dev/null; tick >/dev/null
assert_eq "T1 alive=1/2 (N=1 default: any anchor)" "$(field vpn.alive)" "1"
assert_eq "T1 rtt recorded" "$(field vpn.rtt)" "0.050"
case $(cli wanstatus) in
	*1/2*) ok  "T1 wanstatus shows alive/total" ;;
	*)	bad "T1 wanstatus shows alive/total" "$(cli wanstatus)" "*1/2*" ;;
esac

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

# T3: legacy wan_anchor1/2 still read when list absent
reset_router
setup_two_wans
uci_set globals.wan_anchor1 'http://legacy-one.example/anchor1'
uci_set globals.wan_anchor2 'http://legacy-two.example/anchor2'
map_anchor 'legacy-one=fail'
map_anchor 'legacy-two=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T3 legacy anchors: alive=1/2" "$(field vpn.alive)" "1"

# T4: M=3 N=2 — one dead anchor must not trip; two dead must; recovery
# is probe-driven (6 consecutive oks) and independent of any switching
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
remap_anchor 'a2' 'fail' # now a2 dies too: alive=1 < 2 -> 3 fails -> down
tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "T4 down when alive < N (x3)" "$(wanstate vpn)" "down"
remap_anchor 'a2' 'ok' # recovery: N satisfied again, 6 oks -> up
tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "T4 still down at 5 good probes" "$(wanstate vpn)" "down"
tick >/dev/null
assert_eq "T4 up after 6 good probes" "$(wanstate vpn)" "up"

# T5: N > M clamped to M
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping http://a2.example/ping'
uci_set globals.wan_reliability 5
map_anchor 'a1=fail'
map_anchor 'a2=ok'
tick >/dev/null; tick >/dev/null
assert_eq "T5 alive=1 < clamped N=2 -> probe fails (fails count)" "$(field vpn.fails)" "2"
assert_eq "T5 no crash, state still optimistic-up" "$(wanstate vpn)" "up"

# T6: garbage reliability treated as 1
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
echo "== ucode port: #26 full sh-suite coverage (T19-T24) =="

# T19: head of the list dead -> next in order
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
cli backupset a wan2 wan3 >/dev/null
echo fail > "$WAND/wan2.force" # first in the list dead from the start
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick)
assert_contains "T19 dead head of list skipped" "$out" "failover:a>wan3"
assert_eq "T19 a.iface = wan3" "$(uci -q get wanguard.a.iface)" "wan3"

# T20: conflict-check: home inside backup_iface is warned + dropped; the
# runtime filter drops a hand-edited home entry as well
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
out=$(cli backupset a vpn wan3)
assert_contains "T20 own-iface entry warned" "$out" "note: 'vpn' is the group's own iface"
assert_eq "T20 home entry dropped from list" "$(uci -q get wanguard.a.backup_iface)" "wan3"
out=$(cli backupset b wan3 wan3) # duplicate (wan3 is not b's own)
assert_eq "T20 duplicate kept once" "$(uci -q get wanguard.b.backup_iface)" "wan3"
# hand-edited UCI bypassing the CLI: the runtime filter drops home as well
uci add_list wanguard.a.backup_iface=vpn; uci commit wanguard
assert_eq "T20 raw add_list stored" "$(uci -q get wanguard.a.backup_iface)" "wan3 vpn"
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # vpn down x3
assert_eq "T20 runtime filter: home never selected" "$(uci -q get wanguard.a.iface)" "wan3"

# T21: no list -> default alphabetical (pre-#26 semantics intact)
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
out=$(tick); out=$(tick); out=$(tick)
assert_contains "T21 default order is alphabetical" "$out" "failover:a>wan2"

# T22: re-failover: sitting backup dies, home still down -> next in list.
# lastswitch bypasses are the T9 dwell trick: ucode uses real time(),
# the sh suite's stub date advances +60/call instead
reset_router
setup_three_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
cli backupset a wan2 wan3 >/dev/null
tick >/dev/null # seed
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # failover a>wan2
echo fail > "$WAND/wan2.force" # the backup dies too, home still down
echo 0 > "$WAND/a.lastswitch"  # bypass dwell deterministically
out=$(tick); out=$(tick); out=$(tick)
assert_contains "T22 re-failover to next backup" "$out" "failover:a>wan3"
assert_eq "T22 a.iface = wan3" "$(uci -q get wanguard.a.iface)" "wan3"
assert_eq "T22 flush names the dead backup" "$(cat "$WAND/a.flush" 2>/dev/null)" "wan2"
rm -f "$WAND/vpn.force"
echo 0 > "$WAND/a.lastswitch" # dwell bypass again (real time() here)
out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick) # vpn 6 oks
assert_contains "T22 failback from second backup" "$out" "failback:a>vpn"
assert_eq "T22 a.iface back home" "$(uci -q get wanguard.a.iface)" "vpn"

# T23: backupset validation
reset_router
setup_three_wans
add_iface_dev wan4 pppoe-wan4 # in netifd, but no group sits on it
add_group p
uci_set p.type proxy
out=$(cli backupset a nosuch)
assert_contains "T23 unknown iface rejected" "$out" "unknown netifd iface: 'nosuch'"
out=$(cli backupset p wan2)
assert_contains "T23 proxy group rejected" "$out" "backups are a direct-group feature"
out=$(cli backupset b)
assert_contains "T23 empty list usage" "$out" "usage: wanguard backupset"
out=$(cli backupset a wan4)
assert_contains "T23 unwatched iface warned" "$out" "not watched by the watchdog"
assert_eq "T23 unwatched iface still listed" "$(uci -q get wanguard.a.backup_iface)" "wan4"
out=$(cli backupset a wan2 wan3) # re-set: replaces, not appends
assert_contains "T23 order echoed" "$out" "backup order:wan2 wan3"
assert_eq "T23 re-set replaces the list" "$(uci -q get wanguard.a.backup_iface)" "wan2 wan3"

# T24: wanstatus shows the backup order per group
reset_router
setup_three_wans
cli backupset a wan3 wan2 >/dev/null
out=$(cli wanstatus)
row=$(echo "$out" | grep '^a ')
assert_eq "T24 wanstatus shows the order" "$(echo "$row" | awk '{print $5, $6}')" "wan3 wan2"
rowb=$(echo "$out" | grep '^b ')
assert_eq "T24 default order shown as *" "$(echo "$rowb" | awk '{print $5}')" "*"

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

# --- W1 (sh T14): wanset flushes the old egress immediately; same-iface
# wanset does not. Native wanset since stage 4; its trailing apply() runs
# under the legacy no-op nft/ip mocks (NFT_STATE/IP_STATE unset) — enough
# for the runner, the assertions target the flush protocol itself ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
add_iface_addr vpn 198.51.100.10
add_iface_addr wan2 198.51.100.20
tick >/dev/null # seed
: > "$CONNTRACKLOG"
out=$(cli wanset a wan2)
assert_contains "T14 wanset re-pins the group" "$out" "pinned to 'wan2'"
assert_contains "T14 wanset flushed the old egress" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.10"
: > "$CONNTRACKLOG"
out=$(cli wanset a wan2) # same iface: no switch, no flush
assert_eq "T14 same-iface wanset: no conntrack call" "$(cat "$CONNTRACKLOG")" ""

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
echo "== #38: direct-lb render (mock-сьют, render mode) =="
#
# The LB tests run the apply renderer against the STATEFUL nft/ip mocks
# (NFT_STATE/IP_STATE render mode, stage-3 harness): the only fixtures
# able to pin tags/bodies/handle order/idempotency/orphan cleanup. Env
# is set INSIDE the wrappers (never as `VAR=v func` prefixes — busybox
# ash persists those into the suite shell, apply-parity.sh lesson).
#
# Allocation pinned by these tests (witness 'a' first, slots keyed by
# SORTED member name, 300 = mihomo skipped):
#   a:wan3        mark 100 table 400 prio 8100   (direct, witness)
#   lb:wan1       mark 200 table 401 prio 8101
#   lb:wan2       mark 400 table 402 prio 8102
#   lb:wan3       mark 500 table 403 prio 8103   (3-member fixture)

# one-time: the skeleton at the apk path (ensure_table loads it in
# render mode; the tick path above never touches nft)
mkdir -p /usr/share/wanguard
cp "$ROOT/router/wanguard.nft" /usr/share/wanguard/wanguard.nft

RSTATE=$TMP/lb-nft.db
RIP=$TMP/lb-ip

rapply() { NFT_STATE=$RSTATE IP_STATE=$RIP ucode -L "$MOCK" "$UC" apply 2>&1; }
rcli()   { NFT_STATE=$RSTATE IP_STATE=$RIP ucode -L "$MOCK" "$UC" "$@" 2>&1; }
rnft()   { NFT_STATE=$RSTATE "$MOCKBIN/nft" "$@" 2>&1; }
rip()    { IP_STATE=$RIP "$MOCKBIN/ip" "$@" 2>&1; }
marking() { rnft -a list chain inet wanguard marking; }
handle_of() { printf '%s' "$1" | sed -n 's/.*# handle \([0-9]*\).*/\1/p'; }

lb_reset() { # render state + fixtures to zero (keepalive-contract seed:
	rm -rf "$RSTATE" "$RIP" /tmp/.uci # main default + links, as stage 3)
	mkdir -p "$RIP"
	: > "$UBUS_IFACES"
	: > "$UBUS_ADDRS"
	printf 'default via 192.0.2.1 dev mockwan metric 10\n' > "$RIP/route.main"
	: > "$RIP/links"
	for d in mockwan eth0 eth1 eth2 Meta; do printf '%s\n' "$d" >> "$RIP/links"; done
	add_iface_dev wan1 eth0
	add_iface_dev wan2 eth1
	add_iface_dev wan3 eth2
}

conf_lb2() { # the lab-shaped fixture: witness + 2 members 70/30
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'wan3'

config group 'lb'
	option type 'direct-lb'
	list member_iface 'wan1'
	list member_iface 'wan2'
	option weight_wan1 '70'
	option weight_wan2 '30'

config member
	option mac 'aa:bb:cc:dd:ee:55'
	option group 'lb'
	option name 'client'
EOF
}

conf_lb1() { # single member: the unconditional-remainder-only form
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'wan3'

config group 'lb'
	option type 'direct-lb'
	list member_iface 'wan1'

config member
	option mac 'aa:bb:cc:dd:ee:55'
	option group 'lb'
	option name 'client'
EOF
}

conf_lb3() { # three members, NO weight options (defaults 50/50/50)
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'wan3'

config group 'lb'
	option type 'direct-lb'
	list member_iface 'wan1'
	list member_iface 'wan2'
	list member_iface 'wan3'

config member
	option mac 'aa:bb:cc:dd:ee:55'
	option group 'lb'
	option name 'client'
EOF
}

conf_lbpx() { # proxy + witness + lb: the #27 boundary (proxy/witness
	# must be untouched by LB rules); no member sections needed here
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'

config group 'p'
	option type 'proxy'

config group 'a'
	option type 'direct'
	option iface 'wan3'

config group 'lb'
	option type 'direct-lb'
	list member_iface 'wan1'
	list member_iface 'wan2'
	option weight_wan1 '70'
	option weight_wan2 '30'
EOF
}

# --- LB1: applied -> in-sync (keepalive contract on an LB config) ---
lb_reset; conf_lb2
out=$(rapply); case "$out" in applied*) ok "LB1 first apply: applied" ;; *) bad "LB1 first apply: applied" "$out" "applied*" ;; esac
out=$(rapply); assert_eq "LB1 second apply: exactly in-sync" "$out" "in-sync"

# --- LB2: tags and bodies, INCLUDING the cascade verdict (return) ---
mk=$(marking)
st=$(printf '%s\n' "$mk" | grep 'comment "wg:lb:stick"')
case "$st" in
	*'ct mark != 0 counter meta mark set ct mark return'*) ok "LB2 stick body (restore + return)" ;;
	*) bad "LB2 stick body (restore + return)" "$st" "*ct mark != 0*meta mark set ct mark return*" ;;
esac
r1=$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s70@200"')
r2=$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s100@400"')
case "$r1" in
	*'numgen random mod 100 < 70 counter meta mark set 200 ct mark set meta mark return'*) ok "LB2 member 1: draw < 70, mark 200, ct pin, return" ;;
	*) bad "LB2 member 1: draw < 70, mark 200, ct pin, return" "$r1" "*numgen random mod 100 < 70*mark set 200*ct mark set meta mark return*" ;;
esac
case "$r2" in
	*numgen*) bad "LB2 member 2: unconditional remainder (no draw)" "$r2" "no numgen" ;;
	*) ok "LB2 member 2: unconditional remainder (no draw)" ;;
esac
case "$r2" in
	*'counter meta mark set 400 ct mark set meta mark return'*) ok "LB2 member 2: mark 400, ct pin, return" ;;
	*) bad "LB2 member 2: mark 400, ct pin, return" "$r2" "*mark set 400*ct mark set meta mark return*" ;;
esac
printf '%s\n' "$mk" | grep -q 'comment "wg:a:m100"' && ok "LB2 witness rule wg:a:m100 present" || bad "LB2 witness rule wg:a:m100 present" "$mk" "*wg:a:m100*"

# --- LB3: cascade order pinned by HANDLES (first render) ---
h1=$(handle_of "$st"); h2=$(handle_of "$r1"); h3=$(handle_of "$r2")
if [ -n "$h1" ] && [ -n "$h2" ] && [ -n "$h3" ] && [ "$h1" -lt "$h2" ] && [ "$h2" -lt "$h3" ]; then
	ok "LB3 handle order stick($h1) < draw($h2) < remainder($h3)"
else
	bad "LB3 handle order stick($h1) < draw($h2) < remainder($h3)" "$h1 $h2 $h3" "ordered"
fi

# --- LB4: slot allocation on the ip side + grouplist rows ---
rip rule show | grep -q '8100:.*fwmark 0x64.*lookup 400' && ok "LB4 witness slot 8100/0x64/400" || bad "LB4 witness slot 8100/0x64/400" "$(rip rule show)" "*8100*0x64*400*"
rip rule show | grep -q '8101:.*fwmark 0xc8.*lookup 401' && ok "LB4 slot wan1 8101/0xc8/401" || bad "LB4 slot wan1 8101/0xc8/401" "$(rip rule show)" "*8101*0xc8*401*"
rip rule show | grep -q '8102:.*fwmark 0x190.*lookup 402' && ok "LB4 slot wan2 8102/0x190/402 (300 skipped)" || bad "LB4 slot wan2 8102/0x190/402" "$(rip rule show)" "*8102*0x190*402*"
case "$(rip route show table 400 | grep '^default')" in *'dev eth2'*) ok "LB4 table 400 -> eth2 (witness)" ;; *) bad "LB4 table 400 -> eth2" "$(rip route show table 400)" "*dev eth2*" ;; esac
case "$(rip route show table 401 | grep '^default')" in *'dev eth0'*) ok "LB4 table 401 -> eth0 (wan1)" ;; *) bad "LB4 table 401 -> eth0" "$(rip route show table 401)" "*dev eth0*" ;; esac
case "$(rip route show table 402 | grep '^default')" in *'dev eth1'*) ok "LB4 table 402 -> eth1 (wan2)" ;; *) bad "LB4 table 402 -> eth1" "$(rip route show table 402)" "*dev eth1*" ;; esac
for t in 400 401 402; do
	case "$(rip route show table $t)" in
		*' metric 200'*) ok "LB4 table $t: metric-200 fallback" ;;
		*) bad "LB4 table $t: metric-200 fallback" "$(rip route show table $t)" "* metric 200*" ;;
	esac
done
gl=$(rcli grouplist)
printf '%s\n' "$gl" | grep -q 'lb.*direct-lb.*wan1.*200.*401' && ok "LB4 grouplist row lb:wan1 200/401" || bad "LB4 grouplist row lb:wan1 200/401" "$gl" "*lb*direct-lb*wan1*200*401*"
printf '%s\n' "$gl" | grep -q 'lb.*direct-lb.*wan2.*400.*402' && ok "LB4 grouplist row lb:wan2 400/402" || bad "LB4 grouplist row lb:wan2 400/402" "$gl" "*lb*direct-lb*wan2*400*402*"

# --- LB5: weight flip = whole-cascade swap, ip-side snapshot frozen ---
before=$( { rip rule show; rip route show table 400; rip route show table 401; \
	rip route show table 402; rnft list set inet wanguard mac_lb; } 2>/dev/null )
uci_set lb.weight_wan1 '30'
uci_set lb.weight_wan2 '70'
out=$(rapply); case "$out" in applied*) ok "LB5 flip: applied" ;; *) bad "LB5 flip: applied" "$out" "applied*" ;; esac
mk=$(marking)
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s30@200"' && ok "LB5 new tag s30@200" || bad "LB5 new tag s30@200" "$mk" "*wg:lb:s30@200*"
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s100@400"' && ok "LB5 remainder tag s100@400 kept" || bad "LB5 remainder tag s100@400 kept" "$mk" "*wg:lb:s100@400*"
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s70@200"' && bad "LB5 old tag s70@200 gone" "still there" "removed" || ok "LB5 old tag s70@200 gone"
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:stick"' && ok "LB5 stick survived the flip" || bad "LB5 stick survived the flip" "$mk" "*wg:lb:stick*"
pf1=$(handle_of "$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s30@200"')")
pf2=$(handle_of "$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s100@400"')")
if [ -n "$pf1" ] && [ -n "$pf2" ] && [ "$pf1" -lt "$pf2" ]; then
	ok "LB5 post-flip order: draw($pf1) < remainder($pf2) — append-bug regression"
else
	bad "LB5 post-flip order: draw($pf1) < remainder($pf2)" "$pf1 $pf2" "ordered"
fi
after=$( { rip rule show; rip route show table 400; rip route show table 401; \
	rip route show table 402; rnft list set inet wanguard mac_lb; } 2>/dev/null )
assert_eq "LB5 ip-side snapshot unchanged by the flip" "$before" "$after"
out=$(rapply); assert_eq "LB5 post-flip apply: in-sync" "$out" "in-sync"

# --- LB6: single member = unconditional rule without draw, one slot ---
lb_reset; conf_lb1
rapply >/dev/null
out=$(rapply); assert_eq "LB6 single: in-sync" "$out" "in-sync"
mk=$(marking)
sr=$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s100@200"')
case "$sr" in
	*'numgen'*) bad "LB6 single: no draw in the only member rule" "$sr" "no numgen" ;;
	*'counter meta mark set 200 ct mark set meta mark return'*) ok "LB6 single: unconditional, mark 200, return" ;;
	*) bad "LB6 single: unconditional, mark 200, return" "$sr" "*mark set 200*return*" ;;
esac
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s100@200"' && printf '%s\n' "$mk" | grep -c 'comment "wg:lb:s[0-9]' | grep -q '^1$' \
	&& ok "LB6 single: exactly one member rule" || bad "LB6 single: exactly one member rule" "$(printf '%s\n' "$mk" | grep -c 'comment "wg:lb:s[0-9]')" "1"
rip rule show | grep -q '8101:.*lookup 401' && ok "LB6 single: slot 8101/401 present" || bad "LB6 single: slot 8101/401 present" "$(rip rule show)" "*8101*401*"
rip rule show | grep -qE '810[23]:' && bad "LB6 single: no second slot" "$(rip rule show)" "no 8102/8103" || ok "LB6 single: no second slot"
case "$(rip route show table 401 | grep '^default')" in *'dev eth0'*) ok "LB6 single: table 401 -> eth0" ;; *) bad "LB6 single: table 401 -> eth0" "$(rip route show table 401)" "*dev eth0*" ;; esac

# --- LB7: three members, default weights: buckets 33/33/34 -> 200/400/500 ---
lb_reset; conf_lb3
out=$(rapply); case "$out" in applied*) ok "LB7 three: applied" ;; *) bad "LB7 three: applied" "$out" "applied*" ;; esac
mk=$(marking)
t1=$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s33@200"')
t2=$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s66@400"')
t3=$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s100@500"')
case "$t1" in *'numgen random mod 100 < 33'*) ok "LB7 member 1 draws < 33" ;; *) bad "LB7 member 1 draws < 33" "$t1" "*< 33*" ;; esac
case "$t2" in *'numgen random mod 100 < 66'*) ok "LB7 member 2 draws < 66" ;; *) bad "LB7 member 2 draws < 66" "$t2" "*< 66*" ;; esac
case "$t3" in *numgen*) bad "LB7 member 3: unconditional remainder" "$t3" "no numgen" ;; *) ok "LB7 member 3: unconditional remainder" ;; esac
h1=$(handle_of "$t1"); h2=$(handle_of "$t2"); h3=$(handle_of "$t3")
if [ -n "$h1" ] && [ -n "$h2" ] && [ -n "$h3" ] && [ "$h1" -lt "$h2" ] && [ "$h2" -lt "$h3" ]; then
	ok "LB7 cascade order 33($h1) < 66($h2) < remainder($h3)"
else
	bad "LB7 cascade order 33($h1) < 66($h2) < remainder($h3)" "$h1 $h2 $h3" "ordered"
fi
rip rule show | grep -q '8103:.*fwmark 0x1f4.*lookup 403' && ok "LB7 third slot 8103/0x1f4/403" || bad "LB7 third slot 8103/0x1f4/403" "$(rip rule show)" "*8103*0x1f4*403*"
out=$(rapply); assert_eq "LB7 three: in-sync" "$out" "in-sync"

# --- LB8: groupdel -> orphan cleanup of BOTH slots, witness intact ---
lb_reset; conf_lb2
rapply >/dev/null
uci delete wanguard.lb
uci commit wanguard
out=$(rapply); case "$out" in applied*) ok "LB8 delete: applied" ;; *) bad "LB8 delete: applied" "$out" "applied*" ;; esac
mk=$(marking)
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:' && bad "LB8 no wg:lb: rules survive" "$(printf '%s\n' "$mk" | grep 'wg:lb:' | head -n 1)" "none" || ok "LB8 no wg:lb: rules survive"
rnft list set inet wanguard mac_lb >/dev/null 2>&1 && bad "LB8 mac_lb set deleted" "still there" "removed" || ok "LB8 mac_lb set deleted"
rip rule show | grep -qE '810[12]:' && bad "LB8 slot ip rules deleted" "$(rip rule show)" "no 8101/8102" || ok "LB8 slot ip rules deleted"
[ -s "$RIP/route.401" ] && bad "LB8 table 401 flushed" "$(rip route show table 401)" "empty" || ok "LB8 table 401 flushed"
[ -s "$RIP/route.402" ] && bad "LB8 table 402 flushed" "$(rip route show table 402)" "empty" || ok "LB8 table 402 flushed"
printf '%s\n' "$mk" | grep -q 'comment "wg:a:m100"' && ok "LB8 witness rule intact" || bad "LB8 witness rule intact" "$mk" "*wg:a:m100*"
case "$(rip route show table 400 | grep '^default')" in *'dev eth2'*) ok "LB8 witness table intact" ;; *) bad "LB8 witness table intact" "$(rip route show table 400)" "*dev eth2*" ;; esac
out=$(rapply); assert_eq "LB8 post-delete: in-sync" "$out" "in-sync"

# --- LB9: member SHRINK (3 -> 2): the dropped slot is cleaned precisely,
# the remaining slots keep their keyed marks, cascade re-renders in order ---
lb_reset; conf_lb3
rapply >/dev/null
uci del_list wanguard.lb.member_iface='wan3'
uci commit wanguard
out=$(rapply); case "$out" in applied*) ok "LB9 shrink: applied" ;; *) bad "LB9 shrink: applied" "$out" "applied*" ;; esac
mk=$(marking)
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s100@500"' && bad "LB9 dropped-slot rule s100@500 gone" "still there" "removed" || ok "LB9 dropped-slot rule s100@500 gone"
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s33@200"' && bad "LB9 re-keyed old tag s33@200 gone" "still there" "removed" || ok "LB9 re-keyed old tag s33@200 gone"
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s50@200"' && ok "LB9 renormalized tag s50@200" || bad "LB9 renormalized tag s50@200" "$mk" "*wg:lb:s50@200*"
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s100@400"' && ok "LB9 remainder s100@400" || bad "LB9 remainder s100@400" "$mk" "*wg:lb:s100@400*"
sf1=$(handle_of "$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s50@200"')")
sf2=$(handle_of "$(printf '%s\n' "$mk" | grep 'comment "wg:lb:s100@400"')")
if [ -n "$sf1" ] && [ -n "$sf2" ] && [ "$sf1" -lt "$sf2" ]; then
	ok "LB9 post-shrink order: draw($sf1) < remainder($sf2)"
else
	bad "LB9 post-shrink order: draw($sf1) < remainder($sf2)" "$sf1 $sf2" "ordered"
fi
rip rule show | grep -qE '8103:' && bad "LB9 orphan slot rule 8103 deleted" "$(rip rule show)" "no 8103" || ok "LB9 orphan slot rule 8103 deleted"
[ -s "$RIP/route.403" ] && bad "LB9 orphan table 403 flushed" "$(rip route show table 403)" "empty" || ok "LB9 orphan table 403 flushed"
rip rule show | grep -q '8101:.*fwmark 0xc8.*lookup 401' && ok "LB9 kept slot wan1 200/401 intact" || bad "LB9 kept slot wan1 200/401 intact" "$(rip rule show)" "*8101*0xc8*401*"
printf '%s\n' "$mk" | grep -q 'comment "wg:a:m100"' && ok "LB9 witness intact" || bad "LB9 witness intact" "$mk" "*wg:a:m100*"

# --- LB10: #27 boundary — proxy and witness untouched by the LB cascade ---
lb_reset; conf_lbpx
rapply >/dev/null
mk=$(marking)
pr=$(printf '%s\n' "$mk" | grep 'comment "wg:p:m300"')
case "$pr" in
	*'meta l4proto != tcp ip daddr != @local_v4 ip daddr != @no_mark meta mark set 300'*) ok "LB10 proxy rule shape unchanged (no cascade involvement)" ;;
	*) bad "LB10 proxy rule shape unchanged" "$pr" "*l4proto != tcp*mark set 300*" ;;
esac
rd=$(rnft -a list chain inet wanguard redir)
printf '%s\n' "$rd" | grep -q 'comment "wg:p:r7892"' && ok "LB10 redir rule intact" || bad "LB10 redir rule intact" "$rd" "*wg:p:r7892*"
printf '%s\n' "$mk" | grep 'comment "wg:lb:' | grep -q '@300' && bad "LB10 no cascade rule carries mark 300" "found" "none" || ok "LB10 no cascade rule carries mark 300"
prh=$(handle_of "$pr"); wh=$(handle_of "$(printf '%s\n' "$mk" | grep 'comment "wg:a:m100"')")
uci_set lb.weight_wan1 '30'
uci_set lb.weight_wan2 '70'
out=$(rapply); case "$out" in applied*) ok "LB10 flip: applied" ;; *) bad "LB10 flip: applied" "$out" "applied*" ;; esac
mk=$(marking)
[ "$(handle_of "$(printf '%s\n' "$mk" | grep 'comment "wg:p:m300"')")" = "$prh" ] \
	&& ok "LB10 proxy rule handle untouched by the flip" || bad "LB10 proxy rule handle untouched by the flip" "$(printf '%s\n' "$mk" | grep 'wg:p:m300')" "handle $prh"
[ "$(handle_of "$(printf '%s\n' "$mk" | grep 'comment "wg:a:m100"')")" = "$wh" ] \
	&& ok "LB10 witness rule handle untouched by the flip" || bad "LB10 witness rule handle untouched by the flip" "$(printf '%s\n' "$mk" | grep 'wg:a:m100')" "handle $wh"
out=$(rapply); assert_eq "LB10 post-flip: in-sync" "$out" "in-sync"

echo
echo "== #39: direct-lb tick (member_live / lbover / #24-flush) =="
#
# Fixture-driven, deterministic (force-hook probes, real time() never
# gates anything here: the LB phase has NO dwell — the probe hysteresis
# IS the debounce). The keepalive order tick -> apply -> wan-flush is
# replayed manually in LT6; event forms are the prototype's:
#   down:<member> ... lbover:<g>:<member>><live>, flush after apply.

conf_lbt() { # direct witness + 2-member LB group (70/30)
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config group 'lb'
	option type 'direct-lb'
	list member_iface 'wan1'
	list member_iface 'wan2'
	option weight_wan1 '70'
	option weight_wan2 '30'
EOF
}

lbt_reset() { # reset_router (tick fixtures) + lb_reset (render fixtures):
	# LT6 replays the keepalive order tick -> apply -> wan-flush, so the
	# render leg needs links/tables too (eth9 = the vpn witness device)
	reset_router
	lb_reset
	add_iface_dev vpn eth9
	add_iface_addr vpn 198.51.100.30
	add_iface_addr wan1 198.51.100.10
	add_iface_addr wan2 198.51.100.20
	printf '%s\n' eth9 >> "$RIP/links"
}

# --- LT1: LB members are IN the probe list (unwatched member = slot
# that can neither fail over nor fail back) ---
lbt_reset; conf_lbt
map_anchor 'gstatic=ok'
map_anchor 'detectportal=ok'
tick >/dev/null; tick >/dev/null
[ -s "$WAND/wan1.alive" ] && ok "LT1 wan1 (LB member) probed" || bad "LT1 wan1 (LB member) probed" "absent" "$WAND/wan1.alive"
[ -s "$WAND/wan2.alive" ] && ok "LT1 wan2 (LB member) probed" || bad "LT1 wan2 (LB member) probed" "absent" "$WAND/wan2.alive"
[ -s "$WAND/vpn.alive" ] && ok "LT1 direct witness still probed" || bad "LT1 direct witness still probed" "absent" "$WAND/vpn.alive"

# --- LT2: member death x3 -> down + lbover + member_live + pending flush ---
lbt_reset; conf_lbt
map_anchor 'gstatic=ok'
map_anchor 'detectportal=ok'
tick >/dev/null # seed
echo fail > "$WAND/wan1.force"
out=$(tick); out=$(tick)
out=$(tick)
assert_contains "LT2 down event for the member" "$out" "down:wan1"
assert_contains "LT2 lbover event (slot inherited by first alive)" "$out" "lbover:lb:wan1>wan2"
assert_eq "LT2 member_live written (both slots on wan2)" "$(uci -q get wanguard.lb.member_live)" "wan2 wan2"
assert_eq "LT2 pending flush names the dead member" "$(cat "$WAND/lb.flush" 2>/dev/null)" "wan1"

# --- LT3: the #24 flush executes AFTER apply, aimed at the dead egress ---
: > "$CONNTRACKLOG"
out=$(flush)
assert_eq "LT3 flush event byte-form" "$out" "wand:flush:lb>wan1(198.51.100.10)"
assert_contains "LT3 conntrack aimed at the dead egress IP" "$(cat "$CONNTRACKLOG")" "-D -q 198.51.100.10"

# --- LT4: recovery: the alive-in-slot member takes its slot BACK; no
# flush on failback-to-self (alt == member) ---
rm -f "$WAND/wan1.force"
out=$(tick); out=$(tick); out=$(tick); out=$(tick); out=$(tick)
out=$(tick) # 6 oks -> up + slot re-claim in the same tick
assert_contains "LT4 up event after OKS_UP" "$out" "up:wan1"
assert_contains "LT4 reverse lbover (slot back to its member)" "$out" "lbover:lb:wan1>wan1"
assert_eq "LT4 member_live back to declared" "$(uci -q get wanguard.lb.member_live)" "wan1 wan2"
assert_eq "LT4 no flush on failback-to-self" "$(flist)" "none"

# --- LT5: zero alive -> slots hold declared, NO spurious events ---
lbt_reset; conf_lbt
map_anchor 'gstatic=ok'
map_anchor 'detectportal=ok'
tick >/dev/null # seed
echo fail > "$WAND/wan1.force"
echo fail > "$WAND/wan2.force"
out=$(tick); out=$(tick)
out=$(tick)
assert_contains "LT5 both members reported down" "$out" "down:wan1"
assert_contains "LT5 both members reported down" "$out" "down:wan2"
case "$out" in
	*lbover*) bad "LT5 no spurious lbover at zero-alive" "$out" "no lbover" ;;
	*) ok "LT5 no spurious lbover at zero-alive" ;;
esac
assert_eq "LT5 member_live left unset (declared)" "$(uci -q get wanguard.lb.member_live 2>/dev/null || echo '')" ""
assert_eq "LT5 no flush at zero-alive" "$(flist)" "none"

# --- LT6: tick -> apply -> wan-flush: the inherited slot's TABLE
# re-targets to the alive member; marks (slots) do not re-key ---
lbt_reset; conf_lbt
map_anchor 'gstatic=ok'
map_anchor 'detectportal=ok'
rapply >/dev/null
out=$(rapply); assert_eq "LT6 baseline in-sync" "$out" "in-sync"
case "$(rip route show table 401 | grep '^default')" in *'dev eth0'*) ok "LT6 slot wan1 on eth0 before death" ;; *) bad "LT6 slot wan1 on eth0 before death" "$(rip route show table 401)" "*dev eth0*" ;; esac
tick >/dev/null # seed
echo fail > "$WAND/wan1.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null # down + lbover + member_live
out=$(rapply); case "$out" in applied*) ok "LT6 apply after lbover: applied" ;; *) bad "LT6 apply after lbover: applied" "$out" "applied*" ;; esac
case "$(rip route show table 401 | grep '^default')" in *'dev eth1'*) ok "LT6 inherited slot re-targets table 401 to eth1" ;; *) bad "LT6 inherited slot re-targets table 401 to eth1" "$(rip route show table 401)" "*dev eth1*" ;; esac
case "$(rip route show table 402 | grep '^default')" in *'dev eth1'*) ok "LT6 own slot wan2 untouched (eth1)" ;; *) bad "LT6 own slot wan2 untouched (eth1)" "$(rip route show table 402)" "*dev eth1*" ;; esac
mk=$(marking)
printf '%s\n' "$mk" | grep -q 'comment "wg:lb:s70@200"' && ok "LT6 marks stable across failover (no re-key)" || bad "LT6 marks stable across failover (no re-key)" "$mk" "*wg:lb:s70@200*"
out=$(rapply); assert_eq "LT6 post-failover apply: in-sync" "$out" "in-sync"
: > "$CONNTRACKLOG"
out=$(flush)
assert_eq "LT6 flush consumed after apply (keepalive order)" "$out" "wand:flush:lb>wan1(198.51.100.10)"

echo
echo "== #42: group metadata (groupset -label/-color/-description, groupmeta) =="
#
# The metadata options are UCI-only (the render never reads them): the
# assertions target the COMMITTED UCI BYTES (real uci in this runner) and
# the machine-readable groupmeta rows. The legacy groupset target form is
# byte-frozen (stages 10-11) — GM5 keeps it pinned.

gm_opts() { # committed metadata bytes of group $1 (grep over /etc/config)
	sed -n "/^config group '$1'/,/^config /p" /etc/config/wanguard
}

# --- GM1: flags write label/color/description; byte-exact confirmation;
#         NO apply side effect (the output is exactly the one msg line) ---
reset_router
setup_two_wans
out=$(cli groupset a -label 'Дом' -color blue -description 'Main home LAN')
assert_eq "GM1 confirmation byte-exact" "$out" "group 'a' metadata updated (label, color, description)"
assert_eq "GM1 label stored" "$(uci -q get wanguard.a.label)" "Дом"
assert_eq "GM1 color stored" "$(uci -q get wanguard.a.color)" "blue"
assert_eq "GM1 description stored" "$(uci -q get wanguard.a.description)" "Main home LAN"
case "$(gm_opts a)" in
	*"option label 'Дом'"*) ok "GM1 committed bytes: label line" ;;
	*)	bad "GM1 committed bytes: label line" "$(gm_opts a)" "*option label 'Дом'*" ;;
esac
case "$(gm_opts a)" in
	*"option color 'blue'"*) ok "GM1 committed bytes: color line" ;;
	*)	bad "GM1 committed bytes: color line" "$(gm_opts a)" "*option color 'blue'*" ;;
esac

# --- GM2: unknown color -> err rc=1, palette named, nothing written ---
reset_router
setup_two_wans
out=$(cli groupset a -color red); rc=$?
assert_contains "GM2 unknown color rejected" "$out" "unknown color: 'red' (palette: blue gray green orange purple)"
assert_rc "GM2 rc=1" "$rc" "1"
assert_eq "GM2 color not written" "$(uci -q get wanguard.a.color)" ""

# --- GM3: empty value clears; missing value errs; repeated flag: last wins ---
reset_router
setup_two_wans
cli groupset a -label 'Temp' >/dev/null
out=$(cli groupset a -label '')
assert_contains "GM3 clear confirmation" "$out" "metadata updated (label cleared)"
assert_eq "GM3 label gone" "$(uci -q get wanguard.a.label)" ""
case "$(gm_opts a)" in
	*option\ label*) bad "GM3 empty option not written" "$(gm_opts a)" "no label line" ;;
	*)	ok "GM3 empty option not written" ;;
esac
out=$(cli groupset a -color)
assert_contains "GM3 missing value errs" "$out" "missing value for '-color'"
out=$(cli groupset a -color blue -color green)
assert_contains "GM3 repeated flag accepted" "$out" "metadata updated (color, color)"
assert_eq "GM3 last value wins" "$(uci -q get wanguard.a.color)" "green"

# --- GM4: unknown flag errs with usage ---
reset_router
setup_two_wans
out=$(cli groupset a -bogus x)
assert_contains "GM4 unknown flag rejected" "$out" "unknown option: '-bogus'"

# --- GM5: legacy target form byte-frozen AND metadata untouched ---
reset_router
setup_two_wans
cli groupset a -label 'Home' -color blue >/dev/null
out=$(cli groupset a wan2); rc=$?
assert_contains "GM5 legacy form message" "$out" "group 'a' updated (direct -> wan2)"
assert_rc "GM5 rc=0 (legacy form incl. trailing apply intact)" "$rc" "0"
assert_eq "GM5 iface flipped" "$(uci -q get wanguard.a.iface)" "wan2"
assert_eq "GM5 label survived the retarget" "$(uci -q get wanguard.a.label)" "Home"
assert_eq "GM5 color survived the retarget" "$(uci -q get wanguard.a.color)" "blue"

# --- GM6: groupmeta rows (all groups sorted, '-' for unset, all types) ---
reset_router
setup_two_wans
add_group p
uci_set p.type proxy
out=$(cli groupmeta)
assert_eq "GM6 unset groups render dashes" "$(printf '%s\n' "$out" | grep '^b')" "b	-	-	-"
assert_eq "GM6 proxy group included" "$(printf '%s\n' "$out" | grep '^p')" "p	-	-	-"
cli groupset a -label 'Дом' -color blue -description 'Main home LAN' >/dev/null
assert_eq "GM6 full row" "$(cli groupmeta a)" "a	Дом	blue	Main home LAN"
assert_eq "GM6 single-group form" "$(cli groupmeta b)" "b	-	-	-"

# --- GM7: groupmeta unknown group -> err rc=1 ---
out=$(cli groupmeta nosuch); rc=$?
assert_contains "GM7 unknown group rejected" "$out" "no such group: 'nosuch'"
assert_rc "GM7 rc=1" "$rc" "1"

echo
echo "== #43: devices TYPE column (hostname heuristic + devtype override) =="
#
# devices gained an ADDITIVE 5th TAB column TYPE. The frozen contract is
# the 4-column prefix — DT4 diffs it byte-wise against the stock sh CLI
# (the F9 differential precedent) on the SAME fixture. The heuristic
# positives below are the full rules table; the override is pinned by
# DT2/DT3 (member `option devtype` > heuristic > generic).

dt_leases() { # one hostname per rule + fallbacks (all offline: no ARP)
	cat > /tmp/dhcp.leases <<'EOF'
1700000001 aa:bb:cc:dd:ee:01 192.168.88.35 watch-hall
1700000002 aa:bb:cc:dd:ee:02 192.168.88.36 dune-hd
1700000003 aa:bb:cc:dd:ee:03 192.168.88.37 ac-livingroom
1700000004 aa:bb:cc:dd:ee:04 192.168.88.38 bosch-fridge
1700000005 aa:bb:cc:dd:ee:05 192.168.88.39 office-pc
1700000006 aa:bb:cc:dd:ee:06 192.168.88.40 laptop-sonia
1700000007 aa:bb:cc:dd:ee:07 192.168.88.41 hp-printer
1700000008 aa:bb:cc:dd:ee:08 192.168.88.42 buddy-052
1700000009 aa:bb:cc:dd:ee:09 192.168.88.43 guest-phone
1700000010 aa:bb:cc:dd:ee:0a 192.168.88.44 iphone-15
1700000011 aa:bb:cc:dd:ee:0b 192.168.88.45 ipad-kids
1700000012 aa:bb:cc:dd:ee:0c 192.168.88.46 tablet-2
1700000013 aa:bb:cc:dd:ee:0d 192.168.88.47 mystery-box
1700000014 aa:bb:cc:dd:ee:0e 192.168.88.48 watchdog-pc
1700000015 11:22:33:44:55:02 192.168.88.49 *
EOF
}

dt_row() { printf '%s\n' "$1" | grep "^$2" | cut -f5; }

# --- DT1: heuristic positives, every type + generic fallbacks ---
reset_router
setup_two_wans
dt_leases
out=$(cli devices)
assert_eq "DT1 watch"        "$(dt_row "$out" aa:bb:cc:dd:ee:01)" "watch"
assert_eq "DT1 tv (dune)"    "$(dt_row "$out" aa:bb:cc:dd:ee:02)" "tv"
assert_eq "DT1 tv (ac-)"     "$(dt_row "$out" aa:bb:cc:dd:ee:03)" "tv"
assert_eq "DT1 tv (bosch)"   "$(dt_row "$out" aa:bb:cc:dd:ee:04)" "tv"
assert_eq "DT1 pc"           "$(dt_row "$out" aa:bb:cc:dd:ee:05)" "pc"
assert_eq "DT1 pc (laptop)"  "$(dt_row "$out" aa:bb:cc:dd:ee:06)" "pc"
assert_eq "DT1 printer"      "$(dt_row "$out" aa:bb:cc:dd:ee:07)" "printer"
assert_eq "DT1 phone (buddy)" "$(dt_row "$out" aa:bb:cc:dd:ee:08)" "phone"
assert_eq "DT1 phone (guest)" "$(dt_row "$out" aa:bb:cc:dd:ee:09)" "phone"
assert_eq "DT1 phone (iphone)" "$(dt_row "$out" aa:bb:cc:dd:ee:0a)" "phone"
assert_eq "DT1 tablet (ipad)" "$(dt_row "$out" aa:bb:cc:dd:ee:0b)" "tablet"
assert_eq "DT1 tablet"        "$(dt_row "$out" aa:bb:cc:dd:ee:0c)" "tablet"
assert_eq "DT1 generic"       "$(dt_row "$out" aa:bb:cc:dd:ee:0d)" "generic"
assert_eq "DT1 watchdog-pc is a pc (not a watch)" "$(dt_row "$out" aa:bb:cc:dd:ee:0e)" "pc"
assert_eq "DT1 '*' name -> generic" "$(dt_row "$out" 11:22:33:44:55:02)" "generic"
assert_contains "DT1 first 4 columns byte-frozen" "$out" "aa:bb:cc:dd:ee:01	192.168.88.35	watch-hall	0	watch"

# --- DT2: member devtype override beats the heuristic; '-' clears it ---
reset_router
setup_two_wans
dt_leases
uci set wanguard.m_05=member
uci set wanguard.m_05.mac='aa:bb:cc:dd:ee:05'
uci set wanguard.m_05.devtype='tv'
uci commit wanguard
assert_eq "DT2 override wins over heuristic" "$(cli devices | cut -f1-5 | grep aa:bb:cc:dd:ee:05 | cut -f5)" "tv"
out=$(cli devset aa:bb:cc:dd:ee:05 -)
assert_contains "DT2 clear confirmation" "$out" "devtype cleared (hostname heuristic applies)"
assert_eq "DT2 cleared -> heuristic again" "$(cli devices | grep aa:bb:cc:dd:ee:05 | cut -f5)" "pc"

# --- DT3: devset validation + write bytes ---
reset_router
setup_two_wans
dt_leases
uci set wanguard.m_0d=member
uci set wanguard.m_0d.mac='aa:bb:cc:dd:ee:0d'
uci commit wanguard
out=$(cli devset aa:bb:cc:dd:ee:0d mystery); rc=$?
assert_contains "DT3 unknown type rejected" "$out" "unknown device type: 'mystery' (types: generic pc phone printer tablet tv watch; '-' clears)"
assert_rc "DT3 rc=1" "$rc" "1"
out=$(cli devset aa:bb:cc:dd:ee:99 tv)
assert_contains "DT3 unregistered mac rejected" "$out" "aa:bb:cc:dd:ee:99 not registered"
out=$(cli devset zz tv)
assert_contains "DT3 invalid mac rejected" "$out" "invalid mac: zz"
out=$(cli devset aa:bb:cc:dd:ee:0d printer)
assert_eq "DT3 set confirmation" "$out" "device aa:bb:cc:dd:ee:0d devtype set: printer"
assert_eq "DT3 devices shows the override" "$(cli devices | grep aa:bb:cc:dd:ee:0d | cut -f5)" "printer"
case "$(grep -A3 "option mac 'aa:bb:cc:dd:ee:0d'" /etc/config/wanguard)" in
	*"option devtype 'printer'"*) ok "DT3 committed bytes: devtype line" ;;
	*)	bad "DT3 committed bytes: devtype line" "$(grep -A3 "option mac 'aa:bb:cc:dd:ee:0d'" /etc/config/wanguard)" "*option devtype 'printer'*" ;;
esac

# --- DT4: the frozen 4-column prefix is byte-identical to the sh CLI ---
reset_router
setup_two_wans
dt_leases
out_uc=$(cli devices | cut -f1-4)
out_sh=$(sh "$SH" devices 2>&1 | cut -f1-4)
assert_eq "DT4 4-column prefix byte-identical to the sh reference" "$out_uc" "$out_sh"
assert_contains "DT4 sanity: sh actually printed rows" "$out_sh" "aa:bb:cc:dd:ee:01	192.168.88.35	watch-hall	0"

echo
echo "== #44/#45: diagnostics data plane (events / syncstatus / diag / inspect / diag-report) =="
#
# The ring and the probes are ucode-only (groupmeta precedent): no sh
# differential here, the surfaces are pinned by stage-5 goldens in the
# contract gate. The ring rows are `ts<TAB>code<TAB>detail`; ts is REAL
# time() (the date stub is irrelevant), so assertions match code/detail.

UBUS_SERVICES=$TMP/ubus.svc
export UBUS_SERVICES

evrow() { awk -F '\t' -v c="$1" -v d="$2" '$2 == c && $3 == d { n++ } END { print n + 0 }' "$WAND/events" 2>/dev/null; }
evcode() { awk -F '\t' -v c="$1" '$2 == c { n++ } END { print n + 0 }' "$WAND/events" 2>/dev/null; }
evn()   { if [ -f "$WAND/events" ]; then wc -l < "$WAND/events"; else echo 0; fi; }

conf_diag() {
	cat > /etc/config/wanguard <<'EOF'
config group 'freedom'
	option type 'direct'
	option iface 'wan1'
	list backup_iface 'wan2'
config group 'proxy'
	option type 'proxy'
config member 'm_d8bbc1cc1771'
	option name 'tower'
	option mac 'd8:bb:c1:cc:17:71'
	option group 'freedom'
EOF
}

diag_leases() {
	cat > /tmp/dhcp.leases <<'EOF'
1700000001 d8:bb:c1:cc:17:71 192.168.88.10 tower
1700000002 aa:bb:cc:dd:ee:99 192.168.88.99 freeloader
1700000003 02:03:04:05:06:07 192.168.88.50 cast-tv
EOF
}

# --- EV1: apply_ok heartbeat — the FIRST of a quiet run only ---
lb_reset
conf_diag
out=$(rapply)
assert_eq "EV1 fresh apply -> applied row" "$(evrow apply_ok applied)" "1"
n1=$(evn)
out=$(rapply)
assert_eq "EV1 quiet apply -> in-sync row" "$(evrow apply_ok in-sync)" "1"
assert_eq "EV1 first heartbeat appended once" "$(evn)" "$((n1 + 1))"
out=$(rapply)
assert_eq "EV1 quiet rerun still one in-sync row" "$(evrow apply_ok in-sync)" "1"
assert_eq "EV1 heartbeat deduped (ring did not grow)" "$(evn)" "$((n1 + 1))"
assert_contains "EV1 apply stdout still exactly in-sync (frozen)" "$out" "in-sync"

# --- EV2: tick failover/failback land in the ring (T9 fixture) ---
reset_router
setup_two_wans
uci_set globals.wan_anchors 'http://a1.example/ping'
tick >/dev/null
echo fail > "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "EV2 failover row" "$(evrow failover 'a>wan2')" "1"
echo 0 > "$WAND/a.lastswitch" # bypass dwell deterministically
rm -f "$WAND/vpn.force"
tick >/dev/null; tick >/dev/null; tick >/dev/null
tick >/dev/null; tick >/dev/null; tick >/dev/null
assert_eq "EV2 failback row" "$(evrow failback 'a>vpn')" "1"

# --- EV3: ring clamps at 200 (FIFO head drop), newest survives ---
reset_router
i=0
while [ $i -lt 250 ]; do
	printf '%s\tinjected\trow%s\n' "$i" "$i" >> "$WAND/events"
	i=$((i + 1))
done
rapply >/dev/null
assert_eq "EV3 ring clamped to 200" "$(evn)" "200"
assert_eq "EV3 head dropped (51 oldest gone)" "$(head -n1 "$WAND/events")" "51	injected	row51"
case "$(tail -n1 "$WAND/events")" in
	*"$(printf 'apply_ok\t')"*) ok "EV3 newest row survived the clamp" ;;
	*) bad "EV3 newest row survived the clamp" "$(tail -n1 "$WAND/events")" "*apply_ok*" ;;
esac

# --- EV4: events tail — default 20, explicit N, silence, usage ---
reset_router
out=$(cli events)
assert_eq "EV4 empty ring is silent" "$out" ""
printf '1000\talpha\tone\n1001\tbeta\ttwo\n1002\tgamma\tthree\n' > "$WAND/events"
out=$(cli events)
assert_eq "EV4 default tail prints the whole (short) ring" "$out" "$(cat "$WAND/events")"
out=$(cli events 2)
assert_eq "EV4 N=2 tail" "$out" "$(printf '1001\tbeta\ttwo\n1002\tgamma\tthree')"
out=$(cli events abc); rc=$?
assert_contains "EV4 non-numeric N rejected" "$out" "usage: wanguard events [N]"
assert_rc "EV4 non-numeric N rc=1" "$rc" "1"

# --- EV5: drift/restored — live edit under an unchanged UCI ---
lb_reset
conf_diag
rapply >/dev/null
printf 'delete element inet wanguard mac_freedom { d8:bb:c1:cc:17:71 }\n' > "$TMP/drift.nft"
rnft -f "$TMP/drift.nft" >/dev/null
out=$(rapply)
assert_eq "EV5 drift detected" "$(evcode drift)" "1"
assert_eq "EV5 drift repaired in the same run" "$(evcode restored)" "1"
assert_contains "EV5 drift detail counts the diff" "$(awk -F '\t' '$2 == "drift"' "$WAND/events")" "nft:1"
assert_contains "EV5 apply stdout still applied (frozen)" "$out" "applied"

# --- EV6: wan-flush -> flush row (detail = the byte-exact event) ---
reset_router
setup_two_wans
echo vpn > "$WAND/a.flush"
echo 198.51.100.10 > "$WAND/vpn.addr"
out=$(flush)
assert_eq "EV6 flush stdout byte-frozen" "$out" "wand:flush:a>vpn(10.99.0.1)"
assert_eq "EV6 flush row" "$(evrow flush 'flush:a>vpn(10.99.0.1)')" "1"

# --- EV7: apply failure -> apply_err row ---
lb_reset
cat > /etc/config/wanguard <<'EOF'
config group 'freedom'
	option type 'direct'
	option iface 'wan1'
config member 'm_bad'
	option mac 'zz:bb:cc:dd:ee:ff'
	option group 'freedom'
EOF
out=$(rapply); rc=$?
assert_contains "EV7 nft -c gate rejects" "$out" "nft check failed"
assert_rc "EV7 rc=1" "$rc" "1"
assert_eq "EV7 apply_err row" "$(evrow apply_err 'nft check failed, nothing applied')" "1"

# --- SS: syncstatus — live probe, exit 0 always ---
lb_reset
conf_diag
out=$(rcli syncstatus); rc=$?
assert_rc "SS1 rc=0 even on drift" "$rc" "0"
assert_eq "SS1 bare system: drift" "$(echo "$out" | sed -n 1p)" "status=drift"
assert_eq "SS1 bare system: no stamp" "$(echo "$out" | sed -n 2p)" "last_apply=-"
assert_eq "SS1 bare system: no age" "$(echo "$out" | sed -n 3p)" "age=-"
rapply >/dev/null
out=$(rcli syncstatus)
assert_eq "SS2 synced: in-sync" "$(echo "$out" | sed -n 1p)" "status=in-sync"
case "$out" in
	*"last_apply=1"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) ok "SS2 last_apply stamped (unix ts)" ;;
	*) bad "SS2 last_apply stamped (unix ts)" "$out" "last_apply=<10 digits>" ;;
esac
case "$out" in
	*"age="[0-9]*) ok "SS2 age in seconds" ;;
	*) bad "SS2 age in seconds" "$out" "age=<digits>" ;;
esac
uci set wanguard.m_new=member
uci set wanguard.m_new.mac='aa:bb:cc:dd:ee:77'
uci set wanguard.m_new.group='freedom'
uci commit wanguard
out=$(rcli syncstatus); rc=$?
assert_eq "SS3 UCI edit -> drift" "$(echo "$out" | sed -n 1p)" "status=drift"
assert_rc "SS3 drift keeps rc=0 (probe, not verdict)" "$rc" "0"
rapply >/dev/null
assert_eq "SS3 apply heals" "$(rcli syncstatus | sed -n 1p)" "status=in-sync"

# --- DG: diag sections (read-only, TAB rows under section headers) ---
lb_reset
conf_diag
rapply >/dev/null
diag_leases
printf 'wanguard=running\nmihomo=running\n' > "$UBUS_SERVICES"
printf '1.5.0-r1\n' > /usr/share/wanguard/version
out=$(rcli diag rules)
assert_contains "DG1 rules header" "$out" "$(printf 'section\trules')"
assert_contains "DG1 our rule visible" "$out" "$(printf '8100:\tfrom all fwmark 0x64 lookup 400')"
assert_contains "DG1 base rules visible (full dump)" "$out" "0:	from all lookup local"
out=$(rcli diag tables)
assert_contains "DG2 slot row" "$out" "$(printf 'slot\tfreedom\tdirect\teth0\tmark=100\ttable=400\tprio=8100')"
assert_contains "DG2 route row" "$out" "$(printf 'route\tfreedom\tdefault dev eth0 ')"
out=$(rcli diag nft)
assert_contains "DG3 table dump" "$out" "table inet wanguard {"
assert_contains "DG3 applied set visible" "$out" "set mac_freedom"
out=$(rcli diag health)
assert_contains "DG4 wanguard service" "$out" "$(printf 'service\twanguard\trunning')"
assert_contains "DG4 mihomo service" "$out" "$(printf 'service\tmihomo\trunning')"
assert_contains "DG4 config valid" "$out" "$(printf 'config\tvalid')"
assert_contains "DG4 version stamp" "$out" "$(printf 'version\t1.5.0-r1')"
uci set wanguard.broken=group
uci set wanguard.broken.type='magic'
uci commit wanguard
assert_contains "DG5 invalid config reported" "$(rcli diag health)" "$(printf 'config\tinvalid')"
assert_contains "DG5 warning row names the group" "$(rcli diag health)" "warning	group 'broken' has no valid type"
out=$(rcli diag bogus); rc=$?
assert_contains "DG6 unknown section rejected" "$out" "unknown diag section: 'bogus'"
assert_rc "DG6 rc=1" "$rc" "1"
uci delete wanguard.broken
uci commit wanguard
before_nft=$(rnft list table inet wanguard)
before_ip="$(rip rule show)
$(rip route show table all)"
rcli diag all >/dev/null
assert_eq "DG7 diag is read-only: nft db untouched" "$(rnft list table inet wanguard)" "$before_nft"
assert_eq "DG7 diag is read-only: ip state untouched" "$(rip rule show)
$(rip route show table all)" "$before_ip"

# --- IN: inspect — configured vs live ---
lb_reset
conf_diag
rapply >/dev/null
diag_leases
out=$(rcli inspect d8:bb:c1:cc:17:71)
assert_contains "IN1 device row" "$out" "$(printf 'device\td8:bb:c1:cc:17:71')"
assert_contains "IN1 lease name" "$out" "$(printf 'name\ttower')"
assert_contains "IN1 lease ip" "$out" "$(printf 'ip\t192.168.88.10')"
assert_contains "IN1 group" "$out" "$(printf 'group\tfreedom')"
assert_contains "IN1 slot: configured vs live" "$out" "$(printf 'slot\tdirect\tmark=100\ttable=400\tprio=8100\tconfigured=wan1\tlive=eth0')"
assert_contains "IN1 set membership (applied)" "$out" "$(printf 'set\tmac_freedom\tmember')"
assert_contains "IN1 live rule of the group" "$out" "$(printf 'rule\tmarking\twg:freedom:m100\thandle=')"
out=$(rcli inspect 192.168.88.50)
assert_contains "IN2 ip resolves to mac" "$out" "$(printf 'mac\t02:03:04:05:06:07')"
assert_contains "IN2 lease hostname" "$out" "$(printf 'name\tcast-tv')"
assert_contains "IN2 ungrouped answer is valid" "$out" "$(printf 'group\t-')"
out=$(rcli inspect cast-tv)
assert_contains "IN2 hostname resolves" "$out" "$(printf 'mac\t02:03:04:05:06:07')"
out=$(rcli inspect nosuchdevice); rc=$?
assert_contains "IN3 unresolvable rejected" "$out" "cannot resolve: 'nosuchdevice'"
assert_rc "IN3 rc=1" "$rc" "1"
# proxy member: Meta link is the live device
uci set wanguard.m_pxy=member
uci set wanguard.m_pxy.mac='aa:bb:cc:dd:ee:99'
uci set wanguard.m_pxy.group='proxy'
uci commit wanguard
rapply >/dev/null
out=$(rcli inspect aa:bb:cc:dd:ee:99)
assert_contains "IN4 proxy slot" "$out" "$(printf 'slot\tproxy\tmark=300\ttable=500\tprio=8000\tconfigured=proxy\tlive=Meta')"
assert_contains "IN4 proxy redir rule live" "$out" "$(printf 'rule\tredir\twg:proxy:r7892\thandle=')"
# direct-lb member: slot lines carry member= + live=
lb_reset
conf_lb2
rapply >/dev/null
out=$(rcli inspect aa:bb:cc:dd:ee:55)
assert_contains "IN5 lb slot: member + live" "$out" "$(printf 'slot\tdirect-lb\tmark=200\ttable=401\tprio=8101\tconfigured=wan1\tmember=wan1\tlive=eth0')"
assert_contains "IN5 lb second slot" "$out" "$(printf 'slot\tdirect-lb\tmark=400\ttable=402\tprio=8102\tconfigured=wan2\tmember=wan2\tlive=eth1')"

# --- DR: diag-report — the secrets-free one-liner for LuCI ---
lb_reset
conf_diag
rapply >/dev/null
diag_leases
printf 'wanguard=running\n' > "$UBUS_SERVICES"
out=$(rcli diag-report)
assert_contains "DR1 report header" "$out" "# wanguard diag-report"
assert_contains "DR1 generated stamp" "$out" "$(printf 'generated\t')"
assert_contains "DR1 sync row" "$out" "sync	in-sync	last_apply="
for s in rules tables nft health devices events; do
	assert_contains "DR1 section $s" "$out" "$(printf "section\t$s")"
done
assert_contains "DR1 members configured-vs-live row" "$out" "$(printf 'member\td8:bb:c1:cc:17:71\ttower\tfreedom\teth0')"
cat > /etc/config/network <<'EOF'
config interface 'wan'
	option proto 'pppoe'
	option password 'SUPERSECRET-PPPOE-PASS'
	list servers 'SUPERSECRET-WG-KEY'
EOF
n_net=$(grep -c 'SUPERSECRET' /etc/config/network || true)
n_rep=$(printf '%s' "$out" | grep -c 'SUPERSECRET' || true)
assert_eq "DR2 sanity: markers ARE planted in /etc/config/network" "$n_net" "2"
assert_eq "DR2 report carries NO secrets" "$n_rep" "0"
rm -f /etc/config/network

rm -f /tmp/dhcp.leases

echo
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$TMP" "$WAND"
[ "$FAIL" = 0 ]
