#!/bin/sh
# setup.sh — in-container bootstrap for the SPIKE #27 Docker lab:
# installs the package under test, writes the router-shaped UCI
# config with a direct group AND a direct-lb group, starts real ubusd +
# fake-netifd, creates the nft table, and builds br-lan (eth3 enslaved —
# the LAN side the marking rules match on) + LAN->WAN masquerade in a
# SEPARATE spike table (never in table inet wanguard).
# Runs INSIDE wanguard-lab.
#
# WG_PKG=spike (default): the LB spike package (wanguard-lb — /usr/bin/
# wanguard = wand-lb.uc). WG_PKG=prod: the PRODUCTION package (stock
# apk/build.sh — /usr/bin/wanguard = docs/spike-ucode/wand.uc), the #38
# acceptance vehicle for the L1 battery against production.
set -eu
mkdir -p /var/run /etc/config /tmp/lab

# deps; ucode itself is preinstalled in 25.12.5
apk add --quiet nftables ip-full conntrack curl iptables >/dev/null 2>&1

# package under test
if [ ! -s /tmp/apk.dl ]; then
	cp /tmp/apk.static /tmp/apk.dl
	chmod +x /tmp/apk.dl
fi
if [ "${WG_PKG:-spike}" = prod ]; then
	sh /repo/apk/build.sh /repo /tmp/apk.dl 0.0.0-r99 /tmp/out >/dev/null
	apk add --quiet --allow-untrusted /tmp/out/wanguard-0.0.0-r99.apk >/dev/null
	echo "lab: PROD package installed ($(ucode /usr/bin/wanguard help >/dev/null 2>&1 && echo native))"
else
	sh /repo/docs/spike-lb/build-lb-spike.sh /repo /tmp/apk.dl 0.0.0-r99 /tmp/out >/dev/null
	apk add --quiet --allow-untrusted /tmp/out/wanguard-lb-0.0.0-r99.apk >/dev/null
fi

# the router config: one direct group (wan3, regression witness: its
# rendering must be byte-identical to the pre-spike shape) + one LB group
cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://203.0.113.10/anchor'
	list wan_anchors 'http://198.51.100.10/anchor'

config group 'a'
	option type 'direct'
	option iface 'wan3'

config group 'lb'
	option type 'direct-lb'
	list member_iface 'wan1'
	list member_iface 'wan2'
	option weight_wan1 '70'
	option weight_wan2 '30'

config member
	option mac 'aa:bb:cc:dd:ee:55'
	option group 'lb'
	option name 'client'
EOF

# fake netifd fixtures: wan1=eth0 up, wan2=eth1 up, wan3=eth2 up
printf '{ "wan1": { "up": true, "device": "eth0", "address": "203.0.113.2" }, "wan2": { "up": true, "device": "eth1", "address": "198.51.100.2" }, "wan3": { "up": true, "device": "eth2", "address": "192.0.2.2" } }' > /tmp/netifd.json

# LAN side: br-lan with eth3 enslaved (marking matches iifname "br-lan").
# Docker assigned 198.18.0.2 to eth3 at attach: flush it BEFORE the
# enslave (duplicate connected route eth3+br-lan = asymmetric blackhole,
# live finding: neigh goes INCOMPLETE on the bare port), and re-pin the
# main default to wanA (docker re-points the container default at the
# LAST attached network's gateway, which would poison the metric-200
# fallback that reconciles from main's default line)
ip addr flush dev eth3 2>/dev/null || true
ip link add br-lan type bridge 2>/dev/null || true
ip link set eth3 master br-lan 2>/dev/null || true
ip addr add 198.18.0.2/24 dev br-lan 2>/dev/null || true
ip link set br-lan up
while ip route del default 2>/dev/null; do :; done
ip route add default via 203.0.113.1 dev eth0

# forward + LAN->WAN masquerade (spike-only table; the anchor addresses
# exist only on their own bridge, so wrong egress = honest timeout).
# ip_forward is set at `docker run --sysctl` (proc/sys is read-only here)
grep -q '^1$' /proc/sys/net/ipv4/ip_forward || {
	echo "setup: net.ipv4.ip_forward != 1 (run the container with --sysctl)" >&2
	exit 1
}
nft delete table ip spike_nat 2>/dev/null || true
nft -f - <<'EOF'
table ip spike_nat {
	chain postrouting {
		type nat hook postrouting priority 100; policy accept;
		ip saddr 198.18.0.0/24 oifname != "br-lan" masquerade
	}
}
EOF

# daemons survive the exec session (plain background children do); the
# netifd keepalive timer is what keeps IT alive, not nohup
ubusd >/tmp/lab/ubusd.log 2>&1 &
sleep 1
ucode /repo/docs/spike-ucode/lab/netifd.uc >/tmp/lab/netifd.log 2>&1 &
sleep 1
ubus call network.interface dump >/dev/null && echo "lab: ubus netifd ok"

nft -f /usr/share/wanguard/wanguard.nft
echo "lab: nft table created"

/usr/bin/wanguard apply
echo "lab: ready"
