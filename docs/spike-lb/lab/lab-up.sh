#!/bin/sh
# lab-up.sh — Docker lab orchestrator for the SPIKE #27 batteries (L1/L2),
# topology of the spike-ucode lab (#30) PLUS a lan bridge with a client
# container (LB is MAC-marked LAN traffic — without a LAN side the whole
# subject is untestable):
#
#   network wanA 203.0.113.0/24    network wanB 198.51.100.0/24
#        |                               |
#   [wanguard-lab-net]  (the "internet": uhttpd anchor, ONE docroot on
#     every address it owns; NET_ADMIN)
#     eth0 203.0.113.10 (anchor A)   eth1 198.51.100.10 (anchor B)
#     aliases 203.0.113.11/.12 (N-of-M, L5) + /www/blob (20 MB, L2 drill)
#   network wanC 192.0.2.0/24
#     eth2 192.0.2.10 (anchor C, third member in L5)
#        |
#   [wanguard-lab]  (the "router": spike package + real ubusd + fake-netifd)
#     eth0 203.0.113.2 (wan1) eth1 198.51.100.2 (wan2) eth2 192.0.2.2 (wan3)
#     eth3 -> br-lan 198.18.0.2/24 (setup.sh enslaves it; LAN-side marking)
#        |
#   network lan 198.18.0/24
#     [wanguard-lab-client] eth0 198.18.0.55 MAC aa:bb:cc:dd:ee:55
#     (provisioned with curl over a temporary docker bridge, then its
#      default route is pinned to the router: all test traffic is
#      marked/policy-routed by wanguard)
#
# ADDRESSING (live finding, session 1): TEST-NET/benchmark ranges, NOT
# 172.30.x — the wanguard rules exclude `ip daddr @local_v4` (172.16/12
# included), and 172.30.x sits INSIDE that exclusion: the marking chain
# never matched and every flow rode main unmarked. The anchor also runs
# an INPUT nft table binding each owned address to its own interface:
# the weak-host model would otherwise answer wrong-(egress, anchor)
# pairs (dst is local on another NIC), killing the honest-timeout
# property the whole lab verdict method rests on.
#
# Usage: lab-up.sh net|client|up|up-prod|shell|client-shell|L1|L2|all|down
set -eu
REPO="$(cd "$(dirname "$0")/../.." && pwd)"   # /repo = repo root (in-container)
HOSTREPO="$(cd "$(dirname "$0")/../../.." && pwd)" # host path of the repo
# Git Bash runner (Windows, no WSL docker integration needed): convert the
# mount path to the docker-acceptable mixed form and stop MSYS from
# mangling the container-absolute args (/repo/..., /tmp/...)
if command -v cygpath >/dev/null 2>&1; then
	HOSTREPO="$(cygpath -m "$HOSTREPO")"
	export MSYS_NO_PATHCONV=1
fi
IMAGE=openwrt/rootfs:x86_64-25.12.5
LAB=wanguard-lab
NET=wanguard-lab-net
CLIENT=wanguard-lab-client
LB=docs/spike-lb/lab

netup() {
	for spec in wanA:203.0.113.0/24 wanB:198.51.100.0/24 wanC:192.0.2.0/24 lan:198.18.0.0/24; do
		n="${spec%%:*}"; s="${spec#*:}"
		docker network inspect "$n" >/dev/null 2>&1 || \
			docker network create --subnet "$s" "$n" >/dev/null
	done
}

case "${1:-up}" in
down)
	docker rm -f $LAB $CLIENT $NET 2>/dev/null || true
	exit 0
;;
net)
	netup
	docker rm -f $NET 2>/dev/null || true
	# one docroot /www served on every address the anchor owns; the
	# busybox httpd applet is NOT in the 25.12.5 rootfs — uhttpd is
	docker run -d --name $NET --cap-add=NET_ADMIN --network wanA --ip 203.0.113.10 $IMAGE \
		sh -c 'mkdir -p /www; echo ok > /www/anchor; \
			dd if=/dev/zero of=/www/blob bs=1M count=20 2>/dev/null; \
			ip addr add 203.0.113.11/24 dev eth0; \
			ip addr add 203.0.113.12/24 dev eth0; \
			apk add --quiet uhttpd nftables >/dev/null 2>&1; \
			while ! ip link show eth1 >/dev/null 2>&1 || ! ip link show eth2 >/dev/null 2>&1; do sleep 1; done; \
			nft -f - <<ISOLEOF
table inet anchor_isol {
	chain in {
		type filter hook input priority 0; policy accept;
		iifname != "eth0" ip daddr 203.0.113.10 drop
		iifname != "eth1" ip daddr 198.51.100.10 drop
		iifname != "eth2" ip daddr 192.0.2.10 drop
	}
}
ISOLEOF
			uhttpd -p 0.0.0.0:80 -h /www; sleep infinity'
	docker network connect --ip 198.51.100.10 wanB $NET
	docker network connect --ip 192.0.2.10 wanC $NET
	# wait for uhttpd (the entrypoint apk-adds it first — a fixed sleep
	# loses that race on a cold image cache; DNS can be slow too).
	# NB: the check hits 127.0.0.1 — the anchor's own external addresses
	# are isolated to their interfaces (iif lo would be dropped by
	# anchor_isol), the honest-property check happens from the client
	ok=''
	for t in $(seq 1 30); do
		sleep 1
		if docker exec $NET sh -c 'wget -q -T 3 -O /dev/null http://127.0.0.1/anchor 2>/dev/null && nft list table inet anchor_isol >/dev/null 2>&1' 2>/dev/null; then
			ok=1; break
		fi
	done
	[ -n "$ok" ] || { echo "net: anchors never came up" >&2; exit 1; }
	echo "anchors: ok"
;;
client)
	netup
	docker rm -f $CLIENT 2>/dev/null || true
	# --mac-address: the group member identity (marking is by ether saddr)
	docker run -d --name $CLIENT --cap-add=NET_ADMIN --network lan \
		--ip 198.18.0.55 --mac-address aa:bb:cc:dd:ee:55 $IMAGE sleep infinity
	# provisioning lane (docker default bridge): curl + iperf3 without
	# touching the router path; afterwards the default route is pinned
	# to the router — everything else goes through wanguard
	docker network connect bridge $CLIENT
	docker exec $CLIENT sh -c 'apk add --quiet curl >/dev/null 2>&1'
	docker exec $CLIENT sh -c 'while ip route del default 2>/dev/null; do :; done; \
		ip route add default via 198.18.0.2; \
		ip -o link show eth0 | grep -q "aa:bb:cc:dd:ee:55" || ip link set dev eth0 address aa:bb:cc:dd:ee:55'
	docker exec $CLIENT sh -c 'ip -o link show eth0 | grep -q aa:bb:cc:dd:ee:55 && ip route | grep -q "default via 198.18.0.2" && echo client: ok'
;;
up|up-prod)
	# `up` installs the LB SPIKE package (wanguard-lb, build-lb-spike.sh);
	# `up-prod` installs the PROD package instead (stock apk/build.sh —
	# /usr/bin/wanguard = docs/spike-ucode/wand.uc byte-identically):
	# the #38 acceptance vehicle — the L1 battery runs against
	# production, not the spike
	flav=spike
	[ "$1" = up-prod ] && flav=prod
	docker rm -f $LAB 2>/dev/null || true
	docker run -d --name $LAB --cap-add=NET_ADMIN --network wanA --ip 203.0.113.2 \
		--sysctl net.ipv4.ip_forward=1 \
		-v "$HOSTREPO:/repo:ro" \
		-v "${APK_STATIC:-$HOSTREPO/../apk.static}:/tmp/apk.static:ro" \
		$IMAGE sleep infinity
	docker network connect --ip 198.51.100.2 wanB $LAB
	docker network connect --ip 192.0.2.2 wanC $LAB
	docker network connect --ip 198.18.0.2 lan $LAB
	docker exec -e WG_PKG="$flav" $LAB sh /repo/$LB/setup.sh
;;
shell)
	docker exec -it $LAB sh
;;
client-shell)
	docker exec -it $CLIENT sh
;;
L1) docker exec $LAB sh /repo/$LB/L1-render.sh ;;
# L2 and L4 are HOST-orchestrated: they drive BOTH sides (client curls
# + router conntrack/nft/tick), which no single container can do
L2) sh "$HOSTREPO/$LB/L2-stickiness.sh" ;;
L4) sh "$HOSTREPO/$LB/L4-failover.sh" ;;
L5) sh "$HOSTREPO/$LB/L5-edges.sh" ;;
all)
	"$0" net
	"$0" client
	"$0" up
	for c in L1 L2 L4 L5; do
		echo "===== $c ====="
		"$0" $c || exit 1
	done
	echo "LAB-ALL-GREEN"
;;
*)
	echo "usage: lab-up.sh net|client|up|shell|client-shell|L1|L2|all|down" >&2
	exit 2
;;
esac
