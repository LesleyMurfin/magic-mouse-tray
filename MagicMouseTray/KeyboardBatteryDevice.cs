// IBatteryDevice implementation for Apple Wireless Keyboard (2011, PID=0x0239) and variants.
//
// Device: Apple Wireless Keyboard A1314, 2011 ANSI/ISO/JIS revision (VID=0x05AC).
// PID source: Linux kernel hid-apple.c (USB_DEVICE_ID_APPLE_ALU_WIRELESS_2011_*).
//
// Battery path status (empirical, 2026-05-07, exhaustive):
//   col02: Input ValueCap RID=0x47 UP=0x0006/U=0x0020 (Battery Strength, BitSize=8, LogMax=255).
//   FeatureReportByteLength=0 on col02/col01 — no Feature reports anywhere.
//   col03 has FeatLen=4 but only RID=0x09 (status flag, not battery).
//
//   ALL active read paths ruled out (tested as admin, all access modes, all collections):
//   - HidD_GetInputReport: all 255 RIDs return err=87 — firmware does not support GET_REPORT.
//   - HidD_GetFeature: FeatLen=0, err=1 on col01/col02; RID=0x47 absent on col03.
//   - DeviceIoControl IOCTL_HID_GET_FEATURE: err=1784 — driver validates FeatLen=0 first.
//   - ReadFile on col02 while connected: silent for 120s — device only pushes on BT connect.
//   - WinRT DeviceContainer/BluetoothDevice BatteryLife: empty — Windows does not cache it.
//   - VID=0x004C (BLE) path: keyboard has no BLE counterpart, Classic BT only.
//
//   Only viable path: keyboard pushes RID=0x47 on col02 interrupt IN pipe at BT connect time.
//   Strategy: open col02 with FILE_FLAG_OVERLAPPED, wait up to 30s for the push, cache result.
//   Static state persists battery across DeviceRegistry.Discover() calls (new instances per poll).

using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace MagicMouseTray;

internal sealed class KeyboardBatteryDevice : IBatteryDevice
{
    internal record struct VidPidEntry(string VidPattern, string PidPattern, string DisplayName);

    internal static readonly VidPidEntry[] KnownKeyboards =
    [
        // 2011 revision (A1314) — PID source: Linux kernel hid-apple.c
        new("000205AC", "PID&0239", "Apple Wireless Keyboard (2011)"),
        new("000205AC", "PID&023A", "Apple Wireless Keyboard (2011) ISO"),
        new("000205AC", "PID&023B", "Apple Wireless Keyboard (2011) JIS"),
        // Magic Keyboard (A1644, 2015+)
        new("000205AC", "PID&024F", "Magic Keyboard"),
        new("000205AC", "PID&0250", "Magic Keyboard ISO"),
        // Magic Keyboard with Touch ID (A2449, 2021+)
        new("000205AC", "PID&0267", "Magic Keyboard with Touch ID"),
        new("000205AC", "PID&026C", "Magic Keyboard with Touch ID ISO"),
    ];

    // Static: battery cache persists across DeviceRegistry.Discover() (new instance per poll).
    // Written by monitor thread, read by GetBatteryPercent().
    static volatile int s_cachedBattery = -1;
    static volatile string? s_currentPath;
    static Thread? s_monitorThread;
    static readonly object s_monitorLock = new();

    readonly string _path;

    public string DeviceName { get; }
    public DeviceKind Kind => DeviceKind.MagicKeyboard;

    internal KeyboardBatteryDevice(string path, string displayName)
    {
        _path = path;
        DeviceName = displayName;
        EnsureMonitor(path);
    }

    static void EnsureMonitor(string path)
    {
        lock (s_monitorLock)
        {
            if (!string.Equals(s_currentPath, path, StringComparison.OrdinalIgnoreCase))
            {
                // Path changed = keyboard reconnected. Reset cache and restart.
                s_cachedBattery = -1;
                s_currentPath = path;
                s_monitorThread = null;
            }

            if (s_monitorThread?.IsAlive == true) return;

            var t = new Thread(() => MonitorLoop(path))
            {
                IsBackground = true,
                Name = "KB-Battery-Monitor"
            };
            t.Start();
            s_monitorThread = t;
        }
    }

    static void MonitorLoop(string monitoredPath)
    {
        Logger.Log($"KB_MONITOR_START path={monitoredPath}");

        while (string.Equals(s_currentPath, monitoredPath, StringComparison.OrdinalIgnoreCase))
        {
            using var handle = HidNative.CreateFile(
                monitoredPath,
                HidNative.GENERIC_READ,
                HidNative.FILE_SHARE_READ | HidNative.FILE_SHARE_WRITE,
                IntPtr.Zero,
                HidNative.OPEN_EXISTING,
                HidNative.FILE_FLAG_OVERLAPPED,
                IntPtr.Zero);

            if (handle.IsInvalid)
            {
                Logger.Log($"KB_MONITOR_OPEN_FAIL err={Marshal.GetLastWin32Error()}");
                Thread.Sleep(5000);
                continue;
            }

            Logger.Log("KB_MONITOR_OPEN_OK waiting_for_battery_push");
            int pct = ReadWithTimeout(handle, timeoutMs: 30_000);

            if (pct is >= 0 and <= 100)
            {
                Interlocked.Exchange(ref s_cachedBattery, pct);
                Logger.Log($"KB_BATTERY_OK pct={pct}%");
                // Battery changes slowly — sleep before next read attempt.
                Thread.Sleep(TimeSpan.FromMinutes(5));
            }
            else if (pct == -3)
            {
                // Keyboard disconnected during wait.
                Logger.Log("KB_MONITOR_DISCONNECTED");
                Interlocked.Exchange(ref s_cachedBattery, -1);
                Thread.Sleep(2000);
            }
            else
            {
                // Timeout: no push in 30s. Re-open immediately so we never miss a reconnect push.
                Logger.Log($"KB_MONITOR_TIMEOUT cached={s_cachedBattery}");
            }
        }

        Logger.Log($"KB_MONITOR_EXIT path={monitoredPath}");
    }

    // Returns battery% (0-100), -1=timeout or bad data, -3=device not connected.
    // Uses overlapped ReadFile so we can impose a timeout without blocking or sending BT requests.
    static int ReadWithTimeout(SafeFileHandle handle, int timeoutMs)
    {
        var hEvent = HidNative.CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        if (hEvent == IntPtr.Zero || hEvent == HidNative.INVALID_HANDLE_VALUE) return -1;

        try
        {
            var buf = new byte[64];
            var ov = new HidNative.OVERLAPPED { hEvent = hEvent };

            bool ok = HidNative.ReadFile(handle, buf, (uint)buf.Length, IntPtr.Zero, ref ov);
            int err = Marshal.GetLastWin32Error();

            if (!ok && err != (int)HidNative.ERROR_IO_PENDING)
                return err == (int)HidNative.ERROR_DEVICE_NOT_CONNECTED ? -3 : -1;

            uint waitResult = HidNative.WaitForSingleObject(hEvent, (uint)timeoutMs);

            if (waitResult != HidNative.WAIT_OBJECT_0)
            {
                HidNative.CancelIo(handle);
                return -1;
            }

            if (!HidNative.GetOverlappedResult(handle, ref ov, out uint transferred, false))
                return -1;

            // RID=0x47 at buf[0], battery% at buf[1]
            if (transferred < 2 || buf[0] != 0x47) return -1;
            int pct = buf[1];
            return pct is >= 0 and <= 100 ? pct : -1;
        }
        finally
        {
            HidNative.CloseHandle(hEvent);
        }
    }

    public int GetBatteryPercent()
    {
        int cached = s_cachedBattery;
        if (cached >= 0)
            Logger.Log($"KB_BATTERY device={DeviceName} pct={cached}%");
        else
            Logger.Log($"KB_BATTERY_PENDING device={DeviceName} (waiting for connect-push)");
        return cached;
    }
}
