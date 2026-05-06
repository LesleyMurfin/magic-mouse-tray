// IBatteryDevice implementation for Apple Magic Keyboard.
//
// Battery is reported via HID Generic Device Battery Strength (UsagePage=0x0006/Usage=0x0020),
// Feature Report 0x47. Unlike the Magic Mouse unified-mode path, the keyboard driver does NOT
// appear to block Feature 0x47 reads. To be confirmed empirically in M2.
using System.Runtime.InteropServices;

namespace MagicMouseTray;

internal sealed class KeyboardBatteryDevice : IBatteryDevice
{
    // Known Magic Keyboard VID/PID entries (BT only; USB keyboards power from USB and don't report).
    internal record struct VidPidEntry(string VidPattern, string PidPattern, string DisplayName);

    internal static readonly VidPidEntry[] KnownKeyboards =
    [
        new("000205AC", "PID&0239", "Magic Keyboard"),       // BT, VID=Apple USB-IF 0x05AC
        new("000205AC", "PID&0267", "Magic Keyboard Touch"), // BT, Touch ID variant
    ];

    const ushort UP_GENDEV_BATTERY     = 0x0006;
    const ushort USG_GENDEV_BATTSTRENG = 0x0020;

    readonly string _path;

    public string DeviceName { get; }
    public DeviceKind Kind => DeviceKind.MagicKeyboard;

    internal KeyboardBatteryDevice(string path, string displayName)
    {
        _path = path;
        DeviceName = displayName;
    }

    public int GetBatteryPercent()
    {
        using var handle = HidNative.CreateFile(
            _path,
            0,
            HidNative.FILE_SHARE_READ | HidNative.FILE_SHARE_WRITE,
            IntPtr.Zero,
            HidNative.OPEN_EXISTING,
            0,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            Logger.Log($"KB_OPEN_FAILED path={_path} err={Marshal.GetLastWin32Error()}");
            return -1;
        }

        if (!HidNative.HidD_GetPreparsedData(handle, out var preparsed)) return -1;

        byte featureRid = 0;
        int featureLen = 0;
        bool found = false;

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
                            featureRid = fcaps[i].ReportID;
                            found = true;
                            break;
                        }
                    }
                }
            }
        }
        finally
        {
            HidNative.HidD_FreePreparsedData(preparsed);
        }

        if (!found || featureLen == 0) return -1;

        var buf = new byte[Math.Max(featureLen, 2)];
        buf[0] = featureRid;
        if (HidNative.HidD_GetFeature(handle, buf, buf.Length))
        {
            int pct = buf[1];
            if (pct is >= 0 and <= 100)
            {
                Logger.Log($"KB_BATTERY_OK device={DeviceName} pct={pct}%");
                return pct;
            }
            return -1;
        }

        Logger.Log($"KB_FEATURE_FAILED device={DeviceName} err={Marshal.GetLastWin32Error()}");
        return -1;
    }
}
