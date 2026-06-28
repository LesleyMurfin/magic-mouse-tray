// IBatteryDevice implementation for Apple Wireless Keyboard (2011, PID=0x0239) and variants.
//
// Device: Apple Wireless Keyboard A1314, 2011 ANSI/ISO/JIS revision (VID=0x05AC).
// PID source: Linux kernel hid-apple.c (USB_DEVICE_ID_APPLE_ALU_WIRELESS_2011_*).
//
// Battery path (empirical, 2026-06-25):
//   col02: RID=0x47 UP=0x0006/U=0x0020 ("Battery Strength", BitSize=8).
//   Natively the descriptor declares 0x47 as Input-only (FeatureReportByteLength=0), so it is
//   unreadable: HidD_GetFeature/GetInputReport return nothing and ReadFile never fires (the
//   device only pushes on BT connect). Verified exhaustively: 6,859 consecutive read timeouts,
//   255-RID sweep with zero hits.
//
//   After the BTHPORT CachedServices SDP cache is patched to expose 0x47 as a *Feature* report
//   (scripts/kbd-patch-cachedservices.ps1 inserts 09 20 B1 02 at the COL02 close), col02 reports
//   FeatureReportByteLength=2 and a Feature ValueCap for Battery Strength. HidD_GetFeature(0x47)
//   then returns [0x47, pct] — confirmed live: GetFeature 0x47 -> [47 0E].
//
//   This is an active synchronous read on col02; DeviceRegistry.Discover() hands us the col02
//   interface path and creates a fresh instance per poll, so no caching/monitor thread is needed.
//   When the patch is absent (e.g. erased by a re-pair) the Feature cap is missing and we return
//   -2 ("present but blocked"). The tray surfaces a how-to link to the patch instructions
//   (DeviceCapability.KbPatchAnchor); auto-patch is NOT wired (the patch needs admin and there
//   is no installed scheduled task for it, unlike MM-Dev-Cycle for the mouse flip).

using System.Runtime.InteropServices;

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
        // PIDs below: numeric facts only from hid-ids.h (GPL) — no kernel code/comments copied.
        // Magic Keyboard 2021/2024 (BLE company-id 0x004C or BT-classic 0x05AC)
        new("0001004C", "PID&029C", "Magic Keyboard (2021)"),
        new("000205AC", "PID&029C", "Magic Keyboard (2021)"),
        new("0001004C", "PID&029A", "Magic Keyboard with Touch ID (2021)"),
        new("000205AC", "PID&029A", "Magic Keyboard with Touch ID (2021)"),
        new("0001004C", "PID&029F", "Magic Keyboard with Numeric Keypad (2021)"),
        new("000205AC", "PID&029F", "Magic Keyboard with Numeric Keypad (2021)"),
        new("0001004C", "PID&0320", "Magic Keyboard (2024)"),
        new("000205AC", "PID&0320", "Magic Keyboard (2024)"),
        new("0001004C", "PID&0321", "Magic Keyboard with Touch ID (2024)"),
        new("000205AC", "PID&0321", "Magic Keyboard with Touch ID (2024)"),
        new("0001004C", "PID&0322", "Magic Keyboard with Numeric Keypad (2024)"),
        new("000205AC", "PID&0322", "Magic Keyboard with Numeric Keypad (2024)"),
        new("000205AC", "PID&0255", "Apple Wireless Keyboard (2011 ANSI)"),
        new("000205AC", "PID&0256", "Apple Wireless Keyboard (2011 ISO)"),
        new("000205AC", "PID&0257", "Apple Wireless Keyboard (2011 JIS)"),
    ];

    // Battery Strength on Generic Device Controls page — readable as a Feature after the patch.
    const ushort UP_GENDEV_BATTERY    = 0x0006;
    const ushort USG_GENDEV_BATTSTRENG = 0x0020;

    readonly string _path;

    public string DeviceName { get; }
    public DeviceKind Kind => DeviceKind.MagicKeyboard;

    internal KeyboardBatteryDevice(string path, string displayName)
    {
        _path = path;
        DeviceName = displayName;
    }

    // Active read of the col02 Battery Strength Feature report (RID 0x47).
    // Returns 0-100, -2 if present but the Feature cap/read is blocked (patch needed), -1 on open failure.
    public int GetBatteryPercent()
    {
        using var handle = HidNative.CreateFile(
            _path,
            0,                              // zero access — read Feature without needing GENERIC_READ
            HidNative.FILE_SHARE_READ | HidNative.FILE_SHARE_WRITE,
            IntPtr.Zero,
            HidNative.OPEN_EXISTING,
            0,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            Logger.Log($"KB_OPEN_FAILED device={DeviceName} err={Marshal.GetLastWin32Error()}");
            return -1;
        }

        if (!HidNative.HidD_GetPreparsedData(handle, out var preparsed))
        {
            Logger.Log($"KB_PREPARSED_FAILED device={DeviceName}");
            return -1;
        }

        byte batteryReportId = 0;
        bool hasBatteryFeature = false;
        int featureLen = 0;
        try
        {
            var caps = new HidNative.HIDP_CAPS();
            if (HidNative.HidP_GetCaps(preparsed, ref caps) != HidNative.HIDP_STATUS_SUCCESS)
            {
                Logger.Log($"KB_CAPS_FAILED device={DeviceName}");
                return -1;
            }
            featureLen = caps.FeatureReportByteLength;
            Logger.Log($"KB_HIDP_CAPS device={DeviceName} FeatLen={featureLen} FeatValueCaps={caps.NumberFeatureValueCaps}");

            if (caps.NumberFeatureValueCaps > 0)
            {
                var fcaps = new HidNative.HIDP_VALUE_CAPS[caps.NumberFeatureValueCaps];
                ushort len = caps.NumberFeatureValueCaps;
                if (HidNative.HidP_GetValueCaps(2 /* Feature */, fcaps, ref len, preparsed) == HidNative.HIDP_STATUS_SUCCESS)
                {
                    for (int i = 0; i < len; i++)
                    {
                        if (fcaps[i].UsagePage == UP_GENDEV_BATTERY && fcaps[i].Usage == USG_GENDEV_BATTSTRENG)
                        {
                            hasBatteryFeature = true;
                            batteryReportId = fcaps[i].ReportID;
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

        // No Feature cap = unpatched descriptor (or patch erased by re-pair). Present but blocked.
        if (!hasBatteryFeature || featureLen <= 0)
        {
            Logger.Log($"KB_BATTERY_BLOCKED device={DeviceName} (no Feature 0x47 cap — patch needed)");
            return -2;
        }

        var fbuf = new byte[Math.Max(featureLen, 2)];
        fbuf[0] = batteryReportId;
        if (HidNative.HidD_GetFeature(handle, fbuf, fbuf.Length) && fbuf[1] is >= 0 and <= 100)
        {
            int pct = fbuf[1];
            Logger.Log($"KB_BATTERY_OK device={DeviceName} pct={pct}% (Feature 0x{batteryReportId:X2})");
            return pct;
        }

        Logger.Log($"KB_FEATURE_BLOCKED device={DeviceName} err={Marshal.GetLastWin32Error()} (Feature 0x{batteryReportId:X2} unreadable — patch needed)");
        return -2;
    }
}
