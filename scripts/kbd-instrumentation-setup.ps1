#Requires -RunAsAdministrator
# kbd-instrumentation-setup.ps1
# Sets up boot-persistent ETW autologger + enables KMDF event log so
# next-reboot diagnostics actually capture data even though MagicKbDesc.sys
# is built Release (KdPrint suppressed).
#
# What it sets up:
#   1. Autologger 'KbdInstrumentation' (boot-persistent ETW session)
#      Captures providers:
#        - Microsoft-Windows-Kernel-PnP (device-stack construction order)
#        - Microsoft-Windows-DriverFrameworks-KernelMode (KMDF IRP routing)
#        - Microsoft-Windows-Kernel-Debug-Print (any DbgPrint output)
#        - Microsoft-Windows-Bluetooth-Bthusb (BT stack events)
#      Output: C:\mm-dev-queue\kbd-instr.etl (rotates at 100 MB)
#   2. Enables Microsoft-Windows-DriverFrameworks-KernelMode/Operational
#      event log so it actually records.
#
# Idempotent. Re-running rebuilds the autologger config without errors.

$ErrorActionPreference = 'Stop'
$autologgerName = 'KbdInstrumentation'
$etlPath = 'C:\mm-dev-queue\kbd-instr.etl'

# Provider GUIDs (well-known, from manifests)
$providers = @(
    @{Name='Microsoft-Windows-Kernel-PnP';                  Guid='{9C205A39-1250-487D-ABD7-E831C6290539}'; Level=5; Keywords=0xFFFFFFFFFFFFFFFF}
    @{Name='Microsoft-Windows-DriverFrameworks-KernelMode'; Guid='{486A5C7C-11CC-46C5-9DE7-43DFE0BB57C1}'; Level=5; Keywords=0xFFFFFFFFFFFFFFFF}
    @{Name='Microsoft-Windows-Kernel-Debug-Print';          Guid='{13976D09-A327-438C-950B-7F03192815C7}'; Level=5; Keywords=0xFFFFFFFFFFFFFFFF}
    @{Name='Microsoft-Windows-Bluetooth-Bthusb';            Guid='{8a1f9517-3a8c-4a9e-a017-9f3666c5d2b3}'; Level=5; Keywords=0xFFFFFFFFFFFFFFFF}
)

Write-Host "=== KBD Instrumentation Setup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# 1. Tear down any existing config so we start clean
Write-Host "[1/3] Removing any prior autologger config '$autologgerName'..."
Remove-AutologgerConfig -Name $autologgerName -ErrorAction SilentlyContinue
& logman stop $autologgerName -ets 2>$null
& logman delete $autologgerName -ets 2>$null
# Belt-and-braces: nuke residual reg if cmdlet didn't
$alReg = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$autologgerName"
if (Test-Path $alReg) {
    Remove-Item -Path $alReg -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed stale reg key $alReg"
}

# Clean up the Data Collector Set we created earlier (different from autologger reg)
& logman delete $autologgerName 2>$null | Out-Null

# 2. Write boot-persistent autologger directly to registry (canonical format).
# This is what `New-AutologgerConfig` does under the covers, but we control
# every value rather than fight the cmdlet's parameter quirks.
Write-Host "[2/3] Writing boot-persistent autologger reg for '$autologgerName' -> $etlPath"
$alReg = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$autologgerName"
New-Item -Path $alReg -Force | Out-Null
$sessionGuid = [guid]::NewGuid().ToString('B')   # {GUID}
Set-ItemProperty -Path $alReg -Name 'Start'           -Value 1                -Type DWord
Set-ItemProperty -Path $alReg -Name 'Guid'            -Value $sessionGuid     -Type String
Set-ItemProperty -Path $alReg -Name 'FileName'        -Value $etlPath         -Type String
Set-ItemProperty -Path $alReg -Name 'FileMax'         -Value 100              -Type DWord       # MB
Set-ItemProperty -Path $alReg -Name 'BufferSize'      -Value 1024             -Type DWord       # KB
Set-ItemProperty -Path $alReg -Name 'MinimumBuffers'  -Value 32               -Type DWord
Set-ItemProperty -Path $alReg -Name 'MaximumBuffers'  -Value 64               -Type DWord
Set-ItemProperty -Path $alReg -Name 'LogFileMode'     -Value 0x10001          -Type DWord       # CIRCULAR | PREALLOCATE
Write-Host "  session GUID: $sessionGuid"

foreach ($p in $providers) {
    $pReg = Join-Path $alReg $p.Guid
    New-Item -Path $pReg -Force | Out-Null
    Set-ItemProperty -Path $pReg -Name 'Enabled'         -Value 1               -Type DWord
    Set-ItemProperty -Path $pReg -Name 'EnableLevel'     -Value $p.Level        -Type DWord
    Set-ItemProperty -Path $pReg -Name 'MatchAnyKeyword' -Value $p.Keywords     -Type QWord
    Write-Host "  + provider: $($p.Name)  $($p.Guid)"
}

# 3. Enable any KMDF/HID at-rest event logs that exist (best-effort, varies by build)
Write-Host "[3/3] Enabling at-rest event logs (best-effort)..."
$logsToTry = @(
    'Microsoft-Windows-DriverFrameworks-KernelMode/Operational',
    'Microsoft-Windows-DriverFrameworks-UserMode/Operational',
    'Microsoft-Windows-Kernel-PnP/Configuration',
    'Microsoft-Windows-Kernel-PnP/Device Configuration'
)
foreach ($ln in $logsToTry) {
    $exists = Get-WinEvent -ListLog $ln -ErrorAction SilentlyContinue
    if ($exists) {
        if (-not $exists.IsEnabled) {
            & wevtutil set-log "$ln" /enabled:true /quiet:true 2>&1 | Out-Null
            Write-Host "  enabled: $ln"
        } else {
            Write-Host "  already enabled: $ln  records=$($exists.RecordCount)"
        }
    } else {
        Write-Host "  not present on this build: $ln"
    }
}

# Verify
Write-Host ""
Write-Host "=== VERIFY ==="
$reg = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$autologgerName"
if (Test-Path $reg) {
    $cfg = Get-ItemProperty $reg
    Write-Host "Autologger reg: Start=$($cfg.Start) FileName=$($cfg.FileName)"
    Get-ChildItem $reg -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Provider: $($_.PSChildName)"
    }
} else {
    Write-Host "FAIL: autologger reg not present" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== DONE ==="
Write-Host "Autologger '$autologgerName' will start on next reboot."
Write-Host "After next boot, decode with:"
Write-Host "  Get-WinEvent -Path '$etlPath' -Oldest | Where-Object { `$_.Message -match 'MagicKbDesc|HidBth|BTHENUM.*0239' }"
exit 0
