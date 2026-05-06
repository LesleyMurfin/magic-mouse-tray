// IBatteryDevice implementation for Apple Magic Mouse (all generations).
//
// Battery read strategy:
//   Split path (COL02, Mode A): UsagePage=0xFF00/Usage=0x0014, Input Report 0x90, buf[2]=pct.
//     Requires applewirelessmouse NOT in LowerFilters (PATH-B via FLIP:NoFilter).
//   Unified path (Mode B): Feature 0x47 Battery Strength — blocked by Apple driver (err=87).
//     Returns -2 so callers can distinguish "present but unreadable" from "not found".
using System.Runtime.InteropServices;
using System.Threading;

namespace MagicMouseTray;

internal sealed class MouseBatteryDevice : IBatteryDevice
{
    internal record struct VidPidEntry(string VidPattern, string PidPattern, string DisplayName, DeviceKind Kind);

    internal static readonly VidPidEntry[] KnownMice =
    [
        new("0001004C", "PID&0323", "Magic Mouse 2024", DeviceKind.MagicMouseV3), // BT v3
        new("VID_05AC",  "PID_0323", "Magic Mouse 2024", DeviceKind.MagicMouseV3), // USB v3
        new("000205AC", "PID&030D", "Magic Mouse v1",   DeviceKind.MagicMouseV1), // BT v1
        new("000205AC", "PID&0269", "Magic Mouse v2",   DeviceKind.MagicMouseV2), // BT v2 (M2 confirm pending)
    ];

    const ushort UP_VENDOR_BATTERY     = 0xFF00;
    const ushort USG_VENDOR_BATTERY    = 0x0014;
    const ushort UP_GENDEV_BATTERY     = 0x0006;
    const ushort USG_GENDEV_BATTSTRENG = 0x0020;
    const byte   BatteryReportId       = 0x90;

    readonly string _path;

    public string DeviceName { get; }
    public DeviceKind Kind { get; }

    internal MouseBatteryDevice(string path, string displayName, DeviceKind kind)
    {
        _path = path;
        DeviceName = displayName;
        Kind = kind;
    }

    public int GetBatteryPercent()
    {
        using var handle = HidNative.CreateFile(
            _path,
            0,  // zero access — avoids err=5 on mouhid-owned interfaces
            HidNative.FILE_SHARE_READ | HidNative.FILE_SHARE_WRITE,
            IntPtr.Zero,
            HidNative.OPEN_EXISTING,
            0,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            Logger.Log($"MOUSE_OPEN_FAILED path={_path} err={Marshal.GetLastWin32Error()}");
            return -1;
        }

        if (!HidNative.HidD_GetPreparsedData(handle, out var preparsed)) return -1;

        bool splitVendor = false;
        bool unifiedApple = false;
        byte unifiedRid = 0;
        int featureLen = 0;

        try
        {
            var caps = new HidNative.HIDP_CAPS();
            if (HidNative.HidP_GetCaps(preparsed, ref caps) != HidNative.HIDP_STATUS_SUCCESS) return -1;

            featureLen = caps.FeatureReportByteLength;

            if (caps.NumberFeatureValueCaps > 0)
            {
                var fcaps = new HidNative.HIDP_VALUE_CAPS[caps.NumberFeatureValueCaps];
                ushort len = caps.NumberFeatureValueCaps;
                if (HidNative.HidP_GetValueCaps(2, fcaps, ref len, preparsed) == HidNative.HIDP_STATUS_SUCCESS)
                {
                    for (int i = 0; i < len; i++)
                    {
                        if (fcaps[i].UsagePage == UP_GENDEV_BATTERY && fcaps[i].Usage == USG_GENDEV_BATTSTRENG)
                        {
                            unifiedApple = true;
                            unifiedRid = fcaps[i].ReportID;
                            break;
                        }
                    }
                }
            }

            if (caps.UsagePage == UP_VENDOR_BATTERY && caps.Usage == USG_VENDOR_BATTERY
                && caps.InputReportByteLength >= 3)
                splitVendor = true;
        }
        finally
        {
            HidNative.HidD_FreePreparsedData(preparsed);
        }

        if (splitVendor)
        {
            var buf = new byte[3];
            for (int attempt = 0; attempt < 3; attempt++)
            {
                buf[0] = BatteryReportId;
                if (HidNative.HidD_GetInputReport(handle, buf, buf.Length))
                {
                    if (buf[0] != BatteryReportId) return -1;
                    int pct = buf[2];
                    if (pct is < 0 or > 100) return -1;
                    Logger.Log($"MOUSE_BATTERY_OK device={DeviceName} pct={pct}% (split)");
                    return pct;
                }
                if (attempt < 2) Thread.Sleep(50);
            }
            Logger.Log($"MOUSE_READ_FAILED device={DeviceName} err={Marshal.GetLastWin32Error()}");
            return -1;
        }

        if (unifiedApple && featureLen > 0)
        {
            var fbuf = new byte[Math.Max(featureLen, 2)];
            fbuf[0] = unifiedRid;
            if (HidNative.HidD_GetFeature(handle, fbuf, fbuf.Length))
            {
                int pct = fbuf[1];
                if (pct is >= 0 and <= 100)
                {
                    Logger.Log($"MOUSE_BATTERY_OK device={DeviceName} pct={pct}% (unified Feature 0x{unifiedRid:X2})");
                    return pct;
                }
                return -1;
            }
            int err = Marshal.GetLastWin32Error();
            // Apple driver (6.2.0.0) traps Feature 0x47 — empirically confirmed 2026-04-27.
            Logger.Log($"MOUSE_UNIFIED_BLOCKED device={DeviceName} err={err} (Mode B — needs PATH-B recycle)");
            return -2;
        }

        return -1;
    }
}
