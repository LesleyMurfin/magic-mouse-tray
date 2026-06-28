// Discovers all connected Apple HID battery devices by scanning the HID device interface list.
// Returns a fresh snapshot per call — no caching. AdaptivePoller drives the poll cadence.

namespace MagicMouseTray;

internal static class DeviceRegistry
{
    /// <summary>
    /// Scans all present HID interfaces and returns one IBatteryDevice per matched Apple device.
    /// Matching priority: mouse VID/PID checked first, then keyboard VID/PID.
    /// </summary>
    public static IReadOnlyList<IBatteryDevice> Discover(bool enableThirdParty = false)
    {
        var results = new List<IBatteryDevice>();

        foreach (var path in HidNative.EnumerateHidPaths())
        {
            var device = TryClassify(path, enableThirdParty);
            if (device is not null)
                results.Add(device);
        }

        return results;
    }

    static IBatteryDevice? TryClassify(string path, bool enableThirdParty)
    {
        // Magic Mouse — check all variants
        foreach (var entry in MouseBatteryDevice.KnownMice)
        {
            if (path.Contains(entry.VidPattern, StringComparison.OrdinalIgnoreCase) &&
                path.Contains(entry.PidPattern, StringComparison.OrdinalIgnoreCase))
                return new MouseBatteryDevice(path, entry.DisplayName, entry.Kind);
        }

        // B2 (experimental, flag-gated): directly-connected Logitech HID++ devices ONLY.
        // Checked BEFORE the keyboard col02 gate below: Logitech HID paths have no col02
        // collection, so gating on col02 first would make this branch unreachable. The
        // VID 046d match keeps it from interfering with Apple-keyboard classification.
        // Unifying/Bolt RECEIVERS are intentionally excluded — they require per-device-index
        // (1-6) addressing, not 0xFF; reading them is out of scope.
        if (enableThirdParty
            && path.Contains("vid_046d", StringComparison.OrdinalIgnoreCase)
            && !IsLogitechReceiver(path))
            return new LogitechBatteryDevice(path);

        // Magic Keyboard — col02 only (col01=keyboard, col03=consumer+vendor; battery cap is on col02).
        // Filtering here prevents 3 instances per physical keyboard (one per collection).
        if (!path.Contains("col02", StringComparison.OrdinalIgnoreCase)) return null;
        foreach (var entry in KeyboardBatteryDevice.KnownKeyboards)
        {
            if (path.Contains(entry.VidPattern, StringComparison.OrdinalIgnoreCase) &&
                path.Contains(entry.PidPattern, StringComparison.OrdinalIgnoreCase))
                return new KeyboardBatteryDevice(path, entry.DisplayName);
        }

        return null;
    }

    // Known Logitech receiver PIDs (Unifying / Bolt / nano variants). Receivers are excluded
    // from B2 because battery must be queried per paired device index, not at 0xFF.
    static readonly string[] LogitechReceiverPids = ["c52b", "c548", "c531", "c52f", "c534"];

    static bool IsLogitechReceiver(string path) =>
        Array.Exists(LogitechReceiverPids, pid => path.Contains(pid, StringComparison.OrdinalIgnoreCase));
}
