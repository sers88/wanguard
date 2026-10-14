<#
deploy-whitelist.ps1 — apply the whitelist rules from config.yaml.example to the router.

config.yaml.example is the single source of truth for the `rules:` section.
The script fetches the real proxy name from the router config, substitutes it,
replaces the whole `rules:` section on the router (idempotent by design),
validates with `mihomo -t`, restarts mihomo and waits for the Hysteria2 tunnel
warmup (~1-2 min, see docs/ARCHITECTURE.md) before probing.

Usage:
  .\scripts\deploy-whitelist.ps1                          # 192.168.88.1, restart + verify
  .\scripts\deploy-whitelist.ps1 -Router 192.168.88.50
  .\scripts\deploy-whitelist.ps1 -SkipRestart             # build + validate only

Requirements: ssh/scp (OpenSSH client) with key auth to root@router.
#>
param(
    [string]$Router = "192.168.88.1",
    [string]$User = "root",
    [string]$Example = "",
    [int]$WarmupSeconds = 150,
    [switch]$SkipRestart
)

$ErrorActionPreference = "Stop"
if (-not $Example) { $Example = Join-Path $PSScriptRoot "..\config\mihomo\config.yaml.example" }
$SshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new")
$RemoteCfg = "/etc/mihomo/config.yaml"
$NewCfg = "/tmp/config.yaml.new"

function Invoke-Remote([string]$Cmd) {
    & ssh @SshOpts "$User@$Router" $Cmd
    if ($LASTEXITCODE -ne 0) { throw "remote command failed: $Cmd" }
}
function Get-RemoteOutput([string]$Cmd) {
    & ssh @SshOpts "$User@$Router" $Cmd
}

Write-Host "==> example: $Example"
if (-not (Test-Path $Example)) { throw "example not found: $Example" }

# --- 1. extract rules: section from the example (must be the last section) ---
$lines = Get-Content $Example
$ruleStart = ($lines | Select-String -Pattern '^rules:' | Select-Object -First 1).LineNumber
if (-not $ruleStart) { throw "no 'rules:' section in $Example" }
$rulesLines = $lines[($ruleStart - 1) .. ($lines.Count - 1)]
$stray = $rulesLines | Select-String -Pattern '^[A-Za-z][A-Za-z0-9_-]*:' | Where-Object { $_.Line -ne 'rules:' }
if ($stray) { throw "unsupported: top-level keys after 'rules:' in example: $($stray.Line -join ', ')" }
Write-Host ("==> rules found: {0}" -f ($rulesLines | Where-Object { $_ -match '^\s*-' }).Count)

# --- 2. real proxy name from the router ---
$proxyName = (Get-RemoteOutput 'sed -n ''/- name:/{s/.*name: *//p;q}'' /etc/mihomo/config.yaml' | Select-Object -First 1)
if (-not $proxyName) { throw "could not read proxy name from $RemoteCfg" }
Write-Host "==> proxy name: $proxyName"

# --- 3. assemble the new config: remote head (before rules:) + new rules ---
$remoteLines = Get-RemoteOutput "cat $RemoteCfg"
$remoteStart = ($remoteLines | Select-String -Pattern '^rules:' | Select-Object -First 1).LineNumber
if (-not $remoteStart) { throw "no 'rules:' section in remote config" }
$rulesText  = (($rulesLines -join "`n") -replace '<PROXY_NAME>', $proxyName).TrimEnd()
$newConfig  = (($remoteLines[0 .. ($remoteStart - 2)] -join "`n")).TrimEnd() + "`n" + $rulesText + "`n"

$tmp = Join-Path $env:TEMP "config.yaml.new"
[IO.File]::WriteAllText($tmp, $newConfig)
Write-Host "==> new config assembled: $((($newConfig -split "`n") | Select-String '^\s*-').Count) list items"

# --- 4. upload + validate with mihomo -t (old config untouched on failure) ---
& scp @SshOpts -O $tmp "${User}@${Router}:$NewCfg" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "scp failed" }
Invoke-Remote "mihomo -t -d /usr/share/mihomo -f $NewCfg >/tmp/mihomo-test.log 2>&1 || touch /tmp/mihomo-test.fail"
$verdict = Get-RemoteOutput 'test -f /tmp/mihomo-test.fail && echo FAIL || echo OK'
Invoke-Remote 'rm -f /tmp/mihomo-test.fail /tmp/mihomo-test.log' | Out-Null
if ($verdict -ne 'OK') {
    Invoke-Remote "rm -f $NewCfg"
    throw "mihomo -t FAILED, running config untouched. Details: ssh ${User}@${Router} cat /tmp/mihomo-test.log"
}
Write-Host "==> mihomo -t: OK"

if ($SkipRestart) {
    Write-Host "==> -SkipRestart: new config left at ${Router}:$NewCfg (not applied)"
    exit 0
}

# --- 5. backup, swap, restart ---
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Invoke-Remote "cp $RemoteCfg ${RemoteCfg}.bak-$stamp && mv $NewCfg $RemoteCfg && /etc/init.d/mihomo restart"
Write-Host "==> applied (backup: ${RemoteCfg}.bak-$stamp), mihomo restarting..."

# --- 6. wait for tunnel warmup, then probe a whitelisted domain ---
$probe = ($rulesText -split "`n" |
    Select-String -Pattern '^\s*- (DOMAIN(?:-SUFFIX)?),([^,]+),' |
    ForEach-Object { $_.Matches[0].Groups[2].Value } |
    Select-Object -Unique -First 5)
Write-Host ("==> warmup: waiting up to {0}s, probing: {1}" -f $WarmupSeconds, ($probe -join ', '))

Start-Sleep -Seconds 45
$deadline = (Get-Date).AddSeconds($WarmupSeconds)
$ok = $false
while ((Get-Date) -lt $deadline -and -not $ok) {
    foreach ($d in $probe) {
        $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 8 --max-redirs 0 "https://$d/" 2>$null
        if ($code -and $code -ne '000') {
            Write-Host "==> tunnel is up: https://$d/ -> HTTP $code (via proxy rules)"
            $ok = $true; break
        }
    }
    if (-not $ok) { Start-Sleep -Seconds 20; Write-Host "    tunnel not ready yet, retrying..." }
}
if (-not $ok) {
    Write-Warning "tunnel did not answer within ${WarmupSeconds}s. Check on the router: logread | grep mihomo"
    Write-Warning "rollback: ssh ${User}@${Router} `"ls -t /etc/mihomo/config.yaml.bak-* | head -1`" then cp it back and restart mihomo"
    exit 1
}
Write-Host "==> done."
