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
export WANGUARD_SH=/usr/bin/wanguard   # passthrough target for apply etc.
RUNNER=ucode WG=/tmp/wanguard.ucode CMDS=wand-tick sh /tmp/bench-sh.sh
```

`wanguard.ucode` ports the tick path only (UCI via uci.so, iface status
via one ubus dump, probe via curl child — see the PROBE NOTE in the file,
backup selection, state machine). `apply`/`wan-flush` pass through to the
stock sh CLI, so they are NOT benched in this window (only `wand-tick`
runs the ucode code); the sh baseline numbers from window 1 cover them.

Also run during the window: `WANGUARD_SH=/usr/bin/wanguard ucode /tmp/wanguard.ucode
probe-selftest` — prints the ubus iface map and per-anchor probe results for
manual comparison with `curl --interface <dev> ...` behavior (Phase 1.3
evidence).

## Anti-goals (both windows)

- no `uci commit` changes, no package installs, no service restarts
- no deploys: the feed ships from tagged `main` only; the spike never deploys
