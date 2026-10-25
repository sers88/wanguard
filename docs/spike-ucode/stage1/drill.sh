#!/bin/sh
# drill.sh — stage-1 live failover/failback drill (issue #30, window phase F).
#
# Runs ON THE ROUTER while the keepalive drives ticks through the ucode
# wand-tick. Forces the home WAN's probes dead, watches the state machine
# flip the group to its backup (UCI + apply + #24 flush), unblocks, and
# watches the failback. Real traffic moves for real — the drill only fakes
# the PROBE decision; every other step (state files, UCI, apply render,
# conntrack flush protocol) is the production path being accepted.
#
# Usage:
#   sh drill.sh <group> [cycles] [--nft-only|--force-only] [--auto] [--any]
#
#   <group>      direct group to drill, e.g. freedom (must sit on wan_home)
#   [cycles]     how many failover/failback cycles (default 5)
#   --nft-only   every cycle via the real probe path (nft anchor block)
#   --force-only every cycle via the .force test hook (#6)
#   mixed (default, owner decision 2026-10-25): cycles 1-2 via nft — the
#   honest curl-into-reject path is what is NEW in ucode; cycles 3+ via
#   .force — fast, exercises the state machine/UCI/flush protocol
#   --auto       skip the interactive battery prompts (lab use)
#   --any        do not require /usr/bin/wanguard to be the ucode port
#
# nft method: a SEPARATE temporary table inet drill_drain with an output
# hook rejects ONLY the router's own curls to the anchor IPs through the
# home device (oifname). Client (forwarded) traffic never traverses an
# output hook — LAN is untouched; the only visible effect is the real
# failover that follows. #23 lesson: oifname, never `oif` (ifindex dies
# on ifup; nothing ifups during the drill).
#
# Abort/timeout is SAFE: the trap removes the block and the force files,
# and the watchdog then fails the group back home by itself (~2 min).
set -u

GROUP=""
CYCLES=5
MODE="mixed"
AUTO=0
ANY=0
for a in "$@"; do
	case "$a" in
	--nft-only) MODE=nft ;;
	--force-only) MODE=force ;;
	--auto) AUTO=1 ;;
	--any) ANY=1 ;;
	[0-9]*) CYCLES=$a ;;
	-*) echo "unknown flag: $a" >&2; exit 2 ;;
	*) if [ -z "$GROUP" ]; then GROUP=$a; else echo "extra arg: $a" >&2; exit 2; fi ;;
	esac
done
if [ -z "$GROUP" ] || [ "$CYCLES" -lt 1 ]; then
	echo "usage: sh drill.sh <group> [cycles] [--nft-only|--force-only] [--auto] [--any]" >&2
	exit 2
fi

WAND_DIR=/tmp/wanguard
STEP=3 # poll step, s (tick is 10 s)

# ---------- cleanup trap: runs on ANY exit path ----------
cleanup() {
	trap - EXIT INT TERM
	rm -f "$WAND_DIR"/*.force 2>/dev/null
	nft delete table inet drill_drain 2>/dev/null
	rm -f /tmp/drill_drain.nft 2>/dev/null
	echo
	echo "== cleanup done (no force files, no drill_drain table)"
	echo "   if the group is still on the backup, the watchdog fails it back"
	echo "   automatically within ~2 min; check: uci -q get wanguard.$GROUP.iface"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

fail() { echo "ABORT: $*" >&2; exit 1; }

# ---------- preflight ----------
[ -d "$WAND_DIR" ] || fail "no $WAND_DIR (keepalive never ran?)"
if [ "$ANY" != 1 ]; then
	head -1 /usr/bin/wanguard 2>/dev/null | grep -q ucode \
		|| fail "/usr/bin/wanguard is not the ucode port (--any to override)"
fi
HOME_WAN=$(uci -q get "wanguard.$GROUP.wan_home" 2>/dev/null) || true
[ -n "$HOME_WAN" ] || fail "group $GROUP has no wan_home (wand never seeded it — not steady state)"
CUR=$(uci -q get "wanguard.$GROUP.iface" 2>/dev/null) || true
[ "$CUR" = "$HOME_WAN" ] || fail "group $GROUP sits on '$CUR', home is '$HOME_WAN' — run from steady state (wanmode auto, home up)"
dead_backups=$(wanguard wanstatus 2>/dev/null | awk \
	'$1!="WAN" && $1!="GROUP" && $1!="HOME" && NF>=3 && $1!="'$HOME_WAN'" && $3 ~ /^down/ {print $1}')
[ -z "$dead_backups" ] || fail "backup WAN(s) down: $dead_backups — nothing to fail over to; restore steady state first"
nft list table inet drill_drain >/dev/null 2>&1 && fail "leftover drill_drain table from an earlier run: nft delete table inet drill_drain"
ls "$WAND_DIR"/*.force >/dev/null 2>&1 && fail "leftover force files: rm $WAND_DIR/*.force"
svc_ok=0
if [ -x /etc/init.d/wanguard ] && /etc/init.d/wanguard status 2>/dev/null | grep -q running; then
	svc_ok=1
elif ps 2>/dev/null | grep '[w]anguard-keep' >/dev/null; then
	svc_ok=1 # keepalive alive without procd (lab); NB busybox ps truncates
fi
[ "$svc_ok" = 1 ] || fail "keepalive loop is not running — the drill needs it to drive ticks"

ROW=$(wanguard grouplist 2>/dev/null | awk -v g="$GROUP" '$1==g{print}')
[ -n "$ROW" ] || fail "group $GROUP not found in grouplist"
MARK=$(echo "$ROW" | awk '{print $4}')
TABLE=$(echo "$ROW" | awk '{print $5}')
DEV0=$(echo "$ROW" | awk '{print $6}')
[ -n "$DEV0" ] || fail "cannot read current device for $GROUP from grouplist"

# ---------- watchers ----------
state_of() { cat "$WAND_DIR/$1.state" 2>/dev/null || echo up; }
iface_now() { uci -q get "wanguard.$GROUP.iface" 2>/dev/null || echo ''; }
dev_now() { wanguard grouplist 2>/dev/null | awk -v g="$GROUP" '$1==g{print $6}'; }

wait_state() { # $1=wan $2=want $3=timeout_s
	_n=0
	while [ "$_n" -lt "$3" ]; do
		[ "$(state_of "$1")" = "$2" ] && { echo "  ok: $1.state=$2 (+${_n}s)"; return 0; }
		sleep "$STEP"; _n=$((_n + STEP))
	done
	echo "TIMEOUT: $1.state never became $2" >&2
	return 1
}
wait_iface() { # $1=want (use ! to invert) $2=timeout_s
	_n=0
	while [ "$_n" -lt "$2" ]; do
		_c=$(iface_now)
		case "$1" in
		'!'*) [ "$_c" != "${1#!}" ] && [ -n "$_c" ] && { echo "  ok: iface=$_c (+${_n}s)"; return 0; } ;;
		*) [ "$_c" = "$1" ] && { echo "  ok: iface=$_c (+${_n}s)"; return 0; } ;;
		esac
		sleep "$STEP"; _n=$((_n + STEP))
	done
	echo "TIMEOUT: iface never became $1 (now: $(iface_now))" >&2
	return 1
}
battery() {
	[ "$AUTO" = 1 ] && { echo "  (auto: battery prompt skipped)"; return 0; }
	printf '  батарея 5/5 с клиента? [y/N] '
	read -r _ans || _ans=""
	case "$_ans" in y | Y | yes | да | Д | д) return 0 ;; *) return 1 ;; esac
}

# ---------- anchor resolution for the nft method ----------
anchor_ips() {
	hosts=$(uci -q get wanguard.globals.wan_anchors 2>/dev/null | tr ' ' '\n' | sed -e '/^$/d')
	if [ -z "$hosts" ]; then # list absent -> legacy pair (#23 precedence)
		hosts=$(uci -q get wanguard.globals.wan_anchor1 2>/dev/null)
		hosts="$hosts
$(uci -q get wanguard.globals.wan_anchor2 2>/dev/null)"
	fi
	hosts=$(echo "$hosts" | sed -e 's#^[a-zA-Z]*://##' -e 's#[/:].*##' -e '/^$/d')
	_ips=""
	for h in $hosts; do
		case "$h" in
		*[!0-9.]*) # hostname: resolve via LAN dnsmasq (probe DNS is unbound)
			_r=$(nslookup "$h" 127.0.0.1 2>/dev/null | sed -n 's/^Address[ 0-9]*: \([0-9.]*\)$/\1/p' | head -n 2)
			;;
		*) _r="$h" ;; # anchor URL with an IP literal (lab)
		esac
		for one in $_r; do
			case " $_ips " in *" $one "*) ;; *) _ips="$_ips $one" ;; esac
		done
	done
	echo $_ips
}
drain_up() { # $1=home device
	ips=$(anchor_ips)
	[ -n "$ips" ] || { echo "ABORT: no anchor IPs resolved" >&2; return 1; }
	settxt=""
	for ip in $ips; do settxt="$settxt$ip, "; done
	settxt="${settxt%, }"
	echo "  nft drain: oifname $1 <- anchors:$settxt (tcp/80, router output only)"
	cat >/tmp/drill_drain.nft <<EOF
table inet drill_drain {
	chain output {
		type filter hook output priority -150; policy accept;
		ip daddr { $settxt } oifname "$1" tcp dport 80 counter reject comment "wanguard stage1 drill"
	}
}
EOF
	nft -f /tmp/drill_drain.nft
}

# ---------- headline ----------
echo "drill: group=$GROUP home=$HOME_WAN cycles=$CYCLES mode=$MODE auto=$AUTO"
echo "  mark=$MARK table=$TABLE dev=$DEV0"
echo "  restore command if anything goes wrong:"
echo "    sh /root/rollback/$(ls -t /root/rollback 2>/dev/null | head -1)/rollback.sh"
echo

i=1
while [ "$i" -le "$CYCLES" ]; do
	case "$MODE" in
	nft) cm=nft ;;
	force) cm=force ;;
	*) [ "$i" -le 2 ] && cm=nft || cm=force ;;
	esac
	echo "== cycle $i/$CYCLES [$cm] =============================="

	# --- dead phase ---
	case "$cm" in
	nft)
		drain_up "$DEV0" || exit 1
		;;
	force)
		echo fail >"$WAND_DIR/$HOME_WAN.force"
		echo "  force: $HOME_WAN.force=fail"
		;;
	esac
	wait_state "$HOME_WAN" down 90 || exit 1
	wait_iface "!$HOME_WAN" 180 || exit 1
	DEV1=$(dev_now)
	if [ "$DEV1" != "$DEV0" ]; then
		echo "  egress moved: $DEV0 -> $DEV1"
	else
		echo "  WARN: device unchanged ($DEV1) — inspect grouplist"
	fi
	ip route get 1.1.1.1 mark "$MARK" 2>/dev/null | head -1 || true
	battery || fail "battery RED while failed over (self-heals: cleanup unblocks, watchdog fails back ~2 min)"

	# --- recover phase ---
	case "$cm" in
	nft) nft delete table inet drill_drain && echo "  nft drain removed" ;;
	force) echo ok >"$WAND_DIR/$HOME_WAN.force" && echo "  force: $HOME_WAN.force=ok" ;;
	esac
	wait_state "$HOME_WAN" up 150 || exit 1
	wait_iface "$HOME_WAN" 120 || exit 1
	battery || fail "battery RED after failback"
	echo "  cycle $i green"
	i=$((i + 1))
done

# ---------- final sanity ----------
echo
echo "== drill complete: $CYCLES/$CYCLES green"
[ "$(state_of "$HOME_WAN")" = up ] && echo "  state: $HOME_WAN=up"
[ "$(iface_now)" = "$HOME_WAN" ] && echo "  iface: $GROUP=$HOME_WAN (home)"
DEVF=$(dev_now)
[ "$DEVF" = "$DEV0" ] && echo "  device: $DEVF (as before)"
ls "$WAND_DIR"/*.force >/dev/null 2>&1 && {
	# the drill's own force file is removed by the EXIT trap — warn only about foreign ones
	_foreign=$(ls "$WAND_DIR"/*.force 2>/dev/null | grep -v "/$HOME_WAN.force$")
	[ -z "$_foreign" ] && echo "  no foreign force files" || { echo "  WARN: foreign force files left:"; echo "$_foreign"; }
} || echo "  no force files"
nft list table inet drill_drain >/dev/null 2>&1 && echo "  WARN: drill_drain left" || echo "  no drill_drain table"
wanguard wanstatus 2>&1 | head -8
