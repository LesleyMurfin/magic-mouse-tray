# postpatch-probe-all-2026-05-08.ps1
# Full battery-read probe across all three Apple HID devices post-patch.
# Tests both HidD_GetFeature and HidD_GetInputReport with battery-relevant RIDs
# on every collection. Outputs structured JSON + human summary.
#
# Goal: determine if the unified GetFeature(rid) call shape works for
#       v1 mouse, v3 mouse, and Apple keyboard simultaneously after the patch.
#
# Run as Administrator.

$ErrorActionPreference = 'Continue'

$OutDir  = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-08-postpatch'
$OutTxt  = Join-Path $OutDir 'probe-all.txt'
$OutJson = Join-Path $OutDir 'probe-all.json'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }

L "=== POSTPATCH PROBE ALL $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L ""

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    L "ERROR: Must run as Administrator. Right-click PowerShell -> Run as administrator."
    $log | Set-Content -Path $OutTxt -Encoding UTF8
    exit 1
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class Probe {
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
    [DllImport("hid.dll")]
    public static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES attrs);
    [DllImport("hid.dll")]
    public static extern bool HidD_GetProductString(SafeFileHandle h,
        [MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder buf, int len);

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES { public int Size; public ushort VID, PID, Ver; }

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

# Apple device profiles to probe.
$DEVICES = @(
    @{ Name = "v1 Magic Mouse";    VidPattern = "VID&000205AC"; PidPattern = "PID&030D"; ExpectedRids = @(0x47) },
    @{ Name = "v3 Magic Mouse";    VidPattern = "VID&0001004C"; PidPattern = "PID&0323"; ExpectedRids = @(0x90, 0x47) },
    @{ Name = "Apple Keyboard";    VidPattern = "VID&000205AC"; PidPattern = "PID&0239"; ExpectedRids = @(0x47) }
)

# RIDs to try across all collections (battery-relevant + a couple controls).
$TEST_RIDS = @(0x47, 0x90, 0x09, 0x12)

$GENERIC_READ = [Convert]::ToUInt32("80000000", 16)
$GENERIC_RW   = [Convert]::ToUInt32("C0000000", 16)
$HID_GUID     = "{4d1e55b2-f16f-11cf-88cb-001111000030}"

# Build all candidate paths from registry (covers col01/col02/col03).
function Find-DevicePaths($vidPat, $pidPat) {
    $paths = @()
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\HID' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "$vidPat" -and $_.Name -match "$pidPat" -and $_.Name -match 'Col\d\d' } |
        ForEach-Object {
            $parts = $_.Name -split '\\'
            $enum = $parts[-2].ToLower()
            $inst = $parts[-1].ToLower()
            $col = if ($enum -match 'col(\d\d)') { "col$($matches[1])" } else { 'col??' }
            $paths += [PSCustomObject]@{
                Col = $col
                Path = "\\?\hid#$enum#$inst#$HID_GUID"
            }
        }
    return $paths | Sort-Object Col
}

$results = @()

foreach ($dev in $DEVICES) {
    L "================================================================"
    L "DEVICE: $($dev.Name)  ($($dev.VidPattern), $($dev.PidPattern))"
    L "================================================================"

    $paths = Find-DevicePaths $dev.VidPattern $dev.PidPattern
    if ($paths.Count -eq 0) {
        L "  NOT PRESENT (not enumerated by Windows)"
        L ""
        $results += [PSCustomObject]@{ Device = $dev.Name; Status = "absent"; Collections = @() }
        continue
    }

    $devResult = [PSCustomObject]@{
        Device = $dev.Name
        Status = "present"
        Collections = @()
    }

    foreach ($p in $paths) {
        L "  --- $($p.Col) ---"
        L "    Path: $($p.Path)"

        $h = [Probe]::CreateFile($p.Path, $GENERIC_RW, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
        $accessMode = "GENERIC_RW"
        if ($h.IsInvalid) {
            $h = [Probe]::CreateFile($p.Path, $GENERIC_READ, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
            $accessMode = "GENERIC_READ"
        }
        if ($h.IsInvalid) {
            $h = [Probe]::CreateFile($p.Path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
            $accessMode = "access=0"
        }
        if ($h.IsInvalid) {
            L "    OPEN FAIL err=$([Probe]::LastErr())"
            continue
        }
        L "    Open OK ($accessMode)"

        # Attributes
        $attrs = New-Object Probe+HIDD_ATTRIBUTES; $attrs.Size = 12
        [Probe]::HidD_GetAttributes($h, [ref]$attrs) | Out-Null

        $sb = New-Object System.Text.StringBuilder 256
        [Probe]::HidD_GetProductString($h, $sb, 512) | Out-Null

        # Caps
        $pp = [IntPtr]::Zero
        [Probe]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
        $caps = New-Object Probe+HIDP_CAPS
        [Probe]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
        [Probe]::HidD_FreePreparsedData($pp) | Out-Null

        L "    Attrs: VID=0x$('{0:X4}' -f $attrs.VID) PID=0x$('{0:X4}' -f $attrs.PID) Ver=0x$('{0:X4}' -f $attrs.Ver) Product='$($sb.ToString())'"
        L "    Caps:  InputLen=$($caps.InputReportByteLength) FeatLen=$($caps.FeatureReportByteLength) UP=0x$('{0:X4}' -f $caps.UsagePage) U=0x$('{0:X4}' -f $caps.Usage)"

        $colResult = [PSCustomObject]@{
            Collection = $p.Col
            AccessMode = $accessMode
            InputLen   = $caps.InputReportByteLength
            FeatLen    = $caps.FeatureReportByteLength
            UsagePage  = ('0x{0:X4}' -f $caps.UsagePage)
            Usage      = ('0x{0:X4}' -f $caps.Usage)
            FeatureReads = @()
            InputReads   = @()
        }

        # Battery byte position depends on the report layout:
        #   RID=0x47 (standard HID Feature, UP=0x06 BatteryStrength)  -> buf[1]
        #   RID=0x90 (Apple vendor TLC, UP=0xFF00)                    -> buf[2]
        #   anything else: unknown — show both for inspection
        function Get-BatteryByte([byte]$rid, [byte[]]$buf) {
            switch ($rid) {
                0x47    { return $buf[1] }
                0x90    { return $buf[2] }
                default { return $null }
            }
        }

        # Try GetFeature with each RID.
        foreach ($rid in $TEST_RIDS) {
            $bufLen = [Math]::Max($caps.FeatureReportByteLength, 8)
            $buf = New-Object byte[] $bufLen; $buf[0] = [byte]$rid
            $ok = [Probe]::HidD_GetFeature($h, $buf, $bufLen)
            $err = [Probe]::LastErr()
            if ($ok) {
                $hex = ($buf[0..([Math]::Min($bufLen-1, 7))] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                $batteryByte = Get-BatteryByte $rid $buf
                $batteryStr = if ($null -ne $batteryByte) { "battery=$batteryByte%" } else { "buf[1]=$($buf[1]) buf[2]=$($buf[2])" }
                L "    *** GetFeature  RID=0x$('{0:X2}' -f $rid) OK  buf=[$hex]  $batteryStr ***"
                $colResult.FeatureReads += [PSCustomObject]@{ Rid = ('0x{0:X2}' -f $rid); Ok = $true; Buf = $hex; Battery = $batteryByte; Buf1 = $buf[1]; Buf2 = $buf[2] }
            } else {
                L "    GetFeature  RID=0x$('{0:X2}' -f $rid) MISS err=$err"
                $colResult.FeatureReads += [PSCustomObject]@{ Rid = ('0x{0:X2}' -f $rid); Ok = $false; Err = $err }
            }
        }

        # Try GetInputReport with each RID.
        foreach ($rid in $TEST_RIDS) {
            $bufLen = [Math]::Max($caps.InputReportByteLength, 8)
            $buf = New-Object byte[] $bufLen; $buf[0] = [byte]$rid
            $ok = [Probe]::HidD_GetInputReport($h, $buf, $bufLen)
            $err = [Probe]::LastErr()
            if ($ok) {
                $hex = ($buf[0..([Math]::Min($bufLen-1, 7))] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
                $batteryByte = Get-BatteryByte $rid $buf
                $batteryStr = if ($null -ne $batteryByte) { "battery=$batteryByte%" } else { "buf[1]=$($buf[1]) buf[2]=$($buf[2])" }
                L "    *** GetInput    RID=0x$('{0:X2}' -f $rid) OK  buf=[$hex]  $batteryStr ***"
                $colResult.InputReads += [PSCustomObject]@{ Rid = ('0x{0:X2}' -f $rid); Ok = $true; Buf = $hex; Battery = $batteryByte; Buf1 = $buf[1]; Buf2 = $buf[2] }
            } else {
                $colResult.InputReads += [PSCustomObject]@{ Rid = ('0x{0:X2}' -f $rid); Ok = $false; Err = $err }
            }
        }

        $h.Close()
        $devResult.Collections += $colResult
        L ""
    }
    $results += $devResult
}

# Summary table.
L "================================================================"
L "SUMMARY"
L "================================================================"
foreach ($r in $results) {
    if ($r.Status -ne "present") {
        L "$($r.Device): ABSENT"
        continue
    }
    foreach ($c in $r.Collections) {
        $hits = @()
        foreach ($f in $c.FeatureReads) { if ($f.Ok) { $hits += "GetFeature RID=$($f.Rid) battery=$($f.Battery)" } }
        foreach ($i in $c.InputReads)   { if ($i.Ok) { $hits += "GetInput RID=$($i.Rid) battery=$($i.Battery)" } }
        if ($hits.Count -gt 0) {
            L "$($r.Device) $($c.Collection): $($hits -join '  |  ')"
        } else {
            L "$($r.Device) $($c.Collection): no battery read worked"
        }
    }
}
L ""
L "Saved: $OutTxt"
L "Saved: $OutJson"

$log | Set-Content -Path $OutTxt -Encoding UTF8
$results | ConvertTo-Json -Depth 8 | Set-Content -Path $OutJson -Encoding UTF8
