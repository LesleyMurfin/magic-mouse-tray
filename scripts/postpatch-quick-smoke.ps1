# postpatch-quick-smoke-2026-05-08.ps1
# 30-second smoke test: does HidD_GetFeature(0x47) work on keyboard col02 after MagicKbDesc filter?
# Run as Administrator. If this passes, run postpatch-probe-all-2026-05-08.ps1 for the full matrix.
#
# Exit codes:
#   0 = battery read OK (filter is bound and working)
#   1 = filter not bound or device not present
#   2 = call returned but value out of range (firmware quirk)

$ErrorActionPreference = 'Stop'

function L([string]$m) { Write-Host $m }

L "=== POSTPATCH QUICK SMOKE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    L "ERROR: Must run as Administrator."
    exit 1
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class Smoke {
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
'@

$GENERIC_RW = [Convert]::ToUInt32("C0000000", 16)

# Find keyboard col02 path dynamically — 2-level (no recursion) so we don't
# accidentally grab sub-subkeys like "Device Parameters" instead of the instance.
$enumKey = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match 'VID&000205AC.*PID&0239.*Col02' } |
    Select-Object -First 1

if (-not $enumKey) {
    L "FAIL: keyboard col02 enum subkey not found (PID 0x0239 not present)"
    exit 1
}

$instKey = Get-ChildItem $enumKey.PSPath -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $instKey) {
    L "FAIL: no instance subkey under $($enumKey.PSChildName)"
    exit 1
}

$enum = $enumKey.PSChildName.ToLower()
$inst = $instKey.PSChildName.ToLower()
$path = "\\?\hid#$enum#$inst#{4d1e55b2-f16f-11cf-88cb-001111000030}"
L "Enum: $($enumKey.PSChildName)"
L "Inst: $($instKey.PSChildName)"
L "Path: $path"

$h = [Smoke]::CreateFile($path, $GENERIC_RW, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h.IsInvalid) {
    L "FAIL: CreateFile err=$([Smoke]::LastErr())"
    exit 1
}

$pp = [IntPtr]::Zero
[Smoke]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
$caps = New-Object Smoke+HIDP_CAPS
[Smoke]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
[Smoke]::HidD_FreePreparsedData($pp) | Out-Null
L "Caps: InputLen=$($caps.InputReportByteLength) FeatLen=$($caps.FeatureReportByteLength)"

if ($caps.FeatureReportByteLength -eq 0) {
    L "FAIL: FeatLen=0 -> filter NOT bound (or filter does not expose Feature 0x47)"
    $h.Close()
    exit 1
}

$len = [Math]::Max($caps.FeatureReportByteLength, 2)
$buf = New-Object byte[] $len
$buf[0] = 0x47

$ok = [Smoke]::HidD_GetFeature($h, $buf, $len)
$err = [Smoke]::LastErr()
$h.Close()

if (-not $ok) {
    L "FAIL: HidD_GetFeature err=$err"
    exit 1
}

$hex = ($buf[0..([Math]::Min($len-1, 7))] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
L "Buffer: [$hex]"

if ($buf[0] -ne 0x47) {
    L "WARN: RID echo mismatch (got 0x$('{0:X2}' -f $buf[0]))"
    exit 2
}

$pct = $buf[1]
if ($pct -lt 0 -or $pct -gt 100) {
    L "WARN: Battery value out of 0..100 range: $pct"
    exit 2
}

L ""
L "=== PASS: keyboard battery = $pct% ==="
L "Filter is bound. Run postpatch-probe-all-2026-05-08.ps1 for full device matrix."
exit 0
