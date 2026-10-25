#!/bin/sh
# make-manifest.sh — stage-1 rollback kit, part 2 (issue #30).
#
# Builds the spike package wanguard-ucode and emits stage1-manifest.txt:
# sha256 of the apk (verify after scp) + md5sums of the INSTALLED-STATE
# files under their ROUTER paths, so the window gate C is a single
# `md5sum -c stage1-manifest.txt` on the router.
#
# Runs in the Docker lab (or any Linux): needs the pinned apk.static and
# the repo checkout.
#
# Usage (in the lab container, repo mounted at /repo):
#   sh /repo/docs/spike-ucode/stage1/make-manifest.sh /repo [/out-dir]
# Defaults: APK_STATIC=/tmp/apk.static, out=/tmp/stage1
set -eu
ROOT="${1:?usage: make-manifest.sh <repo-root> [outdir]}"
OUT="${2:-/tmp/stage1}"
APKBIN="${APK_STATIC:-/tmp/apk.static}"

[ -s "$APKBIN" ] || { echo "no $APKBIN — mount the pinned apk.static first" >&2; exit 1; }
[ -f "$ROOT/docs/spike-ucode/wand.uc" ] || { echo "no wand.uc under $ROOT" >&2; exit 1; }

VER="0.0.0-r$(date +%m%d%H%M)"
mkdir -p "$OUT"
sh "$ROOT/docs/spike-ucode/build-spike.sh" "$ROOT" "$APKBIN" "$VER" "$OUT"
APKFILE="$OUT/wanguard-ucode-$VER.apk"

M="$OUT/stage1-manifest.txt"
{
	echo "# stage-1 spike manifest — $(date -u '+%Y-%m-%dT%H:%M:%SZ') ver=$VER"
	echo "# verify on the router:"
	echo "#   sha256sum the apk and compare the sha256 line below"
	echo "#   grep -E '^[0-9a-f]{32}  /' stage1-manifest.txt | md5sum -c -"
	echo "# (busybox md5sum -c does NOT skip comments — filter first; the"
	echo "#  /usr/bin/wanguard line is EXPECTED TO FAIL before the install)"
} >"$M"
sha256sum "$APKFILE" | sed 's#  .*/#  <apk> #' >>"$M"
md5line() { # $1=repo file $2=router path
	printf '%s  %s\n' "$(md5sum "$1" | cut -d' ' -f1)" "$2" >>"$M"
}
md5line "$ROOT/docs/spike-ucode/wand.uc"      /usr/bin/wanguard
md5line "$ROOT/router/wanguard"               /usr/bin/wanguard-sh
md5line "$ROOT/router/wanguard-keepalive"     /usr/bin/wanguard-keepalive
md5line "$ROOT/router/wan-watch"              /usr/bin/wan-watch
md5line "$ROOT/router/init.d/wanguard"        /etc/init.d/wanguard
md5line "$ROOT/router/init.d/wan-watch"       /etc/init.d/wan-watch
md5line "$ROOT/router/wanguard.nft"           /usr/share/wanguard/wanguard.nft

echo
echo "== manifest: $M"
cat "$M"
echo
echo "== transfer to the router (from the PC):"
echo "  scp $OUT/wanguard-ucode-$VER.apk root@192.168.88.1:/tmp/"
echo "  scp $OUT/stage1-manifest.txt root@192.168.88.1:/tmp/"
echo "  scp $ROOT/docs/spike-ucode/stage1/make-savepoint.sh \\"
echo "      $ROOT/docs/spike-ucode/stage1/drill.sh root@192.168.88.1:/tmp/"
