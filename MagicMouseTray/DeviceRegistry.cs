// Discovers all connected Apple HID battery devices by scanning the HID device interface list.
// Returns a fresh snapshot per call — no caching. AdaptivePoller drives the poll cadence.

namespace MagicMouseTray;

internal static class DeviceRegistry
{
    /// <summary>
    /// Scans all present HID interfaces and returns one IBatteryDevice per matched Apple device.
    /// Matching priority: mouse VID/PID checked first, then keyboard VID/PID.
    /// </summary>
    public static IReadOnlyList<IBatteryDevice> Discover()
    {
        var results = new List<IBatteryDevice>();

        foreach (var path in HidNative.EnumerateHidPaths())
        {
            var device = TryClassify(path);
            if (device is not null)
                results.Add(device);
        }

        return results;
    }

    static IBatteryDevice? TryClassify(string path)
    {
        // Magic Mouse — check all variants
        foreach (var entry in MouseBatteryDevice.KnownMice)
        {
            if (path.Contains(entry.VidPattern, StringComparison.OrdinalIgnoreCase) &&
                path.Contains(entry.PidPattern, StringComparison.OrdinalIgnoreCase))
                return new MouseBatteryDevice(path, entry.DisplayName, entry.Kind);
        }

        // Magic Keyboard
        foreach (var entry in KeyboardBatteryDevice.KnownKeyboards)
        {
            if (path.Contains(entry.VidPattern, StringComparison.OrdinalIgnoreCase) &&
                path.Contains(entry.PidPattern, StringComparison.OrdinalIgnoreCase))
                return new KeyboardBatteryDevice(path, entry.DisplayName);
        }

        return null;
    }
}
