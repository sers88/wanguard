#!/bin/sh
# probe.sh — byte-exact transcripts of REAL nft + ip for stage-3
# render-parity (#33), recorded in stage3/NOTES.md.
#
# v2 fixes of the first run: (1) sets are created BEFORE rules referencing
# them (real nft rejects rules naming an absent set — atomic, rc 1);
# (2) `apk add ip-full` up front — the ROUTER runs ip-full (stage #13),
# the bare rootfs only has busybox ip; (3) dummy dev is set UP before
# `route replace` (a down device gives "RTNETLINK answers: Network is
# down", rc 2 — captured in v1, kept here as an explicit probe).
#
# Covers exactly the surfaces the wanguard CLI parses (and the ucode port
# will parse): nft chain tags/handles, set elements + sorting, mark
# normalization, batch atomicity, -c semantics; ip rule hex marks/prios,
# route `dev <name>` rendering (the trailing-space grep!), metric-200
# fallback, table-all dump order, link-show rc codes.
#
# Every rendered surface goes through show(): <TAB>/<EOL> markers make
# trailing whitespace visible — that whitespace is THE parity question.
#
# Run (from PowerShell, repo mounted read-only):
#   docker run --rm --cap-add=NET_ADMIN -v "<repo>:/repo:ro" `
#     openwrt/rootfs:x86_64-25.12.5 sh /repo/docs/spike-ucode/stage3/probe.sh
set -u

apk add --quiet nftables ip-full >/dev/null 2>&1 || {
	apk update >/dev/null
	apk add --quiet nftables ip-full >/dev/null
}

hdr() { printf '\n===== %s =====\n' "$*"; }
rc()  { printf -- '-- rc=%d\n' "$1"; }
show() { sed -e 's/\t/<TAB>/g; s/$/<EOL>/'; }

SKEL=/repo/router/wanguard.nft

hdr P0 versions
nft --version
ip --version # ip-full expected (router parity); busybox ip has no --version

hdr "P1 skeleton load; list table (wrap + interval sorting!)"
nft -f "$SKEL"; rc $?
nft list table inet wanguard | show

hdr "P2 sets FIRST, then rules (order = the CLI's batch order)"
nft -f - <<'EOF'
add set inet wanguard mac_a { type ether_addr; flags interval; }
add set inet wanguard no_mark { type ipv4_addr; flags interval; }
add element inet wanguard mac_a { aa:bb:cc:dd:ee:ff, 11:22:33:44:55:66 }
EOF
rc $?
nft -f - <<'EOF'
add rule inet wanguard marking iifname "br-lan" ether saddr @mac_a ip daddr != @local_v4 ip daddr != @no_mark meta mark set 300 comment "wg:a:m300"
add rule inet wanguard redir iifname "br-lan" ether saddr @mac_a ip daddr != @local_v4 ip daddr != @no_mark meta l4proto tcp redirect to :7892 comment "wg:a:r7892"
EOF
rc $?
nft -a list chain inet wanguard marking | show
nft -a list chain inet wanguard redir | show

hdr "P3 list set (elements render; sorted interval output)"
nft list set inet wanguard mac_a | show

hdr "P4 dup element: rc"
nft -f - <<'EOF'
add element inet wanguard mac_a { aa:bb:cc:dd:ee:ff }
EOF
rc $?

hdr "P5 delete absent element: message + rc + atomicity"
nft -f - <<'EOF'
add element inet wanguard mac_a { aa:bb:cc:dd:ee:ff }
delete element inet wanguard mac_a { 00:00:00:00:00:00 }
EOF
rc $?
nft list set inet wanguard mac_a | show

hdr "P6 list absent set: message + rc"
nft list set inet wanguard mac_missing
rc $?

hdr "P7 rule-handle delete; empty-chain render; fresh handle on re-add"
H=$(nft -a list chain inet wanguard marking | sed -n 's/.*comment "wg:a:m300".*# handle \([0-9]*\)$/\1/p')
echo "rule handle=$H"
nft -f - <<EOF
delete rule inet wanguard marking handle $H
EOF
rc $?
nft -a list chain inet wanguard marking | show
nft -f - <<'EOF'
add rule inet wanguard marking iifname "br-lan" ether saddr @mac_a ip daddr != @local_v4 ip daddr != @no_mark meta mark set 100 comment "wg:a:m100"
EOF
rc $?
nft -a list chain inet wanguard marking | show

hdr "P8 flush set / delete set; list after"
nft -f - <<'EOF'
flush set inet wanguard mac_a
delete set inet wanguard mac_a
EOF
rc $?
nft list set inet wanguard mac_a
rc $?

hdr "P9 -c good batch: rc 0, nothing applied"
nft -c -f - <<'EOF'
add set inet wanguard mac_check { type ether_addr; flags interval; }
EOF
rc $?
nft list set inet wanguard mac_check
rc $?

hdr "P10 -c bad batch: rc 1, nothing applied"
nft -c -f - <<'EOF'
add set inet wanguard mac_check { type ether_addr; flags interval; }
delete element inet wanguard mac_a { 00:00:00:00:00:00 }
EOF
rc $?
nft list set inet wanguard mac_check
rc $?

hdr "P11 cyrillic set name: -c and -f both reject"
printf 'add set inet wanguard mac_кириллица { type ether_addr; flags interval; }\n' > /tmp/bad.nft
nft -c -f /tmp/bad.nft
rc $?
nft -f /tmp/bad.nft
rc $?

hdr "P12 set-names surface (the CLI's have_sets sed)"
nft list table inet wanguard | sed -n 's/^[[:space:]]*set \([A-Za-z0-9_]*\).*/\1/p' | show

hdr "P13 delete table; list after"
nft delete table inet wanguard
rc $?
nft list table inet wanguard
rc $?

hdr "I1 ip rule show base (trailing space!)"
ip rule show | show

hdr "I2 rule add fwmark decimal: hex render, prio sort"
ip rule add prio 8000 fwmark 300 table 500; rc $?
ip rule add prio 8100 fwmark 100 table 400; rc $?
ip rule show | show

hdr "I3 prio extraction surface (the CLI's sed)"
ip rule show | sed -n 's/^[[:space:]]*\([0-9][0-9]*\):.*/\1/p' | show

hdr "I4 rule del existing / del absent: rc"
ip rule del prio 8000; rc $?
ip rule del prio 8000
rc $?

hdr "I5 dummy dev UP; route replace default dev Meta table 500"
ip link add Meta type dummy; rc $?
ip link set Meta up; rc $?
ip route replace default dev Meta table 500; rc $?
ip route show table 500 | show

hdr "I6 'default dev X ' grep surface (the trailing-space contract)"
ip route show table 500 | grep -q 'default dev Meta '; rc $? # 0 = grep matched

hdr "I7 route replace with unknown dev: message + rc"
ip route replace default dev Nope table 501
rc $?

hdr "I8 metric-200 fallback: replace \$mainline metric 200 table 400"
mainline=$(ip route show table main | grep '^default ' | head -n1)
echo "mainline=[$mainline]" # NB: brackets expose the trailing space
ip route replace $mainline metric 200 table 400; rc $?
ip route show table 400 | show

hdr "I9 ' metric 200' grep surface"
ip route show table 400 | grep -E ' metric 200($| )' | show
rc $?

hdr "I10 route show table all (suffix placement, dump order)"
ip route show table all | show

hdr "I11 table-number extraction surface (the CLI's orphan scan)"
ip route show table all | sed -n 's/.* table \([0-9][0-9]*\).*/\1/p' | sort -u | show

hdr "I12 route flush table 400; show after"
ip route flush table 400; rc $?
ip route show table 400 | show
rc $?

hdr "I13 route show absent table: rc"
ip route show table 999 | show
rc $?

hdr "I14 link show existing / absent: message + rc (ip-full!)"
ip link show Meta | show
rc $?
ip link show Ghost
rc $?

hdr "I15 down device replace (v1 finding): link down then replace"
ip link set Meta down
ip route replace default dev Meta table 502
rc $?
ip link set Meta up

hdr DONE
