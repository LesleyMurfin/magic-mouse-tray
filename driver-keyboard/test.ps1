# test.ps1 -- smoke test the descriptor patch landed.
# HidD_GetFeature(Col02, RID=0x47, len=2) should succeed once the
# MagicKbDesc filter is in the stack.
# Expected: *** SUCCESS *** [47 NN]   BATTERY = NN%

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Hid {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string p, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("hid.dll",     SetLastError=true)] public static extern bool HidD_GetFeature(IntPtr h, byte[] b, uint l);
}
'@

$col02 = Get-PnpDevice -Class HIDClass | Where-Object { $_.InstanceId -match 'PID&0239&Col02' -and $_.InstanceId -match '00001124' } | Select-Object -First 1
if (-not $col02) { Write-Host 'Col02 not found -- keyboard not paired/connected?' -ForegroundColor Red; exit 1 }

$key  = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{4d1e55b2-f16f-11cf-88cb-001111000030}"
$path = (Get-ChildItem $key | Where-Object { $_.PSChildName -match ($col02.InstanceId -replace '\\','#') } | Select-Object -First 1).PSChildName -replace '^##\?#','\\?\' -replace '#\{','#{'

Write-Host "path: $path"

$h = [Hid]::CreateFileW($path, 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h -eq [IntPtr]::new(-1)) {
    Write-Host "CreateFile FAILED err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" -ForegroundColor Red
    exit 1
}

$buf = New-Object byte[] 2; $buf[0] = 0x47
$ok  = [Hid]::HidD_GetFeature($h, $buf, 2)
$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
[Hid]::CloseHandle($h) | Out-Null

if ($ok) {
    Write-Host ("*** SUCCESS *** [{0:X2} {1:X2}]   BATTERY = {1}%" -f $buf[0], $buf[1]) -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED ok=$ok err=$err" -ForegroundColor Yellow
    if ($err -eq 1)  { Write-Host '  err=1 = ERROR_INVALID_FUNCTION (descriptor patch not applied -- check stack via .\restart-device.ps1)' }
    if ($err -eq 87) { Write-Host '  err=87 = ERROR_INVALID_PARAMETER (buffer size mismatch?)' }
    exit 1
}
