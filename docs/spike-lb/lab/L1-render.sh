#!/bin/sh
# L1-render.sh — SPIKE #27 render battery (kernel-backed, no mocks):
# render/idempotency/minimal-diff/orphan-cleanup of the direct-lb group.
# Layout of the seeded config (see setup.sh): group 'a' (direct, wan3,
# regression witness) + group 'lb' (direct-lb, members wan1/wan2 70/30,
# client MAC aa:bb:cc:dd:ee:55).
#
# Allocation the battery pins (slots keyed by SORTED member name):
#   a:wan3        mark 100 table 400 prio 8100 (direct, byte-identical
#                 to the pre-spike shape)
#   lb:wan1       mark 200 table 401 prio 8101
#   lb:wan2       mark 400 table 402 prio 8102   (300 = mihomo, skipped)
# Hash rule tag encodes the map: wg:lb:j100:70@200:30@400
set -u
UG=/usr/bin/wanguard
fail() { echo "L1 FAIL: $1"; exit 1; }

MARKING='nft -a list chain inet wanguard marking'
reset_lab() {
	rm -rf /tmp/wanguard /tmp/.uci
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://172.30.10.10/anchor'
	list wan_anchors 'http://172.30.20.10/anchor'

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

snap_state() { # ip-side state that a WEIGHT change must NOT touch
	{ ip rule show; ip route show table 400; ip route show table 401;
	  ip route show table 402; nft list set inet wanguard mac_lb; } 2>/dev/null
}

reset_lab
out=$($UG apply 2>&1)
case "$out" in applied*|in-sync) ;; *) fail "first apply: '$out'" ;; esac # state may already
out=$($UG apply 2>&1); case "$out" in in-sync) ;; *) fail "second apply: '$out' (want in-sync)" ;; esac # be in-sync
echo "ok: applied -> in-sync"

# --- chain content: witness group + stick + hash rules with exact tags ---
$MARKING | grep -q 'comment "wg:a:m100"' || fail "witness rule wg:a:m100 missing"
st=$($MARKING | grep 'comment "wg:lb:stick"')
[ -n "$st" ] || fail "stick rule missing"
case "$st" in *'ct mark != 0'*'meta mark set ct mark return'*) ;; *) fail "stick body wrong: $st" ;; esac
r1=$($MARKING | grep 'comment "wg:lb:s70@200"')
r2=$($MARKING | grep 'comment "wg:lb:s100@400"')
[ -n "$r1" ] || fail "member rule missing (tag wg:lb:s70@200)"
[ -n "$r2" ] || fail "member rule missing (tag wg:lb:s100@400)"
# NB: cascade — rule 1 draws `numgen random mod 100 < 70`, the LAST
# member is the unconditional remainder (no draw; also sidesteps nft's
# "< 100 exceeds valid range" rejection). mark VALUES are verified
# behaviorally below (route get per mark), never by text
case "$r1" in *'numgen random mod 100 < 70'*) ;; *) fail "member rule 1 body wrong: $r1" ;; esac
case "$r2" in *'numgen'*) fail "last member must be the unconditional remainder: $r2" ;; esac
# session-2 live finding: a member rule WITHOUT a verdict does not stop
# traversal — the unconditional last rule overwrote every earlier mark
# and 100% of flows funneled into the last member. The return is what
# makes the cascade a cascade.
case "$r1" in *'ct mark set meta mark return'*) ;; *) fail "member rule 1 must end with return (cascade verdict): $r1" ;; esac
case "$r2" in *'ct mark set meta mark return'*) ;; *) fail "member rule 2 must end with return: $r2" ;; esac
case "$r1$r2" in *'ct mark set meta mark'*) ;; *) fail "ct pin missing" ;; esac
h1=$(printf '%s' "$st" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
h2=$(printf '%s' "$r1" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
[ -n "$h1" ] && [ -n "$h2" ] || fail "handles not readable"
[ "$h1" -lt "$h2" ] || fail "stick (handle $h1) must precede member rules ($h2)"
# session-2 live finding #2: the cascade is ORDER-SENSITIVE. The tag-diff
# appends a replaced member rule at the chain END — after the
# unconditional remainder — which silently funneled every flow into the
# last member. The draw rule must precede the remainder, always.
h3=$(printf '%s' "$r2" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
[ -n "$h3" ] || fail "handle not readable (member 2)"
[ "$h2" -lt "$h3" ] || fail "cascade order broken: draw rule ($h2) must precede the unconditional remainder ($h3)"
echo "ok: stick($h1) + numgen cascade($h2+), draw before remainder($h3)"

# --- sets ---
nft list set inet wanguard mac_lb | grep -q 'aa:bb:cc:dd:ee:55' || fail "mac_lb missing the client MAC"
nft list set inet wanguard mac_a >/dev/null 2>&1 || fail "mac_a missing"
echo "ok: mac sets"

# --- ip rules + tables per slot ---
ip rule show | grep -q '8100:.*fwmark 0x64.*lookup 400' || fail "ip rule a (8100/0x64/400) missing"
ip rule show | grep -q '8101:.*fwmark 0xc8.*lookup 401' || fail "ip rule lb:wan1 (8101/0xc8/401) missing"
ip rule show | grep -q '8102:.*fwmark 0x190.*lookup 402' || fail "ip rule lb:wan2 (8102/0x190/402) missing"
for t in 400 401 402; do
	rt=$(ip route show table $t | grep '^default')
	case "$rt" in *' metric 200'*) ;; *) fail "table $t: no metric-200 fallback ($rt)" ;; esac
done
case "$(ip route show table 400 | grep '^default')" in *'dev eth2'*) ;; *) fail "table 400 dev (want eth2)" ;; esac
case "$(ip route show table 401 | grep '^default')" in *'dev eth0'*) ;; *) fail "table 401 dev (want eth0)" ;; esac
case "$(ip route show table 402 | grep '^default')" in *'dev eth1'*) ;; *) fail "table 402 dev (want eth1)" ;; esac
echo "ok: ip rules + per-slot tables (400/eth2, 401/eth0, 402/eth1)"

# --- policy lookup per mark (the #13 route-get contract, per slot) ---
case "$(ip route get 9.9.9.9 mark 100 2>&1)" in *'dev eth2'*) ;; *) fail "route get mark 100 (want eth2)" ;; esac
case "$(ip route get 9.9.9.9 mark 200 2>&1)" in *'dev eth0'*) ;; *) fail "route get mark 200 (want eth0)" ;; esac
case "$(ip route get 9.9.9.9 mark 400 2>&1)" in *'dev eth1'*) ;; *) fail "route get mark 400 (want eth1)" ;; esac
echo "ok: route get per mark 100/200/400 -> eth2/eth0/eth1"

# --- minimal diff: weight flip replaces ONLY the hash rule ---
before=$(snap_state)
uci set wanguard.lb.weight_wan1='30'
uci set wanguard.lb.weight_wan2='70'
uci commit wanguard
out=$($UG apply 2>&1); case "$out" in applied*) ;; *) fail "apply after weight flip: '$out'" ;; esac
$MARKING | grep -q 'comment "wg:lb:s30@200"' || fail "new member tag s30@200 missing after flip"
$MARKING | grep -q 'comment "wg:lb:s100@400"' || fail "member tag s100@400 missing after flip"
$MARKING | grep -q 'comment "wg:lb:s70@200"' && fail "old member tag s70@200 survived"
$MARKING | grep -q 'comment "wg:lb:stick"' || fail "stick rule lost by weight flip"
# post-flip cascade order (the exact place the append bug manifested):
# the re-added draw rule (s30@200) must sit BEFORE the remainder (s100)
pf1=$($MARKING | grep 'comment "wg:lb:s30@200"' | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
pf2=$($MARKING | grep 'comment "wg:lb:s100@400"' | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
[ -n "$pf1" ] && [ -n "$pf2" ] || fail "post-flip handles unreadable"
[ "$pf1" -lt "$pf2" ] || fail "post-flip cascade order broken (append bug): draw($pf1) must precede remainder($pf2)"
[ -z "$(nft -a list chain inet wanguard redir 2>/dev/null | grep 'wg:')" ] || fail "unexpected redir rules"
after=$(snap_state)
[ "$before" = "$after" ] || fail "weight flip moved ip-side state (must be nft-only)"
out=$($UG apply 2>&1); case "$out" in in-sync) ;; *) fail "post-flip apply: '$out'" ;; esac
echo "ok: weight flip = hash-rule swap only (ip side untouched)"
uci set wanguard.lb.weight_wan1='70'
uci set wanguard.lb.weight_wan2='30'
uci commit wanguard
$UG apply >/dev/null 2>&1

# --- grouplist shows the slots ---
gl=$($UG grouplist 2>&1)
printf '%s\n' "$gl" | grep -q 'lb.*direct-lb.*wan1.*200.*401' || fail "grouplist: lb:wan1 row missing: $gl"
printf '%s\n' "$gl" | grep -q 'lb.*direct-lb.*wan2.*400.*402' || fail "grouplist: lb:wan2 row missing: $gl"
echo "ok: grouplist slots"

# --- orphan cleanup: groupdel lb must remove slots, keep witness ---
uci delete wanguard.lb
uci commit wanguard
out=$($UG apply 2>&1); case "$out" in applied*) ;; *) fail "apply after lb delete: '$out'" ;; esac
$MARKING | grep -q 'comment "wg:lb:' && fail "lb rules survived groupdel"
nft list chain inet wanguard lb_lb >/dev/null 2>&1 && fail "sub-chain lb_lb survived groupdel"
nft list set inet wanguard mac_lb >/dev/null 2>&1 && fail "mac_lb survived groupdel"
ip rule show | grep -qE '810[12]:' && fail "lb ip rules survived groupdel"
ip route show table 401 | grep -q . && fail "table 401 survived groupdel"
ip route show table 402 | grep -q . && fail "table 402 survived groupdel"
$MARKING | grep -q 'comment "wg:a:m100"' || fail "witness group damaged by lb cleanup"
case "$(ip route show table 400 | grep '^default')" in *'dev eth2'*) ;; *) fail "witness table damaged" ;; esac
out=$($UG apply 2>&1); case "$out" in in-sync) ;; *) fail "post-delete apply: '$out'" ;; esac
echo "ok: orphan cleanup precise (lb slots gone, witness intact)"

# reseed for L2
reset_lab
$UG apply >/dev/null 2>&1
echo "L1-OK"
