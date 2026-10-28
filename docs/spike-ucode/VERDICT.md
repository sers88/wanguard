# Verdict draft — ucode migration (issue #29 spike)

**Status: DECIDED — YES, full staged ucode migration (owner, 2026-10-25).**
The acceptance battery C1–C6 ran GREEN in one lab session (openwrt/rootfs
25.12.5 containers, real ubusd, real curl probes, real nft/ip-rule/
conntrack under NET_ADMIN); the router itself was never touched (owner
decision). After this evidence the owner accepted the full staged
migration: single agent, no-rush schedule, per-stage tests + tag + live
5/5 acceptance. The staged plan and its issues live in the private
tracker (sers88/wanguard-home); this document records the evidence and
the original draft recommendation (kept below as history).

**MIGRATION EXECUTED — FINAL STAGE IN ACCEPTANCE (2026-10-28).** All five
stages executed, each with a green battery, a feed tag and a live 5/5
router window: v1.0.5 (wand-tick) → v1.0.6 (wan-flush) → v1.0.7 (apply) →
v1.0.8 (CLI CRUD). **Stage 5 (full test-suite port + sh retirement) is
dev-complete and lab-green** (`docs/spike-ucode/stage5/`: NOTES/LAB/
contract-gate + golden bytes; 87 ucode checks = 67 sh equivalents +
extras; the package ships only the ucode CLI, rollback = reinstall the
previous feed tag) — the final live window + the v1.0.9 tag close it
out. The historical material below is kept as-is.

## What was proven (all green, reproducible)

| Artifact | Result |
|---|---|
| `wand.uc` — ucode port of the tick path | 311 lines vs 939 sh (whole-file; tick path is ~40% of the sh file) |
| Differential scenarios (`scenario.sh`, `scenario26.sh`) | byte-identical events sh vs ucode: seed / 3-fail down / failover / dwell hold / 6-ok up / failback / #26 list-order failover / re-failover / flush protocol / final UCI state; 3×3 GREEN consolidated runs (suites + scenarios in one container); one flake root-caused to stray uci deltas (`/tmp/.uci`) and cross-script stub leakage — both now cleaned in every reset |
| **Docker-lab battery C1–C6** (`lab/`, one lab session, all green) | **C1** regress: sh 67/67 + ucode 20/20 + scenarios byte-identical (caught one stale mock API after the live-path fixes — mock ubus `close()` → `disconnect()`, the exact trap of грабля №2; differential method did its job). **C2** live failover drill: 5/5 cycles `down:wan1 → failover:a>wan2 → apply → table 400 dev eth0→eth1` and back, sh parity cycle, iptables trap clean. **C3** live 3-WAN (#26): wan1→wan3 (list order) → wan3 dies → RE-failover wan2 → failback, table 400 eth0→eth2→eth1→eth0, flush protocol `flush:a>wanX(ip)` each hop. **C4** keepalive ×100 through the unmodified loop body via the ucode CLI: rc=0 everywhere, 1 applied + 99 in-sync, silence after settle; `list/grouplist/wanstatus/devices` byte-identical + same exit codes vs the sh CLI on identical state (dhcp.leases fixture: invalid mac, `*` name, uppercase, duplicate). **C5** edges: black-hole anchor (DROP) = one honest 5 s curl-`-m 5` tick, `wan1.fails=1`; N-of-M reliability 2 of 3: one anchor dead → alive=2 → up, two dead → alive=1 → `down:wan1` after 3 consecutive fails; override group held through `down:wan2` with zero x events. **C6** metrics below |
| `run-tests-ucode.sh` — representative T-port | 20/20 (#23 T1–T10, #6 T9, #26 B1/B2); sh suite 67/67 in the same container |
| Test infrastructure feasibility (the HIGH risk) | **resolved**: ucode children are spawned via /bin/sh → existing PATH stubs (curl/date/conntrack) intercept unchanged; native ubus is mocked by a `.uc` module shadowing via `ucode -L`; uci stays REAL on /etc/config on both sides |
| Packaging (`build-spike.sh` + `install-test.sh`) | apk builds with pinned apk.static 3.0.7; installs into openwrt/rootfs 25.12.5; `#!/usr/bin/ucode` shebang works; ucode itself was already installed (not pulled as a dependency); unmodified keepalive loop body drives the ucode CLI; passthrough output byte-parity for apply/wan-flush |
| Porting traps caught by the differential method | (a) string-option word-split parity (`uci set wan_anchors='u1 u2 u3'`), (b) rtt string fidelity (0.050 vs 0.05), (c) popen close() exit-code form, (d) `export function` breaks module compilation in ucode 2026.01.16 (trailing `export{}` works) |

## Gains matrix (measured)

| # | Gain | Evidence |
|---|---|---|
| 1 | Fork collapse per 10 s tick | **DOCKER (live lab, real bus, real curl): sh 54 → ucode 4 external children per tick (13.5×)** — ucode = 4 curl (probe only) and uci 22 → 0 (native uci.so); sh = 22 uci + 4 curl + 28 other (awk/grep/jsonfilter/sort/cut/sed/date/tr/ubus). Earlier mock-env prod-shape count: sh 58 → 4 (14.5×) — same family |
| 2 | Bug classes eliminated by design | jsonfilter quoted-key (live prod bug e98ae77), word-splitting, `case " $(cmd) "` multiline (#26) — NOTE: all already patched in sh; the classes are closed, not open |
| 3 | Wall-time per tick | **DOCKER (live lab, 40 ticks, real curl): sh 68.7 ms → ucode 14.1 ms (4.9×)**; earlier container mock probe (forced-probe path): sh ~110 ms vs ucode ~13.5 ms (~8×). NB: on the router the tick's wall-time is dominated by the REAL curl probes, which are identical external calls in both variants — the win applies to the non-blocking plumbing only |
| 4 | Memory | **DOCKER (main-process VmHWM, children excluded on BOTH sides): ucode 1280 kB vs sh 768 kB.** The ucode interpreter is the heavier single process; but the sh tick additionally spawns ~50 children per tick (each ~0.7–1 MB resident, short-lived) — total sh footprint is the larger one. Memory is not the deciding axis in either direction |
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

## Scope of the evidence: DOCKER, not hardware (owner decision)

The router was not touched; everything above ran in the Docker lab
(`lab/lab-up.sh`, reproducible): three isolated bridge networks as three
honest WANs, one uhttpd anchor container (alias IPs for N-of-M), the lab
container with the spike package, real ubusd + fake-netifd publishing
real `network.interface` objects, NET_ADMIN for nft/ip-rule/conntrack.

- **не железо**: absolute wall-times are NOT translatable to the router
  (different CPU, no bridge isolation, real RTTs to public anchors). The
  router's tick time is dominated by the curl probes themselves —
  identical external calls in both variants.
- **userland is exactly the target**: openwrt/rootfs 25.12.5, ucode
  2026.01.16 — the interpreter and module surface (uci/ubus/fs) are the
  ones that would ship.
- **kernel behavior verified functional, not timed**: nft table render,
  policy-routing table flips (400: eth0→eth2→eth1→eth0) and conntrack
  flush all execute under NET_ADMIN (WSL2 kernel) — semantics proven,
  timings meaningless for the router.
- Live failover/failback/re-failover on the actual hardware remains
  unproven (see losses #1) — that trust cannot be earned in Docker.

## Verdict draft (owner decides)

**RECORDED DECISION (2026-10-25): YES — full staged migration** (этапы:
tick → wan-flush → apply → CLI → retire sh; каждая стадия = тесты зелёные
+ тег + живая приёмка 5/5; один агент, без спешки). Драфт-рекомендация
ниже сохранена как история обсуждения.

- **Recommended: NO — keep sh, with an explicit revisit trigger.** The
  measured wins are real but modest on this scale: the fork collapse
  (54 → 4 children/tick, 13.5×, live lab) buys <1% CPU on the tick
  budget, and the 4.9× wall-time win lives in the plumbing that is not
  the tick's bottleneck on the router (curl probes are); every bug class
  ucode excludes is already patched in sh; and the price is forfeiting
  the hardware-accepted failover trust plus a staged 6–9 day migration
  of the riskiest file in the project. Revisit when ANY of: (a) a new
  sh-only bug class appears that ucode excludes by design, (b) the core
  grows past ~1500 lines, (c) OpenWrt upstream forces a ucode-only
  integration (rpcd/LuCI2 API surface).
- **Hybrid (tick in ucode, rest sh):** defensible if the fork number
  matters (50 of 54 tick spawns die); permanent two-runtime cost, two
  test runners; the spike package + wand.uc are lab-accepted and ready
  to ship as-is (staged live re-acceptance still required — losses #1).
- **Yes (full rewrite):** only if strategic alignment with the ucode
  ecosystem is itself the goal; 6–9 days staged as above.

All spike artifacts (wand.uc, mocks, runners, bench, package) live on
`spike/ucode` and can seed any of the three outcomes. The branch never
deploys: the feed ships from tagged `main` only.
