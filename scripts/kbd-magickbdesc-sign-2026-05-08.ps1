# kbd-magickbdesc-sign-2026-05-08.ps1
# Sign MagicKbDesc.sys + .cat via mm-task-runner SIGN-FILE route (SYSTEM context
# has private-key access to the M12 CN=MagicMouseFix cert in LocalMachine\My).
#
# Pre: kbd-magickbdesc-postbuild-*.cmd has produced the staged .sys + .cat at
#      C:\Windows\Temp\MagicKbDescStage\.

$thumb='16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'
$stage='C:\Windows\Temp\MagicKbDescStage'
$q='C:\mm-dev-queue'

function Sign-One($f){
  $n='sign-'+[guid]::NewGuid().ToString().Substring(0,8)
  Set-Content "$q\request.txt" "SIGN-FILE|$n|$f|$thumb" -Encoding ASCII
  Remove-Item "$q\result.txt" -Force -ErrorAction SilentlyContinue
  schtasks /run /tn MM-Dev-Cycle | Out-Null
  $d=(Get-Date).AddMinutes(2)
  while((Get-Date) -lt $d){
    if(Test-Path "$q\result.txt"){
      $r=(Get-Content "$q\result.txt" -Raw).Trim()
      if($r -match "\|$n"){ Write-Host "  $f -> $r"; return [int]($r -split '\|')[0] }
    }
    Start-Sleep -Milliseconds 500
  }
  Write-Host "  TIMEOUT $f" -ForegroundColor Red
  return 124
}

Write-Host '=== signing MagicKbDesc.sys ==='
$rc1 = Sign-One "$stage\MagicKbDesc.sys"
Write-Host '=== signing MagicKbDesc.cat ==='
$rc2 = Sign-One "$stage\MagicKbDesc.cat"

if ($rc1 -ne 0 -or $rc2 -ne 0) {
    Write-Host "Sign failed (sys=$rc1 cat=$rc2)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== Authenticode signature on .sys ==='
Get-AuthenticodeSignature "$stage\MagicKbDesc.sys" | Format-List Status,SignerCertificate,TimeStamperCertificate
