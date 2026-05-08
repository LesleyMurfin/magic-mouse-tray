# install.ps1 — pnputil /add-driver via mm-task-runner INSTALL-DRIVER route.
# Runs as SYSTEM (admin PnP rights). Pre: sign.ps1 has signed the staged files.

param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$inf = 'C:\Windows\Temp\MagicKbDescStage\MagicKbDesc.inf'
$q   = 'C:\mm-dev-queue'

if ($Uninstall) {
    $nonce = 'uninst-' + [guid]::NewGuid().ToString().Substring(0,8)
    $rx = pnputil /enum-drivers | Select-String -Pattern 'MagicKbDesc' -Context 0,3 | Select-Object -First 1
    if (-not $rx) { Write-Host 'MagicKbDesc not installed.'; return }
    $oem = ($rx.Context.PostContext | Where-Object { $_ -match 'oem\d+\.inf' } | Select-Object -First 1) -replace '.*?(oem\d+\.inf).*', '$1'
    if (-not $oem) { Write-Host 'Could not parse oemNN.inf'; return }
    Write-Host "Uninstalling $oem ..."
    Set-Content "$q\request.txt" "UNINSTALL-DRIVER|$nonce|$oem" -Encoding ASCII
    Remove-Item "$q\result.txt" -Force -ErrorAction SilentlyContinue
    schtasks /run /tn MM-Dev-Cycle | Out-Null
    $d = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $d) {
        if (Test-Path "$q\result.txt") {
            $r = (Get-Content "$q\result.txt" -Raw).Trim()
            if ($r -match "\|$nonce") { Write-Host "[uninstall] $r"; return }
        }
        Start-Sleep -Milliseconds 500
    }
    return
}

if (-not (Test-Path $inf)) { throw "$inf missing — run .\sign.ps1 first" }

$nonce = 'install-' + [guid]::NewGuid().ToString().Substring(0,8)
Set-Content "$q\request.txt" "INSTALL-DRIVER|$nonce|$inf" -Encoding ASCII
Remove-Item "$q\result.txt" -Force -ErrorAction SilentlyContinue
schtasks /run /tn MM-Dev-Cycle | Out-Null

$d = (Get-Date).AddMinutes(2)
while ((Get-Date) -lt $d) {
    if (Test-Path "$q\result.txt") {
        $r = (Get-Content "$q\result.txt" -Raw).Trim()
        if ($r -match "\|$nonce") { Write-Host "[install] $r"; break }
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ''
Get-Content "$q\install-$nonce.log" -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'After this, run .\restart-device.ps1 (or toggle BT off/on) to bind the new filter.'
