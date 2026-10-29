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
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$TMP" "$WAND"
[ "$FAIL" = 0 ]
