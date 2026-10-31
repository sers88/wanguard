# Spike ucode (issue #29) — frozen CLI contract

**Invariant of the spike:** everything below must keep working byte-for-byte
when `router/wanguard` is rewritten in ucode. The clients (keepalive,
init.d, LuCI app, wan-watch, operator muscle memory) are NOT touched.

Branch: `spike/ucode` only. Feed ships from tagged `main` only — the spike
can never deploy.

## 1. Subcommands (dispatch: router/wanguard case block, lines 996–1011)

| Subcommand | Args | Exit 0 stdout | Notes |
|---|---|---|---|
| `list` | — | `NAME MAC GROUP` table (`%-16s %-20s %-8s`), then `nft: in-sync` or `nft: DRIFT (...)` | **DRIFT → exit 1** (LuCI shows "unavailable") |
| `add` | `<mac> <group> [name]` | `added <mac> -> <group>` | mac normalized `aa:bb:cc:dd:ee:ff` |
| `move` | `<mac> <group>` | `moved <mac> -> <group>` | |
| `remove` | `<mac>` | `removed <mac>` | |
| `apply` | — | **exactly `in-sync`** when no change; else change summary lines | keepalive compares `[ "$out" = in-sync ]` — literal string |
| `grouplist` | — | `GROUP TYPE IFACE MARK TABLE DEVICE MEMBERS` table | |
| `devices` | — | `mac<TAB>ip<TAB>name<TAB>online` per line | parsed by LuCI `parseDevices()` |
| `groupadd` | `<name> <iface\|proxy>` | `group <name> -> <target>` | |
| `groupset` | `<name> <iface\|proxy>` | `group <name> -> <target>` | may echo flush event |
| `groupdel` | `<name>` | `group <name> removed` | |
| `wanstatus` | — | two tables (WANs, then GROUPS) | human-readable, not machine-parsed |
| `wanset` | `<group> <iface>` | `wand: <group> pinned to <iface> (manual)` | |
| `wanauto` | `<group>` | `wand: <group> auto (watchdog)` | |
| `backupset` | `<group> <iface>...` | confirmation line | #26 |
| `wand-tick` | — | `wand:<events>` one line, empty when quiet | runs before apply in keepalive |
| `wan-flush` | — | `wand: flush:...` events, empty when quiet | runs after apply in keepalive; native ucode since stage 2 (#32) |
| (default/help) | — | usage/help text | **exit 0** (`""`/`help`/`-h`/`--help` → cmd_help) | |

Errors: `wanguard: <message>` on **stderr**, exit 1 (`err()`).

## 1.1 Post-freeze deltas (each reviewed; goldens re-captured deliberately)

Since the stage-5 freeze (issue #35), the contract grew ADDITIVELY — the
frozen bytes of the existing surfaces never moved:

| Delta | Issue | Contract effect |
|---|---|---|
| `devices` 5th TAB column TYPE (hostname heuristic; member `option devtype` overrides) | #43 | The frozen contract is the **4-column prefix** — `stage4/cli-parity.sh` compares it byte-wise (`do_pair_dev`), the `D.out` golden was re-captured with the new column |
| `groupset <name> -label V [-color V] [-description V]` (metadata form; empty value = clear; color = blue/green/purple/orange/gray; **no apply**) | #42 | New form; the legacy target form `<name> <iface|proxy>` stays byte-frozen |
| `groupmeta [name]` — `name<TAB>label<TAB>color<TAB>description`, `-` = unset, no header | #42 | New subcommand (appending columns to `grouplist` would have broken the freeze — hence separate) |
| `devset <mac> <type\|->` — devtype override (whitelist watch/tv/pc/printer/phone/tablet/generic; err on unregistered MAC; **no apply**) | #43 | New subcommand |
| `help` text extended for the above | #42/#43 | `H.out` golden re-captured |
| wand state: `last-apply` + `events` ring (ucode-only; tmpfs — lost on reboot by design, UI feed not syslog) | #44 | New WAND_DIR files: `last-apply` = unix ts written on EVERY successful apply (both `applied` and `in-sync`); `events` = FIFO ring, max 200 lines, `ts<TAB>code<TAB>detail` (no tabs/newlines inside fields). Best-effort writes (fs.writefile tmp+rename) — a ring failure never breaks tick→apply→flush |
| `events [N]` — ring tail, default 20, TAB rows, no header | #44 | New subcommand |
| `syncstatus` — `status=in-sync\|drift`, `last_apply=<ts>`, `age=<s>` | #44 | New subcommand; drift computed LIVE (the `list` sets-diff, not the ring); `age` = now − last-apply |
| `diag [all\|rules\|tables\|nft\|health]` — read-only TAB sections | #45 | New subcommand; only read verbs apply already uses. Decisions: `rules` = FULL `ip rule show` (foreign prio-1000 rules are exactly what debugging needs to see); `health` = procd state via `ubus call service list` (wanguard, mihomo) + config validation + package version from `/usr/share/wanguard/version` (stamped by apk/build.sh from `$VER`; missing file → `-`) |
| `inspect <mac\|ip\|hostname>` — configured vs live for one device | #45 | New subcommand; MAC normalization + dhcp.leases/inventory resolve; prints group, allocation (mark/table), configured iface vs live (netifd dump), nft `mac_<g>` membership, matching `wg:<g>:` rules. Cases: direct / proxy / direct-lb / ungrouped / unknown |
| `diag-report` — full text report (LuCI "Download report") | #45 | New subcommand; aggregate: diag sections + inspect summary + syncstatus + timestamp header. NEVER reads `/etc/config/network` (PPPoE/WG secrets) or any secret-bearing config — only read-command output; test-gated by a secrets-marker grep |
| `help` text extended for the above | #44/#45 | `H.out` golden re-captured (append-only) |

Machine readers of `devices` that stop at 4 fields (old LuCI) keep working
unchanged.

### 1.2 Diagnostics data-plane decisions (#44/#45, fixed before code)

- Event codes and their single write site: `config_validated` (apply, after
  the validation pass), `apply_ok` (apply success — `in-sync` path too),
  `apply_err` (apply failure branch, e.g. `nft check failed`), `drift` /
  `restored` (apply: drift is a found diff whose desired-side hash equals
  the last successful apply's — i.e. UCI did NOT change, live did; e.g. a
  manual `nft` edit. `restored` fires after that same run repairs it;
  legitimate UCI-induced renders are NOT drift), `flush` (wan-flush, detail
  = the existing `flush:<g>><old>(<ip>)`), `failover`/`failback` (tick UCI
  flips), `lbover` (tick LB block).
- `syncstatus` exit 0 always (a state probe, not a verdict — LuCI reads it
  on every header render; DRIFT semantics stay exclusive to `list`).
- `diag`/`inspect`/`diag-report` are ucode-only (the `groupmeta` precedent,
  #42): the sh reference (`router/wanguard`) is not extended, cli-parity
  gains no pairs, the surfaces are pinned by new stage-5 goldens instead.
- No new rpcd/ACL grants: LuCI keeps exec'ing exactly one binary.

## 2. Client expectations (the actual consumers of the contract)

1. **keepalive** (`router/wanguard-keepalive`, sh, unchanged):
   - `wand-tick 2>&1` → if non-empty, `logger -t wanguard-wand`
   - `apply 2>&1` → logged **unless stdout is exactly `in-sync`**
   - `wan-flush 2>&1` → if non-empty, logged
   - every 10 s; any exit code tolerated (output-driven)
2. **init.d/wanguard**: `wanguard apply >/dev/null 2>&1 || true` — exit code
   advisory only.
3. **LuCI** (`luci-app-wanguard`): rpc `file exec` of `/usr/bin/wanguard`
   with `list` / `devices` / `apply` (rpcd ACL grants exec). Parses:
   - `devices`: `mac\tip\tname\tonline` (tab-separated, `online` = 0/1)
   - `list`: warning line about unknown groups + `nft: in-sync|DRIFT` are
     surfaced; table rows parsed loosely
4. **wan-watch**: does not call the CLI (mihomo watchdog only) but co-exists.

## 3. Cross-invocation state (must survive a rewrite)

- UCI `/etc/config/wanguard`: single source of truth; `apply` renders all
  (nft sets/rules with `wg:<group>:*` comment tags, ip rules, per-group
  tables/routes). Allocation is deterministic from sorted group names
  (ARCHITECTURE.md §2): proxy → fwmark 300/table 500/prio 8000; direct →
  marks 100,200,400…, tables 400+k, prio 8100+k.
- `/tmp/wanguard/` (WAND_DIR): `<wan>.state|oks|fails|since|rtt|alive|addr`,
  `<group>.lastswitch|flush`. The `.flush` files are a **protocol** between
  `wand-tick` (writer) and `wan-flush` (reader).
- `/usr/share/wanguard/wanguard.nft` — table skeleton installed by apk.

## 4. Environment dependencies observed (fork sites to eliminate or keep)

`uci` ×76, `tr` ×45, `printf` builtin, `ip` ×26, `nft` ×20, `sort` ×14,
`grep` ×13, `conntrack` ×12, `sed` ×9, `date` ×5, `curl` ×4, `ubus` ×4,
`jsonfilter` ×3, `awk` (devices/probe-min) — per 10 s tick dozens of
processes spawn.

Key semantics that must be reproduced exactly:

- `iface_device/iface_addr`: `ubus call network.interface.<x> status` →
  `up:true` + `l3_device` + `ipv4-address[0].address` (jsonfilter
  quoted-key form — dotted form breaks on hyphenated iface names, live bug
  fixed in e98ae77).
- `wand_probe`: `curl --interface <dev> -m 5 -sf -o /dev/null -w
  '%{time_total}' <anchor>` — **device binding, 5 s timeout, RTT
  extraction**; N-of-M anchors must answer (`wan_reliability`); min RTT of
  answering anchors persisted; `/tmp/wanguard/<wan>.force` file with
  `ok|fail` is the test hook.
- Failover state machine: 3 fails = down, 6 oks = up (`WAND_FAILS_DOWN=3`,
  `WAND_OKS_UP=6`), min dwell 60 s between switches, failback to home when
  home recovers, re-failover down the `wand_backups()` list (#26), flips
  go through UCI (never render directly).
