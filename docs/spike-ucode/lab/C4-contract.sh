#!/bin/sh
# C4-contract.sh — the keepalive contract under the ucode CLI:
# 1) the UNMODIFIED keepalive loop body (router/wanguard-keepalive lines
#    17-22: wand-tick -> apply -> wan-flush, output-driven logging) run
#    x100 through /usr/bin/wanguard — logger captured to a file instead
#    of syslog, sleep elided (the contract under test is the output
#    protocol, not the timer);
# 2) byte-parity of the machine-parsed outputs (list/grouplist/wanstatus/
#    devices — what LuCI and keepalive actually parse) between the ucode
#    CLI and the stock sh CLI on IDENTICAL state, exit codes included.
set -u

UG=/usr/bin/wanguard
SHG=/usr/bin/wanguard-sh
A=172.30.10.10
B=172.30.20.10
ITER=100

fail() { echo "C4 FAIL: $1"; exit 1; }

delrule() { while iptables -D OUTPUT "$@" 2>/dev/null; do :; done; }
# fast-fail for wrong-path anchor pairs (lab artifact — see C3 header):
# keeps every tick live (real curl) and fast (no honest 5s timeouts)
FF="eth0:$B eth1:$A"
for p in $FF; do
	iptables -I OUTPUT -o ${p%%:*} -d ${p##*:} -j REJECT || fail "fast-fail $p"
done
trap 'for p in $FF; do delrule -o ${p%%:*} -d ${p##*:} -j REJECT; done' EXIT

reset_lab() {
	rm -rf /tmp/wanguard /tmp/.uci # .uci deltas: грабля 7
	cat > /tmp/netifd.json <<'EOF'
{ "wan1": { "up": true, "device": "eth0", "address": "172.30.10.2" },
  "wan2": { "up": true, "device": "eth1", "address": "172.30.20.2" } }
EOF
	cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://172.30.10.10/anchor'
	list wan_anchors 'http://172.30.20.10/anchor'

config group 'a'
	option type 'direct'
	option iface 'wan1'
	list mac 'aa:bb:cc:dd:ee:01'
	list mac 'aa:bb:cc:dd:ee:02'

config group 'b'
	option type 'direct'
	option iface 'wan2'
	list mac 'aa:bb:cc:dd:ee:03'
EOF
	# dhcp.leases fixture (dnsmasq shape: expiry mac ip name) for `devices`:
	# valid rows, an invalid mac, a "*" name, an uppercase mac, a duplicate
	cat > /tmp/dhcp.leases <<'EOF'
1792900000 aa:bb:cc:dd:ee:01 192.168.1.10 alpha
1792900000 aa:bb:cc:dd:ee:03 192.168.1.11 *
1792900000 aa:bb:cc:dd:ee:09 192.168.1.12 not-a-mac
1792900000 aa:BB:cc:dd:ee:02 192.168.1.13 upper
1792900000 aa:bb:cc:dd:ee:01 192.168.1.10 alpha-dup
EOF
}

echo "== C4: keepalive x100 (unmodified loop body, ucode CLI) + byte-parity"
reset_lab

# --- 1) keepalive loop x100: lines 17-22 of router/wanguard-keepalive ---
LOG=/tmp/c4-keepalive.log
: > $LOG
i=0; spoke=0; applied_seen=0; insync_seen=0
while [ $i -lt $ITER ]; do
	i=$(( i + 1 ))
	wout=$($UG wand-tick 2>&1) || fail "iter $i: wand-tick rc=$?"
	[ -n "$wout" ] && { echo "wanguard-wand: $wout" >> $LOG; spoke=$(( spoke + 1 )); }
	out=$($UG apply 2>&1) || fail "iter $i: apply rc=$? ('$out')"
	case "$out" in in-sync) ;; *) echo "wanguard-keepalive: $out" >> $LOG ;; esac
	fout=$($UG wan-flush 2>&1) || fail "iter $i: wan-flush rc=$?"
	[ -n "$fout" ] && { echo "wanguard-wand: $fout" >> $LOG; spoke=$(( spoke + 1 )); }
	# contract assertions
	case "$out" in
		in-sync) insync_seen=$(( insync_seen + 1 )) ;;
		applied*) applied_seen=$(( applied_seen + 1 )) ;;
		*) fail "iter $i: apply said '$out'" ;;
	esac
	if [ $i -eq 1 ]; then
		# first iteration must SEE the real events (the loop is output-driven)
		case "$wout" in *"seed:a>wan1"*) ;; *) fail "iter 1: no seed:a>wan1 in '$wout'" ;; esac
	else
		# settled state: silence (any output = keepalive log spam on the router)
		[ -z "$wout" ] || fail "iter $i: quiet tick spoke: '$wout'"
		[ -z "$fout" ] || fail "iter $i: quiet flush spoke: '$fout'"
		[ "$out" = in-sync ] || fail "iter $i: expected in-sync, got '$out'"
	fi
done
echo "keepalive x$ITER: rc=0 everywhere; apply: $applied_seen applied / $insync_seen in-sync; log-worthy lines: $(grep -c . $LOG)"
head -3 $LOG | sed 's/^/  log: /'

# --- 2) byte-parity on identical state (no mutation between calls) ---
$UG wand-tick >/dev/null 2>&1 # warm RTT/state files for wanstatus
for cmd in list grouplist wanstatus devices; do
	$UG $cmd > /tmp/c4-uc.out 2>&1; rc1=$?
	$SHG $cmd > /tmp/c4-sh.out 2>&1; rc2=$?
	[ $rc1 -eq $rc2 ] || fail "$cmd: exit-code mismatch ($rc1 vs $rc2)"
	cmp -s /tmp/c4-uc.out /tmp/c4-sh.out || fail "$cmd: outputs differ"
	echo "  $cmd: byte-identical (rc=$rc1)"
done
sed -n '1,2p' /tmp/c4-uc.out | sed 's/^/  devices head: /'

# --- 3) wan-flush byte-parity on identical state (#32: native since
# stage 2) — event line and the idle rerun must match the sh CLI ---
echo wan2 > /tmp/wanguard/a.flush
u=$($UG wan-flush 2>&1)
case "$u" in "wand:flush:a>wan2(172.30.20.2)") ;; *) fail "wan-flush event: '$u'" ;; esac
echo wan2 > /tmp/wanguard/a.flush # identical re-seed for the sh run
s=$($SHG wan-flush 2>&1)
[ "$u" = "$s" ] || fail "wan-flush parity: ucode '$u' vs sh '$s'"
u=$($UG wan-flush 2>&1); s=$($SHG wan-flush 2>&1) # idle rerun: both silent
[ -z "$u$s" ] || fail "wan-flush idle rerun spoke: '$u'/'$s'"
echo "  wan-flush: byte-identical + idle-silent parity"

echo "C4-OK ($ITER keepalive iterations, machine-parsed outputs + wan-flush events byte-identical)"
