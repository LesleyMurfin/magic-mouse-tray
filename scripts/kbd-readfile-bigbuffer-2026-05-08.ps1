# kbd-readfile-bigbuffer-2026-05-08.ps1
#
# The repo currently does ReadFile on col02 with the default input buffer
# queue depth (32 reports on Windows). The "silent for 120s" finding in
# KeyboardBatteryDevice.cs could be masked by that queue overflowing during
# the connect handshake — pushed reports get dropped before our app opens
# the device.
#
# This probe calls HidD_SetNumInputBuffers(handle, 512) BEFORE ReadFile so
# we don't lose any pushed RID 0x47 input reports during the warm-up window.
# Then it does an overlapped ReadFile loop for 120s and logs every report.
#
# Run as Administrator. Disconnect and reconnect the keyboard once after
# the script prints "Now reconnect the keyboard...". Keyboard must be
# paired but not necessarily currently connected.

$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'kbd-readfile-bigbuffer.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB READFILE BIG-BUFFER PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
L "HidD_SetNumInputBuffers(512), then 120s ReadFile loop on col02"
L ""

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbBig {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadFile(SafeFileHandle h, byte[] buf, uint n,
        IntPtr nRead, ref OVERLAPPED ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetOverlappedResult(SafeFileHandle h, ref OVERLAPPED ov,
        out uint xferred, bool wait);
    [DllImport("kernel32.dll")]
    public static extern IntPtr CreateEvent(IntPtr sec, bool manual, bool init, IntPtr name);
    [DllImport("kernel32.dll")]
    public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")]
    public static extern bool CancelIo(SafeFileHandle h);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_SetNumInputBuffers(SafeFileHandle h, uint num);
    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetNumInputBuffers(SafeFileHandle h, out uint num);
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

    [StructLayout(LayoutKind.Sequential)]
    public struct OVERLAPPED {
        public UIntPtr Internal, InternalHigh;
        public uint Offset, OffsetHigh;
        public IntPtr hEvent;
    }
}

public static class HidEnum2 {
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

$GENERIC_RW    = [Convert]::ToUInt32("C0000000", 16)
$FILE_SHARE_RW = [uint32]3
$OPEN_EXISTING = [uint32]3
$FILE_FLAG_OVERLAPPED = [uint32]0x40000000

$kbPaths = [HidEnum2]::GetHidPaths() | Where-Object { $_ -like '*000205AC*' -and $_ -like '*0239*' }
$col02 = $kbPaths | Where-Object { $_ -match '&col02#' } | Select-Object -First 1

if (-not $col02) {
    L "FATAL: col02 not found. Is the keyboard paired?"
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}
L "col02: $col02"

L ""
L "*** Now disconnect the keyboard and reconnect it (slide power switch off/on). ***"
L "ReadFile loop will start in 5 seconds and run for 120 seconds."
L ""
Start-Sleep -Seconds 5

$h = [KbBig]::CreateFile($col02, $GENERIC_RW, $FILE_SHARE_RW, [IntPtr]::Zero,
    $OPEN_EXISTING, $FILE_FLAG_OVERLAPPED, [IntPtr]::Zero)
if ($h.IsInvalid) {
    L "OPEN FAIL err=$([KbBig]::LastErr())"
    $log | Set-Content -Path $Out -Encoding UTF8
    return
}

# Bump input buffer queue depth from default (32) to 512.
$origCount = [uint32]0
$gotOrig = [KbBig]::HidD_GetNumInputBuffers($h, [ref]$origCount)
L "Original input buffer count: $(if ($gotOrig) { $origCount } else { 'unknown' })"
$setOk = [KbBig]::HidD_SetNumInputBuffers($h, [uint32]512)
$verifiedCount = [uint32]0
[KbBig]::HidD_GetNumInputBuffers($h, [ref]$verifiedCount) | Out-Null
L "After SetNumInputBuffers(512): $verifiedCount  (Set returned $setOk)"

# Get caps for input buffer length
$pp = [IntPtr]::Zero
[KbBig]::HidD_GetPreparsedData($h, [ref]$pp) | Out-Null
$caps = New-Object KbBig+HIDP_CAPS
[KbBig]::HidP_GetCaps($pp, [ref]$caps) | Out-Null
[KbBig]::HidD_FreePreparsedData($pp) | Out-Null
$inLen = [int]$caps.InputReportByteLength
L "InputReportByteLength: $inLen"
L ""

$ev = [KbBig]::CreateEvent([IntPtr]::Zero, $true, $false, [IntPtr]::Zero)
$ov = New-Object KbBig+OVERLAPPED
$ov.hEvent = $ev

$end = (Get-Date).AddSeconds(120)
$reportCount = 0
$rid47Count  = 0
L "ReadFile loop running until $($end.ToString('HH:mm:ss')) ..."
while ((Get-Date) -lt $end) {
    $buf = New-Object byte[] $inLen
    $ok = [KbBig]::ReadFile($h, $buf, [uint32]$inLen, [IntPtr]::Zero, [ref]$ov)
    $err = [KbBig]::LastErr()
    if (-not $ok -and $err -ne 997) {  # 997 = ERROR_IO_PENDING (expected)
        L "  ReadFile FAIL err=$err"
        Start-Sleep -Milliseconds 500
        continue
    }
    $msLeft = [Math]::Max(50, [int]($end - (Get-Date)).TotalMilliseconds)
    $waitRc = [KbBig]::WaitForSingleObject($ev, [uint32][Math]::Min($msLeft, 2000))
    if ($waitRc -ne 0) {
        [KbBig]::CancelIo($h) | Out-Null
        continue
    }
    $xferred = [uint32]0
    [KbBig]::GetOverlappedResult($h, [ref]$ov, [ref]$xferred, $false) | Out-Null
    if ($xferred -gt 0) {
        $reportCount++
        $hex = (0..([Math]::Min($xferred, 16) - 1) | ForEach-Object { '{0:X2}' -f $buf[$_] }) -join ' '
        $rid = $buf[0]
        $now = (Get-Date).ToString('HH:mm:ss.fff')
        L "  $now  RID=0x$('{0:X2}' -f $rid)  len=$xferred  bytes=[$hex]"
        if ($rid -eq 0x47 -and $xferred -ge 2) {
            $rid47Count++
            L "    *** RID 0x47 battery report: $($buf[1])% ***"
        }
    }
}

[KbBig]::CloseHandle($ev) | Out-Null
$h.Close()

L ""
L "=== Summary ==="
L "Total reports received: $reportCount"
L "RID 0x47 (battery) reports: $rid47Count"
L ""
L "If rid47Count >= 1: increased input buffer queue MAY have rescued a"
L "  previously-dropped push. Worth comparing to the existing repo finding"
L "  ('silent for 120s') to see if behavior is reproducible."
L "If rid47Count == 0: not a buffer overflow problem — push truly isn't"
L "  happening, OR the firmware needs the SCO Link State init first."

$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - saved to $Out ==="
