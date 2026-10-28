#!/bin/sh
# cli-parity.sh — byte-parity harness for stage 4 of the ucode migration
# (issue #34): the CLI CRUD + view subcommands.
#
# Method C4 (the issue's acceptance gate): each subject runs the same
# subcommand on IDENTICAL state (UCI + nft + ip + ubus + wand files +
# dhcp.leases + /proc/net/arp fixture), and EVERY artifact must match:
#
#   1. stdout bytes        (tables, confirmations, warnings, the trailing
#                           native `apply` output of every mutation)
#   2. stderr bytes        (`wanguard: ...` error lines — 1:1)
#   3. exit code           (DRIFT -> 1, usage errors -> 1, help -> 0)
#   4. committed UCI bytes (mutations must leave the SAME /etc/config)
#   5. rendered nft/ip state (the trailing native apply of mutations)
#
# Subjects:
#   sh = router/wanguard (the battle-tested reference implementation)
#   uc = docs/spike-ucode/wand.uc — native since stage 4; WANGUARD_SH is
#        NOT involved anymore (the passthrough is gone). The lab/native
#        gate is `WANGUARD_SH=/nonexistent wanguard <cmd>` instead.
#
# Reference assertions (sh side) pin the contract itself per fixture;
# the differential (sh vs uc) is asserted for every artifact of every
# fixture.
#
# Environment: runs INSIDE openwrt/rootfs:x86_64-25.12.5 — REAL uci on
# /etc/config (committed bytes are produced by the same libuci on both
# sides), stateful mocks for nft/ip (stage-3 harness, NOTES.md) + ubus/
# jsonfilter/date/conntrack/curl (tests/mock). /proc/net/arp is
# fixture-driven with REAL kernel neigh entries (probe v3 finding: a
# bind-mount over /proc/net/arp succeeds but readers still see the
# original procfs content — the vehicle is dead; `ip-full` + a dummy
# br-lan + `nud permanent` entries render deterministic /proc/net/arp
# rows instead; needs NET_ADMIN):
#   docker run --rm --cap-add=NET_ADMIN -v <repo>:/repo:ro \
#     openwrt/rootfs:x86_64-25.12.5 sh /repo/docs/spike-ucode/stage4/cli-parity.sh
#
# WARNING: rewrites /etc/config/wanguard — container only.
set -u

ROOT=/repo
WG_SH=$ROOT/router/wanguard
UC=$ROOT/docs/spike-ucode/wand.uc
UCDIR=$ROOT/docs/spike-ucode/mock
MOCKBIN=$ROOT/tests/mock/bin
CONF=/etc/config/wanguard
WAND_DIR=/tmp/wanguard

T=/tmp/wanguard-parity.$$
NFT_STATE=$T/nft.db
IP_STATE=$T/ip
UBUS_IFACES=$T/ubus.ifaces
UBUS_ADDRS=$T/ubus.addrs
DATE_COUNT=$T/date.count
export NFT_STATE IP_STATE UBUS_IFACES UBUS_ADDRS DATE_COUNT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1 (got: '$2', want: '$3')"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
assert_rc()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "rc=$2" "rc=$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "*$3*" ;; esac; }
assert_absent()   { case "$2" in *"$3"*) bad "$1" "$2" "WITHOUT *$3*" ;; *) ok "$1" ;; esac; }
diff_ok() { # $1=label $2 $3=files -> byte equality (this busybox has no
	if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$(cmp "$2" "$3" 2>&1 | head -n 2 | tr '\n' '|')" "identical"; fi
}

setup_shims() {
	# the CLI loads the skeleton from the apk-installed path (NFT_FILE) —
	# install it like the package would (container rw layer)
	mkdir -p /usr/share/wanguard
	cp "$ROOT/router/wanguard.nft" /usr/share/wanguard/wanguard.nft
	# ip-full for the /proc/net/arp fixture vehicle (busybox ip has no
	# `neigh` verb); real binary used ONLY for fixture setup/teardown
	apk add --quiet ip-full >/dev/null 2>&1 || {
		apk update >/dev/null
		apk add --quiet ip-full >/dev/null
	}
	rm -rf /tmp/parity-shim /tmp/parity-shim-nocurl
	mkdir -p /tmp/parity-shim /tmp/parity-shim-nocurl
	for b in nft ip ubus jsonfilter date conntrack curl; do
		cp "$MOCKBIN/$b" /tmp/parity-shim/$b && chmod +x /tmp/parity-shim/$b
	done
	for b in nft ip ubus jsonfilter date conntrack; do # nocurl variant (WS3)
		cp "$MOCKBIN/$b" /tmp/parity-shim-nocurl/$b && chmod +x /tmp/parity-shim-nocurl/$b
	done
	BASEPATH=$PATH
	SHIM_PATH=/tmp/parity-shim:$BASEPATH
	SHIM_NOCURL=/tmp/parity-shim-nocurl:$BASEPATH
	PATH=$SHIM_PATH
	export PATH
	# the REAL ip-full binary (arp fixture vehicle) — the shim `ip` on
	# PATH would intercept the fixture setup calls otherwise
	REAL_IP=$(PATH=$BASEPATH command -v ip)
}

cleanup() {
	${REAL_IP:-ip} link del br-lan 2>/dev/null
	rm -rf "$T" /tmp/parity-shim /tmp/parity-shim-nocurl
}
trap cleanup EXIT

reset_state() { # nft/ip/uci/wand/leases/arp to zero
	${REAL_IP:-ip} link del br-lan 2>/dev/null # drops fixture neigh too
	rm -rf "$NFT_STATE" "$IP_STATE" /tmp/.uci "$WAND_DIR"
	rm -f /tmp/dhcp.leases
	mkdir -p "$IP_STATE" /etc/config
	: > "$CONF" # TRUNCATE (touch would preserve the previous subject's mutations!)
	: > "$UBUS_IFACES"
	: > "$UBUS_ADDRS"
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
arp_entry() { # $1=ip $2=mac $3=dev $4=state(permanent|failed|incomplete)
	"$REAL_IP" neigh replace "$1" lladdr "$2" dev "$3" nud "$4" || \
		bad "arp entry $1" "failed" "ok"
}
wand()     { mkdir -p "$WAND_DIR"; printf '%s\n' "$2" > "$WAND_DIR/$1"; }

snapshot() { # $1=subject — rendered state + committed UCI bytes
	{
		echo "== nft table =="
		nft list table inet wanguard 2>&1
		echo "== chain marking =="
		nft -a list chain inet wanguard marking 2>&1
		echo "== chain redir =="
		nft -a list chain inet wanguard redir 2>&1
		echo "== ip rule =="
		ip rule show 2>&1
		echo "== ip routes all =="
		ip route show table all 2>&1
	} > "$T/$1.state"
	if [ -f "$CONF" ]; then cp "$CONF" "$T/$1.uci"; else : > "$T/$1.uci"; fi
}

run_subj() { # $1=sh|uc, rest = CLI args; SUBJ_PATH may override PATH
	local s=$1; shift
	local p=${SUBJ_PATH:-$SHIM_PATH}
	if [ "$s" = sh ]; then
		PATH=$p sh "$WG_SH" "$@" > "$T/$s.out" 2> "$T/$s.err"
	else
		PATH=$p ucode -L "$UCDIR" "$UC" "$@" > "$T/$s.out" 2> "$T/$s.err"
	fi
	echo $? > "$T/$s.rc"
}

do_pair() { # $1=label $2=fixture-fn, rest = CLI args
	local label=$1 fx=$2; shift 2
	local s
	for s in sh uc; do
		reset_state
		"$fx"
		run_subj "$s" "$@"
		snapshot "$s"
	done
	diff_ok    "$label: stdout"       "$T/sh.out" "$T/uc.out"
	diff_ok    "$label: stderr"       "$T/sh.err" "$T/uc.err"
	assert_rc  "$label: rc" "$(cat "$T/sh.rc")" "$(cat "$T/uc.rc")"
	diff_ok    "$label: uci bytes"    "$T/sh.uci" "$T/uc.uci"
	diff_ok    "$label: nft/ip state" "$T/sh.state" "$T/uc.state"
}

# ---------- fixtures ----------

conf_groups() { # freedom(vpn,up) + rostelecom(wan2,down) + proxy(mihomo)
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
EOF
}

conf_members3() { # tower->freedom, noname->rostelecom, ghost->nosuch
	cat >> "$CONF" <<'EOF'

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
}

ifaces_std() { # vpn up (addr default 10.99.0.1), wan2 known but DOWN
	iface vpn eth1
	addr  vpn 10.99.0.1
	iface wan2 ''
	add_link eth1
}

sync_apply() { sh "$WG_SH" apply >/dev/null 2>&1; } # deterministic render

# ---- L: list ----

f_L1() { : ; } # empty config file
f_L0() { rm -f "$CONF"; } # NO config file at all
f_L2() { conf_groups; conf_members3; ifaces_std; sync_apply; }
f_L3() { conf_groups; conf_members3; ifaces_std; } # unsynced = DRIFT
f_L4() { # synced, then an extra nft element nobody wants (drift other way)
	conf_groups; conf_members3; ifaces_std; sync_apply
	nft -f - <<'EOF'
add element inet wanguard mac_freedom { de:ad:be:ef:00:01 }
EOF
}
f_L5() { # member with an INVALID stored mac: want-side garbage -> DRIFT
	conf_groups
	cat >> "$CONF" <<'EOF'

config member 'm_bad'
	option name 'badmac'
	option mac 'not-a-mac'
	option group 'freedom'
EOF
	ifaces_std
	sync_apply
}
f_L6() { # anonymous member sections + file order (sh uci show order)
	conf_groups
	cat >> "$CONF" <<'EOF'

config member 'm_aa0000000001'
	option name 'first'
	option mac 'aa:00:00:00:00:01'
	option group 'freedom'

config group 'extra'
	option type 'direct'
	option iface 'vpn'

config member
	option name 'anon'
	option mac 'aa:00:00:00:00:02'
	option group 'rostelecom'

config member 'm_aa0000000003'
	option mac 'aa:00:00:00:00:03'
	option group 'freedom'
EOF
	ifaces_std
	sync_apply
}

battery_list() {
	do_pair "L0 list, no config file" f_L0 list
	do_pair "L1 list, empty config"   f_L1 list
	assert_contains "L1 ref: header"  "$(cat "$T/sh.out")" "NAME"
	assert_contains "L1 ref: in-sync" "$(cat "$T/sh.out")" "nft: in-sync"
	assert_rc      "L1 ref: rc0"      "$(cat "$T/sh.rc")" 0
	do_pair "L2 list, populated"      f_L2 list
	assert_contains "L2 ref: tower row"   "$(cat "$T/sh.out")" "tower            d8:bb:c1:cc:17:71    freedom"
	assert_contains "L2 ref: noname dash" "$(cat "$T/sh.out")" "-                11:aa:22:bb:33:cc    rostelecom"
	assert_contains "L2 ref: unknown grp" "$(cat "$T/sh.out")" "ghost            99:88:77:66:55:44    nosuch (??)"
	assert_contains "L2 ref: warn line"   "$(cat "$T/sh.out")" "warning: members reference unknown group(s): nosuch (fail-safe: main table)"
	assert_contains "L2 ref: in-sync"     "$(cat "$T/sh.out")" "nft: in-sync"
	assert_rc      "L2 ref: rc0"          "$(cat "$T/sh.rc")" 0
	do_pair "L3 list, unsynced (DRIFT)"   f_L3 list
	assert_contains "L3 ref: DRIFT" "$(cat "$T/sh.out")" "nft: DRIFT (UCI != nft sets; run: wanguard apply)"
	assert_rc      "L3 ref: rc1"    "$(cat "$T/sh.rc")" 1
	do_pair "L4 list, extra nft element" f_L4 list
	assert_contains "L4 ref: DRIFT" "$(cat "$T/sh.out")" "nft: DRIFT"
	do_pair "L5 list, garbage member mac" f_L5 list
	assert_contains "L5 ref: DRIFT" "$(cat "$T/sh.out")" "nft: DRIFT"
	do_pair "L6 list, anon sections/order" f_L6 list
	assert_contains "L6 ref: first" "$(cat "$T/sh.out")" "first"
	assert_contains "L6 ref: anon"  "$(cat "$T/sh.out")" "anon"
	do_pair "L7 list, extra args ignored" f_L2 list surplus args
}

# ---- A: add ----

f_A1() { conf_groups; ifaces_std; }
f_A1_dup() { # duplicate needs the first add committed first
	conf_groups; ifaces_std
	sh "$WG_SH" add aa:bb:cc:dd:ee:01 freedom phone >/dev/null 2>&1
}
battery_add() {
	do_pair "A1 add happy path" f_A1 add AA:BB:CC:DD:EE:01 freedom phone
	assert_contains "A1 ref: added"   "$(cat "$T/sh.out")" "added aa:bb:cc:dd:ee:01 -> group freedom (phone)"
	assert_contains "A1 ref: applied" "$(cat "$T/sh.out")" "applied"
	assert_rc      "A1 ref: rc0"      "$(cat "$T/sh.rc")" 0
	assert_contains "A1 ref: uci sid" "$(cat "$T/sh.uci")" "config member 'm_aabbccddee01'"
	do_pair "A2 add dotted-quad mac" f_A1 add aabb.ccdd.eeff freedom phone
	assert_contains "A2 ref: normalized" "$(cat "$T/sh.out")" "added aa:bb:cc:dd:ee:ff ->"
	do_pair "A3 add dash mac" f_A1 add aa-bb-cc-dd-ee-ff freedom
	do_pair "A4 add bare hex" f_A1 add 112233445566 rostelecom
	assert_contains "A4 ref: default name" "$(cat "$T/sh.out")" "(mac-22:33:44:55:66)"
	do_pair "A5 add invalid short" f_A1 add aabbcc rostelecom
	assert_contains "A5 ref: err" "$(cat "$T/sh.err")" "wanguard: invalid mac: aabbcc"
	assert_rc      "A5 ref: rc1"  "$(cat "$T/sh.rc")" 1
	do_pair "A6 add invalid long"  f_A1 add aabbccddeeff0 freedom
	do_pair "A7 add invalid chars" f_A1 add zz:bb:cc:dd:ee:ff freedom
	do_pair "A8 add invalid via g" f_A1 add gaabbccddeeff freedom
	do_pair "A9 add unknown group" f_A1 add aabbccddeeff nosuch
	assert_contains "A9 ref: err"  "$(cat "$T/sh.err")" "wanguard: no such group: 'nosuch' (see: wanguard grouplist)"
	do_pair "A10 add no args" f_A1 add
	assert_contains "A10 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard add <mac> <group> [name]"
	do_pair "A11 add one arg" f_A1 add aabbccddeeff
	do_pair "A12 add duplicate" f_A1_dup add aa:bb:cc:dd:ee:01 rostelecom
	assert_contains "A12 ref: err" "$(cat "$T/sh.err")" "wanguard: aa:bb:cc:dd:ee:01 already registered as 'phone' in group freedom (use: wanguard move aa:bb:cc:dd:ee:01 rostelecom)"
	do_pair "A13 add into proxy group" f_A1 add aabbccddeeff proxy
	do_pair "A14 add name with spaces" f_A1 add aabbccddeeff freedom "My Phone"
	assert_contains "A14 ref: name" "$(cat "$T/sh.out")" "(My Phone)"
}

# ---- M: move ----

f_M1() { conf_groups; conf_members3; ifaces_std; sync_apply; }
battery_move() {
	do_pair "M1 move ok" f_M1 move d8:bb:c1:cc:17:71 rostelecom
	assert_contains "M1 ref: moved"   "$(cat "$T/sh.out")" "moved d8:bb:c1:cc:17:71: freedom -> rostelecom"
	assert_contains "M1 ref: applied" "$(cat "$T/sh.out")" "applied"
	do_pair "M2 move same group" f_M1 move d8:bb:c1:cc:17:71 freedom
	assert_contains "M2 ref: already" "$(cat "$T/sh.out")" "d8:bb:c1:cc:17:71 already in group freedom"
	assert_absent  "M2 ref: NO apply" "$(cat "$T/sh.out")" "applied"
	do_pair "M3 move unregistered" f_M1 move de:ad:be:ef:00:01 freedom
	assert_contains "M3 ref: err" "$(cat "$T/sh.err")" "wanguard: de:ad:be:ef:00:01 not registered (use: wanguard add de:ad:be:ef:00:01 <group> [name])"
	do_pair "M4 move invalid mac" f_M1 move nope freedom
	do_pair "M5 move unknown grp" f_M1 move d8:bb:c1:cc:17:71 nosuch
	do_pair "M6 move no args" f_M1 move
	assert_contains "M6 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard move <mac> <group>"
	do_pair "M7 move one arg" f_M1 move aabbccddeeff
}

# ---- R: remove ----
battery_remove() {
	do_pair "R1 remove ok" f_M1 remove d8:bb:c1:cc:17:71
	assert_contains "R1 ref: removed" "$(cat "$T/sh.out")" "removed d8:bb:c1:cc:17:71 (tower)"
	assert_contains "R1 ref: applied" "$(cat "$T/sh.out")" "applied"
	assert_absent  "R1 ref: uci gone" "$(cat "$T/sh.uci")" "m_d8bbc1cc1771"
	do_pair "R2 remove unregistered" f_M1 remove de:ad:be:ef:00:01
	assert_contains "R2 ref: err" "$(cat "$T/sh.err")" "wanguard: de:ad:be:ef:00:01 not registered"
	do_pair "R3 remove invalid" f_M1 remove zz
	do_pair "R4 remove no args" f_M1 remove
	assert_contains "R4 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard remove <mac>"
	do_pair "R5 remove noname member" f_M1 remove 11:aa:22:bb:33:cc
	assert_contains "R5 ref: empty name" "$(cat "$T/sh.out")" "removed 11:aa:22:bb:33:cc ()"
}

# ---- GL: grouplist ----

f_GL1() { conf_groups; conf_members3; ifaces_std; add_link Meta; }
f_GL2() { conf_groups; conf_members3; ifaces_std; } # no Meta link
battery_grouplist() {
	do_pair "GL1 grouplist, Meta present" f_GL1 grouplist
	assert_contains "GL1 ref: header" "$(cat "$T/sh.out")" "GROUP      TYPE    IFACE      MARK  TABLE DEVICE         MEMBERS"
	assert_contains "GL1 ref: proxy row" "$(cat "$T/sh.out")" "proxy      proxy   -          300   500   Meta           0"
	assert_contains "GL1 ref: direct row" "$(cat "$T/sh.out")" "freedom    direct  vpn        100   400   eth1           1"
	assert_contains "GL1 ref: down dev" "$(cat "$T/sh.out")" "rostelecom direct  wan2       200   401   down           1"
	assert_rc      "GL1 ref: rc0" "$(cat "$T/sh.rc")" 0
	do_pair "GL2 grouplist, Meta absent" f_GL2 grouplist
	assert_contains "GL2 ref: proxy down" "$(cat "$T/sh.out")" "proxy      proxy   -          300   500   down"
	do_pair "GL3 grouplist, empty" f_L1 grouplist
	assert_contains "GL3 ref: header only" "$(cat "$T/sh.out")" "MEMBERS"
}

# ---- D: devices ----

f_D_leases() { # ok row, "*" name, short line (k=3, skipped)
	cat > /tmp/dhcp.leases <<'EOF'
1700000001 aa:bb:cc:dd:ee:01 192.168.88.35 buddy-052 aa:bb:cc:dd:ee:01
1700000002 11:22:33:44:55:02 192.168.88.36 * 11:22:33:44:55:02
1700000003 aa:bb:cc:dd:ee:03 192.168.88.37
EOF
}
f_D1() { f_D_leases; }
f_D2() { # arp only (static IPs): complete, incomplete, foreign-iface rows.
	# nud stale renders flags 0x2 (complete), failed renders 0x0 — probe v4
	arp_reset
	arp_entry 192.168.88.90 aa:bb:cc:dd:ee:10 br-lan stale   # 0x2 = online
	arp_entry 192.168.88.91 aa:bb:cc:dd:ee:11 br-lan failed  # 0x0 = skipped
	arp_entry 192.168.88.92 aa:bb:cc:dd:ee:12 eth0  stale    # other dev
}
f_D3() { # merge: lease+arp completion, arp-only, dup mac first-seen order
	f_D_leases
	arp_reset
	arp_entry 192.168.88.35 aa:bb:cc:dd:ee:01 br-lan stale # kernel renders lowercase
	arp_entry 192.168.88.99 aa:bb:cc:dd:ee:99 br-lan stale
	arp_entry 192.168.88.37 aa:bb:cc:dd:ee:03 br-lan stale
}
f_D4() { # invalid macs in leases filtered (kernel rejects garbage lladdrs,
	:      # so the regex-parity rows come from the file side); empty arp
	: > /tmp/dhcp.leases
	cat > /tmp/dhcp.leases <<'EOF'
1700000001 zz:bb:cc:dd:ee:10 192.168.88.90 ghost-zz aa:bb:cc:dd:ee:10
1700000002 aabbccddee55 192.168.88.91 ghost-bare aa:bb:cc:dd:ee:11
1700000003 aa:bb:cc:dd:ee:92 192.168.88.92 ghost-ok aa:bb:cc:dd:ee:92
EOF
	arp_reset
}
battery_devices() {
	do_pair "D1 devices, leases only" f_D1 devices
	assert_contains "D1 ref: row"       "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:01	192.168.88.35	buddy-052	0"
	assert_contains "D1 ref: star name" "$(cat "$T/sh.out")" "11:22:33:44:55:02	192.168.88.36	-	0"
	assert_absent   "D1 ref: skip k<4"  "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:03"
	do_pair "D2 devices, arp only" f_D2 devices
	assert_contains "D2 ref: online"     "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:10	192.168.88.90	-	1"
	assert_absent   "D2 ref: 0x0 skipped" "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:11"
	assert_absent   "D2 ref: foreign"     "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:12"
	do_pair "D3 devices, merge" f_D3 devices
	assert_contains "D3 ref: completed" "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:01	192.168.88.35	buddy-052	1"
	assert_contains "D3 ref: arp-only"  "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:99	192.168.88.99	-	1"
	assert_contains "D3 ref: arp name"  "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:03	192.168.88.37	-	1"
	assert_contains "D3 ref: order"     "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:01	192.168.88.35	buddy-052	1
11:22:33:44:55:02	192.168.88.36	-	0"
	do_pair "D4 devices, garbage macs filtered" f_D4 devices
	assert_contains "D4 ref: valid row" "$(cat "$T/sh.out")" "aa:bb:cc:dd:ee:92	192.168.88.92	ghost-ok	0"
	assert_absent   "D4 ref: zz gone"   "$(cat "$T/sh.out")" "ghost-zz"
	assert_absent   "D4 ref: bare gone" "$(cat "$T/sh.out")" "ghost-bare"
	do_pair "D5 devices, no leases no arp" f_L1 devices
}

# ---- GA: groupadd ----

f_empty() { : ; } # empty (touched) config
f_std() { f_empty; ifaces_std; } # empty config + vpn/wan2 fixtures
f_empty_pxy() { conf_groups; } # proxy already exists
f_empty_exist() { conf_groups; }
battery_groupadd() {
	do_pair "GA1 groupadd direct up-iface" f_std groupadd test vpn
	assert_contains "GA1 ref: created" "$(cat "$T/sh.out")" "group 'test' created (direct -> vpn)"
	assert_contains "GA1 ref: applied" "$(cat "$T/sh.out")" "applied"
	assert_contains "GA1 ref: uci"     "$(cat "$T/sh.uci")" "config group 'test'"
	do_pair "GA2 groupadd direct down-iface" f_std groupadd test wan2
	assert_contains "GA2 ref: note" "$(cat "$T/sh.out")" "note: iface 'wan2' is down or missing in netifd — routes will follow once it is up"
	do_pair "GA3 groupadd proxy" f_std groupadd pxy proxy
	assert_contains "GA3 ref: created" "$(cat "$T/sh.out")" "group 'pxy' created (proxy)"
	do_pair "GA4 groupadd second proxy" f_empty_pxy groupadd pxy2 proxy
	assert_contains "GA4 ref: err" "$(cat "$T/sh.err")" "wanguard: proxy group already exists: proxy (mihomo is a singleton)"
	do_pair "GA5 groupadd bad name 16" f_std groupadd abcdef0123456789 vpn
	assert_contains "GA5 ref: err" "$(cat "$T/sh.err")" "wanguard: invalid group name: 'abcdef0123456789' ([A-Za-z0-9_], <=15, not globals/wan)"
	do_pair "GA6 groupadd globals" f_std groupadd globals vpn
	do_pair "GA7 groupadd wan" f_std groupadd wan vpn
	do_pair "GA8 groupadd bad char" f_std groupadd my-group vpn
	do_pair "GA9 groupadd existing" f_empty_exist groupadd freedom vpn
	assert_contains "GA9 ref: err" "$(cat "$T/sh.err")" "wanguard: section 'freedom' already exists in wanguard"
	do_pair "GA10 groupadd no args" f_std groupadd
	assert_contains "GA10 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard groupadd <name> <iface|proxy>"
	do_pair "GA11 groupadd one arg" f_std groupadd test
	do_pair "GA12 groupadd 'direct'" f_std groupadd test direct
	assert_contains "GA12 ref: err" "$(cat "$T/sh.err")" "wanguard: 'direct' alone is not an interface name — pass a netifd iface (e.g. vpn, wan2; see: wanguard grouplist)"
	do_pair "GA13 groupadd unknown iface" f_std groupadd test ghost0
	assert_contains "GA13 ref: note" "$(cat "$T/sh.out")" "note: iface 'ghost0' is down or missing"
}

# ---- GS: groupset ----

f_GS1() { conf_groups; ifaces_std; } # freedom on vpn -> retarget wan2
f_GS2conf() { # direct groups only (proxy retarget must be legal here)
	cat > "$CONF" <<'EOF'
config globals 'globals'
	option no_mark '192.168.88.1'

config group 'freedom'
	option type 'direct'
	option iface 'vpn'

config group 'rostelecom'
	option type 'direct'
	option iface 'wan2'
EOF
	ifaces_std
}
f_GS3() { f_GS2conf; sync_apply; }
f_GS3b() { # stale watchdog opts must die on direct->proxy
	cat > "$CONF" <<'EOF'
config globals 'globals'
	option no_mark '192.168.88.1'

config group 'freedom'
	option type 'direct'
	option iface 'vpn'
	option wan_home 'vpn'
	option wanmode 'auto'

config group 'rostelecom'
	option type 'direct'
	option iface 'wan2'

config member 'm_d8bbc1cc1771'
	option name 'tower'
	option mac 'd8:bb:c1:cc:17:71'
	option group 'freedom'
EOF
	ifaces_std
	sync_apply
}
f_GS4() { conf_groups; iface vpn eth1; add_link eth1; } # proxy -> direct
battery_groupset() {
	do_pair "GS1 groupset direct->direct (flush)" f_GS1 groupset freedom wan2
	assert_contains "GS1 ref: updated" "$(cat "$T/sh.out")" "group 'freedom' updated (direct -> wan2)"
	assert_contains "GS1 ref: applied" "$(cat "$T/sh.out")" "applied"
	assert_contains "GS1 ref: flush"   "$(cat "$T/sh.out")" "wand: flush:freedom>vpn(10.99.0.1)"
	assert_contains "GS1 ref: uci home" "$(cat "$T/sh.uci")" "option wan_home 'wan2'"
	assert_contains "GS1 ref: uci mode" "$(cat "$T/sh.uci")" "option wanmode 'auto'"
	do_pair "GS2 groupset same iface (no flush)" f_GS1 groupset freedom vpn
	assert_contains "GS2 ref: updated" "$(cat "$T/sh.out")" "group 'freedom' updated (direct -> vpn)"
	assert_absent  "GS2 ref: NO flush" "$(cat "$T/sh.out")" "wand: "
	do_pair "GS3 groupset direct->proxy" f_GS3 groupset freedom proxy
	assert_contains "GS3 ref: updated" "$(cat "$T/sh.out")" "group 'freedom' updated (proxy)"
	assert_contains "GS3 ref: applied" "$(cat "$T/sh.out")" "applied"
	assert_absent  "GS3 ref: iface deleted" "$(cat "$T/sh.uci")" "	option iface 'vpn'"
	do_pair "GS4 groupset proxy->direct" f_GS4 groupset proxy vpn
	assert_contains "GS4 ref: uci home" "$(cat "$T/sh.uci")" "option wan_home 'vpn'"
	do_pair "GS5 groupset no such group" f_GS1 groupset nosuch vpn
	assert_contains "GS5 ref: err" "$(cat "$T/sh.err")" "wanguard: no such group: 'nosuch' (see: wanguard grouplist)"
	do_pair "GS6 groupset proxy conflict" f_GS1 groupset rostelecom proxy
	assert_contains "GS6 ref: err" "$(cat "$T/sh.err")" "wanguard: proxy group already exists: proxy (mihomo is a singleton)"
	do_pair "GS7 groupset no args" f_GS1 groupset
	assert_contains "GS7 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard groupset <name> <iface|proxy>"
	do_pair "GS8 groupset 'direct'" f_GS1 groupset freedom direct
	do_pair "GS9 groupset proxy->same proxy" f_GS1 groupset proxy proxy
	do_pair "GS10 groupset stale wand opts deleted" f_GS3b groupset freedom proxy
	assert_absent "GS10 ref: wan_home gone" "$(cat "$T/sh.uci")" "wan_home"
	assert_absent "GS10 ref: wanmode gone" "$(cat "$T/sh.uci")" "wanmode"
}

# ---- GD: groupdel ----

f_GD1() { # empty extra group to delete
	conf_groups
	cat >> "$CONF" <<'EOF'

config group 'tmpgrp'
	option type 'direct'
	option iface 'vpn'
EOF
	ifaces_std
	sync_apply
}
f_GD2() { conf_groups; conf_members3; ifaces_std; } # freedom non-empty
battery_groupdel() {
	do_pair "GD1 groupdel empty group" f_GD1 groupdel tmpgrp
	assert_contains "GD1 ref: deleted" "$(cat "$T/sh.out")" "group 'tmpgrp' deleted"
	assert_contains "GD1 ref: applied" "$(cat "$T/sh.out")" "applied"
	assert_absent  "GD1 ref: uci gone" "$(cat "$T/sh.uci")" "tmpgrp"
	assert_absent  "GD1 ref: set gone" "$(cat "$T/sh.state")" "mac_tmpgrp"
	do_pair "GD2 groupdel non-empty" f_GD2 groupdel freedom
	assert_contains "GD2 ref: err" "$(cat "$T/sh.err")" "wanguard: group 'freedom' still has members: d8:bb:c1:cc:17:71 (move them first: wanguard move <mac> <group>)"
	do_pair "GD3 groupdel no such" f_GD1 groupdel nosuch
	do_pair "GD4 groupdel no args" f_GD1 groupdel
	assert_contains "GD4 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard groupdel <name>"
}

# ---- WS: wanstatus ----

f_WS1() { # full wand state + force hook + a group with a member
	conf_groups; conf_members3; ifaces_std
	wand vpn.state up
	wand vpn.rtt 0.123
	wand vpn.alive 3
	wand vpn.since 1000000000
	wand wan2.state down
	wand wan2.force fail
	sync_apply
}
f_WS2() { conf_groups; ifaces_std; } # bare: no wand files at all
battery_wanstatus() {
	do_pair "WS1 wanstatus full" f_WS1 wanstatus
	assert_contains "WS1 ref: header" "$(cat "$T/sh.out")" "WAN      DEVICE         STATE        RTT(s)    ANCHORS   SINCE"
	assert_contains "WS1 ref: forced" "$(cat "$T/sh.out")" "wan2     -              down/forced  -         -/2       -"
	assert_contains "WS1 ref: rtt"    "$(cat "$T/sh.out")" "vpn      eth1           up           0.123     3/2       01.01 00:00:00"
	assert_contains "WS1 ref: gheader" "$(cat "$T/sh.out")" "GROUP    HOME     CURRENT  MODE      BACKUP               MEMBERS"
	assert_contains "WS1 ref: defaults" "$(cat "$T/sh.out")" "freedom  -        vpn      auto      *                    1"
	assert_contains "WS1 ref: backup star" "$(cat "$T/sh.out")" "rostelecom -        wan2     auto      *                    1"
	assert_rc      "WS1 ref: rc0" "$(cat "$T/sh.rc")" 0
	do_pair "WS2 wanstatus bare" f_WS2 wanstatus
	assert_contains "WS2 ref: vpn row" "$(cat "$T/sh.out")" "vpn      eth1           up           -         -/2       -"
	assert_contains "WS2 ref: wan2 row" "$(cat "$T/sh.out")" "wan2     -              up           -         -/2       -"
}

# ---- WA: wanset / wanauto ----

f_WA() { conf_groups; ifaces_std; sync_apply; }
f_WA_down() { # group sits on a DOWN iface; .addr remembers its IPv4
	cat > "$CONF" <<'EOF'
config globals 'globals'
	option no_mark '192.168.88.1'

config group 'freedom'
	option type 'direct'
	option iface 'wan2'

config group 'rostelecom'
	option type 'direct'
	option iface 'vpn'
EOF
	iface vpn eth1
	iface wan2 ''
	add_link eth1
	mkdir -p "$WAND_DIR"
	echo 10.99.0.9 > "$WAND_DIR/wan2.addr"
	sync_apply
}
f_WA_down_noaddr() { # like f_WA_down but NO .addr file: empty flush event
	cat > "$CONF" <<'EOF'
config globals 'globals'
	option no_mark '192.168.88.1'

config group 'freedom'
	option type 'direct'
	option iface 'wan2'

config group 'rostelecom'
	option type 'direct'
	option iface 'vpn'
EOF
	iface vpn eth1
	iface wan2 ''
	add_link eth1
	sync_apply
}
battery_wanset() {
	do_pair "WA1 wanset pin (flush)" f_WA wanset freedom wan2
	assert_contains "WA1 ref: pinned" "$(cat "$T/sh.out")" "group 'freedom' pinned to 'wan2' (manual override; watchdog skips it; resume: wanguard wanauto freedom)"
	assert_contains "WA1 ref: in-sync" "$(cat "$T/sh.out")" "in-sync"
	assert_contains "WA1 ref: flush"   "$(cat "$T/sh.out")" "wand: flush:freedom>vpn(10.99.0.1)"
	assert_contains "WA1 ref: uci mode" "$(cat "$T/sh.uci")" "option wanmode 'override'"
	do_pair "WA2 wanset same iface" f_WA wanset freedom vpn
	assert_absent "WA2 ref: NO flush" "$(cat "$T/sh.out")" "wand: "
	do_pair "WA3 wanset proxy" f_WA wanset proxy vpn
	assert_contains "WA3 ref: err" "$(cat "$T/sh.err")" "wanguard: group 'proxy' is proxy — it follows mihomo, wanset does not apply"
	do_pair "WA4 wanset no group" f_WA wanset nosuch vpn
	do_pair "WA5 wanset bad iface" f_WA wanset freedom ghost0
	assert_contains "WA5 ref: err" "$(cat "$T/sh.err")" "wanguard: unknown netifd iface: 'ghost0'"
	do_pair "WA6 wanset no args" f_WA wanset
	assert_contains "WA6 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard wanset <group> <iface>"
	do_pair "WA7 wanset one arg" f_WA wanset freedom
	do_pair "WA8 wanset from addr file" f_WA_down wanset freedom vpn
	assert_contains "WA8 ref: flush-file" "$(cat "$T/sh.out")" "wand: flush:freedom>wan2(10.99.0.9)"
	do_pair "WA9 wanset, old has no addr" f_WA_down_noaddr wanset freedom vpn
	assert_contains "WA9 ref: empty event" "$(cat "$T/sh.out")" "wand: "
}
battery_wanauto() {
	do_pair "WB1 wanauto" f_WA wanauto freedom
	assert_contains "WB1 ref: auto" "$(cat "$T/sh.out")" "group 'freedom' back in auto mode (home: ; watchdog fails back once home is up)"
	do_pair "WB2 wanauto proxy" f_WA wanauto proxy
	assert_contains "WB2 ref: err" "$(cat "$T/sh.err")" "wanguard: group 'proxy' is proxy - nothing to automate"
	do_pair "WB3 wanauto no group" f_WA wanauto nosuch
	do_pair "WB4 wanauto no args" f_WA wanauto
	assert_contains "WB4 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard wanauto <group>"
}

# ---- BS: backupset ----

f_BS() { # freedom on vpn; watched = vpn+wan2; wan3 known but unwatched
	conf_groups; ifaces_std
	iface wan3 ''
}
f_BS_listed() { # group with an existing explicit list (reset path)
	cat > "$CONF" <<'EOF'
config globals 'globals'
	option no_mark '192.168.88.1'

config group 'freedom'
	option type 'direct'
	option iface 'vpn'
	list backup_iface 'rostelecom'

config group 'rostelecom'
	option type 'direct'
	option iface 'wan2'
EOF
	iface vpn eth1
	iface wan2 ''
	add_link eth1
}
battery_backupset() {
	do_pair "BS1 backupset two ifaces" f_BS backupset freedom wan2 wan3
	assert_contains "BS1 ref: order" "$(cat "$T/sh.out")" "group 'freedom' backup order:wan2 wan3 (first UP wins; see: wanguard wanstatus)"
	assert_contains "BS1 ref: uci l1" "$(cat "$T/sh.uci")" "	list backup_iface 'wan2'"
	assert_contains "BS1 ref: uci l2" "$(cat "$T/sh.uci")" "	list backup_iface 'wan3'"
	do_pair "BS2 backupset own iface" f_BS backupset freedom vpn wan2
	assert_contains "BS2 ref: note" "$(cat "$T/sh.out")" "note: 'vpn' is the group's own iface — ignored (never its own backup)"
	assert_contains "BS2 ref: kept" "$(cat "$T/sh.out")" "backup order:wan2 (first UP wins"
	do_pair "BS3 backupset all filtered" f_BS backupset freedom vpn
	assert_contains "BS3 ref: err" "$(cat "$T/sh.err")" "wanguard: nothing left after conflict-checks — backup list not changed"
	assert_rc      "BS3 ref: rc1"  "$(cat "$T/sh.rc")" 1
	do_pair "BS4 backupset unknown iface mid-args" f_BS backupset freedom wan2 ghost0
	assert_contains "BS4 ref: err" "$(cat "$T/sh.err")" "wanguard: unknown netifd iface: 'ghost0'"
	do_pair "BS5 backupset unwatched" f_BS backupset freedom wan3
	assert_contains "BS5 ref: note" "$(cat "$T/sh.out")" "note: 'wan3' is not watched by the watchdog (no direct group sits on it) — it is skipped until it becomes some group's iface/wan_home"
	do_pair "BS6 backupset duplicate" f_BS backupset freedom wan2 wan2
	assert_contains "BS6 ref: first" "$(cat "$T/sh.out")" "backup order:wan2 (first UP wins"
	do_pair "BS7 backupset proxy" f_BS backupset proxy wan2
	assert_contains "BS7 ref: err" "$(cat "$T/sh.err")" "wanguard: group 'proxy' is proxy — backups are a direct-group feature"
	do_pair "BS8 backupset no args" f_BS backupset
	assert_contains "BS8 ref: usage" "$(cat "$T/sh.err")" "wanguard: usage: wanguard backupset <group> <iface>..."
	do_pair "BS9 backupset one arg" f_BS backupset freedom
	do_pair "BS10 backupset resets list" f_BS_listed backupset freedom wan2
	assert_contains "BS10 ref: order" "$(cat "$T/sh.out")" "backup order:wan2 (first UP wins"
	assert_absent  "BS10 ref: old list gone" "$(cat "$T/sh.uci")" "	list backup_iface 'rostelecom'"
}

# ---- H: help / usage / unknown ----
battery_help() {
	do_pair "H1 no args" f_L1
	do_pair "H2 help" f_L1 help
	do_pair "H3 -h" f_L1 -h
	do_pair "H4 --help" f_L1 --help
	assert_contains "H ref: usage line" "$(cat "$T/sh.out")" "usage: wanguard <command> [args]"
	assert_contains "H ref: backupset" "$(cat "$T/sh.out")" "backupset <group> <iface>...  backup priority order (#26): first UP wins;"
	assert_contains "H ref: arch tail" "$(cat "$T/sh.out")" "100,200,400,... / tables 400+ (see docs/ARCHITECTURE.md §2)."
	assert_rc      "H ref: rc0" "$(cat "$T/sh.rc")" 0
	do_pair "H5 unknown command" f_L1 frobnicate x y
	assert_contains "H5 ref: err" "$(cat "$T/sh.err")" "wanguard: unknown command: frobnicate (try: wanguard help)"
	assert_rc      "H5 ref: rc1" "$(cat "$T/sh.rc")" 1
}

# ---------- run ----------

setup_shims
echo "== stage 4 CLI byte-parity (issue #34): sh vs ucode =="

battery_list
battery_add
battery_move
battery_remove
battery_grouplist
battery_devices
battery_groupadd
battery_groupset
battery_groupdel
battery_wanstatus
battery_wanset
battery_wanauto
battery_backupset
battery_help

# WS3 rerun with the nocurl shim for both subjects (SUBJ_PATH override):
SUBJ_PATH=$SHIM_NOCURL
do_pair "WS3 wanstatus, curl missing" f_WS2 wanstatus
unset SUBJ_PATH
assert_contains "WS3 ref: note" "$(cat "$T/sh.out")" "note: curl missing — watchdog probes disabled"

# Native gate (the lab entry gate, stage-3 pattern): the ucode CLI must
# work with the sh companion COMPLETELY out of reach — no passthrough
# may be hiding behind any subcommand.
reset_state
conf_groups; conf_members3; ifaces_std; sync_apply
WANGUARD_SH=/nonexistent ucode -L "$UCDIR" "$UC" list > "$T/ng.out" 2> "$T/ng.err"
echo $? > "$T/ng.rc"
assert_rc      "NAT: list rc" "$(cat "$T/ng.rc")" 0
assert_contains "NAT: list in-sync" "$(cat "$T/ng.out")" "nft: in-sync"
reset_state
conf_groups; ifaces_std
WANGUARD_SH=/nonexistent ucode -L "$UCDIR" "$UC" grouplist > "$T/ng.out" 2> "$T/ng.err"
assert_contains "NAT: grouplist runs" "$(cat "$T/ng.out")" "GROUP"
reset_state
conf_groups; ifaces_std; sync_apply
WANGUARD_SH=/nonexistent ucode -L "$UCDIR" "$UC" apply > "$T/ng.out" 2> "$T/ng.err"
assert_contains "NAT: apply in-sync" "$(cat "$T/ng.out")" "in-sync"

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
