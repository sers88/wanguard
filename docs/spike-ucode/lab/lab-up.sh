#!/bin/sh
# lab-up.sh — Docker lab orchestrator for the issue #29 acceptance battery.
# Runs ON THE HOST. Topology (three isolated bridges = three honest WANs):
#
#   network wanA 172.30.10.0/24    network wanB 172.30.20.0/24
#        |                               |
#   [wanguard-lab-net]  (the "internet": uhttpd anchor, ONE docroot on
#     every address it owns; NET_ADMIN for the C5 N-of-M alias IPs)
#     eth0 172.30.10.10 (anchor A)   eth1 172.30.20.10 (anchor B)
#     eth0: aliiases 172.30.10.11 / .12 (anchors A2/A3, N-of-M in C5)
#   network wanC 172.30.30.0/24
#     eth2 172.30.30.10 (anchor C, 3-WAN drill in C3)
#        |
#   [wanguard-lab]  (the "router": spike package + real ubusd + fake-netifd)
#     eth0 172.30.10.2 (wan1)   eth1 172.30.20.2 (wan2)   eth2 172.30.30.2 (wan3)
#
# Docker's inter-bridge isolation makes every wrong (device, anchor) pair
# an honest 5s curl timeout — the C3/C4/C6 scripts REJECT those pairs
# instantly instead (still real curl, really dead paths) so ticks run in
# milliseconds; the honest timeout itself is C5's black-hole test.
#
# Usage: lab-up.sh up|net|shell|C1|C2|C3|C4|C5|C6|all|down
set -eu
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE=openwrt/rootfs:x86_64-25.12.5
LAB=wanguard-lab
NET=wanguard-lab-net

netup() {
	docker network inspect wanA >/dev/null 2>&1 || \
		docker network create --subnet 172.30.10.0/24 wanA >/dev/null
	docker network inspect wanB >/dev/null 2>&1 || \
		docker network create --subnet 172.30.20.0/24 wanB >/dev/null
	docker network inspect wanC >/dev/null 2>&1 || \
		docker network create --subnet 172.30.30.0/24 wanC >/dev/null
}

netup

case "${1:-up}" in
down)
	docker rm -f $LAB $NET 2>/dev/null || true
	exit 0
;;
net)
	docker rm -f $NET 2>/dev/null || true
	# one docroot /www served on every address the anchor owns; the
	# busybox httpd applet is NOT in the 25.12.5 rootfs — uhttpd is
	docker run -d --name $NET --cap-add=NET_ADMIN --network wanA --ip 172.30.10.10 $IMAGE \
		sh -c 'mkdir -p /www; echo ok > /www/anchor; \
			ip addr add 172.30.10.11/24 dev eth0; \
			ip addr add 172.30.10.12/24 dev eth0; \
			apk add --quiet uhttpd curl >/dev/null 2>&1; \
			uhttpd -p 0.0.0.0:80 -h /www; sleep infinity'
	docker network connect --ip 172.30.20.10 wanB $NET
	docker network connect --ip 172.30.30.10 wanC $NET
	sleep 1
	docker exec $NET sh -c 'for ip in 172.30.10.10 172.30.10.11 172.30.10.12 172.30.20.10 172.30.30.10; do curl -m 5 -sf -o /dev/null http://$ip/anchor || exit 1; done && echo anchors: ok'
;;
up)
	# rebuild the spike package + install it into the lab container
	docker rm -f $LAB 2>/dev/null || true
	docker run -d --name $LAB --cap-add=NET_ADMIN --network wanA --ip 172.30.10.2 \
		-v "$REPO:/repo:ro" \
		-v "${APK_STATIC:-$REPO/../../apk.static}:/tmp/apk.static:ro" \
		$IMAGE sleep infinity
	docker network connect --ip 172.30.20.2 wanB $LAB
	docker network connect --ip 172.30.30.2 wanC $LAB
	docker exec $LAB sh /repo/docs/spike-ucode/lab/setup.sh
;;
shell)
	docker exec -it $LAB sh
;;
C1) docker exec $LAB sh /repo/docs/spike-ucode/lab/C1-regress.sh ;;
C2) docker exec -e CYCLES="${CYCLES:-5}" $LAB sh /repo/docs/spike-ucode/lab/C2-failover.sh ;;
C3) docker exec $LAB sh /repo/docs/spike-ucode/lab/C3-3wan.sh ;;
C4) docker exec $LAB sh /repo/docs/spike-ucode/lab/C4-contract.sh ;;
C5) docker exec $LAB sh /repo/docs/spike-ucode/lab/C5-edges.sh ;;
C6) docker exec $LAB sh /repo/docs/spike-ucode/lab/C6-metrics.sh ;;
all)
	"$0" net
	"$0" up
	for c in C1 C2 C3 C4 C5 C6; do
		echo "===== $c ====="
		"$0" $c || exit 1
	done
	echo "LAB-ALL-GREEN"
;;
*)
	echo "usage: lab-up.sh up|net|shell|C1..C6|all|down" >&2
	exit 2
;;
esac
