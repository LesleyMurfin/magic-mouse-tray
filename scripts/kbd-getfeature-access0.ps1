# kbd-getfeature-access0-2026-05-07.ps1
# Try HidD_GetFeature RID=0x47 on col02 with access=0 (not GENERIC_READ).
# col03 probe showed access=0 succeeded where GENERIC_READ failed.
# Also try col01 with access=0 (previously ACCESS_DENIED with GENERIC_READ).

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\getfeature-access0.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KBD GETFEATURE ACCESS=0 PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbdGF {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetFeature(SafeFileHandle h, byte[] buf, int len);
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

$paths = @(
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col01#a&eaf9d13&3&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}\kbd"; name="col01"},
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"; name="col02"},
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col03#a&eaf9d13&3&0002#{4d1e55b2-f16f-11cf-88cb-001111000030}"; name="col03"}
)

foreach ($p in $paths) {
    L "--- $($p.name) access=0 ---"
    $h = [KbdGF]::CreateFile($p.path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) { L "  OPEN FAIL err=$([KbdGF]::LastErr())"; continue }

    $pp = [IntPtr]::Zero
    [KbdGF]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
    $caps = New-Object KbdGF+HIDP_CAPS
    [KbdGF]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
    [KbdGF]::HidD_FreePreparsedData($pp) | Out-Null
    L "  CAPS: InputLen=$($caps.InputReportByteLength) FeatLen=$($caps.FeatureReportByteLength)"

    # Try RID=0x47 with various buffer sizes
    foreach ($sz in @(2, 3, 4, 8, 64)) {
        $buf = New-Object byte[] $sz
        $buf[0] = 0x47
        $ok = [KbdGF]::HidD_GetFeature($h, $buf, $sz)
        $err = [KbdGF]::LastErr()
        if ($ok) {
            $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  *** HIT RID=0x47 buf[$sz]: [$hex]  buf[1]=$($buf[1]) ***"
        } else {
            $errName = switch($err) { 1{'INVALID_FUNC'} 87{'INVALID_PARAM'} 5{'ACCESS_DENIED'} default{$err} }
            L "  MISS RID=0x47 buf[$sz] err=$errName"
        }
    }

    $h.Close()
    L ""
}

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
