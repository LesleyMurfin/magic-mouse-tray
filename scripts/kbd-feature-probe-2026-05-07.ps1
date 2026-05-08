# kbd-feature-probe-2026-05-07.ps1
# Probe HidD_GetFeature on col02, RID=0x47 for Apple Magic Keyboard battery.
# Research basis: NLM "Apple BT HID battery readers" notebook.
# SINGLE CALL ONLY. No retry loop. Will not cause BT disconnect.
# Run as admin if standard user returns err=5 (ACCESS_DENIED).

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\feature-probe.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }

L "=== KB FEATURE PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L "HidD_GetFeature on col02/col03, RID=0x47"
L ""

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class HidProbe {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetFeature(SafeFileHandle hDevice, byte[] buf, int len);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetPreparsedData(SafeFileHandle hDevice, out IntPtr ppData);

    [DllImport("hid.dll")]
    public static extern bool HidD_FreePreparsedData(IntPtr ppData);

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
    public static extern int HidP_GetCaps(IntPtr ppData, ref HIDP_CAPS caps);

    public static uint GetLastErr() { return (uint)Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

$GENERIC_READ  = [Convert]::ToUInt32("80000000", 16)
$GENERIC_WRITE = [Convert]::ToUInt32("40000000", 16)
$GENERIC_RW    = [Convert]::ToUInt32("C0000000", 16)
$FILE_SHARE_READWRITE = [uint32]3
$OPEN_EXISTING = [uint32]3

# Find col02 and col03 paths for keyboard PID&0239
$hidPaths = (Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like '*00001124*' -and
                   $_.InstanceId -like '*000205AC*' -and
                   $_.InstanceId -like '*0239*' }) |
    ForEach-Object {
        $id = $_.InstanceId
        Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters" -ErrorAction SilentlyContinue
    }

# Enumerate HID interface paths directly from SetupDi via .NET
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

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
        public uint cbSize;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
    struct SP_DEVICE_INTERFACE_DETAIL_DATA {
        public uint cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=512)]
        public string DevicePath;
    }

    public static List<string> GetHidPaths() {
        var guid = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
        var devs = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 0x12); // PRESENT|DEVICEINTERFACE
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

$allPaths = [HidEnum]::GetHidPaths()
$kbPaths = $allPaths | Where-Object {
    $_ -like '*000205AC*' -and $_ -like '*0239*'
}

L "Keyboard HID paths found: $($kbPaths.Count)"
foreach ($p in $kbPaths) { L "  $p" }
L ""

foreach ($path in $kbPaths) {
    $col = if ($path -match 'col(\d+)') { "col$($Matches[1])" } else { "col??" }
    L "--- Testing $col ---"
    L "  Path: $path"

    # Try read-only first, then read+write if GetFeature fails with ACCESS_DENIED
    foreach ($access in @($GENERIC_READ, $GENERIC_RW)) {
        $accessName = if ($access -eq $GENERIC_READ) { "GENERIC_READ" } else { "GENERIC_READ|WRITE" }
        $hDev = [HidProbe]::CreateFile($path, $access, $FILE_SHARE_READWRITE,
            [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)

        if ($hDev.IsInvalid) {
            $err = [HidProbe]::GetLastErr()
            L "  OPEN FAIL ($accessName) err=$err"
            continue
        }

        # Get caps to read FeatureReportByteLength
        $ppData = [IntPtr]::Zero
        $capsOk = [HidProbe]::HidD_GetPreparsedData($hDev, [ref]$ppData)
        $featLen = 64  # fallback
        if ($capsOk -and $ppData -ne [IntPtr]::Zero) {
            $caps = New-Object HidProbe+HIDP_CAPS
            $r = [HidProbe]::HidP_GetCaps($ppData, [ref]$caps)
            if ($r -eq 0x00110000) {
                $featLen = [Math]::Max($caps.FeatureReportByteLength, 3)
                L "  CAPS ok: InputLen=$($caps.InputReportByteLength) FeatLen=$($caps.FeatureReportByteLength) NumFeatValCaps=$($caps.NumberFeatureValueCaps)"
            }
            [HidProbe]::HidD_FreePreparsedData($ppData) | Out-Null
        }

        # Single HidD_GetFeature call - RID=0x47 at buf[0]
        $buf = New-Object byte[] $featLen
        $buf[0] = 0x47
        $ok = [HidProbe]::HidD_GetFeature($hDev, $buf, $buf.Length)
        $err = [HidProbe]::GetLastErr()
        $hDev.Close()

        if ($ok) {
            $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            L "  HIT GetFeature RID=0x47 ($accessName): [$hex]"
            L "  Battery%: buf[1]=$($buf[1]) ($(if($buf[1] -le 100){'valid'}else{'out of range'}))"
            break  # no need to try write access if read worked
        } else {
            L "  MISS GetFeature RID=0x47 ($accessName) err=$err $(switch($err){5{'ACCESS_DENIED'} 87{'INVALID_PARAM'} 1167{'NOT_CONNECTED'} 121{'TIMEOUT'} default{''}})"
            if ($err -ne 5) { break }  # only retry with write access for ACCESS_DENIED
        }
    }
    L ""
}

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
