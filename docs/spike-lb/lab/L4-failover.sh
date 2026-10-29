#!/bin/sh
# L4-failover.sh — SPIKE #27 live battery (host-orchestrated, like L2):
# member failover/failback through the REAL tick path:
#   fixture flip -> wand-tick probes -> down:<member> -> lbover:<g>:<m>><live>
#   -> member_live (UCI) -> apply re-renders the slot table
#   -> wan-flush clears the dead egress NAT (#24) -> fixture back
#   -> OKS_UP -> up:<member> -> lbover back -> slots return to declared.
#
# SCOPE NOTE (honest): pinned-RIDER migration across members (DESIGN §4,
# "pinned flows survive the member death") is a PROD property — public
# WAN IPs, no masquerade: the ct-mark keeps the slot and the slot's table
# now points at the live member's device. In the LAB every anchor lives
# on its own docker bridge, so a flow's dst is only reachable via that
# member's WAN — a moved rider cannot reach its dst no matter what, and
# the #24 flush deliberately kills its NAT binding anyway. What the lab
# CAN and does prove here: the whole control plane (event chain,
# member_live, slot re-render, targeted #24 flush, clean failback,
# zero-alive fail-open stance) and that fresh flows work after recovery.
set -u
LAB=wanguard-lab
CLIENT=wanguard-lab-client
A=203.0.113.10
fail() { echo "L4 FAIL: $1"; exit 1; }
rw() { docker exec $LAB sh -c "$*"; }

config() { # seed the router config: direct witness + lb 70/30
	docker exec -i $LAB sh -c 'cat > /etc/config/wanguard' <<EOF
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://$A/anchor'
	list wan_anchors 'http://198.51.100.10/anchor'

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

fixture() { # $1/$2 = wan1/wan2 up state (true|false); wan3 always up
	docker exec -i $LAB sh -c 'cat > /tmp/netifd.json' <<EOF
{ "wan1": { "up": $1, "device": "eth0", "address": "203.0.113.2" }, "wan2": { "up": $2, "device": "eth1", "address": "198.51.100.2" }, "wan3": { "up": true, "device": "eth2", "address": "192.0.2.2" } }
EOF
}

ticks() { # $1 = N of wand-tick rounds; echo combined event output
	n=1; out=''
	while [ $n -le "$1" ]; do
		out="$out$(rw '/usr/bin/wanguard wand-tick 2>&1' || true)"
		n=$(( n + 1 ))
	done
	printf '%s\n' "$out"
}

# ---------- seed ----------
fixture true true
config
out=$(rw '/usr/bin/wanguard apply 2>&1')
case "$out" in applied*|in-sync) ;; *) fail "seed apply: '$out'" ;; esac
rw 'ip route get 9.9.9.9 mark 200 2>&1' | grep -q 'dev eth0' || fail "baseline: mark 200 not eth0"
rw 'ubus call network.interface.wan1 status 2>&1' | grep -q '"up": true' || fail "baseline: fixture wan1 not up"
ticks 1 >/dev/null   # healthy round: remembers per-wan addr (#24 needs
                     # wan1.addr) and seeds the witness group's wan_home
echo "ok: seed + baseline (mark 200 -> eth0, fixture healthy)"

# ---------- failover: wan1 dies ----------
fixture false true
out=$(ticks 4)
printf '%s' "$out" | grep -q 'down:wan1' || fail "no down:wan1 event: $out"
printf '%s' "$out" | grep -q 'lbover:lb:wan1>wan2' || fail "no lbover:lb:wan1>wan2 event: $out"
live=$(rw 'uci get wanguard.lb.member_live 2>&1')
case "$live" in *'wan2'*) ;; *) fail "member_live not set: '$live'" ;; esac
out=$(rw '/usr/bin/wanguard apply 2>&1')
case "$out" in applied*) ;; *) fail "failover apply: '$out'" ;; esac
out=$(rw '/usr/bin/wanguard wan-flush 2>&1')   # AFTER apply (keepalive order)
case "$out" in *'flush:lb>wan1(203.0.113.2)'*) ;; *) fail "no #24 flush event: '$out'" ;; esac
rw 'ip route show table 401 2>&1' | grep -q '^default dev eth1' || fail "slot 401 not re-rendered to wan2 (eth1)"
rw 'ip route get 9.9.9.9 mark 200 2>&1' | grep -q 'dev eth1' || fail "route get mark 200 still eth0 after failover"
rw 'nft list chain inet wanguard marking' | grep -q 'comment "wg:lb:s70@200"' || fail "marking cascade damaged by failover apply"
rw 'ip route get 9.9.9.9 mark 100 2>&1' | grep -q 'dev eth2' || fail "witness group damaged"
echo "ok: failover (down -> lbover:lb:wan1>wan2 -> slot 401 -> eth1, #24 flush, cascade + witness intact)"

# ---------- failback: wan1 returns ----------
fixture true true
out=$(ticks 7)
printf '%s' "$out" | grep -q 'up:wan1' || fail "no up:wan1 event: $out"
printf '%s' "$out" | grep -q 'lbover:lb:wan1>wan1' || fail "no failback lbover: $out"
out=$(rw '/usr/bin/wanguard apply 2>&1')
case "$out" in applied*|in-sync) ;; *) fail "failback apply: '$out'" ;; esac
rw 'ip route get 9.9.9.9 mark 200 2>&1' | grep -q 'dev eth0' || fail "slot 401 did not return to wan1 (eth0)"
echo "ok: failback (up -> lbover:lb:wan1>wan1 -> slot 401 -> eth0)"

# ---------- fresh flows work again ----------
ok=0
t=0
while [ $t -lt 8 ]; do
	t=$(( t + 1 ))
	if docker exec $CLIENT sh -c "curl -s -m 3 -o /dev/null http://$A/anchor" 2>/dev/null; then
		ok=1
		break
	fi
	docker exec $LAB sh -c 'conntrack -D -s 198.18.0.55 >/dev/null 2>&1; true'
done
[ "$ok" = "1" ] || fail "no successful flow to A after recovery"
echo "ok: fresh flows to A succeed again"

# ---------- zero-alive: slots hold declared (fail-open stance) ----------
fixture false false
out=$(ticks 4)
printf '%s' "$out" | grep -q 'lbover:' && fail "zero-alive emitted a spurious lbover: $out"
live=$(rw 'uci get wanguard.lb.member_live 2>&1')
case "$live" in *'wan1'*) ;; *) fail "zero-alive: member_live lost the declared member: '$live'" ;; esac
rw 'ip route show table 401 2>&1' | grep -q '^default dev eth0' || fail "zero-alive: slot 401 moved off its declared member"
rw 'ip route show table 402 2>&1' | grep -q '^default dev eth1' || fail "zero-alive: slot 402 moved off its declared member"
fixture true true
echo "ok: zero-alive holds declared slots (fail-open stance)"

echo "L4-OK"
