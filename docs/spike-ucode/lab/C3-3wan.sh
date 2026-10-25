#!/bin/sh
# C3-3wan.sh — live 3-WAN re-failover drill (#26) in the Docker lab:
# group 'a' (home wan1) walks its explicit `list backup_iface` order
# wan1 -> wan3 -> (wan3 dies too) -> wan2, then failbacks when wan1
# recovers. Real bus (real ubusd + fake-netifd), real curl probes, real
# UCI flips, real nft + policy-routing render (NET_ADMIN). Third WAN:
# eth2 = wanC 172.30.30.2/24, anchor C 172.30.30.10 (topology wired by
# lab-up.sh net + up).
#
# Fast-fail: probing a wrong-path anchor (device/anchor mismatch — a lab
# artifact, docker bridges are isolated) would eat an HONEST 5s curl
# timeout per pair, per tick; we REJECT those pairs instantly instead so
# the drill runs in seconds. The probes stay live (real curl children,
# really dead paths); the honest 5s timeout itself is proven in C5.
set -u

UG=/usr/bin/wanguard
SHG=/usr/bin/wanguard-sh
A=172.30.10.10
B=172.30.20.10
C=172.30.30.10

fail() { echo "C3 FAIL: $1"; exit 1; }

# exact-spec helpers: deletion matches the FULL rule spec, so block rules
# (tcp/80 only) never eat fast-fail rules (all-protocol) and vice versa
delrule() { while iptables -D OUTPUT "$@" 2>/dev/null; do :; done; }
block()   { iptables -I OUTPUT -d "$1" -p tcp --dport 80 -j REJECT || fail "block $1"; }
unblock() { delrule -d "$1" -p tcp --dport 80 -j REJECT; }

# fast-fail matrix: every (device, anchor) pair EXCEPT the right ones
FF="eth0:$B eth0:$C eth1:$A eth1:$C eth2:$A eth2:$B"
for p in $FF; do
	iptables -I OUTPUT -o ${p%%:*} -d ${p##*:} -j REJECT || fail "fast-fail $p"
done
trap 'for p in $FF; do delrule -o ${p%%:*} -d ${p##*:} -j REJECT; done
	delrule -d $A -p tcp --dport 80 -j REJECT
	delrule -d $B -p tcp --dport 80 -j REJECT
	delrule -d $C -p tcp --dport 80 -j REJECT' EXIT

reset_lab() {
	rm -rf /tmp/wanguard /tmp/.uci # .uci deltas: грабля 7
	cat > /tmp/netifd.json <<'EOF'
{ "wan1": { "up": true, "device": "eth0", "address": "172.30.10.2" },
  "wan2": { "up": true, "device": "eth1", "address": "172.30.20.2" },
  "wan3": { "up": true, "device": "eth2", "address": "172.30.30.2" } }
EOF
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://172.30.10.10/anchor'
	list wan_anchors 'http://172.30.20.10/anchor'
	list wan_anchors 'http://172.30.30.10/anchor'

config group 'a'
	option type 'direct'
	option iface 'wan1'
	list backup_iface 'wan3'
	list backup_iface 'wan2'

config group 'b'
	option type 'direct'
	option iface 'wan2'

config group 'c'
	option type 'direct'
	option iface 'wan3'
	option wanmode 'override'
EOF
}

ticks() { # $1=count -> $out accumulates
	out=""; n=0
	while [ $n -lt $1 ]; do out="$out$($UG wand-tick 2>&1)"; n=$(( n + 1 )); done
}

echo "== C3: live 3-WAN re-failover drill (ucode CLI, #26 backup order)"

# prereqs: third WAN wired (host: docker network wanC + connects)
ip -4 addr show dev eth2 2>/dev/null | grep -q 172.30.30.2 || \
	fail "eth2/172.30.30.2 missing — wire wanC first (lab-up.sh up)"
curl --interface eth2 -m 5 -sf -o /dev/null http://$C/anchor || \
	fail "anchor C unreachable via eth2"

# group c is override: wan3 stays WATCHED (homes+ifaces of direct groups)
# but never switches — keeps the drill focused on group a's backup order
reset_lab
ticks 1 # seed homes (a>wan1, b>wan2) + warm probes
case "$out" in *"seed:a>wan1"*) ;; *) fail "no seed:a>wan1 in '$out'" ;; esac
$UG apply >/dev/null 2>&1
rt=$(ip route show table 400 2>/dev/null | grep '^default')
case "$rt" in *"dev eth0"*) ;; *) fail "baseline table400 '$rt' (want dev eth0)" ;; esac
nft list table inet wanguard | grep -q "wg:a" || fail "wg:a rules missing"
echo "baseline: a on wan1 (table400 dev eth0), backup_iface = wan3,wan2"

# --- phase 1: wan1 dies -> failover to the FIRST backup in the list ---
block $A
echo 0 > /tmp/wanguard/a.lastswitch # skip the 60s dwell (T9 trick)
ticks 3
case "$out" in *"down:wan1"*) ;; *) fail "p1: no down:wan1 in '$out'" ;; esac
case "$out" in *"failover:a>wan3"*) ;; *) fail "p1: no failover:a>wan3 in '$out'" ;; esac
case "$out" in *"failover:a>wan2"*) fail "p1: picked wan2 — backup_iface order ignored" ;; esac
[ "$(uci -q get wanguard.a.iface)" = wan3 ] || fail "p1: a.iface=$(uci -q get wanguard.a.iface)"
o=$($UG apply 2>&1); case "$o" in in-sync|applied*) ;; *) fail "p1 apply: '$o'" ;; esac
rt=$(ip route show table 400 | grep '^default')
case "$rt" in *"dev eth2"*) ;; *) fail "p1: table400 '$rt' (want dev eth2)" ;; esac
o=$($UG wan-flush 2>&1)
case "$o" in *"flush:a>wan1("*) ;; *) fail "p1 wan-flush: '$o'" ;; esac
echo "p1: wan1 dead -> failover a>wan3 (list order), table400 dev eth2"

# --- phase 2: wan3 dies too -> #26 RE-failover to the next backup ---
block $C
echo 0 > /tmp/wanguard/a.lastswitch
ticks 3
case "$out" in *"down:wan3"*) ;; *) fail "p2: no down:wan3 in '$out'" ;; esac
case "$out" in *"failover:a>wan2"*) ;; *) fail "p2: no RE-failover a>wan2 in '$out'" ;; esac
[ "$(uci -q get wanguard.a.iface)" = wan2 ] || fail "p2: a.iface=$(uci -q get wanguard.a.iface)"
o=$($UG apply 2>&1); case "$o" in in-sync|applied*) ;; *) fail "p2 apply: '$o'" ;; esac
rt=$(ip route show table 400 | grep '^default')
case "$rt" in *"dev eth1"*) ;; *) fail "p2: table400 '$rt' (want dev eth1)" ;; esac
o=$($UG wan-flush 2>&1)
case "$o" in *"flush:a>wan3("*) ;; *) fail "p2 wan-flush: '$o'" ;; esac
echo "p2: wan3 dead -> RE-failover a>wan2 (#26), table400 dev eth1"

# --- phase 3: wan1 recovers -> failback (wan3 stays dead) ---
unblock $A
echo 0 > /tmp/wanguard/a.lastswitch
ticks 7 # 6 consecutive oks flip wan1 up on the 6th tick (+1 safety)
case "$out" in *"up:wan1"*) ;; *) fail "p3: no up:wan1 in '$out'" ;; esac
case "$out" in *"failback:a>wan1"*) ;; *) fail "p3: no failback:a>wan1 in '$out'" ;; esac
[ "$(uci -q get wanguard.a.iface)" = wan1 ] || fail "p3: a.iface=$(uci -q get wanguard.a.iface)"
o=$($UG apply 2>&1); case "$o" in in-sync|applied*) ;; *) fail "p3 apply: '$o'" ;; esac
rt=$(ip route show table 400 | grep '^default')
case "$rt" in *"dev eth0"*) ;; *) fail "p3: table400 '$rt' (want dev eth0)" ;; esac
o=$($UG wan-flush 2>&1)
case "$o" in *"flush:a>wan2("*) ;; *) fail "p3 wan-flush: '$o'" ;; esac
echo "p3: wan1 recovered -> failback a>wan1, table400 dev eth0"

# --- sh parity: stock sh CLI must honor the same backup-list order ---
unblock $C # sh section needs the fresh baseline: wan3 alive again
reset_lab
$SHG wand-tick >/dev/null 2>&1 # seed
block $A
out=""; n=0
while [ $n -lt 3 ]; do out="$out$($SHG wand-tick 2>&1)"; n=$(( n + 1 )); done
unblock $A
case "$out" in *"failover:a>wan3"*) ;; *) fail "sh: no failover:a>wan3 in '$out'" ;; esac
[ "$(uci -q get wanguard.a.iface)" = wan3 ] || fail "sh: a.iface=$(uci -q get wanguard.a.iface)"
echo "sh live failover: ok (a>wan3, list order honored)"

$UG apply >/dev/null 2>&1
nft list table inet wanguard | grep -q "wg:b" || fail "wg:b rules missing"
echo "C3-OK (live wan1->wan3->wan2->wan1 + sh parity)"
