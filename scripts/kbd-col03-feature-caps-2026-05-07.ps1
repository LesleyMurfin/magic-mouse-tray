# kbd-col03-feature-caps-2026-05-07.ps1
# Check col03 Feature cap UsagePage/Usage/RID (what the original m1 code would have found).
# Also try GetFeature on col03 with access=0 (same as original code), not GENERIC_READ.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\col03-feature-caps.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB COL03 FEATURE CAPS $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HidCaps3 {
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
    [StructLayout(LayoutKind.Sequential, Pack=4)]
    public struct HIDP_VALUE_CAPS {
        public ushort UsagePage;
        public byte ReportID;
        public byte IsAlias;
        public ushort BitField, LinkCollection, LinkUsage, LinkUsagePage;
        public byte IsRange, IsStringRange, IsDesignatorRange, IsAbsolute, HasNull, Reserved;
        public ushort BitSize, ReportCount;
        public ushort Res1, Res2, Res3, Res4, Res5;
        public uint UnitsExp, Units;
        public int LogMin, LogMax, PhysMin, PhysMax;
        public ushort Usage, UsageMax;
        public ushort StrMin, StrMax, DesigMin, DesigMax, IdxMin, IdxMax;
    }
    [DllImport("hid.dll")]
    public static extern int HidP_GetCaps(IntPtr pp, ref HIDP_CAPS caps);
    [DllImport("hid.dll")]
    public static extern int HidP_GetValueCaps(int rtype, [In,Out] HIDP_VALUE_CAPS[] vcaps, ref ushort len, IntPtr pp);
    public static int LastErr() { return Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

$col03 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col03#a&eaf9d13&3&0002#{4d1e55b2-f16f-11cf-88cb-001111000030}"

# Try with access=0 (same as original m1 code) AND GENERIC_READ
foreach ($entry in @(@{access=[uint32]0; name="access=0"}, @{access=[Convert]::ToUInt32("80000000",16); name="GENERIC_READ"})) {
    L ""
    L "--- $($entry.name) ---"
    $h = [HidCaps3]::CreateFile($col03, $entry.access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) { L "  OPEN FAIL err=$([HidCaps3]::LastErr())"; continue }

    $pp = [IntPtr]::Zero
    [HidCaps3]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
    $caps = New-Object HidCaps3+HIDP_CAPS
    [HidCaps3]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
    L "  CAPS: FeatLen=$($caps.FeatureReportByteLength) NumFeatValCaps=$($caps.NumberFeatureValueCaps) NumFeatBtnCaps=$($caps.NumberFeatureButtonCaps)"

    if ($caps.NumberFeatureValueCaps -gt 0) {
        $vcaps = New-Object HidCaps3+HIDP_VALUE_CAPS[] $caps.NumberFeatureValueCaps
        $vlen = $caps.NumberFeatureValueCaps
        $r = [HidCaps3]::HidP_GetValueCaps(2, $vcaps, [ref]$vlen, $pp)
        $rHex = '{0:X8}' -f $r
        L "  GetValueCaps result=0x${rHex} count=$vlen"
        for ($i = 0; $i -lt $vlen; $i++) {
            $vc = $vcaps[$i]
            $upHex = '{0:04X}' -f $vc.UsagePage
            $uHex  = '{0:04X}' -f $vc.Usage
            $ridHex = '{0:02X}' -f $vc.ReportID
            L "  FeatureValueCap[$i]: UP=0x${upHex} U=0x${uHex} RID=0x${ridHex} BitSize=$($vc.BitSize) LogMax=$($vc.LogMax)"
            # Try GetFeature for this RID
            $buf = New-Object byte[] ([Math]::Max($caps.FeatureReportByteLength, 2))
            $buf[0] = $vc.ReportID
            $ok = [HidCaps3]::HidD_GetFeature($h, $buf, $buf.Length)
            $err = [HidCaps3]::LastErr()
            if ($ok) {
                $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                L "    GetFeature HIT: [$hex]  buf[1]=$($buf[1])"
            } else {
                L "    GetFeature MISS: err=$err $(switch($err){87{'INVALID_PARAM'} 1{'INVALID_FUNC'} 5{'ACCESS_DENIED'} default{''}})"
            }
        }
    }

    [HidCaps3]::HidD_FreePreparsedData($pp) | Out-Null
    $h.Close()
}

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE ==="
