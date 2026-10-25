#!/bin/sh
# C2-failover.sh ? live failover/failback drill (issue #29 acceptance):
# real ubus (fake-netifd), real curl probes against local anchors, real
# UCI flips, real nft + policy-routing render via apply (NET_ADMIN).
# "wan1 down" = container-local REJECT of anchor A (fast fail, like a
# dead path); the deep check is that table 400's default route dev
# actually flips eth0 -> eth1 and back.
set -u

UG=/usr/bin/wanguard
SHG=/usr/bin/wanguard-sh
ANCHOR_A=172.30.10.10

fail() { echo "C2 FAIL: $1"; exit 1; }
rules() { iptables -L OUTPUT -n 2>/dev/null | grep -c REJECT; }
block_a()  { iptables -I OUTPUT -d $ANCHOR_A -j REJECT || fail "iptables -I failed"; }
unblock_a(){ iptables -D OUTPUT -d $ANCHOR_A -j REJECT || fail "iptables -D failed"; }
trap 'iptables -D OUTPUT -d '"$ANCHOR_A"' -j REJECT 2>/dev/null' EXIT

reset_lab() {
	rm -rf /tmp/wanguard /tmp/.uci
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://172.30.10.10/anchor'
	list wan_anchors 'http://172.30.20.10/anchor'

config group 'a'
	option type 'direct'
	option iface 'wan1'
	list mac 'aa:bb:cc:dd:ee:01'

config group 'b'
	option type 'direct'
	option iface 'wan2'
EOF
}

echo "== C2: live failover drill (ucode CLI, kernel-backed checks)"
reset_lab
out=$($UG wand-tick 2>&1) # seed (probe fails are fine; force not needed)
out=$($UG wand-tick 2>&1) # oks accumulate
out=$($UG apply 2>&1); case "$out" in in-sync|applied*) ;; *) fail "initial apply: '$out'" ;; esac

rt0=$(ip route show table 400 2>/dev/null | grep '^default')
case "$rt0" in *"dev eth0"*) ;; *) fail "table 400 initial route '$rt0' (want dev eth0)" ;; esac
nft list table inet wanguard | grep -q "wg:a" || fail "wg:a rules missing"
echo "baseline: table400='$rt0', wg:a rules present"

CYCLES=${CYCLES:-5}
i=0
while [ $i -lt $CYCLES ]; do
	i=$(( i + 1 ))

	block_a
	echo 0 > /tmp/wanguard/a.lastswitch # test determinism: skip the 60s
	                                    # dwell (same trick as T9 in the
	                                    # sh suite); the real watchdog
	                                    # rate-limits switches — c2 proved
	                                    # that live: down without flip
	out=""; n=0
	while [ $n -lt 4 ]; do out="$out$($UG wand-tick 2>&1)"; n=$(( n + 1 )); done
	case "$out" in *"down:wan1"*) ;; *) fail "c$i: no down:wan1 in '$out'" ;; esac
	case "$out" in *"failover:a>wan2"*) ;; *) fail "c$i: no failover:a>wan2 in '$out'" ;; esac
	[ "$(uci -q get wanguard.a.iface)" = wan2 ] || fail "c$i: a.iface=$(uci -q get wanguard.a.iface)"
	out=$($UG apply 2>&1); case "$out" in in-sync|applied*) ;; *) fail "c$i: apply after failover: '$out'" ;; esac
	rt=$(ip route show table 400 | grep '^default')
	case "$rt" in *"dev eth1"*) ;; *) fail "c$i: table400 after failover '$rt' (want dev eth1)" ;; esac
	echo "c$i: failover ok ($rt)"

	unblock_a
	echo 0 > /tmp/wanguard/a.lastswitch
	out=""; n=0
	while [ $n -lt 7 ]; do out="$out$($UG wand-tick 2>&1)"; n=$(( n + 1 )); done
	echo "  (post-failback: rules=$(rules) wan1.alive=$(cat /tmp/wanguard/wan1.alive 2>/dev/null))"
	case "$out" in *"failback:a>wan1"*) ;; *) fail "c$i: no failback:a>wan1 in '$out'" ;; esac
	[ "$(uci -q get wanguard.a.iface)" = wan1 ] || fail "c$i: a.iface=$(uci -q get wanguard.a.iface)"
	out=$($UG apply 2>&1); case "$out" in in-sync|applied*) ;; *) fail "c$i: apply after failback: '$out'" ;; esac
	rt=$(ip route show table 400 | grep '^default')
	case "$rt" in *"dev eth0"*) ;; *) fail "c$i: table400 after failback '$rt' (want dev eth0)" ;; esac
	echo "c$i: failback ok ($rt)"
done

# one sh-CLI cycle against the same live bus for parity
reset_lab
$SHG wand-tick >/dev/null 2>&1; $SHG wand-tick >/dev/null 2>&1
block_a
out=""; n=0
while [ $n -lt 4 ]; do out="$out$($SHG wand-tick 2>&1)"; n=$(( n + 1 )); done
unblock_a
case "$out" in *"failover:a>wan2"*) echo "sh live failover: ok" ;; *) fail "sh live failover: '$out'" ;; esac

# invariants
grep -q "wan_home" /etc/config/wanguard || fail "wan_home never seeded"
$UG apply >/dev/null 2>&1
nft list table inet wanguard | grep -q "wg:b" || fail "wg:b rules missing"
echo "C2-OK ($CYCLES ucode live cycles + 1 sh parity cycle)"
