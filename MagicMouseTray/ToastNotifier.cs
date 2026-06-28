// SPDX-License-Identifier: MIT
using Microsoft.Win32;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace MagicMouseTray;

// Sends a Windows toast notification when battery crosses below the alert threshold.
// Registers an AUMID in HKCU on first call — no admin rights required.
// Requires Windows 10 1809+ (TFM net8.0-windows10.0.17763.0).
internal static class ToastNotifier
{
    const string Aumid = "MagicMouseTray.Battery";

    static bool _registered;
    static readonly object _regLock = new();

    internal static void Show(int pct, string deviceName)
    {
        try
        {
            EnsureAumid();

            string title = "Magic Mouse Battery Low";
            if (deviceName.IndexOf("Keyboard", StringComparison.OrdinalIgnoreCase) >= 0)
                title = "Magic Keyboard Battery Low";
            else if (deviceName.IndexOf("Trackpad", StringComparison.OrdinalIgnoreCase) >= 0)
                title = "Magic Trackpad Battery Low";

            var escapedName = System.Security.SecurityElement.Escape(deviceName) ?? deviceName;

            var doc = new XmlDocument();
            doc.LoadXml($"""
                <toast>
                    <visual><binding template="ToastGeneric">
                        <text>{title}</text>
                        <text>{escapedName} is at {pct}% — {(pct <= 10 ? "charge now!" : "charge soon")}</text>
                    </binding></visual>
                </toast>
                """);

            ToastNotificationManager
                .CreateToastNotifier(Aumid)
                .Show(new ToastNotification(doc));

            Logger.Log($"TOAST_SENT pct={pct} device={deviceName}");
        }
        catch (Exception ex)
        {
            Logger.Log($"TOAST_FAILED err={ex.Message}");
        }
    }

    internal static void ShowError(string title, string message)
    {
        try
        {
            EnsureAumid();
            var doc = new XmlDocument();
            doc.LoadXml($"""
                <toast>
                    <visual><binding template="ToastGeneric">
                        <text>{title}</text>
                        <text>{message}</text>
                    </binding></visual>
                </toast>
                """);
            ToastNotificationManager.CreateToastNotifier(Aumid).Show(new ToastNotification(doc));
            Logger.Log($"TOAST_ERROR title={title}");
        }
        catch (Exception ex) { Logger.Log($"TOAST_FAILED err={ex.Message}"); }
    }

    // Writes DisplayName under HKCU\SOFTWARE\Classes\AppUserModelId\<Aumid> so Windows
    // attributes the toast to "Magic Mouse Battery" rather than an anonymous app.
    static void EnsureAumid()
    {
        if (_registered) return;
        lock (_regLock)
        {
            if (_registered) return;
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(
                    $@"SOFTWARE\Classes\AppUserModelId\{Aumid}");
                key.SetValue("DisplayName", "Magic Mouse Battery");
            }
            catch { }
            _registered = true;
        }
    }
}
