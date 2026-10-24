# wanguard

**Per-device WAN routing for OpenWrt** — named groups of LAN clients (by MAC),
each group pinned to any WAN interface (direct) or to a mihomo proxy, with a
LuCI kanban board and an idempotent generator that renders the whole data plane
from a single UCI config. Move client devices between WAN uplinks: named
MAC-address groups, each bound to its own netifd interface (direct) or routed
through mihomo (proxy, single). Everything is managed from
`/etc/config/wanguard`.

## How it works

```
/etc/config/wanguard  (UCI — the single source of truth)
        │  wanguard apply   ← idempotent diff, no flush windows
        ▼
nft sets mac_<group> + marking/redirect rules (tags wg:<group>:…)
ip rules (fwmark → table)
per-group routing tables: default dev <iface> + backup default metric 200
```

- **Deterministic allocation**: proxy → fwmark 300/table 500; direct groups
  alphabetically → 100, 200, 400… / tables 400+ (300 is reserved for mihomo).
- **Self-healing**: keepalive reruns `apply` every 10s — membership survives
  mihomo restarts, nft flushes, and a full reboot.
- **Fail-safe by construction**: a client outside the sets → main table; a
  group's dead interface → fallback route; nothing can take the whole
  internet down.
- **The browser never touches nft**: LuCI edits UCI and calls `wanguard apply`.

Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (allocation, tags,
incident post-mortems, boot order).

## LuCI: kanban board

**Network → WAN Guard** — columns = groups + Unclassified, cards = clients
(name/MAC/IP/online). Drag & drop moves a device, applied instantly; tapping a
card opens a "Move to" menu (touch fallback). DRIFT switches the board to
read-only until keepalive re-syncs the state. A table view remains for bulk
edits.

## Installation

### Via the signed apk feed (the standard way)

The feed is published by CI to the
[`feed`](https://github.com/sers88/wanguard/tree/feed) branch on a `vX.Y.Z`
tag push (packages get version `X.Y.Z-r1`). The `packages.adb` index is signed
with an EC key; the public key is [`keys/wanguard.pem`](keys/wanguard.pem).

On the router (OpenWrt 24.10+/25.x, apk 3.0.x):

```sh
# 1. trust the feed key
curl -o /etc/apk/keys/wanguard.pem \
  https://raw.githubusercontent.com/sers88/wanguard/feed/keys/wanguard.pem

# 2. add the feed
echo "https://raw.githubusercontent.com/sers88/wanguard/feed/packages/x86_64/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list

# 3. install
apk update
apk add wanguard luci-app-wanguard

# 4. config (only if absent yet — apk never touches live UCI)
cp /usr/share/wanguard/etc.config.wanguard.example /etc/config/wanguard

# 5. services
/etc/init.d/wanguard enable && /etc/init.d/wanguard start
/etc/init.d/wan-watch enable && /etc/init.d/wan-watch start   # optional
```

Updates: `apk update && apk upgrade`. For files that must survive a sysupgrade,
add them to `/etc/sysupgrade.conf` (`/usr/bin/wanguard*`,
`/usr/share/wanguard/`, `/etc/init.d/wanguard`, `/etc/init.d/wan-watch`).

### Deploy scripts (development)

Requires ssh key access to the router:

```powershell
powershell .\scripts\deploy-wanguard.ps1    # CLI + keepalive + init.d + nft skeleton
powershell .\scripts\deploy-luci.ps1        # LuCI app
```

**Policy**: production updates must go through the signed feed — push a
`v*` tag, wait for CI, then `apk update && apk upgrade` on the router.
The deploy scripts are for development windows only; anything they put on
the router must be followed by a tag so the feed matches the box again
(the `wanstatus` ANCHORS column doubles as the skew canary).

## Repository layout

| Path | What it is |
|---|---|
| `router/wanguard` | CLI: list/devices/add/move/remove/group*/apply |
| `router/wanguard-keepalive` | procd daemon: apply every 10s |
| `router/wan-watch` | main-path health check (main group from UCI), `ifup` on death (#18) |
| `router/init.d/wanguard` | init script (apply at boot) |
| `router/init.d/wan-watch` | health-check init script |
| `router/wanguard.nft` | nft table skeleton |
| `router/etc.config.wanguard.example` | UCI template |
| `router/wanguard-testmark` | debug: temporary MAC marking |
| `luci-app-wanguard/` | view + menu.d + acl.d |
| `apk/build.sh` | apk package build (wanguard + luci-app-wanguard) |
| `keys/wanguard.pem` | feed signing public key |
| `scripts/deploy-*.ps1` | scp/ssh deploy to the router (development) |

## Requirements

- OpenWrt with apk (24.10+/25.x), nftables (fw4), bash-free busybox sh
- For the proxy group: mihomo with `redir-port` + TUN (a fw4 zone for TUN is
  mandatory)

## License

[MIT](LICENSE)
