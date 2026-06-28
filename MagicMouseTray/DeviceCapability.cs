// SPDX-License-Identifier: MIT
namespace MagicMouseTray;

// Derives the per-device read-path + remediation row for the capability matrix.
// Pure function of (Kind, last battery sentinel, driver status) — no I/O.
// Read paths are deterministic per DeviceKind; the last reading distinguishes
// "working" (>=0) from "present but blocked" (-2) from "not readable/absent" (-1).
//
// CAVEAT (RULE #1): DriverStatus from DriverHealthChecker.GetStatus() is a single
// GLOBAL worst-state-wins value (DriverHealthChecker.cs:114-126), not per-device.
// With multiple Apple mice paired, one device's worst state colors every mouse row.
// Acceptable as a heuristic. The scroll filter governs SCROLL, not the v1/v2 split
// battery read, so a non-Ok driver does NOT mean the v1/v2 battery is unreadable —
// the action below is a scroll-fix, not a battery-fix.
internal static class DeviceCapability
{
    internal readonly record struct Row(
        string ReadMethod,    // e.g. "Split-vendor 0x90 (Mode A)"
        string Status,        // e.g. "Battery OK", "Mode B — battery N/A", "Needs SDP-cache patch"
        string? ActionLabel,  // null = no action; else a clickable menu-item label
        string? ActionUrl);   // doc/remediation URL for ActionLabel (null = in-app action)

    // Map a device display name back to its Kind without changing the event signature.
    // NOTE: both "Magic Mouse 2024" KnownMice entries share one display name -> 10 distinct names.
    internal static DeviceKind? KindForName(string name)
    {
        foreach (var m in MouseBatteryDevice.KnownMice)
            if (string.Equals(m.DisplayName, name, StringComparison.OrdinalIgnoreCase))
                return m.Kind;
        foreach (var k in KeyboardBatteryDevice.KnownKeyboards)
            if (string.Equals(k.DisplayName, name, StringComparison.OrdinalIgnoreCase))
                return DeviceKind.MagicKeyboard;
        return null;
    }

    // Scroll-driver remediation copy for the matrix dropdown. The URLs are kept identical
    // to TrayApp.BuildMenu (:116-127) so the matrix and the top-level driver warning point
    // at the SAME remediation target. Labels intentionally DIFFER from BuildMenu: the
    // top-level item is "⚠ "-prefixed (e.g. "⚠ Install Apple Driver (scroll fix)") and uses
    // a capital "Driver"; nested in the matrix the ⚠ glyph is dropped. Do NOT assert label
    // equality between the two — only URL equality (see MagicMouseTray.Tests).
    static (string Label, string Url) ScrollFix(DriverStatus d) => d switch
    {
        DriverStatus.UnknownAppleMouse =>
            ("Unknown mouse model — check for app update",
             "https://github.com/ReviveBusiness/magic-mouse-tray/releases"),
        DriverStatus.NotBound =>
            ("Driver not bound — scroll fix needed",
             "https://github.com/ReviveBusiness/magic-mouse-tray#scroll-not-working"),
        _ => // NotInstalled (and any non-Ok fallthrough)
            ("Install Apple driver (scroll fix)",
             "https://github.com/tealtadpole/MagicMouse2DriversWin11x64"),
    };

    const string KbPatchAnchor   = "https://github.com/ReviveBusiness/magic-mouse-tray#keyboard-battery-patch";
    const string ScrollFixAnchor = "https://github.com/ReviveBusiness/magic-mouse-tray#scroll-not-working";

    internal static Row Describe(DeviceKind kind, int lastPct, DriverStatus driver)
    {
        switch (kind)
        {
            case DeviceKind.MagicMouseV1:
            case DeviceKind.MagicMouseV2:
                // Split-vendor 0x90 read works in Mode A regardless of the scroll filter.
                // Battery Status reflects the reading; any driver action is a SCROLL fix.
                if (driver != DriverStatus.Ok)
                {
                    var (lbl, url) = ScrollFix(driver);
                    return new("Split-vendor 0x90 (Mode A)",
                               lastPct >= 0 ? "Battery OK — scroll driver needs attention"
                                            : "No reading; scroll driver needs attention",
                               lbl, url);
                }
                return new("Split-vendor 0x90 (Mode A)",
                           lastPct >= 0 ? "Battery OK" : "No reading", null, null);

            case DeviceKind.MagicMouseV3:
                // v3 IS coupled to the filter: PATH-B recycle does FLIP:NoFilter -> read ->
                // FLIP:AppleFilter, which needs applewirelessmouse present for Mode B restore.
                if (lastPct >= 0)
                    return new("Split-vendor 0x90 via PATH-B recycle",
                               "Battery read OK (reverts to Mode B between reads)", null, null);
                if (lastPct == -2)
                {
                    // Mode B: battery N/A until the next idle-gated recycle.
                    if (driver != DriverStatus.Ok)
                    {
                        var (lbl, url) = ScrollFix(driver);
                        return new("Unified Feature 0x47 (blocked by Apple driver)",
                                   "Mode B — recycle needs the Apple scroll driver", lbl, url);
                    }
                    return new("Unified Feature 0x47 (blocked by Apple driver)",
                               "Mode B — battery N/A until next read",
                               "Read Battery Now", null); // in-app: V3RecycleManager.ForceReadNowAsync
                }
                return new("Split-vendor 0x90 via PATH-B recycle",
                           "No reading — check driver/pairing", "Scroll/driver help", ScrollFixAnchor);

            case DeviceKind.MagicKeyboard:
                // ACTIVE-READ target: -2 means "present but Feature 0x47 cap absent"
                // (unpatched or patch erased by re-pair) — KeyboardBatteryDevice.cs:122-127,138-139.
                if (lastPct >= 0)
                    return new("Feature 0x47 (after SDP-cache patch)", "OK", null, null);
                if (lastPct == -2)
                    return new("Feature 0x47 (Input-only until SDP-cache patch)",
                               "Needs SDP-cache patch",
                               "How to enable keyboard battery", KbPatchAnchor);
                return new("Feature 0x47 (after SDP-cache patch)",
                           "No reading (open/driver failure)", null, null);

            default:
                return new("Unknown", "Unsupported device", null, null);
        }
    }
}
