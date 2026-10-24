#!/bin/sh
# scenario.sh — differential smoke for the ucode spike (issue #29):
# the same fixture + state files drive the sh CLI and the ucode port;
# the event output must be identical (Phase 1 parity, Phase 2 seed).
#
# In the OpenWrt container (curl installed, no ubusd — probes are driven
# by the #6 force-hook files, exactly like tests/mock/run-tests.sh):
#   sh /spike/scenario.sh sh    -> expected events
#   sh /spike/scenario.sh ucode -> must print the same
set -u
RUNNER=${1:?usage: scenario.sh sh|ucode}
case "$RUNNER" in
	sh)    WG=/repo/router/wanguard ;;
	ucode) WG=/repo/docs/spike-ucode/wand.uc ;;
	*) exit 2 ;;
esac
run() {
	if [ "$RUNNER" = sh ]; then sh "$WG" wand-tick 2>&1
	else ucode -L /repo/docs/spike-ucode/mock "$WG" wand-tick 2>&1; fi
}

mkdir -p /etc/config /var/run
: > /var/run/ubus.sock          # wand.uc access() check; sh stub ignores it
printf 'wan1=eth0\nwan2=eth1\n' > /tmp/ubus.ifaces
export UBUS_IFACES=/tmp/ubus.ifaces
export UBUS_ADDRS=/dev/null
# sh side: ONLY the ubus binary is stubbed (same fixture files); uci/date/
# curl/jsonfilter stay real so both runners see identical /etc/config state
# (fresh dir: run-tests-ucode.sh may have left a date stub in /tmp/shim)
rm -rf /tmp/scen-shim
mkdir -p /tmp/scen-shim
cp /repo/tests/mock/bin/ubus /tmp/scen-shim/ubus
chmod +x /tmp/scen-shim/ubus
PATH="/tmp/scen-shim:$PATH"
export PATH

cat > /etc/config/wanguard <<'EOF'
config group 'a'
	option type 'direct'
	option iface 'wan1'

config group 'b'
	option type 'direct'
	option iface 'wan2'
EOF

reset() {
	rm -rf /tmp/wanguard /tmp/.uci # /tmp/.uci: stray uci deltas from
	mkdir -p /tmp/wanguard        # earlier runs would apply onto the
	echo ok > /tmp/wanguard/wan1.force # fresh heredoc config (flake seen
	echo ok > /tmp/wanguard/wan2.force # once: seed events reordered)
}
reset

echo "T1 seed:";             run
echo "T2 steady:";           run
echo "T3 fail x1:";          echo fail > /tmp/wanguard/wan1.force; run
echo "T4 fail x2:";          run
echo "T5 fail x3 down+failover:"; run
echo "T6 hold (dwell):";     run
echo "T7 ok x1:";            echo ok > /tmp/wanguard/wan1.force; run
echo "T8 ok x2..x5:";        run; run; run; run
echo "T9 ok x6 up+failback:"; echo 0 > /tmp/wanguard/a.lastswitch; run
echo "T10 flush files:";     cat /tmp/wanguard/*.flush 2>/dev/null
echo "T11 final uci:";       uci show wanguard 2>/dev/null | grep -E 'iface|wan_home'
