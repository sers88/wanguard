#!/bin/sh
# build-spike.sh — packaging probe (issue #29; window vehicle for stages
# 1-2, issues #31/#32): build the SPIKE package `wanguard-ucode` = stock
# package with /usr/bin/wanguard swapped for the ucode port (both binaries
# shipped side by side; since stage 4 the ucode CLI is fully native and
# does NOT pass anything through to /usr/bin/wanguard-sh — the sh binary
# stays in the package as the rollback vehicle until stage 5).
#
# NOT a release artifact: exists to prove apk packaging works unchanged
# with a ucode shebang, to pin the real depends delta, and to feed the
# container install test. Never lands on the feed (feed ships tagged
# main only).
#
# Usage (inside any Linux with the pinned apk.static):
#   build-spike.sh <repo-root> <apk.static> <version> <outdir>
set -eu

ROOT="${1:?usage: build-spike.sh <repo-root> <apk.static> <version> <outdir>}"
APK="${2:?missing apk.static path}"
VER="${3:?version}"
OUT="${4:?outdir}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT"

W="$work/wanguard-ucode"
mkdir -p "$W/usr/bin" "$W/etc/init.d" "$W/usr/share/wanguard"
inst() { cp "$1" "$2"; chmod "$3" "$2"; } # busybox has no install(1)
inst "$ROOT/docs/spike-ucode/wand.uc"             "$W/usr/bin/wanguard"      755 # ucode
inst "$ROOT/router/wanguard"                      "$W/usr/bin/wanguard-sh"   755 # stock sh
inst "$ROOT/router/wanguard-keepalive"            "$W/usr/bin/wanguard-keepalive" 755
inst "$ROOT/router/wan-watch"                     "$W/usr/bin/wan-watch"     755
inst "$ROOT/router/init.d/wanguard"               "$W/etc/init.d/wanguard"   755
inst "$ROOT/router/init.d/wan-watch"              "$W/etc/init.d/wan-watch"  755
inst "$ROOT/router/wanguard.nft"                  "$W/usr/share/wanguard/wanguard.nft" 644
inst "$ROOT/router/etc.config.wanguard.example"   "$W/usr/share/wanguard/etc.config.wanguard.example" 644

# depends DELTA vs the stock package: the interpreter and the three
# modules the script requires. On 25.12 images ucode/uci/ubus/fs modules
# are preinstalled (fw4/rpcd depend on them), but declaring them is the
# correct contract for images that might not carry them.
"$APK" mkpkg -F "$W" \
	-I "name:wanguard-ucode" \
	-I "version:$VER" \
	-I "arch:x86_64" \
	-I "description:SPIKE (#29/#32): wanguard core with the ucode wand-tick + wan-flush ports" \
	-I "license:MIT" \
	-I "maintainer:sers88" \
	-I "url:https://github.com/sers88/wanguard" \
	-I "depends:ip-full nftables conntrack curl ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus" \
	--compat 3.0.5 \
	-o "$OUT/wanguard-ucode-$VER.apk"
echo "built $OUT/wanguard-ucode-$VER.apk"
