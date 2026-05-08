<#
.SYNOPSIS
    Keyboard battery empirical data collection - 2026-05-07
    Three phases:
      1. Full HID descriptor dump for ALL cols of PID 0x0239 (kbd)
      2. RID sweep 0x01-0xFF (GetInputReport + GetFeature) on all kbd paths
      3. MAGICKEYBOARDRAEPDO private interface probe
    Output: .ai/test-runs/2026-05-07-kbd-battery-probe/
#>
$OutDir = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe'
if (-not (Test-Path $OutDir)) { New-Item -Path $OutDir -ItemType Directory -Force | Out-Null }

$log = @()
function L { param([string]$m) $script:log += $m; Write-Host $m }

L "=== KBD BATTERY PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# -- P/Invoke shims ----------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbdProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string fn, uint access, uint share,
        IntPtr sa, uint cd, uint fa, IntPtr t);

    [DllImport("hid.dll")] public static extern void   HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] public static extern bool   HidD_GetPreparsedData(SafeFileHandle h, out IntPtr d);
    [DllImport("hid.dll")] public static extern bool   HidD_FreePreparsedData(IntPtr d);
    [DllImport("hid.dll")] public static extern int    HidP_GetCaps(IntPtr d, ref HIDP_CAPS c);
    [DllImport("hid.dll")] public static extern int    HidP_GetValueCaps(int rt, [In,Out] VALUE_CAPS[] caps, ref ushort len, IntPtr d);
    [DllImport("hid.dll")] public static extern int    HidP_GetButtonCaps(int rt, [In,Out] BUTTON_CAPS[] caps, ref ushort len, IntPtr d);
    [DllImport("hid.dll", SetLastError=true)] public static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int l);
    [DllImport("hid.dll", SetLastError=true)] public static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] b, int l);

    [DllImport("setupapi.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr p, int f);
    [DllImport("setupapi.dll", SetLastError=true)]
    public static extern bool SetupDiEnumDeviceInterfaces(IntPtr h, IntPtr di, ref Guid g, int idx, ref SP_DID d);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr h, ref SP_DID d, IntPtr detail, int sz, out int req, IntPtr di);
    [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr h);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inLen,
        byte[] outBuf, int outLen, out int returned, IntPtr overlapped);

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDP_CAPS {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes,
            NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
            NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
            NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }
    [StructLayout(LayoutKind.Sequential, Pack=4)]
    public struct VALUE_CAPS {
        public ushort UsagePage; public byte ReportID;
        [MarshalAs(UnmanagedType.U1)] public bool IsAlias;
        public ushort BitField, LinkCollection, LinkUsage, LinkUsagePage;
        [MarshalAs(UnmanagedType.U1)] public bool IsRange, IsStringRange, IsDesignatorRange, IsAbsolute, HasNull;
        public byte Reserved;
        public ushort BitSize, ReportCount, R1, R2, R3, R4, R5;
        public uint UnitsExp, Units;
        public int LogicalMin, LogicalMax, PhysicalMin, PhysicalMax;
        public ushort UsageMin, UsageMax, StringMin, StringMax, DesigMin, DesigMax, DataIdxMin, DataIdxMax;
    }
    [StructLayout(LayoutKind.Sequential, Pack=4)]
    public struct BUTTON_CAPS {
        public ushort UsagePage; public byte ReportID;
        [MarshalAs(UnmanagedType.U1)] public bool IsAlias;
        public ushort BitField, LinkCollection, LinkUsage, LinkUsagePage;
        [MarshalAs(UnmanagedType.U1)] public bool IsRange, IsStringRange, IsDesignatorRange, IsAbsolute;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=10)] public uint[] Reserved;
        public ushort UsageMin, UsageMax, StringMin, StringMax, DesigMin, DesigMax, DataIdxMin, DataIdxMax;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DID { public int cb; public Guid g; public int f; public IntPtr r; }
}
'@ -ErrorAction Stop

# -- Enumerate all keyboard HID paths (ALL cols) -----------------------------
$hidGuid = [Guid]::Empty
[KbdProbe]::HidD_GetHidGuid([ref]$hidGuid)
$DIGCF = 0x12  # PRESENT | DEVICEINTERFACE
$devInfo = [KbdProbe]::SetupDiGetClassDevs([ref]$hidGuid, [IntPtr]::Zero, [IntPtr]::Zero, $DIGCF)

$kbdPaths = [System.Collections.Generic.List[string]]::new()
$idx = 0
while ($true) {
    $did = New-Object KbdProbe+SP_DID
    $did.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($did)
    if (-not [KbdProbe]::SetupDiEnumDeviceInterfaces($devInfo, [IntPtr]::Zero, [ref]$hidGuid, $idx, [ref]$did)) { break }
    $idx++
    $req = 0
    [KbdProbe]::SetupDiGetDeviceInterfaceDetail($devInfo, [ref]$did, [IntPtr]::Zero, 0, [ref]$req, [IntPtr]::Zero) | Out-Null
    if ($req -le 4) { continue }
    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($req)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($buf, 8)
    if ([KbdProbe]::SetupDiGetDeviceInterfaceDetail($devInfo, [ref]$did, $buf, $req, [ref]$req, [IntPtr]::Zero)) {
        $p = [System.Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]::Add($buf, 4))
        if ($p -match 'vid&000205ac_pid&0239') { $kbdPaths.Add($p) | Out-Null }
    }
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
}
[KbdProbe]::SetupDiDestroyDeviceInfoList($devInfo) | Out-Null

L ""
L "=== PHASE 1: HID DESCRIPTOR DUMP (all cols) ==="
L "Keyboard HID paths found: $($kbdPaths.Count)"

foreach ($path in $kbdPaths) {
    $col = if ($path -match '&col(\d+)#') { "col$($matches[1])" } else { "col00" }
    L ""
    L "--- $col ---"
    L "Path: $path"

    $h = [KbdProbe]::CreateFile($path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) {
        L "  OPEN FAILED: err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        continue
    }
    $pp = [IntPtr]::Zero
    if (-not [KbdProbe]::HidD_GetPreparsedData($h, [ref]$pp)) {
        L "  GetPreparsedData FAILED"
        $h.Close(); continue
    }
    $caps = New-Object KbdProbe+HIDP_CAPS
    [KbdProbe]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
    L "  TLC: UP=0x$("{0:X4}" -f $caps.UsagePage) U=0x$("{0:X4}" -f $caps.Usage)"
    L "  InputLen=$($caps.InputReportByteLength) OutputLen=$($caps.OutputReportByteLength) FeatureLen=$($caps.FeatureReportByteLength)"
    L "  InBC=$($caps.NumberInputButtonCaps) InVC=$($caps.NumberInputValueCaps) FeatBC=$($caps.NumberFeatureButtonCaps) FeatVC=$($caps.NumberFeatureValueCaps)"

    foreach ($rt in 0,1,2) {
        $rtName = @{0='Input';1='Output';2='Feature'}[$rt]
        $vc = switch($rt){0{$caps.NumberInputValueCaps}1{$caps.NumberOutputValueCaps}2{$caps.NumberFeatureValueCaps}}
        $bc = switch($rt){0{$caps.NumberInputButtonCaps}1{$caps.NumberOutputButtonCaps}2{$caps.NumberFeatureButtonCaps}}
        if ($vc -gt 0) {
            $vcaps = New-Object KbdProbe+VALUE_CAPS[] $vc
            $vlen = [uint16]$vc
            [KbdProbe]::HidP_GetValueCaps($rt, $vcaps, [ref]$vlen, $pp) | Out-Null
            for ($i = 0; $i -lt $vlen; $i++) {
                $c = $vcaps[$i]
                L "  $rtName ValueCap[$i]: RID=0x$("{0:X2}" -f $c.ReportID) UP=0x$("{0:X4}" -f $c.UsagePage) U=0x$("{0:X4}" -f $c.UsageMin) BitSize=$($c.BitSize) LogMin=$($c.LogicalMin) LogMax=$($c.LogicalMax)"
            }
        }
        if ($bc -gt 0) {
            $bcaps = New-Object KbdProbe+BUTTON_CAPS[] $bc
            $blen = [uint16]$bc
            [KbdProbe]::HidP_GetButtonCaps($rt, $bcaps, [ref]$blen, $pp) | Out-Null
            for ($i = 0; $i -lt $blen; $i++) {
                $c = $bcaps[$i]
                L "  $rtName ButtonCap[$i]: RID=0x$("{0:X2}" -f $c.ReportID) UP=0x$("{0:X4}" -f $c.UsagePage) U=0x$("{0:X4}" -f $c.UsageMin)-0x$("{0:X4}" -f $c.UsageMax)"
            }
        }
    }
    [KbdProbe]::HidD_FreePreparsedData($pp) | Out-Null
    $h.Close()
}

# -- PHASE 2: RID sweep 0x01-0xFF --------------------------------------------
L ""
L "=== PHASE 2: RID SWEEP (GetInputReport + GetFeature, 0x01-0xFF) ==="

foreach ($path in $kbdPaths) {
    $col = if ($path -match '&col(\d+)#') { "col$($matches[1])" } else { "col00" }
    L ""
    L "--- RID sweep: $col ---"

    $h = [KbdProbe]::CreateFile($path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) { L "  OPEN FAILED"; continue }

    # Determine buffer sizes from caps
    $pp = [IntPtr]::Zero
    $inLen = 64; $featLen = 64
    if ([KbdProbe]::HidD_GetPreparsedData($h, [ref]$pp)) {
        $caps = New-Object KbdProbe+HIDP_CAPS
        [KbdProbe]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
        if ($caps.InputReportByteLength   -gt 1) { $inLen   = [int]$caps.InputReportByteLength }
        if ($caps.FeatureReportByteLength -gt 1) { $featLen = [int]$caps.FeatureReportByteLength }
        [KbdProbe]::HidD_FreePreparsedData($pp) | Out-Null
    }

    $hits = @()
    for ($rid = 1; $rid -le 0xFF; $rid++) {
        # GetInputReport
        $buf = New-Object byte[] ([Math]::Max($inLen, 2))
        $buf[0] = [byte]$rid
        if ([KbdProbe]::HidD_GetInputReport($h, $buf, $buf.Length)) {
            $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  HIT GetInputReport RID=0x$("{0:X2}" -f $rid) [$hex]"
            $hits += "INPUT:RID=0x$("{0:X2}" -f $rid)"
        }
        # GetFeature
        $buf2 = New-Object byte[] ([Math]::Max($featLen, 2))
        $buf2[0] = [byte]$rid
        if ([KbdProbe]::HidD_GetFeature($h, $buf2, $buf2.Length)) {
            $hex2 = ($buf2 | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  HIT GetFeature    RID=0x$("{0:X2}" -f $rid) [$hex2]"
            $hits += "FEATURE:RID=0x$("{0:X2}" -f $rid)"
        }
    }
    if ($hits.Count -eq 0) { L "  No hits on any RID 0x01-0xFF" }
    $h.Close()
}

# -- PHASE 3: MAGICKEYBOARDRAEPDO probe --------------------------------------
L ""
L "=== PHASE 3: MAGICKEYBOARDRAEPDO INTERFACE PROBE ==="

# Find device instance
$raeInst = Get-PnpDevice 2>$null | Where-Object { $_.InstanceId -like '*MAGICKEYBOARD*' }
L "MAGICKEYBOARD instances: $($raeInst.Count)"
foreach ($dev in $raeInst) {
    L "  InstanceId: $($dev.InstanceId)  Status: $($dev.Status)"
}

# Build the file path from instance ID
# Pattern: {GUID}\MAGICKEYBOARDRAEPDO\A&...\...  - \\?\{GUID}#MAGICKEYBOARD...#{GUID}
$raeGuid = '{B28812FC-53E1-4035-9EE6-190ED0EF6025}'
foreach ($dev in $raeInst) {
    $instId  = $dev.InstanceId
    $fileId  = $instId -replace '\\','#'
    $raePath = "\\?\$fileId#$raeGuid"
    L ""
    L "Probing: $raePath"

    $h = [KbdProbe]::CreateFile($raePath, 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h.IsInvalid) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        L "  ReadWrite OPEN FAILED err=$err - trying zero access"
        $h = [KbdProbe]::CreateFile($raePath, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    }
    if ($h.IsInvalid) {
        L "  Zero-access OPEN FAILED err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        continue
    }
    L "  OPEN OK"

    # ReadFile probe (various sizes)
    foreach ($sz in 4, 8, 16, 64) {
        $buf = New-Object byte[] $sz
        try {
            $fs   = [System.IO.FileStream]::new($h, [System.IO.FileAccess]::Read, $false)
            $read = $fs.Read($buf, 0, $sz)
            if ($read -gt 0) {
                $hex = ($buf[0..($read-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                L "  ReadFile($sz) -> $read bytes: [$hex]"
            } else {
                L "  ReadFile($sz) -> 0 bytes"
            }
        } catch { L "  ReadFile($sz) exception: $_" }
        break  # one size is enough for ReadFile
    }

    # DeviceIoControl sweep - Apple private IOCTLs in range 0x22_0000 area
    # Known Apple BT IOCTL base: METHOD_BUFFERED (bits 0-1 = 0), FILE_ANY_ACCESS (bits 14-15 = 0)
    # Sweep function codes 0x800-0x840 (same range probed in Session 12 battery-everything)
    $ioBase = 0x00220000
    foreach ($fn in 0x800, 0x801, 0x802, 0x803, 0x804, 0x810, 0x820, 0x830, 0x840) {
        $code   = [uint32]($ioBase -bor ($fn -shl 2))
        $inBuf  = New-Object byte[] 4
        $outBuf = New-Object byte[] 64
        $returned = 0
        $ok = [KbdProbe]::DeviceIoControl($h, $code, $inBuf, $inBuf.Length, $outBuf, $outBuf.Length, [ref]$returned, [IntPtr]::Zero)
        if ($ok -and $returned -gt 0) {
            $hex = ($outBuf[0..($returned-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  IOCTL 0x$("{0:X8}" -f $code) fn=0x$("{0:X3}" -f $fn) -> $returned bytes: [$hex]"
        }
        # Also try HidD_GetFeature / GetInputReport on this handle with key RIDs
    }

    # Try HidD_GetInputReport and GetFeature on the RAE handle directly
    L "  HID report probe on RAE handle:"
    foreach ($rid in 0x01, 0x09, 0x27, 0x47, 0x90, 0xAA, 0xBB) {
        $buf = New-Object byte[] 64
        $buf[0] = [byte]$rid
        if ([KbdProbe]::HidD_GetFeature($h, $buf, $buf.Length)) {
            $hex = ($buf[0..7] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "    GetFeature  RID=0x$("{0:X2}" -f $rid) -> [$hex]"
        }
        $buf2 = New-Object byte[] 64
        $buf2[0] = [byte]$rid
        if ([KbdProbe]::HidD_GetInputReport($h, $buf2, $buf2.Length)) {
            $hex2 = ($buf2[0..7] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "    GetInputReport RID=0x$("{0:X2}" -f $rid) -> [$hex2]"
        }
    }
    $h.Close()
}

# -- Save output --------------------------------------------------------------
$outFile = Join-Path $OutDir 'kbd-battery-probe.txt'
$log | Set-Content $outFile -Encoding UTF8
Write-Host ""
Write-Host "DONE -> $outFile"
