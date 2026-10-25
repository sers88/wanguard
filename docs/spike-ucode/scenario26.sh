#!/bin/sh
# scenario26.sh — differential smoke for the #26 backup-priority semantics:
# explicit `list backup_iface`, re-failover when the backup dies too,
# unwatched/home entries dropped. sh vs ucode must print the same events.
#
#   sh /spike/scenario26.sh sh
#   sh /spike/scenario26.sh ucode
set -u
RUNNER=${1:?usage: scenario26.sh sh|ucode}
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
: > /var/run/ubus.sock
printf 'wan1=eth0\nwan2=eth1\nwan3=eth2\n' > /tmp/ubus.ifaces
export UBUS_IFACES=/tmp/ubus.ifaces
export UBUS_ADDRS=/dev/null
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
	list backup_iface 'wan3'
	list backup_iface 'wan2'

config group 'b'
	option type 'direct'
	option iface 'wan2'
	list backup_iface 'wan2'
	list backup_iface 'dead-iface'

config group 'c'
	option type 'direct'
	option iface 'wan3'
EOF

reset() {
	rm -rf /tmp/wanguard /tmp/.uci # /tmp/.uci: stray uci deltas
	mkdir -p /tmp/wanguard
	for w in wan1 wan2 wan3; do echo ok > /tmp/wanguard/$w.force; done
}
reset

echo "S1 seed:";              run
echo "S2 wan1 dies (3x):";    echo fail > /tmp/wanguard/wan1.force; run; run; run
echo "S3 hold:";              run
echo "S4 wan2 dies too (3x):"; echo fail > /tmp/wanguard/wan2.force; run; run; run
echo "S5 hold:";              run
echo "S6 wan1 recovers (6x):"; echo ok > /tmp/wanguard/wan1.force
                             echo 0 > /tmp/wanguard/a.lastswitch
                             run; run; run; run; run; run
echo "S7 flush files:";       cat /tmp/wanguard/a.flush 2>/dev/null
echo "S8 final uci:";         uci show wanguard 2>/dev/null | grep -E "'iface'|wan_home" | sort
