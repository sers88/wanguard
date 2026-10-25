#!/bin/sh
# lab-up.sh — Docker lab orchestrator for the issue #29 acceptance battery.
# Runs ON THE HOST. Topology:
#
#   network wanA 172.30.10.0/24   network wanB 172.30.20.0/24
#        |                              |
#   [wanguard-lab-net]  (the "internet": busybox httpd anchors)
#     eth0 172.30.10.10 (anchor A)   eth1 172.30.20.10 (anchor B)
#        |                              |
#   [wanguard-lab]  (the "router": spike package + real ubusd + fake-netifd)
#     eth0 172.30.10.2 (wan1)        eth1 172.30.20.2 (wan2)
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
}

netup

case "${1:-up}" in
down)
	docker rm -f $LAB $NET 2>/dev/null || true
	exit 0
;;
net)
	docker rm -f $NET 2>/dev/null || true
	docker run -d --name $NET --network wanA --ip 172.30.10.10 $IMAGE \
		sh -c 'mkdir -p /a /b; echo ok > /a/anchor; echo ok > /b/anchor; \
			httpd -p 172.30.10.10:80 -h /a; httpd -p 172.30.20.10:80 -h /b; sleep infinity'
	docker network connect --ip 172.30.20.10 wanB $NET
	sleep 1
	docker exec $NET sh -c 'wget -q -O /dev/null http://172.30.10.10/anchor && wget -q -O /dev/null http://172.30.20.10/anchor && echo anchors: ok'
;;
up)
	# rebuild the spike package + install it into the lab container
	docker rm -f $LAB 2>/dev/null || true
	docker run -d --name $LAB --cap-add=NET_ADMIN --network wanA --ip 172.30.10.2 \
		-v "$REPO:/repo:ro" \
		-v "${APK_STATIC:-$REPO/../../apk.static}:/tmp/apk.static:ro" \
		$IMAGE sleep infinity
	docker network connect --ip 172.30.20.2 wanB $LAB
	docker exec $LAB sh /repo/docs/spike-ucode/lab/setup.sh
;;
shell)
	docker exec -it $LAB sh
;;
C1|C2|C3|C4|C5|C6)
	docker exec $LAB sh /repo/docs/spike-ucode/lab/$1.sh
;;
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
