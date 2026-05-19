# kbd-reconnect-battery-test-2026-05-07.ps1
# PROOF TEST: Does keyboard push RID=0x47 (battery%) on BT reconnect?
# HOW TO USE:
#   1. Run this script
#   2. When you see "WAITING - toggle keyboard OFF then ON", do it
#   3. Script reports battery% or failure

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\reconnect-battery-test.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KBD RECONNECT BATTERY PROOF TEST $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbdReconnect {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadFile(SafeFileHandle h, byte[] buf, uint n,
        IntPtr bytesRead, ref OVERLAPPED ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetOverlappedResult(SafeFileHandle h, ref OVERLAPPED ov,
        out uint transferred, bool wait);
    [DllImport("kernel32.dll")]
    public static extern IntPtr CreateEvent(IntPtr sec, bool manual, bool init, IntPtr name);
    [DllImport("kernel32.dll")]
    public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")]
    public static extern bool CancelIo(SafeFileHandle h);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential)]
    public struct OVERLAPPED {
        public UIntPtr Internal, InternalHigh;
        public uint Offset, OffsetHigh;
        public IntPtr hEvent;
    }
    public static int LastErr() { return Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

$col02 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"
$GENERIC_READ = [Convert]::ToUInt32("80000000", 16)
$FILE_FLAG_OV = [Convert]::ToUInt32("40000000", 16)
$TIMEOUT_MS   = 60000

L "Opening col02 (FILE_FLAG_OVERLAPPED) ..."
$h = [KbdReconnect]::CreateFile($col02, $GENERIC_READ, 3, [IntPtr]::Zero, 3, $FILE_FLAG_OV, [IntPtr]::Zero)
if ($h.IsInvalid) {
    L "OPEN FAIL err=$([KbdReconnect]::LastErr())"
    exit 1
}
L "Open OK."
L ""
L "=== WAITING - toggle keyboard OFF then ON (you have 60 seconds) ==="
L ""

$hEvent = [KbdReconnect]::CreateEvent([IntPtr]::Zero, $true, $false, [IntPtr]::Zero)
$buf = New-Object byte[] 64
$ov  = New-Object KbdReconnect+OVERLAPPED
$ov.hEvent = $hEvent

$ok  = [KbdReconnect]::ReadFile($h, $buf, 64, [IntPtr]::Zero, [ref]$ov)
$err = [KbdReconnect]::LastErr()

if ((-not $ok) -and ($err -ne 997)) {
    L "ReadFile immediate fail err=$err"
    [KbdReconnect]::CloseHandle($hEvent) | Out-Null
    $h.Close()
    exit 1
}

L "ReadFile pending... waiting ${TIMEOUT_MS}ms"
$wait = [KbdReconnect]::WaitForSingleObject($hEvent, $TIMEOUT_MS)

if ($wait -ne 0) {
    [KbdReconnect]::CancelIo($h) | Out-Null
    L ""
    L "RESULT: TIMEOUT - no data received in ${TIMEOUT_MS}ms"
    L "Battery push did NOT happen"
} else {
    [uint32]$transferred = 0
    [KbdReconnect]::GetOverlappedResult($h, [ref]$ov, [ref]$transferred, $false) | Out-Null
    $count = [Math]::Min([int]$transferred, 16)
    $hex = ($buf[0..($count-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    L ""
    L "RESULT: DATA RECEIVED - $transferred bytes"
    L "  Raw: [$hex]"
    if ($transferred -ge 2 -and $buf[0] -eq 0x47) {
        $pct = $buf[1]
        L "  *** BATTERY = $pct% *** (RID=0x47 confirmed)"
    } elseif ($transferred -ge 1) {
        $ridHex = '{0:X2}' -f $buf[0]
        L "  RID=0x${ridHex} (not 0x47) - unexpected report, check raw bytes above"
    }
}

[KbdReconnect]::CloseHandle($hEvent) | Out-Null
$h.Close()

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
