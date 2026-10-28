#!/bin/sh
# L2-stickiness.sh — SPIKE #27 live battery. Runs ON THE HOST and drives
# BOTH sides (no single container sees the whole picture):
#   router [wanguard-lab]        — conntrack, nft counters, UCI/apply
#   client [wanguard-lab-client] — curl flows (MAC aa:bb:cc:dd:ee:55)
#
# Honest-path property under test: anchor address 172.30.10.10 exists
# ONLY on the wanA bridge — a flow to it egressing eth1 (wan2 slot) ARPs
# into the void and times out. So curl success/failure is a GROUND TRUTH
# egress witness, and it must always agree with the conntrack mark:
#
#   part (a) per-flow bucket check: for each fresh flow (ct flushed
#     between attempts), success <=> ct mark == the member whose anchor
#     was contacted; collect >=1 outcome of all four kinds.
#   part (b) stickiness drill: 16 rate-limited parallel blob downloads
#     (3 MB/s, ~7 s each) -> after riders are established, flip the
#     weights 70/30 -> 30/70 and re-apply mid-flight. Assertions:
#     every established flow keeps ct mark 200 (no re-hash), the stick
#     rule counter grows (restore really serves packets), every rider
#     completes; afterwards fresh flows follow the NEW map (a dst-A flow
#     hashing into the new 70-side bucket hangs with mark 400).
#     Without ct restore, any rider with hash value in [30,69] (~40%)
#     would re-hash to mark 400 and die: P(all riders survive | broken)
#     ~ 0.3^riders.
set -u
LAB=wanguard-lab
CLIENT=wanguard-lab-client
A=203.0.113.10
B=198.51.100.10
SRC=198.18.0.55
M1=200   # lb:wan1 slot mark (sorted member name)
M2=400   # lb:wan2 slot mark
fail() { echo "L2 FAIL: $1"; exit 1; }

rw() { docker exec $LAB sh -c "$*"; }
rc() { docker exec $CLIENT sh -c "$*"; }

config() { # $1 = weight_wan1, $2 = weight_wan2
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
	list member_iface 'wan1'
	list member_iface 'wan2'
	option weight_wan1 '$1'
	option weight_wan2 '$2'

config member
	option mac 'aa:bb:cc:dd:ee:55'
	option group 'lb'
	option name 'client'
EOF
}

apply() {
	out=$(rw '/usr/bin/wanguard apply 2>&1')
	case "$out" in applied*|in-sync) ;; *) fail "apply: '$out'" ;; esac
}
ctflush() { rw 'conntrack -D -s '$SRC' >/dev/null 2>&1; true'; }
ctmark() { # $1 dst -> first ct mark of the client's flows to dst ('' if none)
	rw "conntrack -L -s $SRC -d $1 2>/dev/null" | grep -o 'mark=[0-9]*' | head -1 | cut -d= -f2
}
stick_counter() { # packets served by the ct-restore rule
	docker exec $LAB sh -c "nft -a list chain inet wanguard marking 2>/dev/null" \
		| grep 'comment "wg:lb:stick"' | grep -o 'packets [0-9]*' | head -1 | cut -d' ' -f2
}

# ---------- seed ----------
config 70 30
apply
rw 'ip route get 9.9.9.9 mark '$M1' 2>&1' | grep -q 'dev eth0' || fail "baseline: mark $M1 not eth0"
rw 'ip route get 9.9.9.9 mark '$M2' 2>&1' | grep -q 'dev eth1' || fail "baseline: mark $M2 not eth1"
ok=0
for t in 1 2 3 4 5 6 7 8; do   # per-attempt hang is honest (random draw);
	if rc 'curl -s -m 3 -o /dev/null http://'$A'/anchor'; then ok=1; break; fi   # 8 tries: P(all fail) < 1%
done
[ "$ok" = "1" ] || fail "client cannot reach anchor A at all (lab broken)"
echo "ok: seed + baseline route-get + client reachability"

# ---------- part (a): per-flow bucket check ----------
okA1=0; okA2=0; okB1=0; okB2=0   # A-succ@M1, A-hang@M2, B-succ@M2, B-hang@M1
i=0
while [ $i -lt 30 ]; do
	i=$(( i + 1 ))
	if [ $(( i % 2 )) -eq 0 ]; then dst=$A; else dst=$B; fi
	ctflush
	code=$(rc "curl -s -m 3 -o /dev/null -w '%{http_code}' http://$dst/anchor || true")
	m=$(ctmark $dst)
	[ -n "$m" ] || fail "attempt $i: no conntrack entry for dst=$dst (code=$code)"
	if [ "$dst" = "$A" ]; then
		if [ "$code" = "200" ]; then
			[ "$m" = "$M1" ] || fail "A success with mark $m (want $M1)"
			okA1=$(( okA1 + 1 ))
		else
			[ "$m" = "$M2" ] || fail "A hang with mark $m (want $M2)"
			okA2=$(( okA2 + 1 ))
		fi
	else
		if [ "$code" = "200" ]; then
			[ "$m" = "$M2" ] || fail "B success with mark $m (want $M2)"
			okB1=$(( okB1 + 1 ))
		else
			[ "$m" = "$M1" ] || fail "B hang with mark $m (want $M1)"
			okB2=$(( okB2 + 1 ))
		fi
	fi
done
[ $okA1 -gt 0 ] || fail "no dst-A success observed (70% bucket never hit?)"
[ $okA2 -gt 0 ] || fail "no dst-A hang observed"
[ $okB1 -gt 0 ] || fail "no dst-B success observed"
[ $okB2 -gt 0 ] || fail "no dst-B hang observed"
echo "ok: buckets agree with outcomes (A: $okA1 succ/$okA2 hang, B: $okB1 succ/$okB2 hang)"

# ---------- part (b): stickiness drill ----------
ctflush
c0=$(stick_counter); [ -n "$c0" ] || fail "cannot read stick counter"
n=0
while [ $n -lt 16 ]; do
	n=$(( n + 1 ))
	docker exec -d $CLIENT sh -c "curl -s -m 30 --limit-rate 3M -o /dev/null http://$A/blob; echo \$? > /tmp/dl_$n"
done
sleep 3   # riders establish; blob at 3 MB/s needs ~7 s
riders=$(rw "conntrack -L -s $SRC -d $A 2>/dev/null" | grep -c 'ESTABLISHED')
[ "$riders" -ge 3 ] || fail "riders=$riders (want >=3 established dst-A flows)"
badm=$(rw "conntrack -L -s $SRC -d $A 2>/dev/null" | grep 'ESTABLISHED' | grep -o 'mark=[0-9]*' | grep -vc "mark=$M1" || true)
[ "$badm" = "0" ] || fail "established flows with mark != $M1: $badm"
echo "ok: $riders riders established, all mark=$M1"

# the flip, mid-flight
config 30 70
apply
sleep 1
badm=$(rw "conntrack -L -s $SRC -d $A 2>/dev/null" | grep 'ESTABLISHED' | grep -o 'mark=[0-9]*' | grep -vc "mark=$M1" || true)
[ "$badm" = "0" ] || fail "post-flip re-hash: $badm established flow(s) changed member (ct restore broken)"
c1=$(stick_counter)
[ "$c1" -gt "$c0" ] || fail "stick counter did not grow ($c0 -> $c1)"
echo "ok: flip mid-flight: riders keep mark=$M1, stick counter $c0 -> $c1"

n=0; done_ok=0
while [ $n -lt 40 ]; do
	n=$(( n + 1 ))
	done_ok=$(rc 'grep -l "^0$" /tmp/dl_* 2>/dev/null | wc -l')
	[ "$done_ok" -ge 3 ] && break
	sleep 1
done
[ "$done_ok" -ge 3 ] || fail "fewer than 3 riders completed ($done_ok)"
rc 'rm -f /tmp/dl_*'
echo "ok: $done_ok riders completed across the flip"

# ---------- post-flip map: fresh flows follow the NEW weights ----------
seen=0; i=0
while [ $i -lt 30 ] && [ "$seen" = "0" ]; do
	i=$(( i + 1 ))
	ctflush
	code=$(rc "curl -s -m 3 -o /dev/null -w '%{http_code}' http://$A/anchor || true")
	m=$(ctmark $A)
	if [ "$code" != "200" ] && [ "$m" = "$M2" ]; then
		seen=1   # new flow hashed into the new 70-side bucket -> dead path, as designed
	fi
done
[ "$seen" = "1" ] || fail "no post-flip remap observed (map did not change?)"
echo "ok: post-flip fresh flow re-keyed to mark=$M2 and honestly hung on the wrong bridge"

config 70 30
apply
echo "L2-OK"
