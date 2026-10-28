# wanguard architecture

## 1. Components

| Component | Role |
|---|---|
| netifd / `ip rule` | policy routing: table selection by fwmark |
| nftables (`table inet wanguard`) | per-source-MAC packet marking |
| mihomo | proxy-group interception (TUN), whitelist → Hysteria2, rest → DIRECT |
| dnsmasq | DHCP for all clients (+ static leases for stable naming) |
| wanguard (CLI) | group membership management (`/etc/config/wanguard` → nft) |
| luci-app-wanguard | web UI over the same UCI |
| wan-watch | main-egress health check (main group read from UCI
  `globals.main_group`, default `a`): 3 dead rounds → `ifup <main-iface>`;
  while the tunnel re-dials, main passively rides the backup default
  (higher metric); 300 s cooldown; `DRYRUN=1` for testing |
| AP mesh | wireless access points, L2 bridge only, no NAT/DHCP |

## 2. Routing: named groups × arbitrary interfaces (issue #13)

Source-MAC selection is done by nftables. `/usr/share/wanguard/wanguard.nft`
is only the **skeleton**: the table, static sets and empty chains. Everything
else — the `mac_<group>` sets, marking/redirect rules, ip rules, routing
tables and fallback routes — is rendered by **`wanguard apply`** from
`/etc/config/wanguard` (idempotent diff, no flush windows).

```
table inet wanguard {                       # skeleton (wanguard.nft)
    set local_v4 { … }    # local/multicast/broadcast — a NAMED set
    set no_mark  { … }    # admin exclusions (from UCI globals.no_mark)
    chain marking  { type filter hook prerouting priority -150; … }   # empty
    chain redirect { type filter hook prerouting priority -100; … }   # empty
}
```

**Why a named set instead of `define`**: a `define` is only expanded inside
`nft -f` files; dynamically added rules (`nft add rule`) never see it. The
semantics are the same — the generator emits `ip daddr != @local_v4`.

Every generated rule carries a tag-comment `wg:<group>:m<mark>` (marking) /
`wg:<group>:r<port>` (redirect). The tag fully identifies the rule body, so
the diff compares tags only and does not depend on nft output normalization
(marks rendered as 0x… etc.).

**Mark/table/prio allocation** is deterministic, driven by sorting group
names (`config group '<name>'`, type direct|proxy):

| Type | fwmark | table | ip rule prio |
|---|---|---|---|
| `proxy` (max 1 — mihomo redir-port and TUN are singletons) | **300** | **500** | 8000 |
| `direct`, alphabetically: 1st, 2nd, 3rd… | 100, 200, 400, 500… (300 skipped) | 400, 401, 402… (≤99 groups) | 8100, 8101, 8102… |

Migration from the legacy scheme (a=100/400, b=200/401, c=300/500) is
zero-cost: today's marks are reproduced by the generator as a special case.

**The LOCAL_V4 exclusion is mandatory** (now the `@local_v4` set in the
skeleton). Without it, a marked client's traffic to the router itself breaks
(dnsmasq DNS, DHCP renewal, SSH, LuCI): packets go into the TUN instead of
local delivery → "internet completely gone". Post-mortem in the issue #5
discussion. `no_mark` holds operational per-IP exceptions (e.g. admin or
management hosts during experiments), populated from UCI `globals.no_mark`.

**A fw4 zone for the TUN is mandatory.** The `Meta` interface belongs to no
OpenWrt firewall zone: fw4's base `forward` chain has `policy drop`, and
`forward_lan` only knows `accept_to_wan`/`accept_to_lan`. Without the zone,
ALL forwarded UDP of the proxy group (br-lan→Meta) is rejected with ICMP
port-unreachable: an online game hangs at matchmaking (its UDP ranges
5000-5500/7100-7300), peer-to-peer VPN apps fall back to relays instead of
direct connections, QUIC dies. TCP was unaffected — it is DNAT'ed into
`redir-port :7892` and traverses INPUT, which is why the defect never showed
during acceptance (all tests were TCP-only). Post-mortem of the 2026-10-07
game-traffic incident: zero packets on Meta while TCP was alive + an ICMP
storm on br-lan. Fix: fw4 zone `proxy` (device Meta, input ACCEPT, forward
REJECT) + forwarding `lan→proxy`; the zone references the device by name, so
it survives `Meta` being recreated on mihomo restarts. A firewall config
backup from before the fix lives on the router (`firewall.bak-<date>`).

Mark→table decoupling and fallback routes are generated too (`wanguard
apply`); UCI `/etc/config/network` is no longer needed for this (legacy
`config rule`/`route` sections are removed manually after #13 acceptance —
until then they coexist harmlessly: apply installs identical rules):

```
ip rule: prio 8000: fwmark 300 lookup 500     # proxy group → mihomo
         prio 8100+: fwmark 100/200/… lookup 400/401/…   # direct groups
```

Tables (one per group, generated):

```
table 500: default dev Meta scope link        # proxy → mihomo (UDP), when TUN is alive
table 400+: default dev <group l3_device>     # direct → its own interface
each:       default <main-default> metric 200 # fallback: target unreachable → directly
main:       default …                         # all "unmarked" + the router itself
```

**Proxy group data plane (final, working):**
- **TCP** → nft redirect → mihomo `redir-port: 7892` (the same ingress class
  as mixed-port — proven to work). The sniffer extracts SNI, so domain rules
  and Telegram IP-CIDRs work as usual. TCP is NOT marked (see the
  `meta l4proto != tcp` rule in marking): after DNAT-to-local a marked packet
  would policy-route into the TUN (post-mortem in issue #5).
- **UDP/rest** → fwmark 300 → table 500 → TUN `Meta` (forward br-lan→Meta is
  permitted by the fw4 zone `proxy` — mandatory, see above; without it the
  group's UDP dies in `handle_reject`).
- TCP-into-TUN does NOT work on this box: SYN passes forward with oif Meta
  but never reaches the TUN fd, the kernel RSTs the client. Diagnosed with
  double tcpdump + nft trace (post-mortem in issue #5). Hence TCP via
  redirect.

**Fail-safety by construction:**
- MAC not in any set → main → internet works.
- nft table wiped → no marks, no redirect → main → internet works
  (keepalive rebuilds from the skeleton in ≤10 s).
- A direct group's interface dies → its route is missing → the group's
  packets fall to `metric 200` (main-default) → internet works; when the
  interface returns, keepalive reinstalls the route.
- mihomo stopped → redirect has no listener: proxy-group TCP gets RST
  (fail-close, immediately visible); UDP falls to `metric 200` → direct.
  TODO: fail-open for TCP, if ever wanted — a separate decision (issue #5).

## 3. mihomo: manual interception (implemented)

Stage 0 (obsolete): `tun.auto-route: true`, `tun.auto-redirect: true` —
mihomo installed ip rules 9000–9002 itself and captured ALL forwarded
traffic. Not viable for multi-WAN: direct groups can't bypass the proxy.

Current state (see `config/mihomo/config.yaml.example`):

```yaml
mixed-port: 7890      # manual HTTP/SOCKS proxy (debugging, special cases)
redir-port: 7892      # nft redirect of the proxy group lands here
tun:
  enable: true
  stack: gvisor
  auto-route: false        # routing is done by ip rule fwmark 300 (wanguard)
  auto-redirect: false     # global interception forbidden
  auto-detect-interface: true   # mihomo's own egress follows the default WAN
```

Nuances:
- mihomo's DIRECT traffic is re-originated from itself — the client's source
  IP cannot be preserved ⇒ per-client WAN selection is only possible in the
  kernel BEFORE mihomo. That is the whole reason for the fwmark scheme.
- `Meta` is recreated on every mihomo restart ⇒ the `default dev Meta` route
  in table 500 is reinstated by the `wanguard-keepalive` loop (procd service
  `wanguard`, START=99): every 10 s it runs `wanguard apply`, which restores
  everything — the nft table from the skeleton, sets, rules, ip rules and
  routes. Verified: after `/etc/init.d/mihomo restart` the route comes back
  on its own.
- After a mihomo restart the Hysteria2 tunnel does not come up instantly.
  For the first ~1–2 minutes proxied connections are dropped: logread fills
  with `dial ... error: authentication failed, status code: 404`, clients
  see TLS breaks. It heals by itself. **Wait a couple of minutes before
  testing or diagnosing** — otherwise warmup is easy to mistake for breakage.
- DNS: clients query the router's dnsmasq (excluded via LOCAL_V4) and get
  **real IPs** — by design: the sniffer gets the domain from TLS SNI/QUIC,
  Telegram is caught by IP-CIDR. Downside: the ISP can poison DNS for
  blocked domains — then only SNI-based domain rules help (enough for
  HTTPS). A client with a hardcoded external DNS (8.8.8.8) lands in the TUN
  → `dns-hijack any:53` catches it.
- The mihomo API (`:9090`) runs without a secret; apply config changes by
  **restarting** the service (`/etc/init.d/mihomo restart`), not PUT /configs
  (it returns 400).

## 4. Boot order

0. `firewall` (fw4) — zone `proxy` by device name `Meta` + forwarding
   `lan→proxy`. Order relative to mihomo does not matter: until `Meta`
   exists, the zone rules simply don't match. Direct-group interfaces must
   be in fw4 zones (wan/lan/…) — wanguard warns but does NOT configure zones.
1. `network` — interfaces, main default. (Legacy `config rule`/`route`
   sections until cleanup — a harmless duplicate.)
2. `mihomo` (procd, late start) — brings up TUN `Meta`, listens on 7890/7892.
3. `wanguard` (procd, START=99, daemon `wanguard-keepalive`) — at boot
   installs the nft table skeleton (if missing), runs `wanguard apply`
   (sets + rules + ip rules + all group tables from UCI) and then repeats
   apply every 10 s: self-healing after mihomo restarts, nft wipes and full
   reboots.
4. `wan-watch` (procd, START=99) — active main-egress health check:
   pings 77.88.8.8/8.8.8.8 via the main group's device (UCI
   `globals.main_group` → `<group>.iface` → its l3_device, re-resolved
   every round), 3 consecutive failures → `ifup <main-iface>` (bounce);
   while the tunnel re-dials, main passively rides the backup default
   (higher metric). Runtime-only netifd actions — no state of its own;
   rollback = reboot or `stop/disable` of the service.

Debug tool: `/usr/bin/wanguard-testmark MAC [sec] [set]` — temporary marking
with self-removal; ignores SIGHUP, run detached:
`setsid wanguard-testmark aa:bb:.. 60 </dev/null >/tmp/tm.log 2>&1 &`
(nohup does not exist on BusyBox). After every window verify
`nft list set inet wanguard mac_c`.

## 5. Config: /etc/config/wanguard

The single source of truth for groups and membership. Read/written uniformly
by `wanguard` (CLI) and luci-app-wanguard; the whole data plane is rendered
by `wanguard apply` (idempotent diff: nft sets and rules by tags, ip rules,
tables).

```
config globals 'globals'
        option redir_port '7892'      # mihomo TCP-redirect (proxy group)
        list no_mark '192.0.2.10'     # never mark/redirect these

config group 'a'                      # name = [A-Za-z0-9_], referenced by members
        option type 'direct'          # direct → netifd interface
        option iface 'vpn'

config group 'c'
        option type 'proxy'           # proxy → mihomo (max 1 group)

config member 'm_001122334455'        # section = m_<mac-without-colons>
        option name 'desktop-eth'
        option mac '00:11:22:33:44:55'
        option group 'c'
```

CLI (`/usr/bin/wanguard`, template: `router/etc.config.wanguard.example`):

```
wanguard list                       members + UCI↔nft drift status
wanguard grouplist                  groups: type/iface/mark/table/device/members
wanguard devices                    LAN clients: mac/ip/name/online (board data)
wanguard add <mac> <group> [name]   register + apply
wanguard move <mac> <group>         change group + apply
wanguard remove <mac>               delete + apply
wanguard apply                      full UCI -> nft + ip rules + tables sync
wanguard groupadd <name> <iface|proxy>   create group + apply
wanguard groupset <name> <iface|proxy>   change group target + apply
wanguard groupdel <name>                 delete empty group + apply
```

Properties and constraints:
- Mark/table/prio allocation is deterministic (see §2); adding a group that
  sorts before existing ones shifts their marks — the transition is
  fail-safe: a packet with a stale mark and no rule falls to main, keepalive
  fixes rules/routes within ≤10 s.
- Group names cannot be renamed (name = UCI section id): groupadd → move →
  groupdel.
- Exactly one proxy group (validated in CLI and LuCI; a second one in UCI is
  ignored with a warning).
- An interface outside fw4 zones: apply warns but does not configure zones
  (forwarding would be dropped — the game-incident class of failure).
- Members referencing a non-existent group are ignored by the renderer;
  `list` warns (fail-safe: main table).
- MACs are normalized (colons, lowercase) — hyphens/dots/bare hex accepted.
- Every mutation applies the diff immediately (no flush windows); before
  applying, a command batch passes `nft -c`.
- Drift self-heals: the keepalive daemon runs `wanguard apply` every 10 s;
  the init script does the same at boot → membership survives mihomo
  restarts, nft table wipes and full reboots.
- `wanguard list` shows DRIFT when UCI and nft diverge (exit 1).
- CLI↔keepalive races are safe: both sides do an idempotent diff.
- **luci-app-wanguard** — a third client of the same UCI: a JS view
  (Network → WAN Guard), two modes behind a "Board / Table" switch.
  **Board**: columns = direct groups alphabetically, proxy, Unclassified;
  cards = clients (name/MAC/IP/online). Dropping a card applies the move
  silently (uci.save → uci.apply; this LuCI version auto-confirms the
  rollback window ~1 s in — no modal needed); on error — a toast and a
  board rebuild from re-read UCI (the card "bounces back"). Tapping a card
  opens a "Move to" menu (touch/keyboard fallback; HTML5 DnD does not work
  on iOS, period). DRIFT makes the board read-only. A 15 s poll re-reads UCI
  + `wanguard devices` — CLI edits show up by themselves.
  **Table**: groups grid, devices grid, adding from `/tmp/dhcp.leases`,
  in-sync/DRIFT indicator; Save & Apply commits UCI and runs `wanguard
  apply` via rpcd file-exec (ACL in acl.d). The browser never touches nft
  directly — only UCI + CLI apply. Online status and Unclassified come from
  `wanguard devices` (leases + ARP: static IPs are visible; the ACL was not
  extended — no router-side data). Files: `luci-app-wanguard/` (view +
  menu.d + acl.d), install via `scripts/deploy-luci.ps1` (clears LuCI
  caches, restarts rpcd).
- #13 rollback: the pre-deploy snapshot made by `deploy-wanguard.ps1` lands
  in `/root/rollback/<date>/` (files + ruleset + ip rule + routes);
  procedure — see the private repo's plan, stage 8.

## 6. MTU/MSS

| Path | MTU | MSS clamp |
|---|---|---|
| PPTP (nomppe) | ~1436 | yes |
| PPPoE | 1492 | yes |
| TUN Meta | 9000 (internal) | n/a |

## 7. What we deliberately do NOT do

- mwan3 — not needed: groups are hard-bound, switching is deliberate.
- Channel bonding/balancing — flows don't get faster, complexity is high.
- Auto-failover for direct groups is done by `wand-tick` (#6), main-egress
  monitoring by `wan-watch` (#18); both exist by owner's decision after the
  incidents of 2026-10-12/14. The per-group fallback route (`metric 200`)
  is still generated as before.
- fw4 zone setup for new interfaces — manually by the owner (wanguard only
  warns).
- **No second runtime: the core is ucode, the POSIX sh core is retired**
  (issue #29 verdict: YES, 2026-10-25; staged migration #30 finished —
  stages v1.0.5 tick / v1.0.6 wan-flush / v1.0.7 apply / v1.0.8 CLI
  CRUD / **v1.0.9 test-suite port + sh retirement, the closing stage**).
  `/usr/bin/wanguard` is a single ucode CLI (`docs/spike-ucode/wand.uc`):
  wand-tick / wan-flush / apply / all 16 subcommands are native; external
  calls stay external by design (`curl` probe: uclient.so cannot
  SO_BINDTODEVICE; `nft`/`ip`/`conntrack`: fork reduction was never the
  goal on those legs — the tick is 4 external children vs 54 in sh).
  The former 939-line sh core stays in the repo (`router/wanguard`) only
  as the lab's differential test reference — it is NOT in the package.
  **Rollback = reinstall the previous feed tag's apk** (single mechanism,
  same UCI/state; since v1.0.9 there is no in-package sh companion to
  fall back to). Contract surfaces are frozen:
  `docs/spike-ucode/00-CLI-CONTRACT.md` + golden byte fixtures
  (`stage5/contract-gate.sh`); evidence: `docs/spike-ucode/VERDICT.md`
  and the stage1–stage5 notes.
