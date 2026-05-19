# kbd-hid-attrs-2026-05-07.ps1
# Get ground-truth VID/PID/Version from HidD_GetAttributes on all keyboard collections.
# This is what HID tools (mkBatteryChecker, WinMagicBattery) actually see - may differ from BTHENUM path.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\hid-attrs.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KBD HID ATTRIBUTES (ground-truth VID/PID) $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbdAttrs {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES {
        public int Size;
        public ushort VendorID, ProductID, VersionNumber;
    }
    [DllImport("hid.dll")]
    public static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES attrs);
    [DllImport("hid.dll")]
    public static extern bool HidD_GetProductString(SafeFileHandle h,
        [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder buf, int len);
    public static int LastErr() { return Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

$paths = @(
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col01#a&eaf9d13&3&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}\kbd"; name="col01"},
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"; name="col02"},
    @{path="\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col03#a&eaf9d13&3&0002#{4d1e55b2-f16f-11cf-88cb-001111000030}"; name="col03"}
)

foreach ($p in $paths) {
    L "--- $($p.name) ---"
    $h = [KbdAttrs]::CreateFile($p.path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) { L "  OPEN FAIL err=$([KbdAttrs]::LastErr())"; continue }

    $attrs = New-Object KbdAttrs+HIDD_ATTRIBUTES
    $attrs.Size = 12
    if ([KbdAttrs]::HidD_GetAttributes($h, [ref]$attrs)) {
        $vidHex = '{0:X4}' -f $attrs.VendorID
        $pidHex = '{0:X4}' -f $attrs.ProductID
        $verHex = '{0:X4}' -f $attrs.VersionNumber
        L "  VID=0x${vidHex} ($($attrs.VendorID)) PID=0x${pidHex} ($($attrs.ProductID)) Ver=0x${verHex}"
    } else {
        L "  HidD_GetAttributes FAIL err=$([KbdAttrs]::LastErr())"
    }

    $sb = New-Object System.Text.StringBuilder 256
    if ([KbdAttrs]::HidD_GetProductString($h, $sb, 512)) {
        L "  ProductString: '$($sb.ToString())'"
    } else {
        L "  ProductString: (unavailable err=$([KbdAttrs]::LastErr()))"
    }

    $h.Close()
    L ""
}

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
