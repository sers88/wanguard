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
DATE_COUNT=$T/date.count
CONNTRACKLOG=$T/conntrack.log
export NFT_STATE IP_STATE UBUS_IFACES UBUS_ADDRS DATE_COUNT CONNTRACKLOG

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

echo "----------------------------------------"
if [ "$CAPTURE" = 1 ]; then
	echo "CAPTURED=$PASS (goldens in docs/spike-ucode/stage5/golden/)"
	echo "Review them against 00-CLI-CONTRACT.md before committing."
else
	echo "PASS=$PASS FAIL=$FAIL"
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
