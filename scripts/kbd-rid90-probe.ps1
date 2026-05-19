# kbd-rid90-probe-2026-05-07.ps1
# Try HidD_GetInputReport with RID=0x90 (3-byte) on col02 - same pattern as Magic Mouse.
# Also try every RID 0x01-0xFF with 3-byte buffer to find any live report.
# ONE call per RID - no retries.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\rid90-probe.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KBD RID=0x90 / ALL-RID PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbdRid90 {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] buf, int len);
    public static int LastErr() { return Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

$col02 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"
$GENERIC_READ  = [Convert]::ToUInt32("80000000", 16)
$GENERIC_RW    = [Convert]::ToUInt32("C0000000", 16)

foreach ($entry in @(
    @{access=$GENERIC_READ; name="GENERIC_READ"},
    @{access=$GENERIC_RW;   name="GENERIC_READ|WRITE"}
)) {
    L "--- $($entry.name) ---"
    $h = [KbdRid90]::CreateFile($col02, $entry.access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) { L "  OPEN FAIL err=$([KbdRid90]::LastErr())"; continue }

    # First: try RID=0x90 with 3-byte buffer (Magic Mouse pattern)
    L "  Trying RID=0x90 (3-byte, mouse pattern)..."
    $buf = New-Object byte[] 3
    $buf[0] = 0x90
    $ok = [KbdRid90]::HidD_GetInputReport($h, $buf, 3)
    $err = [KbdRid90]::LastErr()
    if ($ok) {
        $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        L "  *** HIT RID=0x90: [$hex]  buf[1]=$($buf[1])  buf[2]=$($buf[2]) ***"
    } else {
        $errName = switch($err) { 87{'INVALID_PARAM'} 1{'INVALID_FUNC'} 5{'ACCESS_DENIED'} 1167{'NOT_CONNECTED'} default{''} }
        L "  MISS RID=0x90 err=$err $errName"
    }

    # Second: scan all RIDs that return anything other than err=87/1
    L "  Scanning all RIDs 0x01-0xFF (3-byte buffer)..."
    $hits = @()
    for ($rid = 1; $rid -le 255; $rid++) {
        $b = New-Object byte[] 3
        $b[0] = [byte]$rid
        $ok2 = [KbdRid90]::HidD_GetInputReport($h, $b, 3)
        $e2 = [KbdRid90]::LastErr()
        if ($ok2) {
            $ridHex = '{0:X2}' -f $rid
            $hex2 = ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $hits += "  *** HIT RID=0x${ridHex}: [$hex2]  buf[1]=$($b[1])  buf[2]=$($b[2]) ***"
        } elseif ($e2 -ne 87 -and $e2 -ne 1) {
            $ridHex = '{0:X2}' -f $rid
            $hits += "  Interesting RID=0x${ridHex} err=$e2"
        }
    }
    if ($hits.Count -eq 0) {
        L "  All RIDs returned err=87 or err=1 (device likely does not support GET_REPORT)"
    } else {
        foreach ($hit in $hits) { L $hit }
    }

    $h.Close()
    L ""
}

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
