# Spike runbook — HITL windows on the router (issue #29)

Two short windows are needed from the owner. Everything else runs
offline (container/local). Neither window touches the installed package:
all commands run through copies in `/tmp`.

## Window 1 — sh baseline (Phase 0.3, ~15 min, WANs steady/UP)

```sh
# on the router, as root (copy the file from the repo first, e.g. via scp):
scp docs/spike-ucode/bench-sh.sh root@192.168.x.x:/tmp/   # from the PC
ssh root@192.168.x.x
sh /tmp/bench-sh.sh            # 100 iterations of tick/apply/flush + RSS
cat /tmp/bench.*.context       # context block for the issue
```

Paste back the full output (summary lines + context). Raw samples stay in
`/tmp/bench.$$.*` — paste those too if convenient (they compress well).

Preconditions: both WANs up and stable (no failover in progress — otherwise
the tick does real UCI flips, which we do NOT want in a measurement window).
The real keepalive keeps running; that is intentional (steady state =
in-sync apply, quiet tick).

## Window 2 — ucode tick (Phase 1.5, ~15 min, same method)

After Phase 1 lands the ucode skeleton on `spike/ucode`:

```sh
scp docs/spike-ucode/wand.uc root@192.168.x.x:/tmp/wanguard.ucode
ssh root@192.168.x.x
WG=/tmp/wanguard.ucode sh /tmp/bench-sh.sh
```

`wanguard.ucode` is the ucode port of the tick path (probe + state machine
+ backups selection); `apply`/`wan-flush` in that file intentionally fall
back to invoking the stock sh CLI so the timing comparison stays honest
per-subcommand (documented in the file header).

Also eyeball during the window: `ubus call network.interface.wan2 status`
shape vs what the ucode code reads, and the uclient probe semantics check
(Phase 1.3): `/tmp/wanguard.ucode probe-selftest` prints per-anchor
device-binding + RTT results for manual comparison with curl.

## Anti-goals (both windows)

- no `uci commit` changes, no package installs, no service restarts
- no deploys: the feed ships from tagged `main` only; the spike never deploys
