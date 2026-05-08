# kbd-allcol-probe-2026-05-07.ps1
# Multi-path probe: overlapped ReadFile on col02+col03 (all access modes),
# WinRT BluetoothDevice BatteryLife property, and any-RID logging.
# 30 seconds per test, no BT requests, no reconnect needed.

$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\allcol-probe.txt'
$log = @()
function L([string]$m) { $script:log += $m; Write-Host $m }
L "=== KB ALL-COL PROBE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class KbProbe {
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
    public static int LastErr() { return Marshal.GetLastWin32Error(); }

    [StructLayout(LayoutKind.Sequential)]
    public struct OVERLAPPED {
        public UIntPtr Internal, InternalHigh;
        public uint Offset, OffsetHigh;
        public IntPtr hEvent;
    }

    // Returns: array of (elapsed_ms, bytes) if data received; null = timeout; throws on open fail.
    // Tries access modes: GENERIC_READ, then GENERIC_READ|WRITE.
    public static string TryRead(string path, int timeoutMs) {
        uint[] accessModes = { 0x80000000u, 0xC0000000u };
        string[] modeNames = { "R", "RW" };

        for (int m = 0; m < accessModes.Length; m++) {
            var h = CreateFile(path, accessModes[m], 3, IntPtr.Zero, 3, 0x40000000u, IntPtr.Zero);
            if (h.IsInvalid) {
                int e = LastErr();
                if (e == 5 && m == 0) continue; // try RW
                return "OPEN_FAIL err=" + e;
            }
            try {
                var hEv = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
                try {
                    var buf = new byte[64];
                    var ov = new OVERLAPPED { hEvent = hEv };
                    bool ok = ReadFile(h, buf, (uint)buf.Length, IntPtr.Zero, ref ov);
                    int err = Marshal.GetLastWin32Error();
                    if (!ok && err != 997) { // 997=IO_PENDING
                        return modeNames[m] + " ReadFile_err=" + err;
                    }
                    var t0 = DateTime.Now;
                    uint wr = WaitForSingleObject(hEv, (uint)timeoutMs);
                    int elapsedMs = (int)(DateTime.Now - t0).TotalMilliseconds;
                    if (wr != 0) { CancelIo(h); return modeNames[m] + " TIMEOUT(" + timeoutMs + "ms)"; }
                    uint xferred = 0;
                    if (!GetOverlappedResult(h, ref ov, out xferred, false))
                        return modeNames[m] + " OV_FAIL err=" + LastErr();
                    var hex = new System.Text.StringBuilder();
                    for (int i = 0; i < Math.Min((int)xferred, 16); i++)
                        hex.AppendFormat("{0:X2} ", buf[i]);
                    return string.Format("{0} HIT at {1}ms xferred={2} [{3}]", modeNames[m], elapsedMs, xferred, hex.ToString().Trim());
                } finally { CloseHandle(hEv); }
            } finally { h.Close(); }
        }
        return "ALL_ACCESS_MODES_FAILED";
    }
}
'@ -ErrorAction Stop

$col02 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&3&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"
$col03 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col03#a&eaf9d13&3&0002#{4d1e55b2-f16f-11cf-88cb-001111000030}"

L ""
L "=== PART A: ReadFile 30s wait on col02 and col03 ==="
L ""

foreach ($entry in @(@{col="col02"; path=$col02}, @{col="col03"; path=$col03})) {
    L "Testing $($entry.col) ..."
    $r = [KbProbe]::TryRead($entry.path, 30000)
    L "  $($entry.col): $r"
    L ""
}

L "=== PART B: WinRT BluetoothDevice BatteryLife ==="
L ""
try {
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

    $propKeys = [string[]]@("System.Devices.BatteryLife", "System.Devices.Connected", "System.DeviceInterface.Bluetooth.DeviceAddress")
    $selector = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelector()
    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector, $propKeys)

    $ext = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    $task = $ext.MakeGenericMethod([Windows.Devices.Enumeration.DeviceInformationCollection]).Invoke($null, @($async))

    if (-not $task.Wait(8000)) { L "  TIMEOUT" }
    else {
        $devs = $task.Result
        L "  BT devices found: $($devs.Count)"
        foreach ($d in $devs) {
            $nameMatch = $d.Name -like '*keyboard*' -or $d.Name -like '*magic*' -or $d.Name -like '*apple*'
            $batt = $null; $d.Properties.TryGetValue("System.Devices.BatteryLife", [ref]$batt) | Out-Null
            if (-not $nameMatch -and $batt -eq $null) { continue }
            L "  Device: '$($d.Name)'"
            foreach ($k in $propKeys) {
                $v = $null; $d.Properties.TryGetValue($k, [ref]$v) | Out-Null
                L "    $k = $v"
            }
        }
    }
} catch {
    L "  WinRT error: $($_.Exception.Message -replace '\r?\n',' ')"
}

$log | Set-Content -Path $Out -Encoding UTF8
L ""
L "=== DONE - saved to $Out ==="
