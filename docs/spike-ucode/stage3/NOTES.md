# Stage 3 NOTES — real nft/ip behavior (probe transcripts)

Evidence base for the #33 render-parity fixtures and the ucode `apply`
port. Everything below was captured by running `probe.sh` inside
`openwrt/rootfs:x86_64-25.12.5` with `--cap-add=NET_ADMIN` (2026-10-27):

    docker run --rm --cap-add=NET_ADMIN -v "<repo>:/repo:ro" `
      openwrt/rootfs:x86_64-25.12.5 sh /repo/docs/spike-ucode/stage3/probe.sh

Transcripts use `show()` markers: `<TAB>` = tab, `<EOL>` = end of line —
trailing whitespace is THE parity question for the route greps.

Versions: **nftables v1.1.6** (Commodore Bullmoose), **ip-full**
(iproute2 of 25.12.5 — the package the router runs since stage #13;
busybox ip differs, see the last section).

## A. nft findings

### A1. Skeleton render (P1): wrap + interval sorting + symbolic prios

```
table inet wanguard {
	set local_v4 {
		type ipv4_addr
		flags interval
		elements = { 10.0.0.0/8, 172.16.0.0/12,
			     192.168.0.0/16, 224.0.0.0/4,
			     255.255.255.255 }
	}

	set no_mark {
		type ipv4_addr
		flags interval
	}

	chain marking {
		type filter hook prerouting priority mangle; policy accept;
	}

	chain redir {
		type nat hook prerouting priority dstnat; policy accept;
	}
}
```

- Elements of interval sets render SORTED (by value) and WRAPPED
  (multi-line) when long — the skeleton lists `192.168...` first, nft
  prints `10...` first. The CLI's `current_elements` parse is
  whitespace-insensitive (`tr '\n' ' '` BEFORE the seds) and the diff
  sorts both sides — wrap/sort order never matters to it. The mock
  renders verbatim/single-line: same parsed surface.
- Chain decls render `priority mangle` / `priority dstnat` (symbolic),
  matching the mock's renderer.

### A2. Rules: body normalization + tag/handle shape (P2, P7)

```
	chain marking { # handle 1
		type filter hook prerouting priority mangle; policy accept;
		iifname "br-lan" ether saddr @mac_a ip daddr != @local_v4 ip daddr != @no_mark meta mark set 0x0000012c comment "wg:a:m300" # handle 10
	}
```

- `meta mark set 300` normalizes to **`0x0000012c`** (8 hex digits).
  The CLI never compares bodies — the tag fully determines the rule —
  so normalization is invisible to the diff (by design, issue #13).
- The tag/handle surface the CLI parses is byte-exact:
  `comment "wg:..." ... # handle <n>` — the sh sed and the future ucode
  `match()` both key on this.
- Handles are a shared monotonic counter (skeleton chains 1,2; first
  rule 10; re-add after delete → fresh 12, no reuse). The CLI captures
  handles, never assumes values; mock's global `next` from 1 is fine.

### A3. rc contract + atomicity (P4–P6, P9–P11, P13)

| probe | result |
|---|---|
| dup `add element` | rc 0 (silent ok) |
| batch: valid line + `delete element` of absent member | rc 1, `Error: element does not exist` (+ `file:line:col` caret line), **nothing applied** (atomic) |
| `list set` absent | stderr `Error: No such file or directory`, rc 1 |
| `-c -f` good batch | rc 0, **nothing applied** |
| `-c -f` bad batch | rc 1, nothing applied |
| cyrillic set name | `-c` rc 1 AND `-f` rc 1, `syntax error, unexpected junk` |
| `delete table` then `list table` | rc 0; then `Error: No such file or directory`, rc 1 |

All match the mock's rc behavior. Real nft error output is multi-line
with caret underlines; the mock prints one line — cosmetic divergence,
the CLI only gates on rc and forwards stderr to the operator.

### A4. `delete set` with live referencing rules (P8) — REAL nft refuses

`flush set mac_a` + `delete set mac_a` while a chain rule still
references `@mac_a`:

```
/dev/stdin:2:26-30: Error: Could not process rule: Resource busy
```

rc 1, the set SURVIVES. The CLI can never hit this: inside one atomic
batch it deletes orphan RULES (by tag) before flushing/deleting orphan
SETS, so by the time the delete executes no rule references the set.
The mock does not model rule→set references at all — unreachable from
the CLI's batch order. **Implication for fixtures: keep the CLI's batch
order (sets → orphan-rule deletes → rule adds → element diffs → orphan
set flush/delete); the order is load-bearing on real nft.**

## B. ip-full findings (the router's binary)

### B1. rule show: NO trailing space, hex marks, prio sort (I1–I3)

```
0:<TAB>from all lookup local<EOL>
8000:<TAB>from all fwmark 0x12c lookup 500<EOL>
8100:<TAB>from all fwmark 0x64 lookup 400<EOL>
32766:<TAB>from all lookup main<EOL>
32767:<TAB>from all lookup default<EOL>
```

- Marks render hex SHORT form (`0x12c`, not zero-padded) — exactly the
  mock's `printf '0x%x'`. Sorted by prio. **No trailing space** (the
  first v1 probe ran busybox ip, which DOES print one — see §D).
- The CLI parses prios with `sed -n 's/^[[:space:]]*\([0-9][0-9]*\):.*/\1/p'`
  and greps existence via `^[[:space:]]*$p:` — insensitive to the rest.

### B2. rule del: absent → rc 2 (I4)

`ip rule del prio 8000` for an absent rule: stderr
`RTNETLINK answers: No such file or directory`, **rc 2**. This is the
contract the reconcile loop relies on (`while ip rule del prio P` stops
on the first failure). Mock: rc 2 ✓.

### B3. routes: the trailing-space contract (I5, I6, I8, I9)

```
# route replace default dev Meta table 500 ; route show table 500
default dev Meta scope link <EOL>

# route show table 500 | grep -q 'default dev Meta '  -> rc 0
```

`ip route show table N` renders **with a trailing space** (after
`scope link` here). The CLI's idempotency check is
`grep -q "default dev $dev "` — the trailing space is REQUIRED, without
it every apply would re-replace and log `applied` forever. The v2 mock
fix renders the trailing space; the cosmetic `scope link` absence does
not affect any grep.

metric-200 fallback (I8, I9): mainline capture
`default via 172.17.0.1 dev eth0 ` (trailing space, shell word-splitting
eats it on re-pass), after `ip route replace $mainline metric 200
table 400`:

```
default via 172.17.0.1 dev eth0 metric 200 <EOL>
```

grep ` metric 200($| )` → rc 0 ✓ (on the router mainline carries
`metric 10`, rendering `metric 10 metric 200` — same match).

### B4. rc/message contract of replace/link (I7, I13–I15)

| case | ip-full 25.12.5 | mock ip | CLI impact |
|---|---|---|---|
| `route replace` unknown dev | `Cannot find device "Nope"`, rc 1 | same message, rc 1 ✓ | none (error propagates) |
| `route show table 999` | empty, rc 0 | ✓ | idempotency grep → replace |
| `route flush table N` | rc 0 | ✓ | orphan-table count |
| `ip link show` absent | `Device "Ghost" does not exist.`, **rc 1** | `Cannot find device "Ghost"`, rc 2 | none (only success/non-zero) |
| `route replace` via DOWN dev | `Error: Device for nexthop is not up.`, rc 2 | not modeled | **unreachable**: down ifaces have no l3_device, routes are skipped before any replace |

### B5. `route show table all` (I10, I11)

- The `table N` suffix lands MID-line (`...dev eth0 table 400 metric 200 `);
  main-table lines carry NO `table` suffix; local/IPv6 lines use
  non-numeric names. The CLI's orphan scan
  (`sed -n 's/.* table \([0-9][0-9]*\).*/\1/p' | sort -u`) extracts
  exactly `400 500` — position and dump order irrelevant, `sort -u`
  canonicalizes.
- Dump order is kernel-internal (400, 500, main, local, IPv6...) —
  never parsed positionally.

## C. Mock parity table (after the v2 fixes)

| surface | real (25.12.5) | mock | parsed by CLI? |
|---|---|---|---|
| rule lines trailing space | none | none | no (prio greps insensitive) |
| route lines trailing space | yes | **yes (fixed)** | **YES**: `default dev X `, ` metric 200($| )` |
| `table N` suffix position | mid-line | line end | no |
| metric double-space | normalized to single | single after `$*` join | no |
| `link show` absent rc | 1 | 2 | no (non-zero) |
| link absent message | `Device "X" does not exist.` | `Cannot find device "X"` | no |
| table-all dump order | kernel order | main + sorted | no (`sort -u`) |
| replace on down dev | rc 2 | not modeled | unreachable |
| interval elements | sorted + wrapped | verbatim single-line | no (whitespace-insensitive) |
| mark body | `0x0000012c` | verbatim decimal | no (tag diff) |
| error output shape | multi-line + caret | one line | no (rc only) |
| delete set w/ referencing rules | `Resource busy` rc 1 | allowed | unreachable (batch order) |
| handle allocation | shared counter (rules ≥ 10) | global `next` from 1 | no (captured) |

## D. busybox ip (informational — NOT the router's binary)

The bare rootfs ships busybox ip; v1 probes showed: rule lines WITH a
trailing space, `ip link show Ghost` → `ip: can't find device 'Ghost'`
rc 2, `route replace` to a down dev → `RTNETLINK answers: Network is
down` rc 2. The router (and the lab) run **ip-full** since stage #13 —
the mock models ip-full. Do not record busybox transcripts as router
parity evidence.

## E. Implications for the ucode `apply` port (phase 2)

1. Parse surfaces to reproduce with `match()`/`split()` (same semantics
   as the sh seds/greps): tag+handle from `-a list chain`; elements from
   `list set` (join lines first — real nft wraps); set names from
   `list table`; prios from `rule show`; `default dev <dev> ` and
   ` metric 200($| )` from `route show table N` (trailing space!);
   table numbers from `route show table all`.
2. External calls stay external: `nft` (list/-c/-f), `ip`, `conntrack` —
   fork reduction is not the goal on these legs (stage-2 precedent).
3. Batch ORDER is load-bearing on real nft (§A4): the port must emit the
   same section order as sh — sets → orphan-rule deletes → rule adds →
   element diffs → orphan-set flush/delete.
4. rc contracts to preserve: `nft -c` rc 1 = abort, nothing applied,
   exit 1; `ip rule del` absent rc 2 = stop the delete loop; `route
   replace` bad dev rc 1 = counted as no-change.
5. `applied` vs `in-sync` stays a literal string contract with the
   keepalive (`[ "$out" = in-sync ]`); change-count = nft batch applied
   OR rules changed OR routes changed, exactly as in sh.
