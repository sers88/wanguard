#!/bin/sh
# setup.sh — in-container bootstrap for the Docker lab (issue #29):
# installs the spike package, writes the router-shaped UCI config, starts
# real ubusd + fake-netifd, creates the nft table. Runs INSIDE wanguard-lab.
set -eu
mkdir -p /var/run /etc/config /tmp/lab

# deps; ucode itself is preinstalled in 25.12.5
apk add --quiet nftables ip-full conntrack curl iptables >/dev/null 2>&1

# spike package: /usr/bin/wanguard = ucode port, /usr/bin/wanguard-sh = sh
if [ ! -s /tmp/apk.dl ]; then
	cp /tmp/apk.static /tmp/apk.dl
	chmod +x /tmp/apk.dl
fi
sh /repo/docs/spike-ucode/build-spike.sh /repo /tmp/apk.dl 0.0.0-r99 /tmp/out >/dev/null
apk add --quiet --allow-untrusted /tmp/out/wanguard-ucode-0.0.0-r99.apk >/dev/null

# the router config: two direct groups, one anchor per WAN
cat > /etc/config/wanguard <<'EOF'
config globals 'globals'
	option wan_reliability '1'
	list wan_anchors 'http://172.30.10.10/anchor'
	list wan_anchors 'http://172.30.20.10/anchor'

config group 'a'
	option type 'direct'
	option iface 'wan1'

config group 'b'
	option type 'direct'
	option iface 'wan2'
EOF

# fake netifd fixtures: wan1=eth0 up, wan2=eth1 up
printf '{ "wan1": { "up": true, "device": "eth0", "address": "172.30.10.2" }, "wan2": { "up": true, "device": "eth1", "address": "172.30.20.2" } }' > /tmp/netifd.json

# daemons survive the exec session (plain background children do); the
# netifd keepalive timer is what keeps IT alive, not nohup
ubusd >/tmp/lab/ubusd.log 2>&1 &
sleep 1
ucode /repo/docs/spike-ucode/lab/netifd.uc >/tmp/lab/netifd.log 2>&1 &
sleep 1
ubus call network.interface dump >/dev/null && echo "lab: ubus netifd ok"

nft -f /usr/share/wanguard/wanguard.nft
echo "lab: nft table created"

/usr/bin/wanguard-sh apply >/dev/null 2>&1 || true
echo "lab: ready"
