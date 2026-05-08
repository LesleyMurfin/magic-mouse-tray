# sign.ps1 — sign MagicKbDesc.sys + .cat via mm-task-runner SIGN-FILE route.
# Runs as SYSTEM (private-key access to LocalMachine\My). Pre: build.cmd has
# staged the artifacts at C:\Windows\Temp\MagicKbDescStage\.

$ErrorActionPreference = 'Stop'
$thumb = '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'  # CN=MagicMouseFix in LocalMachine\My
$stage = 'C:\Windows\Temp\MagicKbDescStage'
$q     = 'C:\mm-dev-queue'

foreach ($f in @("$stage\MagicKbDesc.sys", "$stage\MagicKbDesc.cat")) {
    if (-not (Test-Path $f)) { throw "$f not staged — run .\build.cmd first" }
}

function Sign-One($file) {
    $nonce = 'sign-' + [guid]::NewGuid().ToString().Substring(0,8)
    Set-Content "$q\request.txt" "SIGN-FILE|$nonce|$file|$thumb" -Encoding ASCII
    Remove-Item "$q\result.txt" -Force -ErrorAction SilentlyContinue
    schtasks /run /tn MM-Dev-Cycle | Out-Null
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path "$q\result.txt") {
            $r = (Get-Content "$q\result.txt" -Raw).Trim()
            if ($r -match "\|$nonce") {
                Write-Host "  $file -> $r"
                return [int]($r -split '\|')[0]
            }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "  TIMEOUT $file" -ForegroundColor Red
    return 124
}

$rc1 = Sign-One "$stage\MagicKbDesc.sys"
$rc2 = Sign-One "$stage\MagicKbDesc.cat"

if ($rc1 -ne 0 -or $rc2 -ne 0) {
    throw "Sign failed (sys=$rc1 cat=$rc2)"
}

Write-Host ''
Get-AuthenticodeSignature "$stage\MagicKbDesc.sys" | Format-List Status,SignerCertificate
