#!/bin/sh
# install-test.sh — Phase 3 container proof (issue #29):
#  1. build the spike package wanguard-ucode with the pinned apk.static
#  2. install it into the running OpenWrt container
#  3. smoke: shebang execution, wand-tick on a fixture, keepalive cycle
#  4. package shape (stage 5, #35): /usr/bin/wanguard-sh is ABSENT — the
#     sh CLI is retired from the package
#
#   docker run --rm -v <repo>:/repo:ro openwrt/rootfs:x86_64-25.12.5 \
#     sh /repo/docs/spike-ucode/install-test.sh
set -eu

APK_URL=https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.7/x86_64/apk.static
APK_SHA=c07bf5356eacc9dd7a8c56bc537f46702f007170287403299d52a04264e74b3c

cd /tmp
echo "== pinned apk.static 3.0.7 (download skipped when pre-mounted)"
if [ ! -s /tmp/apk.static ]; then
	uclient-fetch -q "$APK_URL" -O apk.static
	chmod +x apk.static
fi
APKBIN=/tmp/apk.static
"$APKBIN" --version
echo "$APK_SHA  apk.static" | sha256sum -c -

echo "== build spike package"
sh /repo/docs/spike-ucode/build-spike.sh /repo /tmp/apk.static 0.0.0-r99 /tmp/out

echo "== install"
apk add --allow-untrusted /tmp/out/wanguard-ucode-0.0.0-r99.apk

for f in /usr/bin/wanguard /usr/bin/wanguard-keepalive \
	/usr/bin/wan-watch /etc/init.d/wanguard /etc/init.d/wan-watch \
	/usr/share/wanguard/wanguard.nft; do
	test -e "$f" || { echo "MISSING: $f"; exit 1; }
done
if [ -e /usr/bin/wanguard-sh ]; then
	echo "RETIRED FILE PRESENT: /usr/bin/wanguard-sh (stage 5: must be absent)"
	exit 1
fi
echo "files: ok (wanguard-sh absent)"

echo "== shebang: /usr/bin/wanguard (ucode) dispatches"
head -1 /usr/bin/wanguard
out=$(/usr/bin/wanguard 2>&1); rc=$?
case "$out" in *"Usage:"*|*"wanguard"*) echo "no-args -> help, rc=$rc (sh contract: exit 0)" ;; *) echo "HELP MISSING"; exit 1 ;; esac

echo "== fixture + ubusd (no netifd: network.interface absent -> ifaces down)"
mkdir -p /etc/config /var/run /tmp/wanguard
/sbin/ubusd & UBUS_PID=$!
sleep 1
cat > /etc/config/wanguard <<'EOF'
config group 'a'
	option type 'direct'
	option iface 'wan1'
EOF
rm -rf /tmp/wanguard; mkdir -p /tmp/wanguard
echo ok > /tmp/wanguard/wan1.force

echo "== wand-tick via installed /usr/bin/wanguard (shebang path, native ubus)"
out=$(/usr/bin/wanguard wand-tick 2>&1) && rc=0 || rc=$?
echo "rc=$rc out='$out'"
case "$out" in *"seed:a>wan1"*) echo "seed event: ok" ;; *) echo "SEED MISSING"; exit 1 ;; esac

echo "== keepalive cycle (unmodified sh loop body, one iteration)"
wout=$(/usr/bin/wanguard wand-tick 2>&1 || true)
out=$(/usr/bin/wanguard apply 2>&1 || true)
fout=$(/usr/bin/wanguard wan-flush 2>&1 || true)
echo "tick='$wout' apply='$out' flush='$fout'"
[ -z "$wout$fout" ] || echo "(non-quiet tick/flush output would be logged)"

kill $UBUS_PID 2>/dev/null || true
echo "INSTALL-TEST-OK"
