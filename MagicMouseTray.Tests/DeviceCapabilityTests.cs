// SPDX-License-Identifier: MIT
using MagicMouseTray;
using Xunit;

namespace MagicMouseTray.Tests;

public class DeviceCapabilityTests
{
    static readonly DriverStatus[] AllDriverStates =
    {
        DriverStatus.Ok, DriverStatus.NotInstalled,
        DriverStatus.NotBound, DriverStatus.UnknownAppleMouse,
    };

    static readonly int[] AllSentinels = { 75, 0, -2, -1 }; // >=0, edge 0, blocked, absent

    // The remediation URLs the matrix is expected to point at, per DriverStatus. These are the
    // SAME URLs used by TrayApp.BuildMenu. We assert URL-equality only — labels intentionally
    // differ (BuildMenu prefixes "⚠ " and uses capital "Driver"); do NOT assert label equality.
    static string ScrollFixUrl(DriverStatus d) => d switch
    {
        DriverStatus.UnknownAppleMouse => "https://github.com/ReviveBusiness/magic-mouse-tray/releases",
        DriverStatus.NotBound          => "https://github.com/ReviveBusiness/magic-mouse-tray#scroll-not-working",
        _                              => "https://github.com/tealtadpole/MagicMouse2DriversWin11x64",
    };

    [Fact]
    public void Describe_CoversEveryCombination_WithoutThrowing()
    {
        foreach (DeviceKind kind in Enum.GetValues(typeof(DeviceKind)))
            foreach (var pct in AllSentinels)
                foreach (var drv in AllDriverStates)
                {
                    var row = DeviceCapability.Describe(kind, pct, drv);
                    Assert.False(string.IsNullOrWhiteSpace(row.ReadMethod));
                    Assert.False(string.IsNullOrWhiteSpace(row.Status));
                    // An action with a label may or may not carry a URL (null URL = in-app action).
                    if (row.ActionUrl is not null)
                        Assert.NotNull(row.ActionLabel);
                }
    }

    [Theory]
    [InlineData(DeviceKind.MagicMouseV1)]
    [InlineData(DeviceKind.MagicMouseV2)]
    public void V1V2_BatteryStatus_DrivenByLastPct_NeverBlockedWhenReadable(DeviceKind kind)
    {
        // A readable battery (>=0) must never be reported as blocked/unreadable, regardless of driver.
        foreach (var drv in AllDriverStates)
        {
            var ok = DeviceCapability.Describe(kind, 50, drv);
            Assert.StartsWith("Battery OK", ok.Status);

            // When the driver is non-Ok, the action is a SCROLL fix whose URL matches BuildMenu's.
            if (drv != DriverStatus.Ok)
            {
                Assert.NotNull(ok.ActionUrl);
                Assert.Equal(ScrollFixUrl(drv), ok.ActionUrl);
            }
            else
            {
                Assert.Null(ok.ActionUrl);
            }
        }
    }

    [Fact]
    public void V3_ModeB_OffersInAppReadAction_WithNullUrl()
    {
        var row = DeviceCapability.Describe(DeviceKind.MagicMouseV3, -2, DriverStatus.Ok);
        Assert.Equal("Read Battery Now", row.ActionLabel);
        Assert.Null(row.ActionUrl); // in-app action, not a link
    }

    [Fact]
    public void V3_ReadOk_HasNoAction()
    {
        var row = DeviceCapability.Describe(DeviceKind.MagicMouseV3, 88, DriverStatus.Ok);
        Assert.Null(row.ActionLabel);
        Assert.Null(row.ActionUrl);
    }

    [Fact]
    public void Keyboard_Unpatched_LinksToPatchDoc()
    {
        var row = DeviceCapability.Describe(DeviceKind.MagicKeyboard, -2, DriverStatus.Ok);
        Assert.Equal("Needs SDP-cache patch", row.Status);
        Assert.Equal("https://github.com/ReviveBusiness/magic-mouse-tray#keyboard-battery-patch", row.ActionUrl);
    }

    [Fact]
    public void Keyboard_Patched_IsOk_NoAction()
    {
        var row = DeviceCapability.Describe(DeviceKind.MagicKeyboard, 60, DriverStatus.Ok);
        Assert.Equal("OK", row.Status);
        Assert.Null(row.ActionLabel);
    }

    [Fact]
    public void Mouse_NonOkDriver_ActionUrl_MatchesBuildMenuUrls()
    {
        // URL parity with the top-level driver warning, asserted for v1/v2 Mode-A reads.
        foreach (var drv in new[] { DriverStatus.NotInstalled, DriverStatus.NotBound, DriverStatus.UnknownAppleMouse })
        {
            var row = DeviceCapability.Describe(DeviceKind.MagicMouseV1, -1, drv);
            Assert.Equal(ScrollFixUrl(drv), row.ActionUrl);
        }
    }
}
