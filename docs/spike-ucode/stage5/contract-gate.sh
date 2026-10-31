#!/bin/sh
# contract-gate.sh — stage-5 acceptance gate (issue #35): after the sh
# retirement there is no /usr/bin/wanguard-sh to diff against, so the
# machine-parsed CLI surfaces are gated BYTE-FOR-BYTE against the FROZEN
# CONTRACT (docs/spike-ucode/00-CLI-CONTRACT.md) instead:
#
#   list / grouplist / wanstatus / devices   (what LuCI + keepalive parse)
#   apply        -> exactly "in-sync"        (the keepalive literal)
#   wan-flush    -> "wand:flush:<g>><old>(<ip>)" event + idle silence
#   help         -> the usage text
#
# The golden bytes in golden/ were captured from the stage-4
# implementation — the one cli-parity.sh proved byte-identical to the sh
# CLI on 127 fixture pairs (stdout/stderr/rc/UCI/nft+ip state). Freezing
# those bytes IS freezing the contract; any future diff is a reviewable
# contract change, not a silent drift.
#
# Native-only by construction: the subject is `ucode -L mock wand.uc` —
# the same invocation the package installs as /usr/bin/wanguard (shebang
# path smoke-tested separately by install-test.sh and lab C4).
#
# Environment: openwrt/rootfs:x86_64-25.12.5, stateful nft/ip mocks
# (stage-3 harness) + ubus/jsonfilter/date/conntrack/curl stubs; the
# devices fixture uses REAL kernel neigh entries (ip-full + dummy br-lan,
# probe v3 finding) and therefore needs NET_ADMIN:
#   docker run --rm --cap-add=NET_ADMIN -v <repo>:/repo:ro \
#     openwrt/rootfs:x86_64-25.12.5 \
#     sh /repo/docs/spike-ucode/stage5/contract-gate.sh
# Capture (regenerate goldens after a REVIEWED contract change):
#   ... env CAPTURE=1 sh /repo/.../contract-gate.sh
#
# WARNING: rewrites /etc/config/wanguard — container only.
set -u

ROOT=/repo
UC=$ROOT/docs/spike-ucode/wand.uc
UCDIR=$ROOT/docs/spike-ucode/mock
MOCKBIN=$ROOT/tests/mock/bin
GOLDEN=$ROOT/docs/spike-ucode/stage5/golden
CONF=/etc/config/wanguard
WAND_DIR=/tmp/wanguard
CAPTURE=${CAPTURE:-0}

T=/tmp/wanguard-contract.$$
NFT_STATE=$T/nft.db
IP_STATE=$T/ip
UBUS_IFACES=$T/ubus.ifaces
UBUS_ADDRS=$T/ubus.addrs
UBUS_SERVICES=$T/ubus.svc
DATE_COUNT=$T/date.count
CONNTRACKLOG=$T/conntrack.log
export NFT_STATE IP_STATE UBUS_IFACES UBUS_ADDRS UBUS_SERVICES DATE_COUNT CONNTRACKLOG

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1 (got: '$2', want: '$3')"; }
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "rc=$2" "rc=$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "*$3*" ;; esac }
diff_ok() { # $1=label $2 $3=files -> byte equality (no diff(1) in busybox)
	if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$(cmp "$2" "$3" 2>&1 | head -n 2 | tr '\n' '|')" "identical"; fi
}

setup_shims() {
	# the CLI loads the skeleton from the apk-installed path (NFT_FILE) —
	# install it like the package would (container rw layer)
	mkdir -p /usr/share/wanguard
	cp "$ROOT/router/wanguard.nft" /usr/share/wanguard/wanguard.nft
	# ip-full for the /proc/net/arp fixture vehicle (busybox ip has no
	# `neigh` verb); the REAL binary is used only for fixture setup
	apk add --quiet ip-full >/dev/null 2>&1 || {
		apk update >/dev/null
		apk add --quiet ip-full >/dev/null
	}
	rm -rf /tmp/contract-shim
	mkdir -p /tmp/contract-shim
	for b in nft ip ubus jsonfilter date conntrack curl; do
		cp "$MOCKBIN/$b" /tmp/contract-shim/$b && chmod +x /tmp/contract-shim/$b
	done
	BASEPATH=$PATH
	PATH=/tmp/contract-shim:$PATH
	export PATH
	REAL_IP=$(PATH=$BASEPATH command -v ip)
}

cleanup() {
	${REAL_IP:-ip} link del br-lan 2>/dev/null
	rm -rf "$T" /tmp/contract-shim
}
trap cleanup EXIT

reset_state() {
	${REAL_IP:-ip} link del br-lan 2>/dev/null # drops fixture neigh too
	rm -rf "$NFT_STATE" "$IP_STATE" /tmp/.uci "$WAND_DIR"
	rm -f /tmp/dhcp.leases
	mkdir -p "$IP_STATE" /etc/config
	: > "$CONF"
	: > "$UBUS_IFACES"
	: > "$UBUS_ADDRS"
	: > "$UBUS_SERVICES"
	: > "$CONNTRACKLOG"
	echo 1000000000 > "$DATE_COUNT"
	printf 'default via 192.0.2.1 dev mockwan metric 10\n' > "$IP_STATE/route.main"
	: > "$IP_STATE/links"
	add_link mockwan # fallback metric-200 target must exist
}

add_link() { printf '%s\n' "$1" >> "$IP_STATE/links"; }
iface()    { printf '%s=%s\n' "$1" "$2" >> "$UBUS_IFACES"; }
addr()     { printf '%s=%s\n' "$1" "$2" >> "$UBUS_ADDRS"; }
arp_reset() { # dummy br-lan UP: /proc/net/arp rows appear under it
	"$REAL_IP" link add br-lan type dummy 2>/dev/null || return 1
	"$REAL_IP" link set br-lan up
}
arp_entry() { # $1=ip $2=mac $3=dev $4=state (stale renders flags 0x2)
	"$REAL_IP" neigh replace "$1" lladdr "$2" dev "$3" nud "$4" || \
		bad "arp entry $1" "failed" "ok"
}
wand()     { mkdir -p "$WAND_DIR"; printf '%s\n' "$2" > "$WAND_DIR/$1"; }

run_native() { # $1=case-id, rest = CLI args; fixture prepared by caller
	local id=$1; shift
	ucode -L "$UCDIR" "$UC" "$@" > "$T/$id.out" 2> "$T/$id.err"
	echo $? > "$T/$id.rc"
	if [ "$CAPTURE" = 1 ]; then
		mkdir -p "$GOLDEN"
		cp "$T/$id.out" "$GOLDEN/$id.out"
		cp "$T/$id.err" "$GOLDEN/$id.err"
		cp "$T/$id.rc" "$GOLDEN/$id.rc"
		ok "$id: golden captured"
	else
		[ -f "$GOLDEN/$id.out" ] || { bad "$id: golden present" "missing" "$GOLDEN/$id.out"; return; }
		diff_ok  "$id: stdout" "$T/$id.out" "$GOLDEN/$id.out"
		diff_ok  "$id: stderr" "$T/$id.err" "$GOLDEN/$id.err"
		assert_rc "$id: rc"    "$(cat "$T/$id.rc")" "$(cat "$GOLDEN/$id.rc")"
	fi
}

run_raw() { # $1=case-id, rest = CLI args -> $T/<id>.{out,err,rc}; NO golden
	local id=$1; shift          # (for the time-bearing #44/#45 surfaces:
	ucode -L "$UCDIR" "$UC" "$@" > "$T/$id.out" 2> "$T/$id.err"  # ring ts,
	echo $? > "$T/$id.rc"                                        # sync age)
}

has_line() { # $1=label $2=fixed needle $3=file (TAB-safe via printf)
	if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "$(head -n 3 "$3" | tr '\n' '|')" "$2"; fi
}

grep_ok() { # $1=label $2=ERE $3=file
	if grep -Eq -- "$2" "$3"; then ok "$1"; else bad "$1" "$(head -n 3 "$3" | tr '\n' '|')" "$2"; fi
}

# ---------- fixtures ----------

conf_std() { # freedom(vpn,up) + rostelecom(wan2,down) + proxy; 3 members
	cat > "$CONF" <<'EOF'
config globals 'globals'
	option no_mark '192.168.88.1'

config group 'freedom'
	option type 'direct'
	option iface 'vpn'

config group 'rostelecom'
	option type 'direct'
	option iface 'wan2'

config group 'proxy'
	option type 'proxy'

config member 'm_d8bbc1cc1771'
	option name 'tower'
	option mac 'd8:bb:c1:cc:17:71'
	option group 'freedom'

config member 'm_11aa22bb33cc'
	option mac '11:aa:22:bb:33:cc'
	option group 'rostelecom'

config member 'm_998877665544'
	option name 'ghost'
	option mac '99:88:77:66:55:44'
	option group 'nosuch'
EOF
	iface vpn eth1
	addr  vpn 10.99.0.1
	iface wan2 ''
	add_link eth1
	add_link Meta
}

sync_apply() { ucode -L "$UCDIR" "$UC" apply >/dev/null 2>&1; }

# ---------- the gate ----------

setup_shims
if [ "$CAPTURE" = 1 ]; then
	echo "== stage 5 contract gate: CAPTURING golden bytes (native CLI) =="
else
	echo "== stage 5 contract gate: native CLI vs frozen contract bytes =="
fi

# L-in list, populated + synced: header, member rows, unknown-group
# warning, trailing "nft: in-sync" (LuCI parses all of it)
reset_state; conf_std; sync_apply
run_native L-in list

# L-drift list with UCI != nft: the warning line + DRIFT verdict + rc 1
# (the contract: DRIFT makes LuCI read-only and the CLI exit 1)
reset_state; conf_std # no sync_apply -> drift by construction
run_native L-drift list

# GL grouplist: proxy row (Meta present), direct up/down rows, marks and
# tables per the deterministic allocation (ARCHITECTURE.md §2)
reset_state; conf_std; sync_apply
run_native GL grouplist

# D devices: leases + ARP merge (LuCI parseDevices(): mac\tip\tname\tonline;
# static-IP devices visible via ARP, complete entries online)
reset_state; conf_std
cat > /tmp/dhcp.leases <<'EOF'
1792900000 aa:bb:cc:dd:ee:01 192.168.88.35 buddy-052
1792900000 11:22:33:44:55:02 192.168.88.36 *
EOF
arp_reset
arp_entry 192.168.88.35 aa:bb:cc:dd:ee:01 br-lan stale # completes lease #1
arp_entry 192.168.88.99 aa:bb:cc:dd:ee:99 br-lan stale # ARP-only device
run_native D devices

# WS wanstatus: full wand state (rtt/alive/since/forced) + the group
# table with home/current/mode/backup order (SINCE via the date stub =
# fixed string; the ANCHORS column is the feed-skew canary)
reset_state; conf_std; sync_apply
wand vpn.state up
wand vpn.rtt 0.123
wand vpn.alive 2
wand vpn.since 1000000000
wand wan2.state down
wand wan2.force fail
uci add_list wanguard.freedom.backup_iface=rostelecom; uci commit wanguard
run_native WS wanstatus

# APL apply on a synced system: EXACTLY "in-sync" (the keepalive
# compares the literal; any extra byte is log spam every 10 s)
reset_state; conf_std; sync_apply
run_native APL apply

# FLE wan-flush event: one pending request -> the byte-exact event line;
# the conntrack delete is aimed at the OLD egress IPv4 (remembered addr:
# wan2 is down in this fixture, the live resolve is impossible — the #24
# degradation path)
reset_state; conf_std; sync_apply
wand freedom.flush wan2
wand wan2.addr 10.99.0.9
: > "$CONNTRACKLOG"
run_native FLE wan-flush
assert_contains "FLE ref: conntrack aimed at old egress" \
	"$(cat "$CONNTRACKLOG")" "-D -q 10.99.0.9"

# FLI wan-flush idle rerun: silence, rc 0 (keepalive logs only non-empty)
run_native FLI wan-flush

# H help: the usage text (default/help/-h/--help, exit 0)
reset_state
run_native H help

# ---- #44/#45 diagnostics data plane ----
# Time-bearing surfaces (ring rows, syncstatus age, the report header
# stamp real time()) are assert-gated below; the time-free ones get
# goldens like every other contract surface.

# DGR diag rules: FULL `ip rule show` — base rules AND every applied
# slot (a foreign prio-1000 rule is exactly what debugging needs to see)
reset_state; conf_std; sync_apply
run_native DGR diag rules

# DGT diag tables: per-slot device row + verbatim table routes
reset_state; conf_std; sync_apply
run_native DGT diag tables

# DGN diag nft: the applied table, verbatim
reset_state; conf_std; sync_apply
run_native DGN diag nft

# DGH diag health: procd fixture + valid config + the build stamp
# (/usr/share/wanguard/version is written by apk/build.sh on release)
reset_state; conf_std; sync_apply
printf 'wanguard=running\n' > "$UBUS_SERVICES"
printf '1.5.0-r1\n' > /usr/share/wanguard/version
run_native DGH diag health

# DGE diag unknown section: usage error, rc 1
reset_state; conf_std
run_native DGE diag bogus

# INM inspect by MAC: registered member, live iface up
reset_state; conf_std; sync_apply
run_native INM inspect d8:bb:c1:cc:17:71

# INH/ING inspect by hostname; ING is the configured-vs-live divergence
# case (rostelecom member, wan2 down: slot row shows live=down)
reset_state; conf_std; sync_apply
cat > /tmp/dhcp.leases <<'EOF'
1792900000 d8:bb:c1:cc:17:71 192.168.88.10 tower
1792900001 aa:bb:cc:dd:ee:99 192.168.88.99 freeloader
EOF
run_native INH inspect tower
run_native ING inspect 11:aa:22:bb:33:cc

# INU inspect ungrouped: leased but not registered — a VALID answer
run_native INU inspect 192.168.88.99

# INX inspect unresolvable: the contract error path (stderr, rc 1)
run_native INX inspect nosuchdevice

# INP inspect proxy member: the Meta link is the live device
reset_state; conf_std
cat >> "$CONF" <<'EOF'
config member 'm_pxy'
	option mac 'aa:bb:cc:dd:ee:42'
	option group 'proxy'
EOF
sync_apply
run_native INP inspect aa:bb:cc:dd:ee:42

# INL inspect direct-lb member: per-slot rows carry member= + live=
reset_state
cat > "$CONF" <<'EOF'
config globals 'globals'

config group 'lb'
	option type 'direct-lb'
	list member_iface 'vpn'
	list member_iface 'wan2'
	option weight_vpn '70'
	option weight_wan2 '30'

config member 'm_lb'
	option mac 'aa:bb:cc:dd:ee:55'
	option group 'lb'
EOF
iface vpn eth1
addr  vpn 10.99.0.1
iface wan2 ''
add_link eth1
add_link Meta
sync_apply
run_native INL inspect aa:bb:cc:dd:ee:55

# SY syncstatus: the key=value probe, exit 0 on BOTH sides (DRIFT
# verdict semantics stay exclusive to `list`)
reset_state; conf_std
run_raw SY1 syncstatus
assert_rc "SY1: rc=0 on drift" "$(cat "$T/SY1.rc")" "0"
grep_ok "SY1: status=drift"  '^status=drift$'    "$T/SY1.out"
grep_ok "SY1: no stamp yet"  '^last_apply=-$'    "$T/SY1.out"
grep_ok "SY1: no age yet"    '^age=-$'           "$T/SY1.out"
sync_apply
run_raw SY2 syncstatus
assert_rc "SY2: rc=0 in-sync" "$(cat "$T/SY2.rc")" "0"
grep_ok "SY2: status=in-sync"    '^status=in-sync$'        "$T/SY2.out"
grep_ok "SY2: last_apply unix ts" '^last_apply=[0-9]+$'    "$T/SY2.out"
grep_ok "SY2: age seconds"        '^age=[0-9]+$'           "$T/SY2.out"

# EVS events ring: rows land in ts<TAB>code<TAB>detail shape; the
# in-sync heartbeat records the FIRST of a quiet run only
reset_state; conf_std
run_raw EV1 apply
run_raw EV2 apply
run_raw EV3 apply
assert_rc "EV: apply rc=0" "$(cat "$T/EV1.rc")" "0"
has_line "EV: applied row recorded"   "$(printf 'apply_ok\tapplied')" "$WAND_DIR/events"
has_line "EV: in-sync heartbeat"      "$(printf 'apply_ok\tin-sync')" "$WAND_DIR/events"
assert_eq "EV: heartbeat deduped (2 rows total)" "$(wc -l < "$WAND_DIR/events")" "2"
run_raw EV4 events 1
assert_rc "EV: tail rc=0" "$(cat "$T/EV4.rc")" "0"
grep_ok "EV: tail row shape" '^[0-9]{10}	apply_ok	in-sync$' "$T/EV4.out"
assert_eq "EV: tail N=1 is one row" "$(wc -l < "$T/EV4.out")" "1"

# DRP diag-report: the secrets-free aggregate (assert-gated: header
# stamp carries real time). The gate PROVES the never-reads-network
# property by planting markers in /etc/config/network and grepping.
reset_state; conf_std; sync_apply
cat > /etc/config/network <<'EOF'
config interface 'wan'
	option proto 'pppoe'
	option password 'SUPERSECRET-PPPOE-PASS'
	list servers 'SUPERSECRET-WG-KEY'
EOF
run_raw DRP diag-report
assert_rc "DRP: rc=0" "$(cat "$T/DRP.rc")" "0"
has_line "DRP: report header" "# wanguard diag-report" "$T/DRP.out"
for s in rules tables nft health devices events; do
	has_line "DRP: section $s" "$(printf "section\t$s")" "$T/DRP.out"
done
has_line "DRP: sync row" "$(printf 'sync\tin-sync\tlast_apply=')" "$T/DRP.out"
has_line "DRP: member row" "$(printf 'member\td8:bb:c1:cc:17:71\ttower\tfreedom\t')" "$T/DRP.out"
if grep -q SUPERSECRET /etc/config/network && ! grep -q SUPERSECRET "$T/DRP.out"; then
	ok "DRP: secrets gate (markers planted, none leaked)"
else
	bad "DRP: secrets gate" "leaked or not planted" "0 leaks with markers present"
fi
rm -f /etc/config/network

echo "----------------------------------------"
if [ "$CAPTURE" = 1 ]; then
	echo "CAPTURED=$PASS (goldens in docs/spike-ucode/stage5/golden/)"
	echo "Review them against 00-CLI-CONTRACT.md before committing."
else
	echo "PASS=$PASS FAIL=$FAIL"
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
