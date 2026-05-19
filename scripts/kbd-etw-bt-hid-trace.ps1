# kbd-etw-bt-hid-trace-2026-05-08.ps1
#
# Capture an ETW trace of Microsoft-Windows-Bluetooth-HID and related HID
# providers around a fresh keyboard reconnect, so we can see the EXACT
# L2CAP PDU bytes Windows sends/receives. Mirrors what the Mac BT Debug
# Profile + PacketLogger would give us, but on Windows.
#
# Why we want this: the Mac capture proved macOS sends Set Protocol +
# vendor Set Report on connect, then a 60s Get Report poll. We want to
# verify what Windows sends in the same situation:
#   - Does Windows send Set Protocol? (almost certainly yes, via HID class)
#   - Does Windows send the vendor Set Report? (probably no — that's the gap)
#   - Does Windows even attempt Get Report? (probably no)
#
# Run as Administrator. Produces an .etl in $env:TEMP that you decode with
# tracerpt or open in Windows Performance Analyzer.

$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'kbd-etw-bt-hid-trace.txt'
$Etl = Join-Path $env:TEMP "kbd-etw-bt-hid-$(Get-Date -Format 'yyyyMMdd-HHmmss').etl"
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }

L "=== KB ETW BT-HID TRACE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L "Output ETL: $Etl"
L ""

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    L "FATAL: must run as Administrator (logman + ETW need elevation)."
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}

# Provider GUIDs (Windows 10/11 in-box):
#   Microsoft-Windows-Bluetooth-MTPEnum         {ABF4E1E7-3DCE-4F84-B7E0-1A1F0B4F5BBE}  (mostly MTP)
#   Microsoft-Windows-Bluetooth-Bthport         {DCBC1C4B-3D43-4C8A-9A3D-7F6F50D9A8BD}
#   Microsoft-Windows-Bluetooth-Profile-HFP     {4DBFE5D0-DDB0-4DA1-A1AB-1FC1B3A5F045}
#   Microsoft-Windows-Bluetooth-BthLEPrepairing {E1FE2A8E-...} (LE only, not us)
#   Microsoft-Windows-HID-PnP                   {25EAD90E-3855-4951-9F0D-46E3F8D7C9E6}
#   Microsoft-Windows-HID                       {30E1D284-5D88-459C-83FD-6345B39B19EC}
#   Microsoft-Windows-Bluetooth-HID-Profile     {6FE5C1B2-...} (may not exist on all builds)
# Use logman with provider names where possible (Windows resolves GUIDs).

$session = "kbd-bt-hid-probe"

L "Stopping any prior session named '$session' (ignore errors)..."
logman stop $session -ets 2>&1 | Out-Null
logman delete $session -ets 2>&1 | Out-Null

L "Starting trace..."
$startCmd = @(
    'start', $session,
    '-o', $Etl,
    '-p', 'Microsoft-Windows-Bluetooth-Bthport', '0xffffffffffffffff', '0xff',
    '-p', 'Microsoft-Windows-HID-PnP',          '0xffffffffffffffff', '0xff',
    '-p', 'Microsoft-Windows-HID',              '0xffffffffffffffff', '0xff',
    '-ets'
)
$startOut = & logman @startCmd 2>&1
L ($startOut -join "`n")

if ($LASTEXITCODE -ne 0) {
    L "FATAL: logman start failed. Some providers may not exist on this build."
    L "Try removing -p flags one at a time to find which is missing."
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}

L ""
L "*** TRACE RUNNING. ***"
L "Now do this in another window or by hand:"
L "  1. Disable Bluetooth on the keyboard (slide switch, or remove battery)."
L "  2. Wait ~5 seconds."
L "  3. Re-enable / power-on the keyboard so it reconnects."
L "  4. Type a few keys to wake it fully."
L ""
L "Holding 90 seconds to capture the connect handshake AND the first 60s"
L "battery poll cycle..."
L ""
Start-Sleep -Seconds 90

L "Stopping trace..."
logman stop $session -ets 2>&1 | Out-Null

L ""
L "Trace saved: $Etl"
L ""
L "To decode to text:"
L "  tracerpt `"$Etl`" -o `"${Etl}.csv`" -of CSV"
L "Or open in Windows Performance Analyzer (wpa.exe) for an interactive view."
L ""
L "What to look for:"
L "  * 'SET_PROTOCOL' or 'SetProtocol' on connect      (Windows should send)"
L "  * 'SET_REPORT' for RID 0x09 on connect            (probably MISSING — the gap)"
L "  * 'GET_REPORT' for RID 0x47 within 60-90s         (probably MISSING)"
L "  * Any L2CAP HID Control PDU hex dumps             (compare to macOS [0x41, 0x47])"
L ""

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE — log: $Out ==="
