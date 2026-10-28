#!/bin/sh
# probe.sh — ucode API facts for the stage-4 CLI port (issue #34),
# recorded in stage4/NOTES.md. Same method as stage3/probe.sh: run inside
# openwrt/rootfs:x86_64-25.12.5, probe the exact surfaces the port will
# use, transcribe with show() markers.
#
# Surfaces (the stage-4 parity questions):
#   P1  printf padding/width (list/grouplist/wanstatus tables)
#   P2  replace()/lc() vs sh tr ('ABCDF-' -> 'abcdef:', delete ':.')
#   P3  uci cursor: 2-arg get (section existence/type), get_all, delete
#       of a MISSING option (sh `uci -q delete` silence), add_list
#       (backupset), list read-back shape, named section create
#   P4  committed /etc/config/wanguard bytes: ucode save+commit vs
#       sh uci set/add_list/commit on the same logical edit
#   P5  fs.readfile on /proc files (size-0: /proc/net/arp)
#   P6  split('a b', /[ \t]+/) — awk field-split parity (leading/trailing
#       empty fields) for the devices port
#   P7  ERE intervals in match() ({5}) for the devices MAC regex
#   P8  mount --bind over /proc/net/arp (harness fixture vehicle) +
#       busybox `ip link add type dummy` + permanent neigh (fallback)
#   P9  popen rc + stderr merge, system() rc (command -v checks)
#   P10 index()/substr() — the `mac-${mac#*:}` default-name port
#   P11 cursor snapshot semantics across mutations (the stage-1 lesson,
#       re-verified for the add->apply single-process flow)
#
# v2 fixes of the first run: (1) the uci config file must EXIST before
# cursor.set / uci set (both silently no-op "Entry not found" on a
# missing config — the committed files stayed empty); (2) ucode uci has
# NO add_list method (live find: "left-hand side is not a function") —
# probing `set(conf, sid, opt, [array])` as the list primitive instead;
# (3) real ucode version print.
#
# Run (from PowerShell):
#   docker run --rm --cap-add=SYS_ADMIN --cap-add=NET_ADMIN `
#     -v "<repo>:/repo:ro" openwrt/rootfs:x86_64-25.12.5 `
#     sh /repo/docs/spike-ucode/stage4/probe.sh
set -u

hdr() { printf '\n===== %s =====\n' "$*"; }
rc()  { printf -- '-- rc=%d\n' "$1"; }
show() { sed -e 's/\t/<TAB>/g; s/$/<EOL>/'; }

hdr P0 versions
head -n1 /etc/openwrt_release
ucode -e 'print("ucode ", version() ?? "?", "\n");' 2>/dev/null || true

# ---------- P1 printf ----------
hdr 'P1 printf padding (sh printf parity)'
ucode -e '
printf("[%-16s][%-20s][%-8s]\n", "NAME", "MAC", "GROUP");
printf("[%-16s][%-20s][%-8s]\n", "phone-livingroom", "aa:bb:cc:dd:ee:ff", "proxy (??)");
printf("[%-8s][%-14s][%-12s][%-9s][%-9s][%s]\n", "WAN", "DEVICE", "STATE", "RTT(s)", "ANCHORS", "SINCE");
printf("[%-10s][%-7s][%-10s][%-5s][%-5s][%-14s][%s]\n", "freedom", "direct", "vpn", "100", "400", "pptp-freedom", "15");
printf("[%s\t%s\t%s\t%d]\n", "aa:bb:cc:dd:ee:01", "192.168.88.35", "buddy-052", 1);
printf("[%s\t%s\t%s\t%d]\n", "aa:bb:cc:dd:ee:02", "-", "-", 0);
printf("[%-8s][%-8s][%-8s][%-9s][%-20s][%s]\n", "freedom", "vpn", "vpn", "auto", "*", "2");
'

# ---------- P2 replace/lc vs sh tr ----------
hdr 'P2 mac normalization primitives'
ucode -e '
function sh_tr(raw) { // sh: tr ABCDEF- abcdef: ; tr -d ":."
	let s = replace(lc("" + raw), /-/g, ":");
	return replace(s, /[:.]/g, "");
}
printf("%s\n", sh_tr("AA-BB-CC-DD-EE-FF"));
printf("%s\n", sh_tr("aabb.ccdd.eeff"));
printf("%s\n", sh_tr("AABBCCDDEEFF"));
printf("[%s]\n", sh_tr("d8:bb:c1:cc:17:71"));
printf("[%s]\n", sh_tr("gaa:bb:cc:dd:ee:ff")); // g survives deletion in sh too
printf("[%s]\n", sh_tr("aabbccddeef"));        // 11 hex
printf("[%s]\n", sh_tr("aabbccddeeff0"));      // 13 hex
printf("[%s]\n", match("aabbccddeeff", /^[0-9a-f]{12}$/) != null ? "ERE{12}=ok" : "ERE{12}=FAIL");
printf("[%s]\n", match("aa:bb:cc:dd:ee:01", /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) != null ? "ERE{2}x5=ok" : "ERE{2}x5=FAIL");
'

# ---------- P3+P4 uci cursor ----------
hdr 'P3 uci cursor: named sections, delete-missing, add_list, get shapes'
rm -f /etc/config/wanguard /tmp/.uci/wanguard
touch /etc/config/wanguard # uci requires the config file to exist (v2 fix)
ucode -L /repo/docs/spike-ucode/mock -e '
import * as uci from "uci";
let c = uci.cursor();
// named section create (3-arg set) — the migrate_legacy pattern
c.set("wanguard", "globals", "globals");
c.set("wanguard", "globals", "no_mark", "192.168.88.1");
c.set("wanguard", "freedom", "group");
c.set("wanguard", "freedom", "type", "direct");
c.set("wanguard", "freedom", "iface", "vpn");
c.set("wanguard", "m_d8bbc1cc1771", "member");
c.set("wanguard", "m_d8bbc1cc1771", "name", "tower");
c.set("wanguard", "m_d8bbc1cc1771", "mac", "d8:bb:c1:cc:17:71");
c.set("wanguard", "m_d8bbc1cc1771", "group", "freedom");
c.save("wanguard"); c.commit("wanguard");
// 2-arg get: section existence/type?
printf("get2 existing: %J\n", c.get("wanguard", "freedom"));
printf("get2 missing:  %J\n", c.get("wanguard", "nosuch"));
printf("get_all existing: %J\n", c.get_all("wanguard", "freedom"));
printf("get_all missing: %J\n", c.get_all("wanguard", "nosuch"));
// list read-back BEFORE any list write
printf("backup before: %J\n", c.get("wanguard", "freedom", "backup_iface"));
// list writing: add_list is ABSENT (v2 finding) — set with array?
try {
	c.set("wanguard", "freedom", "backup_iface", [ "rostelecom", "wan" ]);
	c.save("wanguard"); c.commit("wanguard");
	printf("backup after set-array: %J\n", c.get("wanguard", "freedom", "backup_iface"));
} catch (e) {
	printf("set-array raised: %s\n", e);
}
// delete of a MISSING option — raises or silent? (sh `uci -q delete`)
try {
	c.delete("wanguard", "freedom", "wanmode");
	printf("delete-missing-opt: silent-ok\n");
} catch (e) {
	printf("delete-missing-opt: raised: %s\n", e);
}
// delete of a MISSING section — raises or silent? (groupdel guard)
try {
	c.delete("wanguard", "nosuchsection");
	printf("delete-missing-sec: silent-ok\n");
} catch (e) {
	printf("delete-missing-sec: raised: %s\n", e);
}
// delete existing list option, then re-add one-by-one (add_list semantics)
c.delete("wanguard", "freedom", "backup_iface");
c.set("wanguard", "freedom", "backup_iface", [ "wan" ]);
c.save("wanguard"); c.commit("wanguard");
printf("backup after re-set: %J\n", c.get("wanguard", "freedom", "backup_iface"));
' 2>&1 | show
echo '-- committed file (ucode side) --'
cat /etc/config/wanguard | show
rc=$?

hdr 'P4 byte-parity of the same logical edit via sh uci'
rm -f /etc/config/wanguard /tmp/.uci/wanguard
touch /etc/config/wanguard # uci requires the config file to exist (v2 fix)
uci set wanguard.globals=globals
uci set wanguard.globals.no_mark='192.168.88.1'
uci set wanguard.freedom=group
uci set wanguard.freedom.type=direct
uci set wanguard.freedom.iface=vpn
uci set wanguard.m_d8bbc1cc1771=member
uci set wanguard.m_d8bbc1cc1771.name=tower
uci set wanguard.m_d8bbc1cc1771.mac='d8:bb:c1:cc:17:71'
uci set wanguard.m_d8bbc1cc1771.group=freedom
uci add_list wanguard.freedom.backup_iface='rostelecom'
uci add_list wanguard.freedom.backup_iface='wan'
uci commit wanguard
echo '-- committed file (sh side) --'
cat /etc/config/wanguard | show
echo "-- NOTE: compare with the ucode-side listing above byte-by-byte --"

# ---------- P5 /proc reads ----------
hdr 'P5 fs.readfile on size-0 /proc files'
ucode -L /repo/docs/spike-ucode/mock -e '
import * as fs from "fs";
let arp = fs.readfile("/proc/net/arp");
printf("arp read: %d bytes\n", length(arp ?? ""));
printf("%s\n", substr(arp ?? "", 0, 80));
' 2>&1 | show

# ---------- P6 awk split parity ----------
hdr 'P6 split semantics vs awk'
printf 'awk:   ' ; awk 'BEGIN { k = split("  a  b c ", f, /[ \t]+/); printf "k=%d [%s][%s][%s][%s][%s]\n", k, f[1], f[2], f[3], f[4], f[5] }'
ucode -e '
let f = split("  a  b c ", /[ \t]+/);
printf("ucode: k=%d %J\n", length(f), f);
let g = split("nolead trail ", /[ \t]+/);
printf("ucode: k=%d %J\n", length(g), g);
' | show
printf 'awk:   ' ; awk 'BEGIN { k = split("nolead trail ", f, /[ \t]+/); printf "k=%d [%s][%s][%s]\n", k, f[1], f[2], f[3] }'

# ---------- P8 /proc/net/arp fixture vehicles ----------
hdr 'P8a mount --bind over /proc/net/arp (SUPERSEDED — see NOTES §B1)'
# v4 correction: a bind-mount here returns rc 0 but READERS STILL SEE THE
# ORIGINAL procfs content (the v1/v2 probe listed the real header and was
# misread as success). The working vehicle is ip-full + dummy br-lan +
# `ip neigh ... nud stale` (renders flags 0x2) — see NOTES §B1 and the
# cli-parity.sh arp_reset/arp_entry helpers.
printf '172.16.31.1    0x1         0x2         aa:bb:cc:dd:ee:0a     *        br-lan\n' > /tmp/arpfix
if mount --bind /tmp/arpfix /proc/net/arp 2>/tmp/mount.err; then
	echo 'bind-mount rc: 0 (BUT content below is the ORIGINAL /proc/net/arp!)'
	cat /proc/net/arp | show
	umount /proc/net/arp 2>/dev/null
	echo 'attempted unmount'
else
	echo 'bind-mount: FAILED'
	cat /tmp/mount.err
fi

hdr 'P8b dummy iface + permanent neigh (fallback vehicle) — INFO only'
# busybox ip of the bare rootfs has no `ip neigh` verb (v1 finding:
# "invalid argument 'replace' to 'ip'"); P8a bind-mount is the harness
# vehicle. Kept as a one-line informational probe.
ip neigh 2>&1 | head -n1 | show

# ---------- P9 popen/system rc ----------
hdr 'P9 popen rc + stderr merge; system rc'
ucode -e '
import * as fs from "fs";
let p = fs.popen("echo out; echo err >&2; exit 3", "r");
let out = p.read("all");
printf("rc=%d out=%J\n", p.close(), out);
printf("system rc: %d\n", system("command -v curl >/dev/null 2>&1"));
printf("system rc missing: %d\n", system("command -v definitel'y'absent >/dev/null 2>&1"));
'

# ---------- P10 default-name port ----------
hdr 'P10 index/substr (sh ${mac#*:} parity)'
ucode -e '
let mac = "d8:bb:c1:cc:17:71";
printf("[%s]\n", "mac-" + substr(mac, index(mac, ":") + 1));
let m2 = "aa:bb:cc:dd:ee:ff";
printf("[%s]\n", "mac-" + substr(m2, index(m2, ":") + 1));
'

# ---------- P11 cursor snapshot across in-process mutation ----------
hdr 'P11 foreach visibility of a section set in the SAME process'
rm -f /etc/config/wanguard /tmp/.uci/wanguard
touch /etc/config/wanguard # uci requires the config file to exist (v2 fix)
ucode -e '
import * as uci from "uci";
let c = uci.cursor();
c.set("wanguard", "freedom", "group");
c.set("wanguard", "freedom", "type", "direct");
c.set("wanguard", "m_aa", "member");
c.set("wanguard", "m_aa", "mac", "aa:aa:aa:aa:aa:aa");
c.set("wanguard", "m_aa", "group", "freedom");
c.save("wanguard"); c.commit("wanguard");
let n1 = 0;
c.foreach("wanguard", "member", function(s) { n1++; });
printf("members via STALE cursor: %d\n", n1);
c = uci.cursor();
let n2 = 0;
c.foreach("wanguard", "member", function(s) { n2++; });
printf("members via REFRESHED cursor: %d\n", n2);
' 2>&1 | show
rm -f /etc/config/wanguard /tmp/.uci/wanguard

printf '\n===== probe done =====\n'
