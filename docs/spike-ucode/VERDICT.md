# Verdict draft — ucode migration (issue #29 spike)

**Status: DRAFT.** Phases 0–3 executed on `spike/ucode`; all numbers below
are measured and reproducible from the scripts in this directory. The two
rows marked ROUTER await the HITL windows (RUNBOOK.md). The final verdict
word belongs to the owner; this document prepares it.

## What was proven (all green, reproducible)

| Artifact | Result |
|---|---|
| `wand.uc` — ucode port of the tick path | 311 lines vs 939 sh (whole-file; tick path is ~40% of the sh file) |
| Differential scenarios (`scenario.sh`, `scenario26.sh`) | byte-identical events sh vs ucode: seed / 3-fail down / failover / dwell hold / 6-ok up / failback / #26 list-order failover / re-failover / flush protocol / final UCI state; 3×3 GREEN consolidated runs (suites + scenarios in one container); one flake root-caused to stray uci deltas (`/tmp/.uci`) and cross-script stub leakage — both now cleaned in every reset |
| `run-tests-ucode.sh` — representative T-port | 20/20 (#23 T1–T10, #6 T9, #26 B1/B2); sh suite 67/67 in the same container |
| Test infrastructure feasibility (the HIGH risk) | **resolved**: ucode children are spawned via /bin/sh → existing PATH stubs (curl/date/conntrack) intercept unchanged; native ubus is mocked by a `.uc` module shadowing via `ucode -L`; uci stays REAL on /etc/config on both sides |
| Packaging (`build-spike.sh` + `install-test.sh`) | apk builds with pinned apk.static 3.0.7; installs into openwrt/rootfs 25.12.5; `#!/usr/bin/ucode` shebang works; ucode itself was already installed (not pulled as a dependency); unmodified keepalive loop body drives the ucode CLI; passthrough output byte-parity for apply/wan-flush |
| Porting traps caught by the differential method | (a) string-option word-split parity (`uci set wan_anchors='u1 u2 u3'`), (b) rtt string fidelity (0.050 vs 0.05), (c) popen close() exit-code form, (d) `export function` breaks module compilation in ucode 2026.01.16 (trailing `export{}` works) |

## Gains matrix (measured)

| # | Gain | Evidence |
|---|---|---|
| 1 | Fork collapse per 10 s tick | **sh 58 → ucode 4 external children** (14.5×) in prod shape (2 direct groups, 2 WANs, 2 anchors): sh = 30 uci + 6 awk + 6 grep + 4 jsonfilter + 4 curl + 3 sort + 2 cut + 2 sed + 1 date; ucode = 4 curl (probe only; array-form `fs.popen` would also drop the 4 /bin/sh wrappers) |
| 2 | Bug classes eliminated by design | jsonfilter quoted-key (live prod bug e98ae77), word-splitting, `case " $(cmd) "` multiline (#26) — NOTE: all already patched in sh; the classes are closed, not open |
| 3 | Wall-time per tick | container probe (forced-probe path, full steady state): sh ~110 ms vs ucode ~13.5 ms median (~8×). NB: on the router the tick's wall-time is dominated by the REAL curl probes, which are identical external calls in both variants — the win there applies to the non-blocking plumbing only; the ROUTER row from the HITL windows decides |
| 4 | Memory | pending (VmHWM method in bench-sh.sh). ROUTER: pending |
| 5 | Readability | tick path: state as objects (one ubus dump → map) vs grep/cut/sed pipelines; type-safe numbers (dwell/oks/fails) vs string comparisons |
| 6 | OpenWrt ecosystem alignment | fw4/rpcd/LuCI2 are ucode; matches upstream direction |
| 7 | Test environment | container replaces WSL-only (both suites run in openwrt/rootfs) |

## Losses matrix

| # | Loss | Weight |
|---|---|---|
| 1 | Live-scenario trust resets to zero: 2026-10-13 failover/failback, 2026-10-24 re-failover (1133→0 conntrack, UDP re-key) were accepted ON THE HARDWARE; a rewrite forfeits that and requires staged re-acceptance | HIGH |
| 2 | Test porting: 47 of 67 existing checks cover the ported path and must move (20/20 done as proof; remainder ~1–1.5 days); two runners maintained during any transition period | MEDIUM |
| 3 | Debugging reflexes: `sh -x` line-trace gone (ucode: `-t` opcode trace / udbg debugger — new tooling); error style becomes stack-trace-like | MEDIUM |
| 4 | Hybrid runtime cost if not fully rewritten: keepalive/init.d/wan-watch/LuCI stay sh; apply/wan-flush stay sh — two interpreters, two styles, permanently until stage 3 of a full rewrite | MEDIUM |
| 5 | `uclient.so` cannot replace the probe: no SO_BINDTODEVICE anywhere (libuclient nor uclient-fetch) → `curl --interface` stays external forever; fork win partially capped | MEDIUM (capped, see gain 1) |
| 6 | Platform volatility: `export function` broken in ucode 2026.01.16 module compiler; module APIs moved across versions (uclient binding is 2024+) | LOW-MED |
| 7 | The 939 sh lines are battle-tested, comment-dense, and fully covered — a rewrite spends risk budget to buy optimization of a subsystem that already works | context |

## Full rewrite estimate (only if verdict = yes)

Staged, each stage = tests green + tag + live 5/5 acceptance:

| Stage | Scope | Estimate |
|---|---|---|
| 1 | wand-tick (exists in this branch) + live acceptance | 1 d |
| 2 | wan-flush + conntrack path | 1 d |
| 3 | apply (alloc/render/diff/reconcile: the biggest, riskiest slice) | 2–3 d |
| 4 | CLI CRUD + wanstatus/wanset/wanauto/backupset/devices | 1–2 d |
| 5 | full test-suite port (47 remaining) + retire sh | 1–2 d |
| | **total** | **6–9 d** + HITL windows per stage |

## Verdict draft (owner decides)

- **Recommended: NO — keep sh, with an explicit revisit trigger.** The
  measured wins are real but modest on this scale: the fork collapse buys
  <1% CPU on the tick budget (ROUTER row to confirm), every bug class ucode
  excludes is already patched in sh, and the price is forfeiting the
  hardware-accepted failover trust plus a staged 6–9 day migration of the
  riskiest file in the project. Revisit when ANY of: (a) a new sh-only bug
  class appears that ucode excludes by design, (b) the core grows past
  ~1500 lines, (c) OpenWrt upstream forces a ucode-only integration
  (rpcd/LuCI2 API surface).
- **Hybrid (tick in ucode, rest sh):** defensible if the fork number
  matters (54/58 of tick forks die); permanent two-runtime cost, two test
  runners; the spike package + wand.uc are ready to ship as-is.
- **Yes (full rewrite):** only if strategic alignment with the ucode
  ecosystem is itself the goal; 6–9 days staged as above.

All spike artifacts (wand.uc, mocks, runners, bench, package) live on
`spike/ucode` and can seed any of the three outcomes. The branch never
deploys: the feed ships from tagged `main` only.
