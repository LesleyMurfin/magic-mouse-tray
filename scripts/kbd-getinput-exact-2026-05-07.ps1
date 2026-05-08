# kbd-getinput-exact-2026-05-07.ps1
# ONE call to HidD_GetInputReport with EXACTLY InputReportByteLength=2 bytes.
# Previous probes used 3 or 64 byte buffers -> err=87 due to size mismatch.
# This is the only remaining untested GetInputReport variant.
# ONE call only. Not retried. If err=87 still -> buffer size not the issue.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\getinput-exact.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB GETINPUTREPORT EXACT-SIZE PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L "ONE call, EXACT buffer size = InputReportByteLength = 2 bytes"
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HidExact {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] buf, int len);
    [DllImport("hid.dll")]
    public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr pp);
    [DllImport("hid.dll")]
    public static extern bool HidD_FreePreparsedData(IntPtr pp);
    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS {
        public ushort Usage, UsagePage;
        public ushort InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
        public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }
    [DllImport("hid.dll")]
    public static extern int HidP_GetCaps(IntPtr pp, ref HIDP_CAPS caps);
    public static int LastErr() { return Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

$GENERIC_READ = [Convert]::ToUInt32("80000000", 16)
$GENERIC_RW   = [Convert]::ToUInt32("C0000000", 16)

$col02 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"

foreach ($access in @($GENERIC_READ, $GENERIC_RW)) {
    $modeName = if ($access -eq $GENERIC_READ) { "GENERIC_READ" } else { "GENERIC_READ|WRITE" }
    L "--- Trying $modeName ---"

    $h = [HidExact]::CreateFile($col02, $access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) {
        L "  OPEN FAIL err=$([HidExact]::LastErr())"
        continue
    }

    # Get exact InputReportByteLength
    $pp = [IntPtr]::Zero
    $caps = New-Object HidExact+HIDP_CAPS
    [HidExact]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
    [HidExact]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
    [HidExact]::HidD_FreePreparsedData($pp) | Out-Null
    $inputLen = $caps.InputReportByteLength
    L "  InputReportByteLength = $inputLen"

    # Exact buffer: inputLen bytes, buf[0] = RID 0x47
    $buf = New-Object byte[] $inputLen
    $buf[0] = 0x47

    L "  Calling HidD_GetInputReport with buf[$inputLen], buf[0]=0x47 ..."
    $ok = [HidExact]::HidD_GetInputReport($h, $buf, $buf.Length)
    $err = [HidExact]::LastErr()
    $h.Close()

    if ($ok) {
        $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        L "  HIT: [$hex]"
        $rid = '{0:X2}' -f $buf[0]; L "  RID=0x${rid}  buf[1]=$($buf[1])  battery%=$($buf[1])"
    } else {
        $errName = switch($err) { 87{'INVALID_PARAM'} 1167{'NOT_CONNECTED'} 5{'ACCESS_DENIED'} 1{'INVALID_FUNC'} default{''} }
        L "  MISS err=$err $errName"
    }
    L ""

    if ($ok) { break }
}

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
