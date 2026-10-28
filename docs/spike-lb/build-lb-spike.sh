#!/bin/sh
# build-lb-spike.sh — SPIKE #27 package `wanguard-lb`: stock package with
# /usr/bin/wanguard swapped for the LB renderer (wand-lb.uc). Same vehicle
# as the spike-ucode package (#29-#35): lab-only, never on the feed, the
# router is untouched until the #27 verdict.
#
# Usage: build-lb-spike.sh <repo-root> <apk.static> <version> <outdir>
set -eu

ROOT="${1:?usage: build-lb-spike.sh <repo-root> <apk.static> <version> <outdir>}"
APK="${2:?missing apk.static path}"
VER="${3:?version}"
OUT="${4:?outdir}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT"

W="$work/wanguard-lb"
mkdir -p "$W/usr/bin" "$W/etc/init.d" "$W/usr/share/wanguard"
inst() { cp "$1" "$2"; chmod "$3" "$2"; } # busybox has no install(1)
inst "$ROOT/docs/spike-lb/wand-lb.uc"             "$W/usr/bin/wanguard"      755
inst "$ROOT/router/wanguard-keepalive"            "$W/usr/bin/wanguard-keepalive" 755
inst "$ROOT/router/wan-watch"                     "$W/usr/bin/wan-watch"     755
inst "$ROOT/router/init.d/wanguard"               "$W/etc/init.d/wanguard"   755
inst "$ROOT/router/init.d/wan-watch"              "$W/etc/init.d/wan-watch"  755
inst "$ROOT/router/wanguard.nft"                  "$W/usr/share/wanguard/wanguard.nft" 644
inst "$ROOT/router/etc.config.wanguard.example"   "$W/usr/share/wanguard/etc.config.wanguard.example" 644

"$APK" mkpkg -F "$W" \
	-I "name:wanguard-lb" \
	-I "version:$VER" \
	-I "arch:x86_64" \
	-I "description:SPIKE (#27): direct-lb groups - jhash weights + ct-mark stickiness" \
	-I "license:MIT" \
	-I "maintainer:sers88" \
	-I "url:https://github.com/sers88/wanguard" \
	-I "depends:ip-full nftables conntrack curl ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus" \
	--compat 3.0.5 \
	-o "$OUT/wanguard-lb-$VER.apk"
echo "built $OUT/wanguard-lb-$VER.apk"
