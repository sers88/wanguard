#!/bin/sh
# smoke test for the stateful mock nft (parity fixtures, #33)
set -u
cd "$(dirname "$0")/../.." || exit 1
MOCKBIN=$PWD/tests/mock/bin
export NFT_STATE=/tmp/mocknft.$$
trap 'rm -f "$NFT_STATE" "$NFT_STATE".norm.* "$NFT_STATE".cand.* "$NFT_STATE".t' EXIT
N=$MOCKBIN/nft
PASS=0; FAIL=0
chk() { # name expected actual
	if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "--- expected:"; printf '%s\n' "$2"; echo "--- actual:"; printf '%s\n' "$3"; fi
}
chkrc() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL(rc): $1: want=$2 got=$3"; fi }

# legacy mode: no NFT_STATE
env -u NFT_STATE sh "$N" list table inet wanguard; chkrc "legacy list rc" 0 "$?"
env -u NFT_STATE sh "$N" -f /nonexistent; chkrc "legacy -f rc" 0 "$?"

# absent table
out=$(sh "$N" list set inet wanguard local_v4 2>&1); rc=$?
chkrc "absent set rc" 1 "$rc"
chk "absent set err" "Error: No such file or directory" "$out"

# skeleton load
SKEL=$PWD/router/wanguard.nft
sh "$N" -f "$SKEL"; chkrc "skeleton rc" 0 "$?"
out=$(sh "$N" list set inet wanguard local_v4)
want='table inet wanguard {
	set local_v4 {
		type ipv4_addr
		flags interval
		elements = { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 224.0.0.0/4, 255.255.255.255 }
	}
}'
chk "skeleton local_v4" "$want" "$out"

# list chain empty
out=$(sh "$N" -a list chain inet wanguard marking)
want='table inet wanguard {
	chain marking { # handle 1
		type filter hook prerouting priority mangle; policy accept;
	}
}'
chk "chain -a empty" "$want" "$out"

# batch: add rules
cat > /tmp/rules.nft <<'EOF'
add rule inet wanguard marking iifname "br-lan" ether saddr @mac_x ip daddr != @local_v4 ip daddr != @no_mark meta mark set 100 comment "wg:x:m100"
add rule inet wanguard redir iifname "br-lan" ether saddr @mac_x ip daddr != @local_v4 ip daddr != @no_mark meta l4proto tcp redirect to :7892 comment "wg:x:r7892"
EOF
sh "$N" -f /tmp/rules.nft; chkrc "rules add rc" 0 "$?"
out=$(sh "$N" -a list chain inet wanguard marking | grep 'wg:')
want='		iifname "br-lan" ether saddr @mac_x ip daddr != @local_v4 ip daddr != @no_mark meta mark set 100 comment "wg:x:m100" # handle 3'
chk "rule line + handle" "$want" "$out"

# handle extraction like the sh CLI does
H=$(sh "$N" -a list chain inet wanguard marking | sed -n 's/.*comment "\(wg:[^"]*\)".*# handle \([^ ]*\).*/\2/p')
chk "handle extract" "3" "$H"

# batch: sets/elements
cat > /tmp/els.nft <<'EOF'
add set inet wanguard mac_x { type ether_addr; flags interval; }
add element inet wanguard mac_x { aa:bb:cc:dd:ee:ff, 11:22:33:44:55:66 }
add element inet wanguard no_mark { 192.168.100.5 }
EOF
sh "$N" -f /tmp/els.nft; chkrc "els rc" 0 "$?"
out=$(sh "$N" list set inet wanguard mac_x)
want='table inet wanguard {
	set mac_x {
		type ether_addr
		flags interval
		elements = { aa:bb:cc:dd:ee:ff, 11:22:33:44:55:66 }
	}
}'
chk "mac_x render" "$want" "$out"

# dup element: silent ok
printf 'add element inet wanguard mac_x { aa:bb:cc:dd:ee:ff }\n' > /tmp/dup.nft
sh "$N" -f /tmp/dup.nft; chkrc "dup elem rc" 0 "$?"

# atomicity: batch with one bad line applies nothing
cat > /tmp/bad.nft <<'EOF'
add element inet wanguard mac_x { 99:88:77:66:55:44 }
delete element inet wanguard mac_x { 00:00:00:00:00:00 }
EOF
out=$(sh "$N" -f /tmp/bad.nft 2>&1); chkrc "atomic rc" 1 "$?"
out=$(sh "$N" list set inet wanguard mac_x)
case "$out" in
	*99:88:77:66:55:44*) FAIL=$((FAIL+1)); echo "FAIL: atomicity — bad batch leaked" ;;
	*) PASS=$((PASS+1)) ;;
esac

# -c check does not mutate
sh "$N" -c -f /tmp/bad.nft; chkrc "check rc" 1 "$?"
out=$(sh "$N" list set inet wanguard mac_x)
case "$out" in
	*99:88:77:66:55:44*) FAIL=$((FAIL+1)); echo "FAIL: -c leaked" ;;
	*) PASS=$((PASS+1)) ;;
esac

# delete rule by handle; readd gets a fresh handle
printf 'delete rule inet wanguard marking handle %s\n' "$H" > /tmp/dr.nft
sh "$N" -f /tmp/dr.nft; chkrc "del rule rc" 0 "$?"
n=$(sh "$N" -a list chain inet wanguard marking | grep -c 'wg:')
chk "rule gone" "0" "$n"
sh "$N" -f /tmp/rules.nft
H2=$(sh "$N" -a list chain inet wanguard marking | sed -n 's/.*comment "\(wg:[^"]*\)".*# handle \([^ ]*\).*/\2/p' | head -n1)
[ "$H2" != "$H" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: handle reuse"; }

# flush + delete set
printf 'flush set inet wanguard mac_x\ndelete set inet wanguard mac_x\n' > /tmp/rd.nft
sh "$N" -f /tmp/rd.nft; chkrc "flush+del rc" 0 "$?"
sh "$N" list set inet wanguard mac_x 2>/dev/null; chkrc "gone set rc" 1 "$?"

# empty set renders without elements
printf 'add set inet wanguard mac_e { type ether_addr; flags interval; }\n' > /tmp/es.nft
sh "$N" -f /tmp/es.nft
out=$(sh "$N" list set inet wanguard mac_e)
want='table inet wanguard {
	set mac_e {
		type ether_addr
		flags interval
	}
}'
chk "empty set render" "$want" "$out"

# delete table resets
sh "$N" delete table inet wanguard; chkrc "del table rc" 0 "$?"
sh "$N" list set inet wanguard local_v4 2>/dev/null; chkrc "post-reset rc" 1 "$?"

# cyrillic: -c rejects, nothing applied
printf 'add set inet wanguard mac_кириллица { type ether_addr; flags interval; }\n' > /tmp/cyr.nft
sh "$N" -c -f /tmp/cyr.nft 2>/dev/null; chkrc "cyrillic -c rc" 1 "$?"
printf 'add set inet wanguard mac_кириллица { type ether_addr; flags interval; }\n' > /tmp/cyr.nft
sh "$N" -f /tmp/cyr.nft 2>/dev/null; chkrc "cyrillic -f rc" 1 "$?"

# list table overview
sh "$N" -f "$SKEL"
out=$(sh "$N" list table inet wanguard)
case "$out" in
	"table inet wanguard {"*"set local_v4"*"set no_mark"*"chain marking"*"chain redir"*) PASS=$((PASS+1)) ;;
	*) FAIL=$((FAIL+1)); echo "FAIL: list table overview"; printf '%s\n' "$out" ;;
esac

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
