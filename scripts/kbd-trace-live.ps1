#Requires -RunAsAdministrator
# kbd-trace-live.ps1
# Starts a LIVE ETW trace capturing KMDF framework events + Kernel-PnP +
# Bluetooth, runs for $DurationSec, decodes the resulting ETL with tracefmt.
#
# Captures WDF callback invocations — including EvtIoInternalDeviceControl
# in our MagicKbDesc filter — REGARDLESS of whether the driver emits any
# KdPrint output. This is the diagnostic that answers:
#   "Did our filter ever receive IOCTL_HID_GET_REPORT_DESCRIPTOR?"
#
# Usage:
#   kbd-trace-live.ps1 -DurationSec 60
# During the run, BT-toggle the keyboard or unpair/repair to force fresh
# enumeration. Output: C:\mm-dev-queue\kbd-trace-live.etl + .txt

param(
    [int]$DurationSec = 60
)

$sessionName = 'KbdLiveTrace'
$etl = 'C:\mm-dev-queue\kbd-trace-live.etl'
$txt = 'C:\mm-dev-queue\kbd-trace-live.txt'
$tracelog = 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\tracelog.exe'
$tracefmt = 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\tracefmt.exe'

# Provider GUIDs. tracelog -flag is uint32, so we cap keywords at 0xFFFFFFFF.
# (For full 64-bit keywords use logman/Add-EtwTraceProvider or a -guid file.)
$providers = @(
    @{Name='Microsoft-Windows-DriverFrameworks-KernelMode'; Guid='{486A5C7C-11CC-46C5-9DE7-43DFE0BB57C1}'; Level=5; Keywords='0xFFFFFFFF'}
    @{Name='Microsoft-Windows-Kernel-PnP';                  Guid='{9C205A39-1250-487D-ABD7-E831C6290539}'; Level=5; Keywords='0xFFFFFFFF'}
    @{Name='Microsoft-Windows-Kernel-Debug-Print';          Guid='{13976D09-A327-438C-950B-7F03192815C7}'; Level=5; Keywords='0xFFFFFFFF'}
    @{Name='Microsoft-Windows-Bluetooth-Bthusb';            Guid='{8a1f9517-3a8c-4a9e-a017-9f3666c5d2b3}'; Level=5; Keywords='0xFFFFFFFF'}
)

Write-Host "=== KBD LIVE TRACE  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  duration=${DurationSec}s ==="

# Use logman (which handled this set of providers cleanly in the autologger setup)
# Stop any prior session
& logman stop $sessionName -ets 2>$null | Out-Null
& logman delete $sessionName -ets 2>$null | Out-Null

# Create live ETW session with first provider
$first = $providers[0]
$createArgs = @(
    'create', 'trace', $sessionName,
    '-ow', '-o', $etl,
    '-bs', '1024',
    '-nb', '32', '64',
    '-mode', 'Sequential',
    '-max', '100',
    '-p', $first.Guid, $first.Keywords, $first.Level,
    '-ets'
)
Write-Host "logman $($createArgs -join ' ')"
& logman @createArgs
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: logman create exit=$LASTEXITCODE" -ForegroundColor Red; exit $LASTEXITCODE }

# Add remaining providers
foreach ($p in $providers[1..($providers.Count-1)]) {
    & logman update trace $sessionName -p $p.Guid $p.Keywords $p.Level -ets | Out-Null
    Write-Host "  + $($p.Name)  exit=$LASTEXITCODE"
}

Write-Host ""
Write-Host "Trace running for ${DurationSec} seconds. NOW: BT-toggle or unpair/repair the keyboard."
Write-Host "  Settings -> Bluetooth -> off, wait 5s, on   — or — unpair + re-pair the kb"
Write-Host ""

Start-Sleep -Seconds $DurationSec

Write-Host "Stopping session..."
& logman stop $sessionName -ets | Out-Null
& logman delete $sessionName -ets 2>$null | Out-Null

# Wait briefly for ETL to flush to disk
Start-Sleep -Seconds 2

if (Test-Path $etl) {
    $sz = (Get-Item $etl).Length
    Write-Host "ETL written: $etl  ($sz bytes)"

    Write-Host "Decoding via tracefmt -> $txt"
    & $tracefmt -o $txt -displayonly $etl 2>&1 | Out-Null

    if (Test-Path $txt) {
        $hits = (Get-Content $txt -ErrorAction SilentlyContinue | Select-String 'MagicKbDesc|BTHENUM.*0239|HidBth|EvtIoInternalDeviceControl|GET_REPORT_DESCRIPTOR' | Measure-Object).Count
        Write-Host "Decoded text size: $((Get-Item $txt).Length) bytes  filter-relevant lines: $hits"
        if ($hits -gt 0) {
            Write-Host ""
            Write-Host "=== Filter-relevant lines (first 30) ==="
            Get-Content $txt | Select-String 'MagicKbDesc|BTHENUM.*0239|HidBth|EvtIoInternalDeviceControl|GET_REPORT_DESCRIPTOR' | Select-Object -First 30 | ForEach-Object { Write-Host $_.Line }
        }
    } else {
        Write-Host "tracefmt produced no output file (likely needs WDF TMF for full decode)" -ForegroundColor Yellow
    }
} else {
    Write-Host "FAIL: ETL not produced" -ForegroundColor Red
    exit 2
}
exit 0
