#!/bin/sh
# L5-edges.sh — SPIKE #27 live battery (host-orchestrated): edge shapes
#   (a) MTU asymmetry: wan1 veth at 1436 (PPPoE-ish), 20 MB download
#       through wan1 must survive (PMTUD: router ICMP too-big -> anchor
#       clamps; the marking happens BEFORE any MSS clamp, DESIGN §2)
#   (b) single member: no draw at all (unconditional remainder only),
#       the dropped member's slot (rule/table/ip-rule) cleans precisely
#   (c) three members (wanC joins): buckets 33/33/34 -> cascade cut
#       33 / 66 / remainder, marks 200/400/500, anchor C reachable only
#       via wan3 (outcome <=> mark=500)
#   (d) zero alive: slots hold declared, no spurious lbover; with the
#       dead devices really down, a marked lookup falls through to MAIN
#       (fail-open) — demoed with a live main lane via wanC's gateway
#       (in prod main is the mihomo dial-up lane; in the lab we build an
#       equivalent live lane on the only alive device)
set -u
LAB=wanguard-lab
CLIENT=wanguard-lab-client
A=203.0.113.10
B=198.51.100.10
C=192.0.2.10
SRC=198.18.0.55
fail() { echo "L5 FAIL: $1"; exit 1; }
rw() { docker exec $LAB sh -c "$*"; }
rc() { docker exec $CLIENT sh -c "$*"; }

config() { # $1..$3 = weights (empty arg = member absent)
	mem="	list member_iface 'wan1'"
	wgt="	option weight_wan1 '$1'"
	if [ -n "$2" ]; then
		mem="$mem
	list member_iface 'wan2'"
		wgt="$wgt
	option weight_wan2 '$2'"
	fi
	if [ -n "$3" ]; then
		mem="$mem
	list member_iface 'wan3'"
		wgt="$wgt
	option weight_wan3 '$3'"
	fi
	docker exec -i $LAB sh -c 'cat > /etc/config/wanguard' <<EOF
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://$A/anchor'
	list wan_anchors 'http://$B/anchor'

config group 'a'
	option type 'direct'
	option iface 'wan3'

config group 'lb'
	option type 'direct-lb'
$mem
$wgt

config member
	option mac 'aa:bb:cc:dd:ee:55'
	option group 'lb'
	option name 'client'
EOF
}

fixture() { # $1/$2 = wan1/wan2 up state; wan3 always up
	docker exec -i $LAB sh -c 'cat > /tmp/netifd.json' <<EOF
{ "wan1": { "up": $1, "device": "eth0", "address": "203.0.113.2" }, "wan2": { "up": $2, "device": "eth1", "address": "198.51.100.2" }, "wan3": { "up": true, "device": "eth2", "address": "192.0.2.2" } }
EOF
}

ticks() {
	n=1; out=''
	while [ $n -le "$1" ]; do
		out="$out$(rw '/usr/bin/wanguard wand-tick 2>&1' || true)"
		n=$(( n + 1 ))
	done
	printf '%s\n' "$out"
}

apply_ok() {
	out=$(rw '/usr/bin/wanguard apply 2>&1')
	case "$out" in applied*|in-sync) ;; *) fail "apply: '$out'" ;; esac
}

cthist() { rw "conntrack -L -s $SRC -d $1 2>/dev/null" | grep -o 'mark=[0-9]*' | sort | uniq -c; }

# ---------- (a) MTU asymmetry ----------
fixture true true
config 70 30 ''
apply_ok
rw 'ip link set dev eth0 mtu 1436' || fail "cannot set wan1 mtu"
t0=$(date +%s)
rc 'curl -s -m 60 -o /dev/null -w "%{http_code}" http://'$A'/blob' | grep -q 200 || {
	rw 'ip link set dev eth0 mtu 1500'; fail "20MB download through wan1 (mtu 1436) failed"
}
t1=$(date +%s)
rw 'ip link set dev eth0 mtu 1500'
echo "ok: (a) 20MB through wan1 @mtu1436 ($(( t1 - t0 ))s, PMTUD held)"

# ---------- (b) single member ----------
config 70 '' ''
apply_ok
rw 'nft list chain inet wanguard marking' | grep -q 'comment "wg:lb:s100@200"' || fail "single-member tag s100@200 missing"
rw 'nft list chain inet wanguard marking' | grep 'comment "wg:lb:s100@200"' | grep -q 'numgen' && fail "single member must not draw"
rw 'nft list chain inet wanguard marking' | grep -q 'comment "wg:lb:s100@400"' && fail "dropped member rule survived"
rw 'nft list chain inet wanguard marking' | grep -q 'comment "wg:lb:stick"' || fail "stick lost"
rw 'ip rule show' | grep -q '8102:' && fail "dropped member ip rule 8102 survived"
rw 'ip route show table 402' | grep -q . && fail "dropped member table 402 survived"
rw 'ip route get 9.9.9.9 mark 200 2>&1' | grep -q 'dev eth0' || fail "single slot: mark 200 not eth0"
rw 'conntrack -D -s '$SRC' >/dev/null 2>&1; true'
ok=0; t=0
while [ $t -lt 8 ]; do
	t=$(( t + 1 ))
	rc 'curl -s -m 3 -o /dev/null http://'$A'/anchor' || { rw 'conntrack -D -s '$SRC' >/dev/null 2>&1; true'; continue; }
	ok=$(( ok + 1 ))
done
[ $ok -eq 8 ] || fail "single member: only $ok/8 flows succeeded (all must ride wan1)"
h=$(cthist $A)
case "$h" in *'400'*) fail "single member: a flow left with mark 400: $h" ;; esac
echo "ok: (b) single member (unconditional, slot 402 cleaned, 8/8 flows wan1)"

# ---------- (c) three members ----------
config 33 33 33
apply_ok
rw 'nft list chain inet wanguard marking' | grep -q 'comment "wg:lb:s33@200"' || fail "3-member: tag s33@200 missing"
rw 'nft list chain inet wanguard marking' | grep -q 'comment "wg:lb:s66@400"' || fail "3-member: tag s66@400 missing"
rw 'nft list chain inet wanguard marking' | grep -q 'comment "wg:lb:s100@500"' || fail "3-member: tag s100@500 missing"
h1=$(rw 'nft -a list chain inet wanguard marking' | grep 'comment "wg:lb:s33@200"' | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
h2=$(rw 'nft -a list chain inet wanguard marking' | grep 'comment "wg:lb:s66@400"' | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
h3=$(rw 'nft -a list chain inet wanguard marking' | grep 'comment "wg:lb:s100@500"' | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
[ -n "$h1" ] && [ -n "$h2" ] && [ -n "$h3" ] || fail "3-member: handles unreadable"
[ "$h1" -lt "$h2" ] && [ "$h2" -lt "$h3" ] || fail "3-member cascade order broken: $h1/$h2/$h3"
rw 'nft list chain inet wanguard marking' | grep 'comment "wg:lb:s100@500"' | grep -q 'numgen' && fail "last member must not draw"
rw 'ip route get 9.9.9.9 mark 500 2>&1' | grep -q 'dev eth2' || fail "3-member: mark 500 not eth2"
rw 'conntrack -D -s '$SRC' >/dev/null 2>&1; true'
okC=0; t=0
while [ $t -lt 24 ]; do
	t=$(( t + 1 ))
	rc 'curl -s -m 2 -o /dev/null http://'$C'/anchor' && okC=$(( okC + 1 ))
done
h=$(cthist $C)
m500=$(printf '%s\n' "$h" | grep 'mark=500' | grep -o '[0-9]*' | head -1)
[ -n "$m500" ] || fail "3-member: no flow reached mark 500 (wanC): $h"
[ "$m500" = "$okC" ] || fail "3-member: outcome<->mark mismatch: okC=$okC, mark500=$m500 ($h)"
echo "ok: (c) three members (33/66/remainder cascade, $okC/24 to wanC, outcome==mark500)"

# ---------- (d) zero alive ----------
config 70 30 ''
apply_ok
fixture false false
out=$(ticks 4)
printf '%s' "$out" | grep -q 'lbover:' && fail "zero-alive emitted lbover: $out"
live=$(rw 'uci get wanguard.lb.member_live 2>&1' || true)
rw 'ip link set dev eth0 down' || fail "cannot down wan1"
rw 'ip link set dev eth1 down' || fail "cannot down wan2"
rw 'ip route add default via 192.0.2.1 dev eth2 metric 50' || fail "cannot raise live main lane"
case "$(rw 'ip route get 9.9.9.9 mark 200 2>&1')" in *'dev eth2'*) ;; *) fail "fail-open: marked lookup did not reach the live main lane" ;; esac
case "$(rw 'ip route get 9.9.9.9 mark 400 2>&1')" in *'dev eth2'*) ;; *) fail "fail-open: mark 400 did not reach the live main lane" ;; esac
rw 'ip route del default via 192.0.2.1 dev eth2 metric 50' || true
rw 'ip link set dev eth0 up'
rw 'ip link set dev eth1 up'
fixture true true
echo "ok: (d) zero alive (no lbover, slots stand declared, marked lookups fall through to a live main lane)"

echo "L5-OK"
