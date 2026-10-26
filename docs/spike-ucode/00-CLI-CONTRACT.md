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
