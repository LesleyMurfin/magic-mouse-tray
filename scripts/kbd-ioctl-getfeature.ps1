# kbd-ioctl-getfeature-2026-05-07.ps1
# Use DeviceIoControl with IOCTL_HID_GET_FEATURE directly on col02 (access=0).
# HidD_GetFeature wrapper rejects when FeatLen=0; raw IOCTL bypasses that check.
# Also try IOCTL_HID_GET_INPUT_REPORT as a cross-check.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\ioctl-getfeature.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KBD IOCTL DIRECT PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbdIoctl {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DeviceIoControl(
        SafeFileHandle hDevice,
        uint dwIoControlCode,
        byte[] lpInBuffer, int nInBufferSize,
        byte[] lpOutBuffer, int nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

    public static int LastErr() { return Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

# IOCTL_HID_GET_FEATURE = CTL_CODE(FILE_DEVICE_KEYBOARD=0x0b, 100, METHOD_NEITHER=3, FILE_ANY_ACCESS=0)
# = (0x0b<<16)|(0<<14)|(100<<2)|3 = 0x000B0193
# IOCTL_HID_GET_INPUT_REPORT = CTL_CODE(0x0b, 104, METHOD_NEITHER, 0) = 0x000B01A3
$IOCTL_HID_GET_FEATURE      = [uint32]0x000B0193
$IOCTL_HID_GET_INPUT_REPORT = [uint32]0x000B01A3

$col02 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"

foreach ($access in @(0, [Convert]::ToUInt32("80000000",16))) {
    $accName = if ($access -eq 0) { "access=0" } else { "GENERIC_READ" }
    L "--- $accName ---"
    $h = [KbdIoctl]::CreateFile($col02, $access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) { L "  OPEN FAIL err=$([KbdIoctl]::LastErr())"; continue }
    L "  Open OK"

    foreach ($rid in @(0x47, 0x90, 0x01)) {
        $ridHex = '{0:X2}' -f $rid

        # IOCTL_HID_GET_FEATURE
        $inBuf  = New-Object byte[] 64; $inBuf[0]  = [byte]$rid
        $outBuf = New-Object byte[] 64; $outBuf[0] = [byte]$rid
        [uint32]$returned = 0
        $ok = [KbdIoctl]::DeviceIoControl($h, $IOCTL_HID_GET_FEATURE, $inBuf, 64, $outBuf, 64, [ref]$returned, [IntPtr]::Zero)
        $err = [KbdIoctl]::LastErr()
        if ($ok) {
            $hex = ($outBuf[0..([Math]::Min([int]$returned,15)-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  *** GET_FEATURE RID=0x${ridHex} HIT: [$hex]  buf[1]=$($outBuf[1]) ***"
        } else {
            $errName = switch($err) { 1{'INVALID_FUNC'} 87{'INVALID_PARAM'} 5{'ACCESS_DENIED'} 50{'NOT_SUPPORTED'} default{$err} }
            L "  GET_FEATURE  RID=0x${ridHex} MISS err=$errName"
        }

        # IOCTL_HID_GET_INPUT_REPORT
        $inBuf2  = New-Object byte[] 64; $inBuf2[0]  = [byte]$rid
        $outBuf2 = New-Object byte[] 64; $outBuf2[0] = [byte]$rid
        [uint32]$returned2 = 0
        $ok2 = [KbdIoctl]::DeviceIoControl($h, $IOCTL_HID_GET_INPUT_REPORT, $inBuf2, 64, $outBuf2, 64, [ref]$returned2, [IntPtr]::Zero)
        $err2 = [KbdIoctl]::LastErr()
        if ($ok2) {
            $hex2 = ($outBuf2[0..([Math]::Min([int]$returned2,15)-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  *** GET_INPUT  RID=0x${ridHex} HIT: [$hex2]  buf[1]=$($outBuf2[1]) ***"
        } else {
            $errName2 = switch($err2) { 1{'INVALID_FUNC'} 87{'INVALID_PARAM'} 5{'ACCESS_DENIED'} 50{'NOT_SUPPORTED'} default{$err2} }
            L "  GET_INPUT    RID=0x${ridHex} MISS err=$errName2"
        }
    }

    $h.Close()
    L ""
}

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
