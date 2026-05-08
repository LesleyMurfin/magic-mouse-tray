# kbd-setfeature-then-getinput-2026-05-08.ps1
#
# *** SUPERSEDED — kept as a control test ***
#
# This script was written before the macOS HCI capture revealed the actual
# wire bytes (see docs/M4-MAC-CAPTURE-FINDINGS-2026-05-08.md "Byte-exact
# findings"). The capture proved that:
#
#   - The init Set Feature uses RID 0x4A, which is NOT in the public HID
#     descriptor. Original guess was 0x09 (the only descriptor-advertised
#     Feature); WRONG.
#   - The battery is read as Feature on RID 0x47, despite the descriptor
#     declaring 0x47 as Input only.
#
# Windows HidD_* APIs validate every RID against the parsed descriptor,
# so calls referencing 0x4A (not in any collection) or 0x47-as-Feature
# (not declared Feature on col02) are rejected before reaching the wire.
# This script will therefore MISS — by design — proving the
# descriptor-validation gap.
#
# The actual Windows fix requires raw L2CAP on PSM 0x11 — see
# scripts/kbd-raw-l2cap-2026-05-08.ps1 for the working approach.
#
# Run only if you want to re-confirm the Windows-side blocker.
#
# Sequence:
#   1. Enumerate keyboard HID interfaces (col02 = battery RID 0x47 INPUT;
#      col03 = vendor RID 0x09 FEATURE — only Feature on the device).
#   2. Open col03, call HidD_SetFeature([0x09, 0x03, 0x00, 0x00], 4).
#      0x03 = the SCO Link State value macOS sends on connect.
#   3. Open col02, call HidD_GetInputReport([0x47, 0x00], 2).
#   4. If MISS (err=87), retry with payload variants 0x00, 0x01, 0x02, 0x04
#      to see if any value unlocks GET_REPORT.
#   5. As a control, also test "GetInputReport without prior SetFeature" so
#      we can compare directly to the existing kbd-getinput-exact result.
#
# Run as Administrator. Single shot per variant. Will not cause BT disconnect.
# Keyboard must be CONNECTED (not just paired) before running.
#
# Output: kbd-setfeature-then-getinput.txt next to this script.

$ErrorActionPreference = 'Stop'

$Out = Join-Path $PSScriptRoot 'kbd-setfeature-then-getinput.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }

L "=== KB SetFeature(0x09)+GetInputReport(0x47) PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L "Hypothesis: SCO Link State Set Feature is required before GetInputReport works."
L ""

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HidProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_SetFeature(SafeFileHandle h, byte[] buf, int len);
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

public static class HidEnum {
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, string Enum,
        IntPtr hwnd, uint Flags);
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr devs, IntPtr devInfo,
        ref Guid iClass, uint idx, ref SP_DEVICE_INTERFACE_DATA iface);
    [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Auto)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr devs,
        ref SP_DEVICE_INTERFACE_DATA iface,
        ref SP_DEVICE_INTERFACE_DETAIL_DATA detail,
        uint detailSize, out uint required, IntPtr devInfo);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr devs);

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA {
        public uint cbSize; public Guid InterfaceClassGuid;
        public uint Flags; public IntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
    struct SP_DEVICE_INTERFACE_DETAIL_DATA {
        public uint cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=512)]
        public string DevicePath;
    }

    public static List<string> GetHidPaths() {
        var guid = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
        var devs = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 0x12);
        var paths = new List<string>();
        if (devs == IntPtr.Zero || devs == new IntPtr(-1)) return paths;
        try {
            uint i = 0;
            while (true) {
                var iface = new SP_DEVICE_INTERFACE_DATA();
                iface.cbSize = (uint)Marshal.SizeOf(iface);
                if (!SetupDiEnumDeviceInterfaces(devs, IntPtr.Zero, ref guid, i++, ref iface)) break;
                var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                detail.cbSize = IntPtr.Size == 8 ? 8u : 6u;
                uint req;
                SetupDiGetDeviceInterfaceDetail(devs, ref iface, ref detail, 512, out req, IntPtr.Zero);
                if (!string.IsNullOrEmpty(detail.DevicePath)) paths.Add(detail.DevicePath);
            }
        } finally { SetupDiDestroyDeviceInfoList(devs); }
        return paths;
    }
}
'@ -ErrorAction Stop

$GENERIC_READ  = [Convert]::ToUInt32("80000000", 16)
$GENERIC_RW    = [Convert]::ToUInt32("C0000000", 16)
$FILE_SHARE_RW = [uint32]3
$OPEN_EXISTING = [uint32]3

# --- 1. Enumerate keyboard HID interfaces -----------------------------------

$allPaths = [HidEnum]::GetHidPaths()
$kbPaths  = $allPaths | Where-Object { $_ -like '*000205AC*' -and $_ -like '*0239*' }

$col02 = $kbPaths | Where-Object { $_ -match '&col02#' } | Select-Object -First 1
$col03 = $kbPaths | Where-Object { $_ -match '&col03#' } | Select-Object -First 1

L "Keyboard HID interfaces found: $($kbPaths.Count)"
foreach ($p in $kbPaths) { L "  $p" }
L ""

if (-not $col02 -or -not $col03) {
    L "FATAL: keyboard collections not both found (col02 present=$($null -ne $col02), col03 present=$($null -ne $col03))."
    L "       Is the keyboard CONNECTED (not just paired)?"
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}
L "Using col02: $col02"
L "Using col03: $col03"
L ""

# --- helpers ----------------------------------------------------------------

function Open-Hid([string]$path, [uint32]$access) {
    [HidProbe]::CreateFile($path, $access, $FILE_SHARE_RW, [IntPtr]::Zero,
        $OPEN_EXISTING, 0, [IntPtr]::Zero)
}

function Get-Caps([Microsoft.Win32.SafeHandles.SafeFileHandle]$h) {
    $pp = [IntPtr]::Zero
    [HidProbe]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
    $caps = New-Object HidProbe+HIDP_CAPS
    [HidProbe]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
    [HidProbe]::HidD_FreePreparsedData($pp) | Out-Null
    return $caps
}

function ErrName([int]$err) {
    switch($err){
        0    { 'OK' }
        1    { 'INVALID_FUNC' }
        5    { 'ACCESS_DENIED' }
        87   { 'INVALID_PARAM' }
        121  { 'TIMEOUT' }
        1167 { 'NOT_CONNECTED' }
        1784 { 'INVALID_USER_BUFFER' }
        default { '' }
    }
}

function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

# --- 2. CONTROL: GetInputReport(0x47) on col02 with NO prior SetFeature ----

L "--- CONTROL: GetInputReport RID=0x47 on col02 with NO init ---"
$h = Open-Hid $col02 $GENERIC_RW
if ($h.IsInvalid) {
    L "  open col02 FAIL err=$([HidProbe]::LastErr())"
} else {
    $caps    = Get-Caps $h
    $inLen   = [int]$caps.InputReportByteLength
    L "  caps: InputLen=$inLen FeatLen=$($caps.FeatureReportByteLength)"
    $buf = New-Object byte[] $inLen
    $buf[0] = 0x47
    $ok = [HidProbe]::HidD_GetInputReport($h, $buf, $buf.Length)
    $err = [HidProbe]::LastErr()
    $h.Close()
    if ($ok) {
        L "  HIT (without init): [$(Hex $buf)]  battery=$($buf[1])%"
        L "  -> Hypothesis C' is FALSE. GetInputReport works without init."
    } else {
        L "  MISS (without init): err=$err $(ErrName $err)"
        L "  -> matches the existing repo finding; proceeding to test C'."
    }
}
L ""

# --- 3. Send vendor SCO Link State Set Feature on col03 --------------------

# macOS payload observed in capture:
#   transactionType = 0x05 (Set Report), packetDataSize = 3
#   "SCO Link State: 3" -> RID 0x09, value 0x03, padded to 3 payload bytes
#   Total HID buffer (including RID at buf[0]): 4 bytes (matches MaxFeatureReportSize=4).

$scoVariants = @(0x03, 0x00, 0x01, 0x02, 0x04)

foreach ($scoVal in $scoVariants) {
    L ("--- TRIAL: SetFeature col03 [0x09 0x{0:X2} 0x00 0x00] then GetInputReport col02 ---" -f $scoVal)

    $h3 = Open-Hid $col03 $GENERIC_RW
    if ($h3.IsInvalid) {
        L "  open col03 FAIL err=$([HidProbe]::LastErr())"
        continue
    }
    $caps3   = Get-Caps $h3
    $featLen = [int]$caps3.FeatureReportByteLength
    L "  col03 caps: FeatLen=$featLen InputLen=$($caps3.InputReportByteLength)"
    if ($featLen -lt 2) { $featLen = 4 }   # safety floor; descriptor says 4

    $sf = New-Object byte[] $featLen
    $sf[0] = 0x09
    $sf[1] = [byte]$scoVal
    # remaining bytes left zero (matches Feature padding constant fields)
    L "  SetFeature send: [$(Hex $sf)]"
    $okSf  = [HidProbe]::HidD_SetFeature($h3, $sf, $sf.Length)
    $errSf = [HidProbe]::LastErr()
    if ($okSf) {
        L "  SetFeature OK"
    } else {
        L "  SetFeature MISS err=$errSf $(ErrName $errSf) -- still trying GetInputReport in case ack-not-required"
    }

    # Optional readback to confirm the device latched the value
    $rb = New-Object byte[] $featLen
    $rb[0] = 0x09
    $okRb  = [HidProbe]::HidD_GetFeature($h3, $rb, $rb.Length)
    $errRb = [HidProbe]::LastErr()
    if ($okRb) { L "  GetFeature readback: [$(Hex $rb)]" }
    else       { L "  GetFeature readback MISS err=$errRb $(ErrName $errRb)" }

    $h3.Close()

    # Now try GetInputReport on col02
    $h2 = Open-Hid $col02 $GENERIC_RW
    if ($h2.IsInvalid) {
        L "  open col02 FAIL err=$([HidProbe]::LastErr())"
        continue
    }
    $caps2 = Get-Caps $h2
    $inLen = [int]$caps2.InputReportByteLength
    $gi    = New-Object byte[] $inLen
    $gi[0] = 0x47
    L "  GetInputReport send: RID=0x47 buf=$inLen bytes"
    $okGi  = [HidProbe]::HidD_GetInputReport($h2, $gi, $gi.Length)
    $errGi = [HidProbe]::LastErr()
    $h2.Close()

    if ($okGi) {
        L "  *** HIT *** GetInputReport=[$(Hex $gi)]  battery=$($gi[1])%"
        L ("  Hypothesis C' CONFIRMED with SCO Link State = 0x{0:X2}" -f $scoVal)
        L ""
        $log | Set-Content -Path $Out -Encoding UTF8
        L "=== DONE - saved to $Out ==="
        return
    } else {
        L "  GetInputReport MISS err=$errGi $(ErrName $errGi)"
    }
    L ""

    Start-Sleep -Milliseconds 250  # let device settle between trials
}

L "All SCO Link State variants exhausted without GetInputReport success."
L "Hypothesis C' is NOT confirmed by this test."
L "Next step: investigate Hypothesis C'' (PDU encoding) via raw L2CAP on PSM 0x11,"
L "or compare an HCI capture of macOS vs Windows to see byte-level differences."
L ""

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
