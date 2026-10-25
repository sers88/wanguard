#!/bin/sh
# C5-edges.sh — edge semantics of the wand path (ucode CLI, live lab):
# 1) black-hole anchor: DROP (not REJECT) on the anchor path — curl must
#    eat the FULL honest 5s timeout (contract `-m 5`), the tick must
#    survive it and count exactly one probe fail (one anchor, one WAN:
#    this is the slow case the router sees on a genuinely dead path);
# 2) N-of-M anchors: wan_reliability=2 of M=3 (anchor aliases .10/.11/.12
#    on wanA — all genuinely reachable via eth0, no fast-fail needed):
#    one anchor dead -> alive=2 >= 2 -> stays up; two dead -> alive=1 < 2
#    -> down after 3 consecutive fails (WAND_FAILS_DOWN);
# 3) override groups never switch: wanmode=override skips the group in
#    the tick even when its WAN dies (down:wan2 event proves ticks ran).
set -u

UG=/usr/bin/wanguard
A=172.30.10.10
A2=172.30.10.11
A3=172.30.10.12
B=172.30.20.10

fail() { echo "C5 FAIL: $1"; exit 1; }
delrule() { while iptables -D OUTPUT "$@" 2>/dev/null; do :; done; }
block()   { iptables -I OUTPUT -d "$1" -p tcp --dport 80 -j "$2" || fail "block $1/$2"; }
unblock() { delrule -d "$1" -p tcp --dport 80 -j DROP; delrule -d "$1" -p tcp --dport 80 -j REJECT; }

FF="eth0:$B eth1:$A"
trap 'for p in $FF; do delrule -o ${p%%:*} -d ${p##*:} -j REJECT; done
	delrule -d $A -p tcp --dport 80 -j DROP
	delrule -d $A2 -p tcp --dport 80 -j REJECT
	delrule -d $A3 -p tcp --dport 80 -j REJECT
	delrule -d $B -p tcp --dport 80 -j REJECT' EXIT

reset_lab() { # $1=reliability; $2=override -> add watched-but-fixed group x
	rm -rf /tmp/wanguard /tmp/.uci # .uci deltas: грабля 7
	cat > /tmp/netifd.json <<'EOF'
{ "wan1": { "up": true, "device": "eth0", "address": "172.30.10.2" },
  "wan2": { "up": true, "device": "eth1", "address": "172.30.20.2" } }
EOF
	{
		echo "config globals 'globals'"
		echo "	option wan_reliability '$1'"
		echo "	list wan_anchors 'http://172.30.10.10/anchor'"
		if [ "$1" = 2 ]; then
			# N-of-M: three anchor aliases on wanA, all honest via eth0
			echo "	list wan_anchors 'http://172.30.10.11/anchor'"
			echo "	list wan_anchors 'http://172.30.10.12/anchor'"
		elif [ "${2:-}" = override ]; then
			# override test needs a second WAN with its own anchor
			echo "	list wan_anchors 'http://172.30.20.10/anchor'"
		fi
		# else: single anchor (black-hole test — no honest side timeouts)
		echo ""
		echo "config group 'a'"
		echo "	option type 'direct'"
		echo "	option iface 'wan1'"
		if [ "${2:-}" = override ]; then
			echo ""
			echo "config group 'x'"
			echo "	option type 'direct'"
			echo "	option iface 'wan2'"
			echo "	option wan_home 'wan2'"
			echo "	option wanmode 'override'"
		fi
	} > /etc/config/wanguard
}

ticks() { out=""; n=0; while [ $n -lt $1 ]; do out="$out$($UG wand-tick 2>&1)"; n=$(( n + 1 )); done; }

echo "== C5: edge cases (black-hole timeout, N-of-M, override)"

# --- 1) black-hole anchor: honest 5s timeout in ONE tick ---------------
reset_lab 1
ticks 1 # seed + warm (fast: the single anchor answers)
$UG apply >/dev/null 2>&1
block $A DROP
t0=$(date +%s)
ticks 1
t1=$(date +%s)
dt=$(( t1 - t0 ))
[ "$dt" -ge 5 ] || fail "black hole: tick took ${dt}s — curl did NOT eat the honest -m 5 timeout"
[ "$dt" -le 9 ] || fail "black hole: tick took ${dt}s — something ignored the -m 5 cap"
[ "$(cat /tmp/wanguard/wan1.fails)" = 1 ] || fail "black hole: wan1.fails=$(cat /tmp/wanguard/wan1.fails) (want exactly 1)"
unblock $A
echo "1) black-hole anchor: one tick took ${dt}s (honest curl -m 5 timeout), wan1.fails=1"

# --- 2) N-of-M: reliability=2 of M=3 -----------------------------------
reset_lab 2
ticks 1
case "$out" in *"seed:a>wan1"*) ;; *) fail "nofm: no seed in '$out'" ;; esac
[ "$(cat /tmp/wanguard/wan1.alive)" = 3 ] || fail "nofm: baseline alive=$(cat /tmp/wanguard/wan1.alive) (want 3)"
block $A2 REJECT
ticks 2
[ "$(cat /tmp/wanguard/wan1.alive)" = 2 ] || fail "nofm: alive=$(cat /tmp/wanguard/wan1.alive) after 1/3 dead (want 2)"
[ "$(cat /tmp/wanguard/wan1.state 2>/dev/null || echo up)" = up ] || fail "nofm: wan1 down with 2/3 alive"
case "$out" in *"down:wan1"*) fail "nofm: spurious down:wan1 with 2/3 alive" ;; esac
echo "2) N-of-M: 1 of 3 anchors dead -> alive=2 >= reliability 2 -> stays up"
block $A3 REJECT
ticks 3
case "$out" in *"down:wan1"*) ;; *) fail "nofm: no down:wan1 with 1/3 alive in '$out'" ;; esac
[ "$(cat /tmp/wanguard/wan1.state)" = down ] || fail "nofm: state=$(cat /tmp/wanguard/wan1.state) (want down)"
unblock $A2; unblock $A3
echo "   N-of-M: 2 of 3 dead -> alive=1 < 2 -> down:wan1 after 3 consecutive fails"

# --- 3) override group never switches ----------------------------------
reset_lab 1 override
for p in $FF; do # only here both WANs are probed: fast-fail wrong pairs
	iptables -I OUTPUT -o ${p%%:*} -d ${p##*:} -j REJECT || fail "fast-fail $p"
done
ticks 1 # seed a>wan1 (x is skipped BEFORE seeding — by design)
case "$out" in *"seed:a>wan1"*) ;; *) fail "override: no seed:a>wan1 in '$out'" ;; esac
case "$out" in *"seed:x"*) fail "override: group x was seeded (must be skipped)" ;; esac
block $B REJECT
ticks 4
case "$out" in
	*"down:wan2"*) ;;
	*) { echo "C5 FAIL: override: no down:wan2 in [$out]"; echo "chain at failure:"; iptables -S OUTPUT; exit 1; } ;;
esac
case "$out" in *"failover:x"*) fail "override: x flipped (failover:x)" ;; esac
case "$out" in *"failback:x"*) fail "override: x flipped (failback:x)" ;; esac
[ "$(uci -q get wanguard.x.iface)" = wan2 ] || fail "override: x.iface=$(uci -q get wanguard.x.iface)"
echo "3) override: down:wan2 seen, group x held wan2, zero x events"

echo "C5-OK (honest 5s black-hole tick, N-of-M 2-of-3, override holds)"
