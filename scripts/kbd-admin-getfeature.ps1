# kbd-admin-getfeature-2026-05-07.ps1
# MUST RUN AS ADMINISTRATOR - right-click PowerShell -> "Run as administrator"
# Tests HidD_GetFeature RID=0x47 on col01 (normally ACCESS_DENIED without admin)
# and col02/col03 with GENERIC_READ|WRITE (also needs admin for keyboard nodes).

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\admin-getfeature.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KBD ADMIN GETFEATURE PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
L "Running as admin: $isAdmin"
if (-not $isAdmin) {
    L "ERROR: Must run as Administrator. Right-click PowerShell and select Run as administrator."
    exit 1
}
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbdAdmin {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetFeature(SafeFileHandle h, byte[] buf, int len);
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

$GENERIC_READ  = [Convert]::ToUInt32("80000000", 16)
$GENERIC_WRITE = [Convert]::ToUInt32("40000000", 16)
$GENERIC_RW    = $GENERIC_READ -bor $GENERIC_WRITE

$paths = @(
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col01#a&eaf9d13&3&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}\kbd"; name="col01"},
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"; name="col02"},
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col03#a&eaf9d13&3&0002#{4d1e55b2-f16f-11cf-88cb-001111000030}"; name="col03"}
)

foreach ($p in $paths) {
    foreach ($entry in @(
        @{access=0;            name="access=0"},
        @{access=$GENERIC_READ; name="GENERIC_READ"},
        @{access=$GENERIC_RW;  name="GENERIC_READ|WRITE"}
    )) {
        L "--- $($p.name) $($entry.name) ---"
        $h = [KbdAdmin]::CreateFile($p.path, $entry.access, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        if ($h.IsInvalid) {
            $errName = switch([KbdAdmin]::LastErr()) { 5{'ACCESS_DENIED'} 32{'SHARING_VIOLATION'} default{[KbdAdmin]::LastErr()} }
            L "  OPEN FAIL: $errName"
            continue
        }

        $pp = [IntPtr]::Zero
        [KbdAdmin]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
        $caps = New-Object KbdAdmin+HIDP_CAPS
        [KbdAdmin]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
        [KbdAdmin]::HidD_FreePreparsedData($pp) | Out-Null
        L "  CAPS: InputLen=$($caps.InputReportByteLength) FeatLen=$($caps.FeatureReportByteLength)"

        # HidD_GetFeature RID=0x47
        foreach ($sz in @([Math]::Max($caps.FeatureReportByteLength,2), 2, 3, 8)) {
            $buf = New-Object byte[] $sz; $buf[0] = 0x47
            $ok = [KbdAdmin]::HidD_GetFeature($h, $buf, $sz)
            $err = [KbdAdmin]::LastErr()
            if ($ok) {
                $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                L "  *** GetFeature RID=0x47 buf[$sz] HIT: [$hex]  buf[1]=$($buf[1]) ***"
                break
            } else {
                $errName = switch($err) { 1{'INVALID_FUNC'} 87{'INVALID_PARAM'} 5{'ACCESS_DENIED'} 50{'NOT_SUPPORTED'} default{$err} }
                L "  GetFeature RID=0x47 buf[$sz] MISS: $errName"
            }
        }

        # HidD_GetInputReport RID=0x47 (one attempt)
        $buf2 = New-Object byte[] ([Math]::Max($caps.InputReportByteLength,2)); $buf2[0] = 0x47
        $ok2 = [KbdAdmin]::HidD_GetInputReport($h, $buf2, $buf2.Length)
        $err2 = [KbdAdmin]::LastErr()
        if ($ok2) {
            $hex2 = ($buf2 | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  *** GetInputReport RID=0x47 HIT: [$hex2]  buf[1]=$($buf2[1]) ***"
        } else {
            $errName2 = switch($err2) { 1{'INVALID_FUNC'} 87{'INVALID_PARAM'} 5{'ACCESS_DENIED'} 1167{'NOT_CONNECTED'} default{$err2} }
            L "  GetInputReport RID=0x47 MISS: $errName2"
        }

        $h.Close()
        L ""
    }
}

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
