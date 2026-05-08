# kbd-magickbdesc-restart-device-2026-05-08.ps1
# Force PnP re-enumeration of the keyboard so newly-installed drivers/filters
# bind. Uses mm-task-runner RESTART-DEVICE route (SYSTEM scheduler).

param(
    [string]$InstanceId = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000'
)

$q = 'C:\mm-dev-queue'
$nonce = 'restart-' + [guid]::NewGuid().ToString().Substring(0,8)
Set-Content "$q\request.txt" "RESTART-DEVICE|$nonce|$InstanceId" -Encoding ASCII
Remove-Item "$q\result.txt" -Force -ErrorAction SilentlyContinue
schtasks /run /tn MM-Dev-Cycle | Out-Null

$d = (Get-Date).AddMinutes(2)
while ((Get-Date) -lt $d) {
    if (Test-Path "$q\result.txt") {
        $r = (Get-Content "$q\result.txt" -Raw).Trim()
        if ($r -match "\|$nonce") { Write-Host "[restart] result: $r"; break }
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ''
Write-Host '=== restart log ==='
Get-Content "$q\restart-$nonce.log" -ErrorAction SilentlyContinue

Start-Sleep -Seconds 3

Write-Host ''
Write-Host '=== driver stack after restart ==='
Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Data

Write-Host ''
Write-Host '=== INF in use ==='
Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_DriverDesc' | Select-Object KeyName,Data | Format-Table -AutoSize
