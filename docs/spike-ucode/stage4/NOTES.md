# Stage 4 NOTES — ucode API facts + harness vehicles (issue #34)

Evidence base for the #34 CLI byte-parity port, probed live inside
`openwrt/rootfs:x86_64-25.12.5` (2026-10-28). Probe: `probe.sh` (v2);
harness vehicles debugged in throwaway containers (v3/v4 findings below).

## A. ucode API facts (probe P1–P11)

| # | surface | finding |
|---|---|---|
| A1 | `printf('%-16s...\n', ...)` | width/flags byte-identical to sh printf — the `list`/`grouplist`/`wanstatus` tables need NO formatting shims |
| A2 | `replace()`/`lc()` for MAC normalization | `replace(lc(x), /-/g, ':')` + `replace(s, /[:.]/g, '')` = sh `tr 'ABCDEF-' 'abcdef:'` + `tr -d ':.'` exactly; ERE intervals (`{12}`, `{2}x{5}`) work in `match()` |
| A3 | `cursor.get(conf, sid)` (2-arg) | returns the section **TYPE** string (`"group"`) — the exact `uci -q get conf.sid` existence-check parity; `null` when absent |
| A4 | `cursor.get_all` | full section object with `.type`/`.name` — not needed (A3 suffices) |
| A5 | `cursor.add_list` | **DOES NOT EXIST** in ucode-mod-uci ("left-hand side is not a function"). List writing = `set(conf, sid, opt, [array])` — committed file renders the same `list x 'y'` lines as sh `uci add_list` (byte-compared in probe P3/P4) |
| A6 | `cursor.delete` of missing option/section | silent no-op — sh `uci -q delete` parity, no try/catch needed |
| A7 | committed UCI bytes | ucode save+commit vs sh `uci set/add_list/commit`: **identical** (same libuci serialization, probe P3 vs P4 byte listings) |
| A8 | `fs.readfile` on size-0 /proc files | works (`/proc/net/arp` → 79 bytes of header) — the devices port reads procfs directly |
| A9 | `split(line, /[ \t]+/)` | reproduces awk field splitting INCLUDING leading/trailing empty fields (`"  a  b c "` → `["", "a", "b", "c", ""]`, k=5 both) — the devices port is field-index-equal to the sh awk with `ucode f[0] = awk f[1]` |
| A10 | cursor snapshot | sections set in the SAME process ARE visible to `foreach` on the same cursor (P11) — but the refresh pattern (`cursor = uci.cursor()` after commit) is kept anyway: sh runs every uci call as a fresh process, and the mutation commands feed a trailing native `apply()` |
| A11 | ucode on missing config | `foreach`/`get` on an absent `/etc/config/wanguard` behave like `uci -q`: 0 iterations / null (L0 pair) |
| A12 | `slice(arr, 1)` | exists; used for the backupset argument tail |

## B. Harness vehicles (stage4/cli-parity.sh) — live lessons

1. **`/proc/net/arp` bind-mount is DEAD.** `mount --bind fixture /proc/net/arp`
   returns rc 0 but readers still see the ORIGINAL procfs content (probe v1
   "P8a OK" was a misread — the shown content was the real header, not the
   fixture). The working vehicle: `apk add ip-full` + a dummy `br-lan`
   (`ip link add br-lan type dummy`) + REAL neighbor entries:
   - `ip neigh replace <ip> lladdr <mac> dev br-lan nud stale` → flags **0x2**
     (complete — exactly what the CLI counts as online);
   - `nud permanent` → flags **0x6** — the CLI's `f[3]=="0x2"` filter SKIPS it
     (true on the router too: a permanent entry is not "complete via ARP");
   - `nud failed` → flags **0x0** (skipped); entries on other ifaces (eth0)
     → filtered by the `f[6]==br-lan` device check.
   Kernel REJECTS garbage lladdrs — invalid-MAC filtering is fixture-covered
   through the leases file instead.
2. **`reset_state` must TRUNCATE (`: > $CONF`), not `touch`.** `touch`
   preserved the sh subject's committed mutations into the uc subject's run
   (the phantom "section 'test' already exists" rc mismatch in GA1).
3. **This image has no `diff`, no `od`, no `cat -A`.** Byte-diff reporting
   uses `cmp` output; byte dumps during debugging used `ucode -e
   'printf("%J", fs.readfile(...))'`.
4. **`uci` lives in `/sbin`** — a reduced debug PATH "broke" the sh subject
   with `uci: not found`; the harness inherits the full container PATH under
   the shim prefix. `ip-full` must be invoked by absolute path captured
   BEFORE the shim PATH is prepended (the shim `ip` would intercept).
5. ucode module shadowing (`ucode -L docs/spike-ucode/mock`) + PATH stubs
   for `nft ip ubus jsonfilter date conntrack curl` (tests/mock/bin) — same
   architecture as the stage-3 harness; `WANGUARD_SH` is no longer involved
   (the passthrough is gone) and the harness proves it with the
   `WANGUARD_SH=/nonexistent` native gate on list/grouplist/apply.

## C. Port findings (real parity bugs caught by the harness)

1. **`backupset` confirmation line**: sh prints `backup order:wan2 wan3`
   — NO space after the colon (`${out# }` strips the leading space of the
   accumulated list). The first port draft printed `order: wan2` — caught
   by the BS1/BS6 differential.
2. **`wanstatus` SINCE**: sh `$(date -d ...)` strips trailing newlines;
   `sh_read()` returns the raw popen output — the first draft emitted a
   blank line after every dated row. Fixed with `rtrim(sh_read(...))`
   (rtrim, not trim — sh strips trailing newlines only).

## D. Deliberate deviations (documented, not regressions)

- `probe-selftest` remains a ucode-only dispatch case (window evidence tool
  since stage 1; the sh CLI answers `unknown command` for it — accepted
  deviation, never surfaced to contract clients).
- The sh suite's T-tests (67/67) and the stage-2 F-series (55/55) and the
  stage-3 apply-parity (165/165) all stay green against the stage-4 file:
  `wand-tick`/`wan-flush`/`apply` code paths are untouched.
