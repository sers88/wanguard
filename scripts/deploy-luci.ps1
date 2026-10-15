<#
deploy-luci.ps1 — install/update luci-app-wanguard on the router (issue #8).

Installs the JS view, menu.d and acl.d, clears LuCI caches and restarts rpcd
so the new menu/ACL take effect. Live /etc/config/wanguard is NOT touched.

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
    @{ Src = "$Root\luci-app-wanguard\htdocs\luci-static\resources\view\wanguard.js"; Dst = "/www/luci-static/resources/view/wanguard.js" },
    @{ Src = "$Root\luci-app-wanguard\usr\share\luci\menu.d\luci-app-wanguard.json"; Dst = "/usr/share/luci/menu.d/luci-app-wanguard.json" },
    @{ Src = "$Root\luci-app-wanguard\usr\share\rpcd\acl.d\luci-app-wanguard.json"; Dst = "/usr/share/rpcd/acl.d/luci-app-wanguard.json" }
)

function Invoke-Remote([string]$Cmd) {
    & ssh @SshOpts "$User@$Router" $Cmd
    if ($LASTEXITCODE -ne 0) { throw "remote command failed: $Cmd" }
}

foreach ($f in $Files) {
    if (-not (Test-Path $f.Src)) { throw "missing: $($f.Src)" }
    Write-Host ("==> upload {0}" -f (Split-Path $f.Src -Leaf))
    & scp @SshOpts -O $f.Src "${User}@${Router}:/tmp/wanguard-luci.tmp" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $($f.Src)" }
    Invoke-Remote ("mv /tmp/wanguard-luci.tmp {0} && sed -i 's/`r`$//' {0} && chmod 644 {0}" -f $f.Dst)
}

Write-Host "==> validate JSON files"
Invoke-Remote "jsonfilter -i /usr/share/luci/menu.d/luci-app-wanguard.json >/dev/null && jsonfilter -i /usr/share/rpcd/acl.d/luci-app-wanguard.json >/dev/null && echo JSON-OK"

Write-Host "==> clear LuCI caches + restart rpcd"
Invoke-Remote "rm -f /tmp/luci-indexcache* /tmp/luci-modulecache*; /etc/init.d/rpcd restart; sleep 1"

Write-Host "==> smoke: wanguard list via ubus file exec"
Invoke-Remote "ubus -S call file exec '{""command"":""/usr/bin/wanguard"",""params"":[""list""]}' | jsonfilter -e ""@['stdout']"" | tail -1"

Write-Host "==> done. Open: http://$Router/cgi-bin/luci -> Network -> WAN Guard"
