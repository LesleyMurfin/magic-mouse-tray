// SPDX-License-Identifier: MIT
using Microsoft.Win32;

namespace MagicMouseTray;

internal enum DriverStatus
{
    Ok,               // service present + LowerFilters bound (or no Apple BT device paired)
    NotInstalled,     // AppleWirelessMouse service key absent
    NotBound,         // service present, known Apple PID paired, but LowerFilters not applied
    UnknownAppleMouse // Apple-vendor HID device with a PID not in our INF — likely a new model
}

// Checks whether the AppleWirelessMouse filter driver is installed and bound to the device.
//
// The service can be registered but not bound if:
//   (a) the INF predates the connected model (e.g. PID 0323 absent from the 2019 tealtadpole INF)
//   (b) the device was never re-paired after driver installation
//
// UnknownAppleMouse is returned when we find a paired Apple-vendor BT HID device whose PID
// is not in our known list — this tells the user a future model needs an app/driver update.
internal static class DriverHealthChecker
{
    const string ServiceKey = @"SYSTEM\CurrentControlSet\Services\AppleWirelessMouse";
    const string BtHidEnumBase = @"SYSTEM\CurrentControlSet\Enum\BTHENUM";

    // Bluetooth HID UUID (classic BT HID profile)
    const string HidUuidPrefix = "{00001124-0000-1000-8000-00805f9b34fb}";

    // Apple Bluetooth VID segments as they appear in BTHENUM subkey names.
    // VID&000205ac = Apple USB-IF VID (0x05AC), VID&0001004c = Apple BLE company ID (0x004C).
    static readonly string[] AppleVidSegments = ["_VID&000205ac_", "_VID&0001004c_"];

    // PIDs covered by the patched AppleWirelessMouse.inf (lower-case, 4 hex digits).
    // If Apple ships a new model, its PID won't be here — we surface that as UnknownAppleMouse.
    static readonly string[] KnownPids = ["030d", "0310", "0269", "0323"];

    // Apple BT-HID devices matched by the same VID/UUID scan but that do NOT use the
    // applewirelessmouse scroll filter (trackpads + keyboards). Excluded from BOTH the
    // UnknownAppleMouse and the NotBound verdicts — otherwise the tray shows a false warning.
    // PIDs are numeric facts only (hid-ids.h, GPL) — no kernel code/comments copied.
    static readonly string[] NonScrollApplePids =
    [
        "030e", "0265", "0324",                                       // trackpads (v1, v2, v3)
        "0239", "023a", "023b", "024f", "0250", "0267", "026c",       // existing keyboard rows (latent fix)
        "029c", "029a", "029f", "0320", "0321", "0322",               // Magic Keyboards 2021/2024
        "0255", "0256", "0257",                                       // Apple Wireless Keyboard 2011 (true)
    ];

    internal static DriverStatus GetStatus()
    {
        try
        {
            using var svcKey = Registry.LocalMachine.OpenSubKey(ServiceKey, writable: false);
            if (svcKey == null)
            {
                Logger.Log("DRIVER_CHECK status=NotInstalled (service key missing)");
                return DriverStatus.NotInstalled;
            }

            using var btEnumKey = Registry.LocalMachine.OpenSubKey(BtHidEnumBase, writable: false);
            if (btEnumKey == null)
            {
                Logger.Log("DRIVER_CHECK status=Ok (service present, BTHENUM absent)");
                return DriverStatus.Ok;
            }

            bool anyAppleMouse = false;
            bool anyUnknownPid = false;
            bool anyNotBound = false;

            foreach (var subkeyName in btEnumKey.GetSubKeyNames())
            {
                if (!subkeyName.StartsWith(HidUuidPrefix, StringComparison.OrdinalIgnoreCase))
                    continue;

                bool isApple = false;
                foreach (var seg in AppleVidSegments)
                    if (subkeyName.Contains(seg, StringComparison.OrdinalIgnoreCase))
                    { isApple = true; break; }
                if (!isApple) continue;

                // Extract 4-hex-digit PID from "_PID&XXXX" at end of key name
                int pidIdx = subkeyName.LastIndexOf("_PID&", StringComparison.OrdinalIgnoreCase);
                if (pidIdx < 0 || pidIdx + 9 > subkeyName.Length) continue;
                var pid = subkeyName.Substring(pidIdx + 5, 4).ToLowerInvariant();

                // Non-scroll Apple device (trackpad/keyboard): no scroll filter expected.
                // Skip so it triggers neither UnknownAppleMouse nor NotBound.
                if (Array.Exists(NonScrollApplePids, p => p == pid))
                {
                    Logger.Log($"DRIVER_CHECK skip_non_scroll_apple pid=0x{pid.ToUpper()}");
                    continue;
                }

                using var deviceKey = btEnumKey.OpenSubKey(subkeyName, writable: false);
                if (deviceKey == null) continue;
                var instances = deviceKey.GetSubKeyNames();
                if (instances.Length == 0) continue; // key exists but no device paired

                anyAppleMouse = true;
                bool pidKnown = Array.Exists(KnownPids, p => p == pid);

                foreach (var instanceName in instances)
                {
                    using var instance = deviceKey.OpenSubKey(instanceName, writable: false);
                    var filters = instance?.GetValue("LowerFilters") as string[];
                    bool isBound = filters != null && Array.Exists(filters,
                        f => f.Equals("applewirelessmouse", StringComparison.OrdinalIgnoreCase));

                    if (!pidKnown)
                    {
                        Logger.Log($"DRIVER_CHECK unknown_apple_pid=0x{pid.ToUpper()} bound={isBound}");
                        anyUnknownPid = true;
                    }
                    else if (isBound)
                    {
                        Logger.Log($"DRIVER_CHECK pid=0x{pid.ToUpper()} LowerFilters=bound");
                    }
                    else
                    {
                        Logger.Log($"DRIVER_CHECK pid=0x{pid.ToUpper()} LowerFilters=missing");
                        anyNotBound = true;
                    }
                }
            }

            if (!anyAppleMouse)
            {
                Logger.Log("DRIVER_CHECK status=Ok (service present, no Apple BT HID device paired)");
                return DriverStatus.Ok;
            }

            // Worst-state wins across all paired devices:
            // UnknownAppleMouse > NotBound > Ok
            if (anyUnknownPid)
            {
                Logger.Log("DRIVER_CHECK status=UnknownAppleMouse (PID not in INF)");
                return DriverStatus.UnknownAppleMouse;
            }

            if (anyNotBound)
            {
                Logger.Log("DRIVER_CHECK status=NotBound (service present, known PID, LowerFilters missing)");
                return DriverStatus.NotBound;
            }

            Logger.Log("DRIVER_CHECK status=Ok (service + LowerFilters bound)");
            return DriverStatus.Ok;
        }
        catch (Exception ex)
        {
            Logger.Log($"DRIVER_CHECK_FAILED err={ex.Message}");
            return DriverStatus.Ok; // fail open — don't nag user on transient registry errors
        }
    }
}
