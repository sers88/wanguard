#!/bin/sh
# smoke test for the stateful mock ip (parity fixtures, #33)
set -u
cd "$(dirname "$0")/../.." || exit 1
IP=$PWD/tests/mock/bin/ip
ST=/tmp/mockip.$$
export IP_STATE=$ST
trap 'rm -rf "$IP_STATE"' EXIT
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; printf 'want:\n%s\ngot:\n%s\n' "$2" "$3"; fi }
chkrc() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(rc): $1: want=$2 got=$3"; fi }

# legacy mode
out=$(env -u IP_STATE sh "$IP" route show)
chk "legacy route show" "default via 192.0.2.1 dev mock-wan" "$out"
out=$(env -u IP_STATE sh "$IP" rule show)
chk "legacy rule show" "" "$out"

# base seed
out=$(sh "$IP" rule show | sed 's/[ \t]*$//')
want='0:	from all lookup local
32766:	from all lookup main
32767:	from all lookup default'
chk "base rules" "$want" "$out"

# add + sorted render + hex marks
sh "$IP" rule add prio 8000 fwmark 300 table 500
sh "$IP" rule add prio 8100 fwmark 100 table 400
out=$(sh "$IP" rule show | sed 's/[ \t]*$//')
want='0:	from all lookup local
8000:	from all fwmark 0x12c lookup 500
8100:	from all fwmark 0x64 lookup 400
32766:	from all lookup main
32767:	from all lookup default'
chk "rules sorted" "$want" "$out"

# prio extraction exactly like the sh CLI
prios=$(sh "$IP" rule show | sed -n 's/^[[:space:]]*\([0-9][0-9]*\):.*/\1/p' | tr '\n' ' ')
chk "prio extract" "0 8000 8100 32766 32767 " "$prios"

# del: existing -> gone; absent -> rc 2
sh "$IP" rule del prio 8000; chkrc "del 8000" 0 "$?"
sh "$IP" rule del prio 8000 2>/dev/null; chkrc "del absent" 2 "$?"

# routes: link gate, replace, show, metric-200, flush
mkdir -p "$ST"
printf 'eth1\nMeta\n' > "$ST/links"
printf 'default via 172.30.10.10 dev eth1 metric 10\n' > "$ST/route.main"

out=$(sh "$IP" route show table main | sed 's/[ \t]*$//')
chk "main default" "default via 172.30.10.10 dev eth1 metric 10" "$out"
mainline=$(sh "$IP" route show table main | grep '^default ' | head -n1)
chk "mainline capture (trailing space = real ip-full render)" \
	"default via 172.30.10.10 dev eth1 metric 10 " "$mainline"

sh "$IP" route replace default dev Meta table 500; chkrc "replace 500" 0 "$?"
sh "$IP" route replace $mainline metric 200 table 400; chkrc "replace 400" 0 "$?"
out=$(sh "$IP" route show table 500 | sed 's/[ \t]*$//')
chk "table 500" "default dev Meta" "$out"
out=$(sh "$IP" route show table 400 | sed 's/[ \t]*$//')
chk "table 400" "default via 172.30.10.10 dev eth1 metric 10 metric 200" "$out"
printf '%s\n' "$out" | grep -Eq ' metric 200($| )'; chkrc "metric200 grep" 0 "$?"
sh "$IP" route show table 500 | grep -q 'default dev Meta '
chkrc "dev-trailing-space grep (CLI contract, NOTES.md I5/I6)" 0 "$?"

sh "$IP" route replace default dev Nope table 402 2>/dev/null; chkrc "replace bad dev" 1 "$?"

out=$(sh "$IP" route show table all | sed 's/[ \t]*$//')
want='default via 172.30.10.10 dev eth1 metric 10
default via 172.30.10.10 dev eth1 metric 10 metric 200 table 400
default dev Meta table 500'
chk "show all" "$want" "$out"
# orphan-scan extraction exactly like the sh CLI
tabs=$(sh "$IP" route show table all | sed -n 's/.* table \([0-9][0-9]*\).*/\1/p' | sort -u | tr '\n' ' ')
chk "table scan" "400 500 " "$tabs"

out=$(sh "$IP" route show table 999); chkrc "absent table rc" 0 "$?"
chk "absent table empty" "" "$out"

sh "$IP" route flush table 400; chkrc "flush" 0 "$?"
out=$(sh "$IP" route show table 400)
chk "flushed" "" "$out"

# re-replace default overwrites (not appends)
sh "$IP" route replace default dev Meta table 500
sh "$IP" route replace default dev eth1 table 500
n=$(sh "$IP" route show table 500 | grep -c '^default')
chk "default overwritten" "1" "$n"

# link show
sh "$IP" link show Meta >/dev/null 2>&1; chkrc "link Meta" 0 "$?"
sh "$IP" link show Ghost >/dev/null 2>&1; chkrc "link Ghost" 2 "$?"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
