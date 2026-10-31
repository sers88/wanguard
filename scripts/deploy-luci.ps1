<#
deploy-luci.ps1 — install/update luci-app-wanguard on the router (issue #8,
four-page layout per issue #46).

Installs the five JS files (four views + shared core module), menu.d and
acl.d, removes the retired monolith view, clears LuCI caches and restarts
rpcd so the new menu/ACL take effect. Live /etc/config/wanguard is NOT
touched.

Usage:
  .\scripts\deploy-luci.ps1                 # 192.168.1.1
  .\scripts\deploy-luci.ps1 -Router 192.168.1.50

Requirements: ssh/scp (OpenSSH client) with key auth to root@router.
#>
param(
    [string]$Router = "192.168.1.1",
    [string]$User = "root"
)

$ErrorActionPreference = "Stop"
$Root = Join-Path $PSScriptRoot ".."
$SshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new")

$Files = @(
    @{ Src = "$Root\luci-app-wanguard\htdocs\luci-static\resources\view\wanguard\overview.js"; Dst = "/www/luci-static/resources/view/wanguard/overview.js" },
    @{ Src = "$Root\luci-app-wanguard\htdocs\luci-static\resources\view\wanguard\devices.js"; Dst = "/www/luci-static/resources/view/wanguard/devices.js" },
    @{ Src = "$Root\luci-app-wanguard\htdocs\luci-static\resources\view\wanguard\groups.js"; Dst = "/www/luci-static/resources/view/wanguard/groups.js" },
    @{ Src = "$Root\luci-app-wanguard\htdocs\luci-static\resources\view\wanguard\diagnostics.js"; Dst = "/www/luci-static/resources/view/wanguard/diagnostics.js" },
    @{ Src = "$Root\luci-app-wanguard\htdocs\luci-static\resources\wanguard\core.js"; Dst = "/www/luci-static/resources/wanguard/core.js" },
    @{ Src = "$Root\luci-app-wanguard\usr\share\luci\menu.d\luci-app-wanguard.json"; Dst = "/usr/share/luci/menu.d/luci-app-wanguard.json" },
    @{ Src = "$Root\luci-app-wanguard\usr\share\rpcd\acl.d\luci-app-wanguard.json"; Dst = "/usr/share/rpcd/acl.d/luci-app-wanguard.json" }
)

function Invoke-Remote([string]$Cmd) {
    # PS 5.1 does not escape embedded quotes for native argv: without this,
    # ssh ships the command with quotes stripped ("Parsing message data failed").
    & ssh @SshOpts "$User@$Router" ($Cmd -replace '"', '\"')
    if ($LASTEXITCODE -ne 0) { throw "remote command failed: $Cmd" }
}

foreach ($f in $Files) {
    if (-not (Test-Path $f.Src)) { throw "missing: $($f.Src)" }
    Write-Host ("==> upload {0}" -f (Split-Path $f.Src -Leaf))
    & scp @SshOpts -O $f.Src "${User}@${Router}:/tmp/wanguard-luci.tmp" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $($f.Src)" }
    $DstDir = $f.Dst -replace '/[^/]+$', ''
    Invoke-Remote ("mkdir -p {0} && mv /tmp/wanguard-luci.tmp {1} && sed -i 's/`r`$//' {1} && chmod 644 {1}" -f $DstDir, $f.Dst)
}

Write-Host "==> remove the retired monolith view (issue #46: 4 pages + core)"
Invoke-Remote "rm -f /www/luci-static/resources/view/wanguard.js"

Write-Host "==> validate JSON files"
Invoke-Remote "jsonfilter -i /usr/share/luci/menu.d/luci-app-wanguard.json >/dev/null && jsonfilter -i /usr/share/rpcd/acl.d/luci-app-wanguard.json >/dev/null && echo JSON-OK"

Write-Host "==> clear LuCI caches + restart rpcd"
Invoke-Remote "rm -f /tmp/luci-indexcache* /tmp/luci-modulecache*; /etc/init.d/rpcd restart; sleep 1"

Write-Host "==> smoke: wanguard list via ubus file exec"
# NOTE: jsonfilter on 25.12.5 mis-parses file-exec output (build quirk), so the
# smoke greps the raw ubus result instead — same end-to-end path as the board.
Invoke-Remote "ubus call file exec '{""command"":""/usr/bin/wanguard"",""params"":[""list""]}' | grep -q in-sync && echo SMOKE-OK"

Write-Host "==> done. Open: http://$Router/cgi-bin/luci -> Network -> WAN Guard"
