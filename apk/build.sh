#!/bin/sh
# apk/build.sh - build wanguard apk packages (file packaging, no compilation).
#
# Usage: build.sh <repo-root> <apk.static> <version> <outdir>
#   repo-root   checkout of sers88/wanguard (this repo, main branch)
#   apk.static  pinned apk-tools 3.0.7 binary (has the mkpkg applet; the
#               router's 3.0.5 build does not)
#   version     package version, e.g. 1.0.0-r1 (release) or 0.0.0-rN (dev)
#   outdir      where the *.apk files land
#
# Packages (issue #11):
#   wanguard           core: CLI, keepalive, wan-watch, init scripts,
#                      nft skeleton, example UCI config
#   luci-app-wanguard  LuCI kanban board (depends: wanguard)
#
# Index generation and signing (packages.adb via mkndx --sign) happen in CI,
# not here. Packages are intentionally unsigned; the feed index signature is
# what the router verifies against /etc/apk/keys/wanguard.pem.
set -eu

ROOT="${1:?usage: build.sh <repo-root> <apk.static> <version> <outdir>}"
APK="${2:?missing apk.static path}"
VER="${3:?missing version}"
OUT="${4:?missing outdir}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT"

pkg() { # pkg <name> <description> <depends> <stage-dir>
	name="$1"; desc="$2"; deps="$3"; stage="$4"
	"$APK" mkpkg -F "$stage" \
		-I "name:$name" \
		-I "version:$VER" \
		-I "arch:x86_64" \
		-I "description:$desc" \
		-I "license:MIT" \
		-I "maintainer:sers88" \
		-I "url:https://github.com/sers88/wanguard" \
		-I "depends:$deps" \
		--compat 3.0.5 \
		-o "$OUT/$name-$VER.apk"
	echo "built $OUT/$name-$VER.apk"
}

# ---- wanguard (core) ----
W="$work/wanguard"
mkdir -p "$W/usr/bin" "$W/etc/init.d" "$W/usr/share/wanguard"
install -m 755 "$ROOT/router/wanguard"                    "$W/usr/bin/wanguard"
install -m 755 "$ROOT/router/wanguard-keepalive"          "$W/usr/bin/wanguard-keepalive"
install -m 755 "$ROOT/router/wan-watch"                   "$W/usr/bin/wan-watch"
install -m 755 "$ROOT/router/init.d/wanguard"             "$W/etc/init.d/wanguard"
install -m 755 "$ROOT/router/init.d/wan-watch"            "$W/etc/init.d/wan-watch"
install -m 644 "$ROOT/router/wanguard.nft"                "$W/usr/share/wanguard/wanguard.nft"
install -m 644 "$ROOT/router/etc.config.wanguard.example" "$W/usr/share/wanguard/etc.config.wanguard.example"
pkg wanguard \
	"Per-MAC policy routing for OpenWrt: client groups, nft marking, main-egress health-watch" \
	"ip-full nftables" "$W"

# ---- luci-app-wanguard ----
L="$work/luci-app-wanguard"
mkdir -p "$L/www/luci-static/resources/view" "$L/usr/share/luci/menu.d" "$L/usr/share/rpcd/acl.d"
install -m 644 "$ROOT/luci-app-wanguard/htdocs/luci-static/resources/view/wanguard.js" "$L/www/luci-static/resources/view/wanguard.js"
install -m 644 "$ROOT/luci-app-wanguard/usr/share/luci/menu.d/luci-app-wanguard.json"  "$L/usr/share/luci/menu.d/luci-app-wanguard.json"
install -m 644 "$ROOT/luci-app-wanguard/usr/share/rpcd/acl.d/luci-app-wanguard.json"   "$L/usr/share/rpcd/acl.d/luci-app-wanguard.json"
pkg luci-app-wanguard \
	"LuCI kanban board for wanguard client groups" \
	"wanguard luci-base" "$L"
