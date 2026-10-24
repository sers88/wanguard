#!/bin/sh
# forkcount.sh — empirical fork count per steady-state tick (issue #29):
# a counting shim intercepts every external child of the CLI under test
# and execs the real binary. sh spawns dozens of children (uci/grep/cut/
# sort/jsonfilter/awk/date/curl); the ucode port spawns children only for
# curl probes (and one /bin/sh per popen). Numbers feed the verdict matrix.
#
#   sh /repo/docs/spike-ucode/forkcount.sh sh|ucode
set -u
RUNNER=${1:?usage: forkcount.sh sh|ucode}
case "$RUNNER" in
	sh)    WG=/repo/router/wanguard ;;
	ucode) WG=/repo/docs/spike-ucode/wand.uc ;;
	*) exit 2 ;;
esac

mkdir -p /etc/config /var/run /tmp/realbin /tmp/shim
: > /var/run/ubus.sock
/sbin/ubusd & sleep 1

# real binaries for the shim to exec
for b in uci ubus jsonfilter grep cut sed sort awk date curl tr head tail; do
	p=$(command -v $b 2>/dev/null) && cp "$p" /tmp/realbin/$b
done

# counting shim: log name, exec real thing
for b in uci ubus jsonfilter grep cut sed sort awk date curl tr head tail; do
	[ -e /tmp/realbin/$b ] || continue
	printf '#!/bin/sh\necho %s >> /tmp/calls.log\nexec /tmp/realbin/%s "$@"\n' "$b" "$b" > /tmp/shim/$b
	chmod +x /tmp/shim/$b
done

printf 'wan1=eth0\nwan2=eth1\n' > /tmp/ubus.ifaces
export UBUS_IFACES=/tmp/ubus.ifaces
export UBUS_ADDRS=/dev/null

cat > /etc/config/wanguard <<'EOF'
config group 'a'
	option type 'direct'
	option iface 'wan1'
	option wan_home 'wan1'

config group 'b'
	option type 'direct'
	option iface 'wan2'
	option wan_home 'wan2'
EOF
rm -rf /tmp/wanguard; mkdir -p /tmp/wanguard
echo ok > /tmp/wanguard/wan1.force
echo ok > /tmp/wanguard/wan2.force

PATH="/tmp/shim:$PATH"
export PATH

# warmup (creates files; ucode needs no seed here but sh does)
if [ "$RUNNER" = sh ]; then sh "$WG" wand-tick >/dev/null 2>&1; else ucode "$WG" wand-tick >/dev/null 2>&1; fi

: > /tmp/calls.log
if [ "$RUNNER" = sh ]; then sh "$WG" wand-tick >/dev/null 2>&1
else ucode "$WG" wand-tick >/dev/null 2>&1; fi

echo "== $RUNNER: steady-state tick external children =="
sort /tmp/calls.log | uniq -c | sort -rn
echo "total: $(grep -c . /tmp/calls.log)"
