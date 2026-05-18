#Requires -RunAsAdministrator
# Force MagicKbDesc to unload (old binary in memory) + reload (new binary in
# DriverStore) by disable+enable on the kb's BTHENUM instance. This triggers
# fresh device-stack tear-down/rebuild without a reboot or BT toggle.

$kbId = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&000205AC_PID&0239\9&73B8B28&0&E806884B0741_C00000000'

Write-Host "=== Pre-reload state ==="
Write-Host "Service ImagePath: $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicKbDesc' -ErrorAction SilentlyContinue).ImagePath)"
$instStatus = (Get-PnpDevice -InstanceId $kbId -ErrorAction SilentlyContinue).Status
Write-Host "Device status: $instStatus"

Write-Host ""
Write-Host "Disabling kb..."
Disable-PnpDevice -InstanceId $kbId -Confirm:$false -ErrorAction Stop
Start-Sleep -Seconds 3
Write-Host "Status after disable: $((Get-PnpDevice -InstanceId $kbId).Status)"

Write-Host ""
Write-Host "Enabling kb..."
Enable-PnpDevice -InstanceId $kbId -Confirm:$false -ErrorAction Stop
Start-Sleep -Seconds 5
Write-Host "Status after enable: $((Get-PnpDevice -InstanceId $kbId).Status)"

Write-Host ""
Write-Host "=== Post-reload state ==="
$stack = (Get-PnpDeviceProperty -InstanceId $kbId -KeyName 'DEVPKEY_Device_Stack' -ErrorAction SilentlyContinue).Data
Write-Host "Stack:"
$stack | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "Driver loaded check:"
driverquery /v /fo csv | Select-String 'MagicKbDesc' | ForEach-Object { Write-Host "  $($_.Line)" }
