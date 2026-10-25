#!/bin/sh
# resume.sh — bring the Docker lab back after a host/container restart
# (containers persist, processes do not). Run ON THE HOST:
#
#   sh docs/spike-ucode/lab/resume.sh
#
# Restarts uhttpd in the anchor container (wanguard-lab-net) and
# ubusd + fake-netifd in the router container (wanguard-lab); docker
# networks reattach on docker start automatically. Verifies anchors and
# the ubus dump end to end. (lab-up.sh up|net rebuilds instead — use that
# for a fresh lab.)
set -eu
LAB=wanguard-lab
NET=wanguard-lab-net
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

docker start "$NET" >/dev/null 2>&1 || true
docker start "$LAB" >/dev/null 2>&1 || true

# anchors: one docroot on every address the anchor container owns
# (the .11/.12 alias IPs were added by the entry command — docker does NOT
# re-add them on `docker start`, so resume.sh does)
docker exec "$NET" sh -c '
	mkdir -p /www; echo ok > /www/anchor
	ip addr add 172.30.10.11/24 dev eth0 2>/dev/null
	ip addr add 172.30.10.12/24 dev eth0 2>/dev/null
	command -v uhttpd >/dev/null || apk add --quiet uhttpd
	ps | grep -q "[u]httpd" || uhttpd -p 0.0.0.0:80 -h /www
'

# router container: real ubusd + fake-netifd (keepalive timer inside)
docker exec "$LAB" sh -c '
	mkdir -p /tmp/lab /var/run /etc/config
	ps | grep -q "[u]busd" || { ubusd >/tmp/lab/ubusd.log 2>&1 & sleep 1; }
	ps | grep -q "[n]etifd" || { ucode /repo/docs/spike-ucode/lab/netifd.uc >/tmp/lab/netifd.log 2>&1 & sleep 1; }
'
sleep 1

# end-to-end: every anchor from its own device + the ubus dump
docker exec "$LAB" sh -c '
	curl -m 5 -sf -o /dev/null --interface eth0 http://172.30.10.10/anchor
	curl -m 5 -sf -o /dev/null --interface eth1 http://172.30.20.10/anchor
	curl -m 5 -sf -o /dev/null --interface eth2 http://172.30.30.10/anchor
	ubus call network.interface dump >/dev/null
' && echo "lab resume: anchors + ubus OK"
