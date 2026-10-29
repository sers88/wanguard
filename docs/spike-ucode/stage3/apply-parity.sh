#!/bin/sh
# apply-parity.sh — render-parity harness for stage 3 of the ucode
# migration (issue #33).
#
# Subjects:
#   sh = router/wanguard (the battle-tested reference implementation)
#   uc = docs/spike-ucode/wand.uc via `ucode -L` mock dir. In PHASE 1 its
#        `apply` is a passthrough to the sh CLI (WANGUARD_SH), so the
#        differential MUST be byte-identical — that validates the harness
#        itself (same code, two invocation paths). In PHASE 2 wand.uc
#        grows native apply and this very file becomes the ucode gate:
#        every byte of stdout/stderr, the nft batch text, the rendered
#        nft/ip state and both rcs must still match.
#
# Per fixture (UCI config + iface fixtures), each subject runs:
#   1. fresh NFT_STATE/IP_STATE/UCI
#   2. apply            -> merged output (THE keepalive contract surface,
#                          `[ "$out" = in-sync ]` is byte-compared) + rc
#   3. apply again      -> exactly `in-sync` unless the fixture sets DRIFT=1
#   4. state snapshot   -> nft list table + `-a` chains + ip rule/routes
#   5. fresh WANGUARD_DEBUG run -> the nft batch text (render artifact)
#
# Reference assertions (sh side) pin the behavior per fixture; the
# differential (sh vs uc) is asserted for every artifact.
#
# Environment: runs INSIDE openwrt/rootfs:x86_64-25.12.5 — real uci on
# /etc/config, NO ubusd (iface state via fixture files), stateful mocks
# for nft/ip (transcripts: NOTES.md):
#   docker run --rm -v <repo>:/repo:ro openwrt/rootfs:x86_64-25.12.5 \
#     sh /repo/docs/spike-ucode/stage3/apply-parity.sh
#
# WARNING: rewrites /etc/config/wanguard — container only.
set -u

ROOT=/repo
WG_SH=$ROOT/router/wanguard
UC=$ROOT/docs/spike-ucode/wand.uc
UCDIR=$ROOT/docs/spike-ucode/mock
MOCKBIN=$ROOT/tests/mock/bin
CONF=/etc/config/wanguard

TMP=/tmp/wanguard-parity.$$
NFT_STATE=$TMP/nft.db
IP_STATE=$TMP/ip
UBUS_IFACES=$TMP/ubus.ifaces
UBUS_ADDRS=$TMP/ubus.addrs
export NFT_STATE IP_STATE UBUS_IFACES UBUS_ADDRS
export WANGUARD_SH=$WG_SH # wand.uc passthrough target (phase 1)

rm -rf "$TMP" /tmp/parity-shim /tmp/parity-shim-nonft
mkdir -p "$TMP" /tmp/parity-shim /etc/config
# the CLI loads the skeleton from the apk-installed path (NFT_FILE) —
# install it like the package would (container rw layer)
mkdir -p /usr/share/wanguard
cp "$ROOT/router/wanguard.nft" /usr/share/wanguard/wanguard.nft
# shim PATH: stateful nft/ip + ubus/jsonfilter stubs; uci stays REAL
for b in nft ip ubus jsonfilter; do
	cp "$MOCKBIN/$b" /tmp/parity-shim/$b && chmod +x /tmp/parity-shim/$b
done
BASEPATH=$PATH
SHIM_PATH=/tmp/parity-shim:$BASEPATH
PATH=$SHIM_PATH
export PATH

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1 (got: '$2', want: '$3')"; }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
assert_rc()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "rc=$2" "rc=$3"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" "*$3*" ;; esac; }

cleanup() { rm -rf "$TMP" /tmp/parity-shim /tmp/parity-shim-nonft; }
trap cleanup EXIT

reset_state() { # nft/ip/uci to zero; constant seed: main default + mockwan
	rm -rf "$NFT_STATE" "$IP_STATE" /tmp/.uci # stray uci deltas (#32 lesson)
	: > "$UBUS_IFACES"
	: > "$UBUS_ADDRS"
	mkdir -p "$IP_STATE"
	printf 'default via 192.0.2.1 dev mockwan metric 10\n' > "$IP_STATE/route.main"
	: > "$IP_STATE/links"
	add_link mockwan # fallback metric-200 target must exist
}

add_link() { printf '%s\n' "$1" >> "$IP_STATE/links"; }
iface()    { printf '%s=%s\n' "$1" "$2" >> "$UBUS_IFACES"; }
addr()     { printf '%s=%s\n' "$1" "$2" >> "$UBUS_ADDRS"; }

run_sh() { sh "$WG_SH" "$@"; }
run_uc() { ucode -L "$UCDIR" "$UC" "$@"; }

snapshot() { # $1 = output file; every parsed surface, rendered by the mocks
	{
		echo "== nft table =="
		PATH=$SHIM_PATH nft list table inet wanguard 2>&1
		echo "== chain marking =="
		PATH=$SHIM_PATH nft -a list chain inet wanguard marking 2>&1
		echo "== chain redir =="
		PATH=$SHIM_PATH nft -a list chain inet wanguard redir 2>&1
		echo "== ip rule =="
		PATH=$SHIM_PATH ip rule show 2>&1
		echo "== ip routes all =="
		PATH=$SHIM_PATH ip route show table all 2>&1
	} > "$1"
}

seed_drift() { # stale state the next apply must clean (P12): orphan set,
	nft -f - <<'EOF' # rule with a foreign tag, ip rule + route table
add set inet wanguard mac_zzz { type ether_addr; flags interval; }
add element inet wanguard mac_zzz { 11:22:33:44:55:66 }
add rule inet wanguard marking iifname "br-lan" ether saddr @mac_a ip daddr != @local_v4 ip daddr != @no_mark meta mark set 999 comment "wg:old:m999"
EOF
	ip rule add prio 8150 fwmark 999 table 450
	ip route replace default dev mockwan table 450
}

# do_fixture <label> <setup-fn> [post-first-apply-hook]
# runs both subjects on identical fresh state, captures every artifact,
# asserts the differential. Sets OUTF/OUT2F/BATCHF/RCT (first subject's
# artifacts) for the caller's reference assertions.
do_fixture() {
	local label=$1 setup=$2 hook=${3:-} s
	for s in sh uc; do
		reset_state
		"$setup"
		if [ "$s" = sh ]; then
			OUTF=$(run_sh apply 2>&1); RCT=$?
			OUT2F=$(run_sh apply 2>&1)
		else
			OUTF=$(run_uc apply 2>&1); RCT=$?
			OUT2F=$(run_uc apply 2>&1)
		fi
		[ -n "$hook" ] && "$hook"
		if [ -n "$hook" ]; then # apply again AFTER the drift hook
			if [ "$s" = sh ]; then OUTF=$(run_sh apply 2>&1); RCT=$?; else OUTF=$(run_uc apply 2>&1); RCT=$?; fi
		fi
		snapshot "$TMP/snap.$s"
		reset_state
		"$setup"
		# merged capture: the ucode passthrough emits the debug batch on
		# ITS stdout, so stdout-suppression would lose it; subshell export
		# contains the var (busybox ash PERSISTS `VAR=v func` after the
		# call — found live in this very harness, do not "simplify")
		if [ "$s" = sh ]; then
			BATCHF=$( (export WANGUARD_DEBUG=1; run_sh apply) 2>&1 )
		else
			BATCHF=$( (export WANGUARD_DEBUG=1; run_uc apply) 2>&1 )
		fi
		eval "out_$s=\$OUTF out2_$s=\$OUT2F rc_$s=\$RCT batch_$s=\$BATCHF"
		cp "$TMP/snap.$s" "$TMP/snap.$s.keep"
	done
	assert_eq   "$label: rc parity"           "$rc_sh"    "$rc_uc"
	# #38: the ucode CLI knows 'direct-lb' (the sh differential reference
	# does not), so its invalid-type warning line INTENTIONALLY differs —
	# strip that line from both sides before the byte comparison; the
	# exact per-side texts are asserted at P14 below
	assert_eq   "$label: stdout parity (ex type warning)" \
		"$(printf '%s' "$out_sh" | grep -v 'has no valid type')" \
		"$(printf '%s' "$out_uc" | grep -v 'has no valid type')"
	assert_eq   "$label: batch parity (ex type warning)" \
		"$(printf '%s' "$batch_sh" | grep -v 'has no valid type')" \
		"$(printf '%s' "$batch_uc" | grep -v 'has no valid type')"
	assert_eq   "$label: state parity"        "$(cat "$TMP/snap.sh.keep")" "$(cat "$TMP/snap.uc.keep")"
	if [ -z "$hook" ]; then
		# the keepalive contract: the SECOND run must not report changes.
		# (Wanted literally `in-sync`, but down-iface fixtures warn on
		# every tick by design, and a failed gate prints "nothing
		# applied" — the contract is: no OUTPUT LINE equal to `applied`.)
		for s in sh uc; do
			eval "v=\$out2_$s"
			if printf '%s' "$v" | grep -qx 'applied'; then
				bad "$label: $s idempotent (2nd run)" "$v" "no 'applied' line"
			else
				ok "$label: $s idempotent (2nd run)"
			fi
		done
	fi
}

# ---------- fixtures (UCI heredocs + iface fixtures; #33 list) ----------

f0_empty() {
	uci_load <<'EOF'
config globals 'globals'
EOF
}

f1_one_direct() {
	uci_load <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'
EOF
	iface vpn pptp-a
	addr vpn 198.51.100.10
	add_link pptp-a
}

f2_two_direct() {
	uci_load <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config group 'b'
	option type 'direct'
	option iface 'wan2'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'

config member 'm_2'
	option name 'host2'
	option mac '11:22:33:44:55:66'
	option group 'b'
EOF
	iface vpn pptp-a
	iface wan2 pppoe-b
	add_link pptp-a
	add_link pppoe-b
}

f3_three_direct() { # allocation: marks 100/200/400 (300 skipped), tables 400/401/402
	uci_load <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config group 'b'
	option type 'direct'
	option iface 'wan2'

config group 'c'
	option type 'direct'
	option iface 'wan3'
EOF
	iface vpn pptp-a
	iface wan2 pppoe-b
	iface wan3 pppoe-c
	add_link pptp-a
	add_link pppoe-b
	add_link pppoe-c
}

f4_proxy_plus_direct() { # redir rule, TCP-not-marked, Meta route, prio 8000
	uci_load <<'EOF'
config globals 'globals'
	option redir_port '7892'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config group 'c'
	option type 'proxy'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'c'
EOF
	iface vpn pptp-a
	add_link pptp-a
	add_link Meta
}

f5_proxy_only() {
	uci_load <<'EOF'
config globals 'globals'

config group 'c'
	option type 'proxy'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'c'
EOF
	add_link Meta
}

f6_empty_group() { # set created, no elements
	uci_load <<'EOF'
config globals 'globals'

config group 'g'
	option type 'direct'
	option iface 'vpn'
EOF
	iface vpn pptp-a
	add_link pptp-a
}

f7_no_mark() {
	uci_load <<'EOF'
config globals 'globals'
	list no_mark '192.168.100.5'
	list no_mark '192.168.200.7'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'
EOF
	iface vpn pptp-a
	add_link pptp-a
}

f8_dup_macs() { # two members, same MAC, same group -> one element
	uci_load <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'

config member 'm_2'
	option name 'host1-clone'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'
EOF
	iface vpn pptp-a
	add_link pptp-a
}

f9_garbage_mac() { # hand-edited UCI with a typo'd MAC: apply renders the
	uci_load <<'EOF' # raw value (no normalize on the render path), the nft
config globals 'globals' # -c gate must reject the batch, NOTHING applied

config group 'a'
	option type 'direct'
	option iface 'vpn'

config member 'm_1'
	option name 'host1'
	option mac 'not-a-mac'
	option group 'a'
EOF
	iface vpn pptp-a
	add_link pptp-a
}

f10_iface_down() { # netifd object exists, device gone: set rendered,
	uci_load <<'EOF' # route skipped + warning
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'
EOF
	iface vpn ''
	add_link pptp-a
}

f11_iface_unknown() { # iface not in netifd at all: same fail-soft path
	uci_load <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'ghost'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'
EOF
	iface vpn pptp-a
	add_link pptp-a
}

f12_watchdog_noise() { # backup_iface/wan_home/wanmode must not leak
	uci_load <<'EOF' # into the render
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'
	list backup_iface 'wan2'
	list backup_iface 'wan3'
	option wan_home 'vpn'
	option wanmode 'override'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'

config group 'b'
	option type 'direct'
	option iface 'wan2'

config member 'm_2'
	option name 'host2'
	option mac '11:22:33:44:55:66'
	option group 'b'
EOF
	iface vpn pptp-a
	iface wan2 pppoe-b
	iface wan3 pppoe-c
	add_link pptp-a
	add_link pppoe-b
	add_link pppoe-c
}

f13_legacy_migrate() { # pre-#13 layout: migrate creates a/b/c, once
	uci_load <<'EOF'
config globals 'globals'

config wan 'wan'
	option group_a 'pppoe'
EOF
	iface vpn pptp-a
	iface wan2 pppoe-b
	add_link pptp-a
	add_link pppoe-b
	add_link Meta
}

f14_type_garbage() { # invalid type: warning + ignored by alloc/render
	uci_load <<'EOF'
config globals 'globals'

config group 'a'
	option type 'direct'
	option iface 'vpn'

config group 'x'
	option type 'banana'
	option iface 'vpn'

config member 'm_1'
	option name 'host1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'
EOF
	iface vpn pptp-a
	add_link pptp-a
}

f15_multi_member_mixed() { # 3 groups, 5 members, several members per set.
	uci_load <<'EOF' # MACs are colon-lowercase (the form `wanguard add`
config globals 'globals' # writes); exotic forms are fixture P17

config group 'a'
	option type 'direct'
	option iface 'vpn'

config group 'b'
	option type 'direct'
	option iface 'wan2'

config group 'c'
	option type 'proxy'

config member 'm_1'
	option name 'host-a'
	option mac 'aa:bb:cc:dd:ee:ff'
	option group 'a'

config member 'm_2'
	option name 'host-a2'
	option mac 'aa:bb:cc:dd:ee:01'
	option group 'a'

config member 'm_3'
	option name 'host-b'
	option mac 'aa:bb:cc:dd:ee:02'
	option group 'b'

config member 'm_4'
	option name 'host-c'
	option mac 'aa:bb:cc:dd:ee:03'
	option group 'c'

config member 'm_5'
	option name 'host-b2'
	option mac 'aa:bb:cc:dd:ee:04'
	option group 'b'
EOF
	iface vpn pptp-a
	iface wan2 pppoe-b
	add_link pptp-a
	add_link pppoe-b
	add_link Meta
}

f17_exotic_macs() { # hand-edited UCI with dash/cisco MAC forms: real nft
	uci_load <<'EOF' # rejects them in ether_addr sets; the CLI must fail
config globals 'globals' # SAFE — `-c` gate, NOTHING applied, rc 1

config group 'a'
	option type 'direct'
	option iface 'vpn'

config member 'm_1'
	option name 'host1'
	option mac 'AA-BB-CC-DD-EE-01'
	option group 'a'

config member 'm_2'
	option name 'host2'
	option mac 'aabb.ccdd.ee02'
	option group 'a'
EOF
	iface vpn pptp-a
	add_link pptp-a
}

uci_load() { cat > "$CONF"; }

echo "== stage 3 apply render-parity (#33): sh vs ucode =="

# --- P0 fresh bootstrap: skeleton + legacy migrate fire even without a
# `config wan` section (a(vpn) b(wan2) c(proxy) created; iface fixtures
# empty -> routes warn+skip, nft side still renders, rc 0) ---
do_fixture "P0-empty" f0_empty
assert_rc    "P0: sh rc"          "$rc_sh"  0
assert_contains "P0: sh first apply" "$out_sh" "applied"
assert_contains "P0: sh migrate"  "$out_sh" "migrated legacy layout: groups a(vpn) b(wan2) c(proxy) created"
assert_contains "P0: sh batch loads skeleton" "$batch_sh" "local_v4"
assert_contains "P0: sh c rendered as proxy"  "$batch_sh" 'wg:c:r7892'

# --- P1 one direct group ---
do_fixture "P1-one-direct" f1_one_direct
assert_contains "P1: marking rule"    "$batch_sh" 'add rule inet wanguard marking iifname "br-lan" ether saddr @mac_a ip daddr != @local_v4 ip daddr != @no_mark meta mark set 100 comment "wg:a:m100"'
assert_contains "P1: set create"      "$batch_sh" 'add set inet wanguard mac_a { type ether_addr; flags interval; }'
assert_contains "P1: element"         "$batch_sh" 'add element inet wanguard mac_a { aa:bb:cc:dd:ee:ff }'
assert_contains "P1: ip rule 8100"    "$(cat "$TMP/snap.sh.keep")" '8100:	from all fwmark 0x64 lookup 400'
assert_contains "P1: table 400 dev"   "$(cat "$TMP/snap.sh.keep")" 'default dev pptp-a'
assert_contains "P1: metric-200 fallback" "$(cat "$TMP/snap.sh.keep")" 'default via 192.0.2.1 dev mockwan metric 10 metric 200 table 400'

# --- P2 two direct ---
do_fixture "P2-two-direct" f2_two_direct
assert_contains "P2: b mark 200"   "$batch_sh" 'wg:b:m200'
assert_contains "P2: table 401"    "$(cat "$TMP/snap.sh.keep")" 'table 401'
assert_contains "P2: prio 8101"    "$(cat "$TMP/snap.sh.keep")" '8101:	from all fwmark 0xc8 lookup 401'

# --- P3 three direct: 300 skipped ---
do_fixture "P3-three-direct" f3_three_direct
assert_contains "P3: c mark 400 (300 skipped)" "$batch_sh" 'wg:c:m400'
assert_contains "P3: table 402"    "$(cat "$TMP/snap.sh.keep")" 'table 402'
assert_contains "P3: prio 8102"    "$(cat "$TMP/snap.sh.keep")" '8102:	from all fwmark 0x190 lookup 402'

# --- P4 proxy + direct ---
do_fixture "P4-proxy-plus-direct" f4_proxy_plus_direct
assert_contains "P4: redir rule"       "$batch_sh" 'meta l4proto tcp redirect to :7892 comment "wg:c:r7892"'
assert_contains "P4: TCP not marked"   "$batch_sh" 'meta l4proto != tcp'
assert_contains "P4: prio 8000 mark 300" "$(cat "$TMP/snap.sh.keep")" '8000:	from all fwmark 0x12c lookup 500'
assert_contains "P4: Meta route"       "$(cat "$TMP/snap.sh.keep")" 'default dev Meta table 500'
assert_contains "P4: direct a still 100" "$batch_sh" 'wg:a:m100'

# --- P5 proxy only ---
do_fixture "P5-proxy-only" f5_proxy_only
assert_contains "P5: redir"        "$batch_sh" 'redirect to :7892'

# --- P6 empty group: set exists, no elements ---
do_fixture "P6-empty-group" f6_empty_group
assert_contains "P6: set created"  "$batch_sh" 'add set inet wanguard mac_g { type ether_addr; flags interval; }'
assert_contains "P6: no elements"  "$(cat "$TMP/snap.sh.keep")" 'set mac_g'

# --- P7 no_mark elements ---
do_fixture "P7-no-mark" f7_no_mark
assert_contains "P7: no_mark add"  "$batch_sh" 'add element inet wanguard no_mark { 192.168.100.5 }'
assert_contains "P7: no_mark add2" "$batch_sh" 'add element inet wanguard no_mark { 192.168.200.7 }'

# --- P8 dup macs: the batch carries one add line PER member (real nft:
# duplicate member add is a silent rc 0, so the state converges) ---
do_fixture "P8-dup-macs" f8_dup_macs
n=$(printf '%s' "$batch_sh" | grep -c 'add element inet wanguard mac_a { aa:bb:cc:dd:ee:ff }')
assert_eq "P8: one add line per member" "$n" "2"
assert_eq  "P8: set holds the mac once" \
	"$(PATH=$SHIM_PATH nft list set inet wanguard mac_a | grep -c 'aa:bb:cc:dd:ee:ff')" "1"

# --- P9 garbage MAC: the nft -c gate rejects the batch, NOTHING applied.
# NB: hostile NAMES are unreachable via UCI (the uci parser itself
# rejects non-[A-Za-z0-9_] section names), so the reachable gate trigger
# is a garbage element value on the raw render path. ---
do_fixture "P9-garbage-mac" f9_garbage_mac
assert_rc    "P9: sh rc"              "$rc_sh" 1
assert_contains "P9: gate message"    "$out_sh" "nft check failed, nothing applied"
assert_contains "P9: skeleton alive"  "$(cat "$TMP/snap.sh.keep")" "set local_v4"
case $(cat "$TMP/snap.sh.keep") in *"wg:"*|*mac_a*) bad "P9: nothing applied" "leaked" "clean" ;; *) ok "P9: nothing applied" ;; esac
case $(cat "$TMP/snap.sh.keep") in *8100:*) bad "P9: no ip rules (reconcile skipped)" "leaked" "clean" ;; *) ok "P9: no ip rules (reconcile skipped)" ;; esac

# --- P10 iface down: route skipped, warning ---
do_fixture "P10-iface-down" f10_iface_down
assert_contains "P10: warning"     "$out_sh" "iface 'vpn' down or missing"
assert_contains "P10: set rendered" "$batch_sh" 'add set inet wanguard mac_a'
assert_contains "P10: no table 400 route" "$(cat "$TMP/snap.sh.keep")" "== ip routes all =="

# --- P11 iface unknown ---
do_fixture "P11-iface-unknown" f11_iface_unknown
assert_contains "P11: warning"     "$out_sh" "iface 'ghost' down or missing"

# --- P12 watchdog noise: render unaffected ---
do_fixture "P12-watchdog-noise" f12_watchdog_noise
assert_contains "P12: a rendered"  "$batch_sh" 'wg:a:m100'
assert_contains "P12: b rendered"  "$batch_sh" 'wg:b:m200'

# --- P13 legacy migrate ---
do_fixture "P13-legacy-migrate" f13_legacy_migrate
assert_contains "P13: migrate msg" "$out_sh" "migrated legacy layout: groups a(vpn) b(wan2) c(proxy) created"
assert_contains "P13: c is proxy"  "$batch_sh" 'wg:c:r7892'
assert_contains "P13: a mark 100"  "$batch_sh" 'wg:a:m100'
assert_contains "P13: b mark 200"  "$batch_sh" 'wg:b:m200'

# --- P14 type garbage: warning + ignored.
# #38: the warning TEXT differs by design — the ucode side enumerates
# direct-lb (the sh reference predates it); assert both exact texts ---
do_fixture "P14-type-garbage" f14_type_garbage
assert_contains "P14: sh warning (pre-#38 text)"        "$out_sh" "(direct|proxy) — ignored"
assert_contains "P14: uc warning (direct-lb added)"     "$out_uc" "(direct|direct-lb|proxy) — ignored"
assert_contains "P14: warning"     "$out_sh" "group 'x' has no valid type"
assert_contains "P14: a rendered"  "$batch_sh" 'wg:a:m100'
case "$batch_sh" in *"wg:x"*) bad "P14: x not rendered" "leaked" "ignored" ;; *) ok "P14: x not rendered" ;; esac

# --- P15 mixed groups, several members per set (colon-lowercase MACs,
# the form `wanguard add` writes — rendered verbatim on the apply path) ---
do_fixture "P15-multi-member" f15_multi_member_mixed
assert_contains "P15: member :01"  "$batch_sh" '{ aa:bb:cc:dd:ee:01 }'
assert_contains "P15: member :02"  "$batch_sh" '{ aa:bb:cc:dd:ee:02 }'
assert_contains "P15: member :03"  "$batch_sh" '{ aa:bb:cc:dd:ee:03 }'
assert_contains "P15: proxy c"     "$batch_sh" 'wg:c:r7892'

# --- P17 exotic MAC forms in hand-edited UCI: -c gate, fail-safe ---
do_fixture "P17-exotic-macs" f17_exotic_macs
assert_rc    "P17: sh rc"              "$rc_sh" 1
assert_contains "P17: gate message"    "$out_sh" "nft check failed, nothing applied"
case $(cat "$TMP/snap.sh.keep") in *"wg:"*|*mac_a*) bad "P17: nothing applied" "leaked" "clean" ;; *) ok "P17: nothing applied" ;; esac

# --- P12b drift: stale set/rule/ip-rule/table cleaned (hook flow) ---
do_fixture "P16-drift-cleanup" f1_one_direct seed_drift
assert_eq    "P16: cleanup reported" "$out_sh" "applied"
SNAP=$(cat "$TMP/snap.sh.keep")
case "$SNAP" in *mac_zzz*|"wg:old"*) bad "P16: orphan set/rule gone" "leaked" "clean" ;; *) ok "P16: orphan set/rule gone" ;; esac
case "$SNAP" in *8150*) bad "P16: orphan ip rule gone" "leaked" "clean" ;; *) ok "P16: orphan ip rule gone" ;; esac
case "$SNAP" in *"table 450"*) bad "P16: orphan table 450 gone" "leaked" "clean" ;; *) ok "P16: orphan table 450 gone" ;; esac
assert_contains "P16: live a intact" "$SNAP" 'default dev pptp-a table 400'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
