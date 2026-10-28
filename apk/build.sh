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
# Stage-5 shape (issues #30/#31/#32/#33/#34/#35): /usr/bin/wanguard = the
# ucode CLI (wand.uc) with EVERY subcommand native — wand-tick/wan-flush/
# probe-selftest (stage 1-2), apply (stage 3), CLI CRUD + view (stage 4);
# `conntrack`/`nft`/`ip`/`curl` themselves stay external calls. The POSIX
# sh CLI is RETIRED from the package (stage 5, #35): there is no
# /usr/bin/wanguard-sh anymore — the offline rollback is reinstalling the
# previous feed tag's apk (single mechanism, same UCI/state; the sh source
# stays in the repo only as the lab's differential reference).
# keepalive/init.d/wan-watch are UNCHANGED (frozen contract 00-CLI-CONTRACT.md).
# The ucode interpreter + 3 modules are declared: preinstalled on 25.12
# (fw4/rpcd need them), but the declaration is the correct contract.
# NB: cp+chmod, not install(1) — the OpenWrt container busybox has no
# install(1) (spike грабля №4), and this script is smoke-tested there.
W="$work/wanguard"
mkdir -p "$W/usr/bin" "$W/etc/init.d" "$W/usr/share/wanguard"
inst() { cp "$1" "$2"; chmod "$3" "$2"; }
inst "$ROOT/docs/spike-ucode/wand.uc"           "$W/usr/bin/wanguard"      755
inst "$ROOT/router/wanguard-keepalive"          "$W/usr/bin/wanguard-keepalive" 755
inst "$ROOT/router/wan-watch"                   "$W/usr/bin/wan-watch"     755
inst "$ROOT/router/init.d/wanguard"             "$W/etc/init.d/wanguard"   755
inst "$ROOT/router/init.d/wan-watch"            "$W/etc/init.d/wan-watch"  755
inst "$ROOT/router/wanguard.nft"                "$W/usr/share/wanguard/wanguard.nft" 644
inst "$ROOT/router/etc.config.wanguard.example" "$W/usr/share/wanguard/etc.config.wanguard.example" 644
pkg wanguard \
	"Per-MAC policy routing for OpenWrt: client groups, nft marking, main-egress health-watch" \
	"ip-full nftables conntrack ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus" "$W"

# ---- luci-app-wanguard ----
L="$work/luci-app-wanguard"
mkdir -p "$L/www/luci-static/resources/view" "$L/usr/share/luci/menu.d" "$L/usr/share/rpcd/acl.d"
inst "$ROOT/luci-app-wanguard/htdocs/luci-static/resources/view/wanguard.js" "$L/www/luci-static/resources/view/wanguard.js" 644
inst "$ROOT/luci-app-wanguard/usr/share/luci/menu.d/luci-app-wanguard.json"  "$L/usr/share/luci/menu.d/luci-app-wanguard.json" 644
inst "$ROOT/luci-app-wanguard/usr/share/rpcd/acl.d/luci-app-wanguard.json"   "$L/usr/share/rpcd/acl.d/luci-app-wanguard.json" 644
pkg luci-app-wanguard \
	"LuCI kanban board for wanguard client groups" \
	"wanguard luci-base" "$L"
