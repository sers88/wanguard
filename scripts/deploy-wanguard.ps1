<#
deploy-wanguard.ps1 — install/update the wanguard tooling on the router (issue #7).

Installs: /usr/bin/wanguard (CLI), /usr/bin/wanguard-keepalive,
/etc/init.d/wanguard, /usr/share/wanguard/wanguard.nft.
Creates /etc/config/wanguard from router/etc.config.wanguard.example ONLY if
absent (the live UCI config is the source of truth and is never overwritten).
Restarts the wanguard service and verifies with `wanguard list`.

Usage:
  .\scripts\deploy-wanguard.ps1                 # 192.168.1.1
  .\scripts\deploy-wanguard.ps1 -Router 192.168.1.50
  .\scripts\deploy-wanguard.ps1 -NoRestart      # install files only

Requirements: ssh/scp (OpenSSH client) with key auth to root@router.
#>
param(
    [string]$Router = "192.168.1.1",
    [string]$User = "root",
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"
$Root = Join-Path $PSScriptRoot ".."
$SshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new")

$Files = @(
    @{ Src = "$Root\router\wanguard";                 Dst = "/usr/bin/wanguard";          Mode = "755" },
    @{ Src = "$Root\router\wanguard-keepalive";       Dst = "/usr/bin/wanguard-keepalive"; Mode = "755" },
    @{ Src = "$Root\router\wanguard.nft";             Dst = "/usr/share/wanguard/wanguard.nft"; Mode = "644" },
    @{ Src = "$Root\router\init.d\wanguard";          Dst = "/etc/init.d/wanguard";       Mode = "755" },
    @{ Src = "$Root\router\etc.config.wanguard.example"; Dst = "/usr/share/wanguard/etc.config.wanguard.example"; Mode = "644" }
)

function Invoke-Remote([string]$Cmd) {
    & ssh @SshOpts "$User@$Router" $Cmd
    if ($LASTEXITCODE -ne 0) { throw "remote command failed: $Cmd" }
}

# rollback savepoint (issue #13): snapshot current files + live state on the
# router before anything is overwritten -> /root/rollback/<timestamp>/
Write-Host "==> savepoint: snapshot current router state"
$stamp = (& ssh @SshOpts "$User@$Router" "date +%Y%m%d-%H%M%S")
if ($LASTEXITCODE -ne 0) { throw "ssh failed" }
$stamp = $stamp.Trim()
Invoke-Remote ("mkdir -p /root/rollback/{0} && cp -a /usr/bin/wanguard /usr/bin/wanguard-keepalive /usr/share/wanguard/wanguard.nft /etc/init.d/wanguard /etc/config/wanguard /etc/config/network /root/rollback/{0}/ && nft list ruleset > /root/rollback/{0}/ruleset.nft && ip rule show > /root/rollback/{0}/ip-rule.txt && ip route show table all > /root/rollback/{0}/routes.txt && echo SAVEPOINT-OK" -f $stamp) | ForEach-Object {
    if ($_ -match "SAVEPOINT-OK") { Write-Host ("==> savepoint stored: /root/rollback/" + $stamp) }
}

foreach ($f in $Files) {
    if (-not (Test-Path $f.Src)) { throw "missing: $($f.Src)" }
    Write-Host ("==> upload {0}" -f (Split-Path $f.Src -Leaf))
    & scp @SshOpts -O $f.Src "${User}@${Router}:/tmp/wanguard-deploy.tmp" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $($f.Src)" }
    Invoke-Remote ("mv /tmp/wanguard-deploy.tmp {0} && sed -i 's/`r`$//' {0} && chmod {1} {0}" -f $f.Dst, $f.Mode)
}

# live UCI config: create only if absent
Invoke-Remote "test -f /etc/config/wanguard && echo HAVE || cp /usr/share/wanguard/etc.config.wanguard.example /etc/config/wanguard" | ForEach-Object {
    if ($_ -match "HAVE") { Write-Host "==> /etc/config/wanguard: kept (already exists)" }
    else { Write-Host "==> /etc/config/wanguard: created from example" }
}

# add /etc/config/wanguard to sysupgrade.conf
Invoke-Remote "grep -q '^/etc/config/wanguard`$' /etc/sysupgrade.conf || echo '/etc/config/wanguard' >> /etc/sysupgrade.conf" | Out-Null
Write-Host "==> sysupgrade.conf: /etc/config/wanguard listed"

if ($NoRestart) {
    Write-Host "==> -NoRestart: service not restarted"
    exit 0
}

Invoke-Remote "/etc/init.d/wanguard restart && sleep 2 && /usr/bin/wanguard list"
Write-Host "==> done."
