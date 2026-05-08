# kbd-magickbdesc-install-2026-05-08.ps1
# Install MagicKbDesc.inf via mm-task-runner INSTALL-DRIVER route (admin via
# SYSTEM scheduler). Pre: kbd-magickbdesc-sign-*.ps1 must have signed the
# staged files in C:\Windows\Temp\MagicKbDescStage\.

$inf = 'C:\Windows\Temp\MagicKbDescStage\MagicKbDesc.inf'
$q   = 'C:\mm-dev-queue'

if (-not (Test-Path $inf)) { Write-Host "ERROR: $inf missing — run sign step first" -ForegroundColor Red; exit 1 }

$nonce = 'install-' + [guid]::NewGuid().ToString().Substring(0,8)
Set-Content "$q\request.txt" "INSTALL-DRIVER|$nonce|$inf" -Encoding ASCII
Remove-Item "$q\result.txt" -Force -ErrorAction SilentlyContinue
schtasks /run /tn MM-Dev-Cycle | Out-Null

$d = (Get-Date).AddMinutes(2)
while ((Get-Date) -lt $d) {
    if (Test-Path "$q\result.txt") {
        $r = (Get-Content "$q\result.txt" -Raw).Trim()
        if ($r -match "\|$nonce") { Write-Host "[install] result: $r"; break }
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ''
Write-Host '=== install log ==='
Get-Content "$q\install-$nonce.log" -ErrorAction SilentlyContinue
