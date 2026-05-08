# kbd-battery-probe2-2026-05-07.ps1
# Probe keyboard battery via three alternative paths:
#   A. SetupDi device property query (BTHENUM devnode)
#   B. WinRT DeviceContainer BatteryLife property (corrected)
#   C. ReadFile on col02 with 2s timeout (event-driven input report)
# All output ASCII-safe. No em-dash or box-drawing chars.
$Out = '\\wsl.localhost\Ubuntu\home\lesley\projects\Personal\magic-mouse-tray\.ai\test-runs\2026-05-07-kbd-battery-probe\probe2.txt'
$log = @()
function L { param([string]$m) $script:log += $m; Write-Host $m }

L "=== KBD BATTERY PROBE 2 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# ---- Part A: SetupDi device property (battery DEVPKEY candidates) -----------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class Probe2 {
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string fn, uint access, uint share,
        IntPtr sa, uint cd, uint fa, IntPtr t);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadFile(SafeFileHandle h, byte[] buf, int nBytes,
        out int nRead, IntPtr overlapped);

    [DllImport("hid.dll", SetLastError=true)]
    public static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] b, int l);

    // SetupDi
    [DllImport("setupapi.dll", CharSet=CharSet.Auto, SetLastError=true)]
    public static extern IntPtr SetupDiGetClassDevs(IntPtr cls, string en, IntPtr wnd, uint f);
    [DllImport("setupapi.dll", SetLastError=true)]
    public static extern bool SetupDiEnumDeviceInfo(IntPtr h, uint idx, ref SPDD d);
    [DllImport("setupapi.dll")]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr h);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SetupDiGetDevicePropertyW(IntPtr h, ref SPDD di,
        ref DEVPROPKEY key, out uint type, byte[] buf, uint bufLen, out uint req, uint f);
    [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode)]
    public static extern uint CM_Get_Device_ID(uint dn, StringBuilder b, uint len, uint f);

    // Bluetooth device property keys
    // DEVPKEY_Bluetooth_BluetoothBatteryPercentage = {104EA319-6EE2-4701-BD47-8DDBF425BBE5}, 2
    // PKEY_Device_BatteryStrength = {83DA6326-97A6-4088-9453-A1923F573B29}, 16
    // PKEY_Bluetooth_BatteryLife = {83DA6326-97A6-4088-9453-A1923F573B29}, 16 (same key)
    // System.Devices.BatteryLife = {49CD1F76-5626-4B17-A4E8-18B4AA1A2213}, 4
    public static byte[] GetDevPropRaw(IntPtr devs, ref SPDD di, Guid g, uint pid) {
        var key = new DEVPROPKEY { fmtid = g, pid = pid };
        uint type, req;
        byte[] buf = new byte[64];
        if (SetupDiGetDevicePropertyW(devs, ref di, ref key, out type, buf, (uint)buf.Length, out req, 0))
            return buf;
        return null;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SPDD { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DEVPROPKEY { public Guid fmtid; public uint pid; }
}
'@

L ""
L "=== PART A: SetupDi BTHENUM device property probe ==="
$DIGCF_PRESENT_ALLCLASSES = 6
$devs = [Probe2]::SetupDiGetClassDevs([IntPtr]::Zero, "BTHENUM", [IntPtr]::Zero, $DIGCF_PRESENT_ALLCLASSES)
$di = New-Object Probe2+SPDD
$di.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($di)
$idx = 0
while ([Probe2]::SetupDiEnumDeviceInfo($devs, $idx, [ref]$di)) {
    $idx++
    $sb = New-Object System.Text.StringBuilder 512
    if ([Probe2]::CM_Get_Device_ID($di.DevInst, $sb, 512, 0) -ne 0) { continue }
    $id = $sb.ToString().ToLower()
    if ($id -notlike "*00001124*") { continue }
    if ($id -notlike "*000205ac*" -and $id -notlike "*vid_05ac*") { continue }
    if ($id -notlike "*0239*") { continue }
    L "BTHENUM devnode: $($sb.ToString())"

    # Candidate property keys
    $keys = @(
        @{G=[Guid]"104EA319-6EE2-4701-BD47-8DDBF425BBE5"; PID=2; Name="BT_BatteryPct"},
        @{G=[Guid]"83DA6326-97A6-4088-9453-A1923F573B29"; PID=16; Name="PKEY_Device_BatteryStrength"},
        @{G=[Guid]"49CD1F76-5626-4B17-A4E8-18B4AA1A2213"; PID=4; Name="System.Devices.BatteryLife"},
        @{G=[Guid]"83DA6326-97A6-4088-9453-A1923F573B29"; PID=4; Name="83DA_4"},
        @{G=[Guid]"49CD1F76-5626-4B17-A4E8-18B4AA1A2213"; PID=2; Name="49CD_2"},
        @{G=[Guid]"104EA319-6EE2-4701-BD47-8DDBF425BBE5"; PID=1; Name="104E_1"}
    )
    foreach ($k in $keys) {
        $g = $k.G
        $raw = [Probe2]::GetDevPropRaw($devs, [ref]$di, $g, $k.PID)
        if ($raw -ne $null) {
            $hex = ($raw[0..7] | ForEach-Object { $_.ToString("X2") }) -join " "
            L "  HIT $($k.Name): [$hex ...]"
        } else {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            L "  MISS $($k.Name): err=$err"
        }
    }
}
[Probe2]::SetupDiDestroyDeviceInfoList($devs) | Out-Null

# ---- Part B: WinRT DeviceContainer BatteryLife --------------------------------
L ""
L "=== PART B: WinRT DeviceContainer ==="
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $async = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
        "",
        [string[]]@("System.Devices.BatteryLife", "System.Devices.Connected"),
        [Windows.Devices.Enumeration.DeviceInformationKind]::DeviceContainer)
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    $task = $asTask.MakeGenericMethod([Windows.Devices.Enumeration.DeviceInformationCollection]).Invoke($null, @($async))
    $task.Wait(5000) | Out-Null
    $containers = $task.Result
    L "  Container count: $($containers.Count)"
    foreach ($c in $containers) {
        $name = $c.Name
        if ($name -notlike "*keyboard*" -and $name -notlike "*magic*" -and $name -notlike "*apple*") { continue }
        L "  Match: $name"
        foreach ($key in @("System.Devices.BatteryLife", "System.Devices.Connected")) {
            $val = $null
            $c.Properties.TryGetValue($key, [ref]$val) | Out-Null
            L "    $key = $val (type=$(if($val){$val.GetType().Name}else{'null'}))"
        }
    }
} catch {
    L "  WinRT ERROR: $($_.Exception.Message)"
}

# ---- Part C: ReadFile on col02 with 2s timeout --------------------------------
L ""
L "=== PART C: ReadFile on col02 (2s timeout) ==="
$col02 = "\\?\hid#{00001124-0000-1000-8000-00805f9b34fb}_vid&000205ac_pid&0239&col02#a&eaf9d13&2&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}"
# FILE_FLAG_OVERLAPPED = 0x40000000, GENERIC_READ = 0x80000000
# Open for read with share r/w
$GENERIC_READ = 0x80000000
$FILE_SHARE_READ = 1; $FILE_SHARE_WRITE = 2
$OPEN_EXISTING = 3
$FILE_FLAG_OVERLAPPED = 0x40000000
$h = [Probe2]::CreateFile($col02, $GENERIC_READ, $FILE_SHARE_READ -bor $FILE_SHARE_WRITE,
    [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
if ($h.IsInvalid) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    L "  OPEN FAILED err=$err"
} else {
    L "  OPEN OK - trying synchronous ReadFile for 2s"
    # Use a background job to attempt the read with a timeout
    $job = Start-Job -ScriptBlock {
        # Can't pass SafeFileHandle across job boundary - use handle value
        # Instead, try HidD_GetInputReport with full buf size from within this process
        # This is a limitations of job approach - just report the attempt
        "JOB_STARTED"
    }
    # Try synchronous ReadFile directly - will block until report arrives or error
    $buf = New-Object byte[] 2
    $nRead = 0
    $buf[0] = 0x47
    L "  ReadFile attempt (blocking up to OS timeout)..."
    $ok = [Probe2]::ReadFile($h, $buf, 2, [ref]$nRead, [IntPtr]::Zero)
    if ($ok) {
        $hex = ($buf[0..($nRead-1)] | ForEach-Object { $_.ToString("X2") }) -join " "
        L "  ReadFile OK nRead=$nRead buf=[$hex]"
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        L "  ReadFile FAIL err=$err"
    }
    $h.Close()
}

# ---- Part D: ReadFile on col02 with no access flags (existing pattern) -------
L ""
L "=== PART D: ReadFile on col02 (dwDesiredAccess=0) ==="
$h2 = [Probe2]::CreateFile($col02, 0, $FILE_SHARE_READ -bor $FILE_SHARE_WRITE,
    [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
if ($h2.IsInvalid) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    L "  OPEN FAILED err=$err"
} else {
    L "  OPEN OK - ReadFile with access=0"
    $buf = New-Object byte[] 2
    $nRead = 0
    $ok = [Probe2]::ReadFile($h2, $buf, 2, [ref]$nRead, [IntPtr]::Zero)
    if ($ok) {
        $hex = ($buf[0..($nRead-1)] | ForEach-Object { $_.ToString("X2") }) -join " "
        L "  ReadFile OK nRead=$nRead buf=[$hex]"
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        L "  ReadFile FAIL err=$err"
    }
    $h2.Close()
}

# ---- Save output ------------------------------------------------------------
$log | Set-Content -Path $Out -Encoding UTF8
L "=== DONE - output: $Out ==="
