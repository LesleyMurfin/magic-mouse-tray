// SPDX-License-Identifier: MIT
using System.Linq;
using MagicMouseTray;
using Xunit;

namespace MagicMouseTray.Tests;

public class KindForNameTests
{
    [Fact]
    public void AllKnownMouseNames_ResolveToTheirKind()
    {
        foreach (var m in MouseBatteryDevice.KnownMice)
            Assert.Equal(m.Kind, DeviceCapability.KindForName(m.DisplayName));
    }

    [Fact]
    public void AllKnownKeyboardNames_ResolveToMagicKeyboard()
    {
        foreach (var k in KeyboardBatteryDevice.KnownKeyboards)
            Assert.Equal(DeviceKind.MagicKeyboard, DeviceCapability.KindForName(k.DisplayName));
    }

    [Fact]
    public void TenDistinctDisplayNames_AllResolve()
    {
        // 4 mouse entries (two "Magic Mouse 2024" share one name) + 7 keyboards = 10 distinct names.
        var names = MouseBatteryDevice.KnownMice.Select(m => m.DisplayName)
            .Concat(KeyboardBatteryDevice.KnownKeyboards.Select(k => k.DisplayName))
            .Distinct(System.StringComparer.OrdinalIgnoreCase)
            .ToList();

        Assert.Equal(10, names.Count);
        Assert.All(names, n => Assert.NotNull(DeviceCapability.KindForName(n)));
    }

    [Fact]
    public void UnknownName_ReturnsNull()
    {
        Assert.Null(DeviceCapability.KindForName("Logitech MX Master"));
        Assert.Null(DeviceCapability.KindForName(""));
    }
}
