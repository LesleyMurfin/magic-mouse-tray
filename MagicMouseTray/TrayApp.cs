// SPDX-License-Identifier: MIT
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MagicMouseTray;

// Manages the system tray icon, right-click menu, and battery change display.
// All UI updates are marshaled to the WPF dispatcher (NotifyIcon requires STA thread).
internal sealed class TrayApp : IDisposable
{
    readonly NotifyIcon _tray;
    readonly Config _config;
    readonly AdaptivePoller _poller;
    readonly ToolStripMenuItem[] _thresholdItems;
    readonly ToolStripMenuItem _startupItem;

    // Per-device battery state, keyed by device name. Updated per poll event.
    // Cleared when no devices are detected (empty name from AdaptivePoller).
    readonly Dictionary<string, int> _deviceBatteries = new(StringComparer.OrdinalIgnoreCase);

    // Per-device menu items for live battery display in the right-click menu.
    readonly Dictionary<string, ToolStripMenuItem> _deviceMenuItems = new(StringComparer.OrdinalIgnoreCase);
    ToolStripMenuItem? _deviceSection;

    // Alert boundaries fired per-device this drain cycle. Cleared per-device when battery recovers.
    readonly Dictionary<string, HashSet<int>> _firedBoundaries = new(StringComparer.OrdinalIgnoreCase);

    // Persistent critical alert shown at 1%; auto-closed when mouse unplugs.
    CriticalAlert? _criticalAlert;

    // Not readonly: recomputed on menu Opening so a just-applied driver fix shows without restart.
    DriverStatus _driverStatus;
    readonly V3RecycleManager _recycleManager;

    Icon? _currentIcon;

    // Cached base image (loaded once from embedded resource)
    static Bitmap? _mouseOutline;   // magic-mouse.png — white fill, black border
    static readonly object _bitmapLock = new();

    internal TrayApp(Config config)
    {
        _config = config;
        (_thresholdItems, _startupItem) = (null!, null!); // assigned by BuildMenu

        _driverStatus = DriverHealthChecker.GetStatus();
        var menu = BuildMenu(out _thresholdItems, out _startupItem);

        _currentIcon = MakeIcon(-1, false, _driverStatus != DriverStatus.Ok);
        _tray = new NotifyIcon
        {
            Icon = _currentIcon,
            ContextMenuStrip = menu,
            Visible = true,
            Text = "Magic Mouse Battery — starting..."
        };

        _poller = new AdaptivePoller(_config);
        _poller.BatteryChanged += OnBatteryChanged;

        _recycleManager = new V3RecycleManager(_config);
        _recycleManager.BatteryRead += OnBatteryChanged;

        // Start polling only after every field OnBatteryChanged touches (_recycleManager,
        // _poller) is assigned — the first poll cycle can raise BatteryChanged, and
        // OnBatteryChanged dereferences _recycleManager in UpdateTrayIcon.
        _poller.Start();
    }

    ContextMenuStrip BuildMenu(
        out ToolStripMenuItem[] thresholdItems,
        out ToolStripMenuItem startupItem)
    {
        var menu = new ContextMenuStrip();

        // Recompute driver status + rebuild the matrix on every open so a just-applied
        // driver fix shows without restart. GetStatus() is registry-only and fast.
        menu.Opening += (_, _) => { _driverStatus = DriverHealthChecker.GetStatus(); UpdateDeviceMenuItems(); };

        // --- Device battery status (dynamically updated) ---
        _deviceSection = new ToolStripMenuItem("Devices") { Enabled = false };
        menu.Items.Add(_deviceSection);
        menu.Items.Add(new ToolStripSeparator());

        // --- Low Battery Threshold submenu ---
        var thresholdMenu = new ToolStripMenuItem("Low Battery Threshold");
        thresholdItems = new[] { 10, 15, 20, 25 }.Select(t =>
        {
            var item = new ToolStripMenuItem($"{t}%")
            {
                Tag = t,
                Checked = t == _config.Threshold
            };
            item.Click += (_, _) => OnThresholdClick(t);
            return item;
        }).ToArray();
        thresholdMenu.DropDownItems.AddRange(thresholdItems);
        menu.Items.Add(thresholdMenu);

        // --- Start with Windows ---
        startupItem = new ToolStripMenuItem("Start with Windows")
        {
            Checked = _config.StartWithWindows
        };
        startupItem.Click += (_, _) =>
        {
            _config.SetStartWithWindows(!_config.StartWithWindows);
            _startupItem.Checked = _config.StartWithWindows;
        };
        menu.Items.Add(startupItem);

        menu.Items.Add(new ToolStripSeparator());

        // --- Driver warning (shown when scroll driver is missing, unbound, or unknown model) ---
        if (_driverStatus != DriverStatus.Ok)
        {
            var (label, url) = _driverStatus switch
            {
                DriverStatus.UnknownAppleMouse =>
                    ("⚠ Unknown mouse model — check for app update",
                     "https://github.com/ReviveBusiness/magic-mouse-tray/releases"),
                DriverStatus.NotBound =>
                    ("⚠ Driver not bound — scroll fix needed",
                     "https://github.com/ReviveBusiness/magic-mouse-tray#scroll-not-working"),
                _ =>
                    ("⚠ Install Apple Driver (scroll fix)",
                     "https://github.com/tealtadpole/MagicMouse2DriversWin11x64"),
            };
            var driverItem = new ToolStripMenuItem(label) { ForeColor = System.Drawing.Color.OrangeRed };
            driverItem.Click += (_, _) =>
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url)
                    { UseShellExecute = true });
            menu.Items.Add(driverItem);
            menu.Items.Add(new ToolStripSeparator());
        }

        // --- Battery Reads toggle (PATH-B v3 recycle on/off) ---
        var battReadItem = new ToolStripMenuItem("Battery Reads [On]")
        {
            Checked = _config.EnableV3Recycle
        };
        battReadItem.Click += (_, _) =>
        {
            _config.SetEnableV3Recycle(!_config.EnableV3Recycle);
            battReadItem.Text = _config.EnableV3Recycle ? "Battery Reads [On]" : "Battery Reads [Off]";
            battReadItem.Checked = _config.EnableV3Recycle;
            if (_config.EnableV3Recycle) _recycleManager.ReEnable();
        };
        menu.Items.Add(battReadItem);

        // --- Refresh Now ---
        var refresh = new ToolStripMenuItem("Refresh Now");
        refresh.Click += (_, _) => _poller.RefreshNow();
        menu.Items.Add(refresh);

        // --- Diagnostics (debug surface). The v3 "Read Battery Now" action is also
        //     surfaced contextually in the per-device matrix dropdown. ---
        var diagnostics = new ToolStripMenuItem("Diagnostics");

        var readNow = new ToolStripMenuItem("Read Battery Now");
        readNow.Click += (_, _) => _ = _recycleManager.ForceReadNowAsync();
        diagnostics.DropDownItems.Add(readNow);

        var testToast = new ToolStripMenuItem("Test Notification");
        testToast.Click += (_, _) =>
        {
            var (name, pct) = _deviceBatteries.FirstOrDefault(kv => kv.Value >= 0);
            ToastNotifier.Show(pct >= 0 ? pct : 15, name?.Length > 0 ? name : "Magic Mouse");
        };
        diagnostics.DropDownItems.Add(testToast);

        var openLogs = new ToolStripMenuItem("Open Logs");
        openLogs.Click += (_, _) => OpenLogsInEditor();
        diagnostics.DropDownItems.Add(openLogs);

        var openDiagFolder = new ToolStripMenuItem("Open Diagnostics Folder");
        openDiagFolder.Click += (_, _) => OpenDiagnosticsFolder();
        diagnostics.DropDownItems.Add(openDiagFolder);

        menu.Items.Add(diagnostics);

        menu.Items.Add(new ToolStripSeparator());

        // --- Quit ---
        var quit = new ToolStripMenuItem("Quit");
        quit.Click += (_, _) =>
        {
            Dispose();
            System.Windows.Application.Current.Shutdown();
        };
        menu.Items.Add(quit);

        return menu;
    }

    void OnThresholdClick(int value)
    {
        _config.SetThreshold(value);
        foreach (var item in _thresholdItems)
            item.Checked = (int)item.Tag! == _config.Threshold;
    }

    // Opens debug.log in Notepad++ if installed, falls back to notepad.exe.
    // Notepad++ tail-follows the file (Settings > Misc > File Status Auto-Detection).
    void OpenLogsInEditor()
    {
        var logPath = Logger.LogPath;
        if (!System.IO.File.Exists(logPath))
        {
            System.IO.Directory.CreateDirectory(Logger.LogDir);
            System.IO.File.WriteAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] Log file created on demand from tray.\r\n");
        }

        var npp = FindNotepadPlusPlus();
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo
            {
                FileName = npp ?? "notepad.exe",
                Arguments = $"\"{logPath}\"",
                UseShellExecute = true
            };
            System.Diagnostics.Process.Start(psi);
            Logger.Log($"OPEN_LOGS editor={(npp ?? "notepad.exe")} path={logPath}");
        }
        catch (Exception ex)
        {
            Logger.Log($"OPEN_LOGS_FAIL err={ex.Message}");
        }
    }

    void OpenDiagnosticsFolder()
    {
        try
        {
            System.IO.Directory.CreateDirectory(Logger.LogDir);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"\"{Logger.LogDir}\"",
                UseShellExecute = true
            });
            Logger.Log($"OPEN_DIAG_FOLDER path={Logger.LogDir}");
        }
        catch (Exception ex)
        {
            Logger.Log($"OPEN_DIAG_FOLDER_FAIL err={ex.Message}");
        }
    }

    static string? FindNotepadPlusPlus()
    {
        string[] candidates =
        {
            @"C:\Program Files\Notepad++\notepad++.exe",
            @"C:\Program Files (x86)\Notepad++\notepad++.exe",
        };
        foreach (var c in candidates)
            if (System.IO.File.Exists(c)) return c;
        return null;
    }

    void OnBatteryChanged(int pct, string name)
    {
        // Marshal to WPF/STA thread — NotifyIcon was created there
        System.Windows.Application.Current.Dispatcher.Invoke(() =>
        {
            if (string.IsNullOrEmpty(name))
            {
                // Sentinel from AdaptivePoller: no devices found this cycle — clear all state
                _deviceBatteries.Clear();
                _firedBoundaries.Clear();
            }
            else
            {
                _deviceBatteries[name] = pct;

                // Per-device alert boundaries
                if (pct < 0 || pct >= _config.Threshold)
                {
                    _firedBoundaries.Remove(name);
                }
                else
                {
                    if (!_firedBoundaries.TryGetValue(name, out var fired))
                        _firedBoundaries[name] = fired = new HashSet<int>();

                    var boundaries = _config.Threshold > 10
                        ? new[] { _config.Threshold, 10 }
                        : new[] { _config.Threshold };

                    foreach (var boundary in boundaries)
                    {
                        if (pct < boundary && fired.Add(boundary))
                        {
                            ToastNotifier.Show(pct, name);
                            break;
                        }
                    }
                }

                // Critical alert at 1% — use first device that hits it
                if (pct == 1 && _criticalAlert == null)
                {
                    _criticalAlert = new CriticalAlert(pct, name);
                    _criticalAlert.FormClosed += (_, _) => _criticalAlert = null;
                    _criticalAlert.Show();
                    Logger.Log($"CRITICAL_ALERT_SHOWN device={name} pct={pct}");
                }
            }

            // Close critical alert when all devices are gone or the alerting device reconnects
            if (_criticalAlert != null && (_deviceBatteries.Count == 0 ||
                _deviceBatteries.Values.All(p => p < 0)))
            {
                _criticalAlert.Close();
                Logger.Log("CRITICAL_ALERT_CLOSED reason=no_devices");
            }

            UpdateTrayIcon();
        });
    }

    void UpdateTrayIcon()
    {
        // Icon driven by the lowest valid battery across all devices
        int lowestPct = _deviceBatteries.Count == 0
            ? -1
            : _deviceBatteries.Values.Aggregate(-1, (acc, p) =>
                p >= 0 ? (acc < 0 ? p : Math.Min(acc, p)) : acc);

        bool anyLow = lowestPct >= 0 && lowestPct < _config.Threshold;

        var newIcon = MakeIcon(lowestPct, anyLow, _driverStatus != DriverStatus.Ok);
        var oldIcon = _currentIcon;
        _tray.Icon = newIcon;
        _currentIcon = newIcon;
        oldIcon?.Dispose();

        // Tooltip: list all devices, truncate to 63 chars (Windows limit)
        string tip;
        if (_deviceBatteries.Count == 0)
        {
            tip = "Magic Mouse Battery — no devices detected";
        }
        else
        {
            var parts = _deviceBatteries.Select(kv =>
            {
                var pctStr = kv.Value switch {
                    >= 0 => $"{kv.Value}%",
                    -2   => "N/A",
                    _    => "—",
                };
                return $"{kv.Key}: {pctStr}";
            });
            var joined = string.Join(" | ", parts);
            // Show V3RecycleManager interval if v3 has a valid reading; otherwise AdaptivePoller
            var hasV3Reading = _deviceBatteries.Any(kv =>
                kv.Key.Contains("2024", StringComparison.OrdinalIgnoreCase) && kv.Value >= 0);
            var interval = hasV3Reading ? _recycleManager.NextInterval : _poller.LastInterval;
            tip = $"{joined} · {FormatInterval(interval)}";
            if (_driverStatus != DriverStatus.Ok) tip = $"⚠ {tip}";
        }

        _tray.Text = tip.Length > 63 ? tip[..63] : tip;
        Logger.Log($"TRAY_UPDATE devices={_deviceBatteries.Count} lowest={lowestPct} tooltip=\"{_tray.Text}\"");
        UpdateDeviceMenuItems();
    }

    void UpdateDeviceMenuItems()
    {
        if (_deviceSection is null) return;

        if (_deviceBatteries.Count == 0)
        {
            _deviceSection.Text = "No devices detected";
            // Empty-state guidance (non-clickable child hint).
            _deviceSection.Enabled = true; // enable so the hint dropdown is reachable
            _deviceSection.DropDownItems.Clear();
            _deviceSection.DropDownItems.Add(new ToolStripMenuItem(
                "Pair a Magic Mouse/Keyboard via Bluetooth, then Refresh Now") { Enabled = false });
            // Drop any stale per-device rows
            foreach (var key in _deviceMenuItems.Keys.ToList())
            {
                _tray.ContextMenuStrip?.Items.Remove(_deviceMenuItems[key]);
                _deviceMenuItems.Remove(key);
            }
            return;
        }

        _deviceSection.Enabled = false;
        _deviceSection.DropDownItems.Clear();

        foreach (var kv in _deviceBatteries)
        {
            var pctStr = kv.Value switch {
                >= 0 => $"{kv.Value}%",
                -2   => "N/A (Mode B)",
                _    => "—"
            };

            var rate = DrainRateTracker.GetDrainRatePctPerHour(kv.Key);
            var rateStr = rate > 0.001 ? $"  {rate:F2}%/h" : string.Empty;
            var label = $"{kv.Key}: {pctStr}{rateStr}";

            if (!_deviceMenuItems.TryGetValue(kv.Key, out var item))
            {
                item = new ToolStripMenuItem(label);   // enabled — carries the matrix dropdown
                _deviceMenuItems[kv.Key] = item;
                // Insert before the separator that follows the device section
                var sepIdx = _tray.ContextMenuStrip!.Items.IndexOf(_deviceSection) + 1;
                _tray.ContextMenuStrip.Items.Insert(sepIdx, item);
            }
            else
            {
                item.Text = label;
            }

            // Capability matrix dropdown for this device.
            item.DropDownItems.Clear();
            var knd = DeviceCapability.KindForName(kv.Key);
            if (knd is { } k)
            {
                var row = DeviceCapability.Describe(k, kv.Value, _driverStatus);
                item.DropDownItems.Add(new ToolStripMenuItem($"Read method: {row.ReadMethod}") { Enabled = false });
                item.DropDownItems.Add(new ToolStripMenuItem($"Status: {row.Status}") { Enabled = false });
                if (row.ActionLabel is { } al)
                {
                    var action = new ToolStripMenuItem(al) { ForeColor = System.Drawing.Color.OrangeRed };
                    if (row.ActionUrl is { } url)
                        action.Click += (_, _) => System.Diagnostics.Process.Start(
                            new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
                    else // in-app action (today only v3 "Read Battery Now")
                    {
                        // ForceReadNowAsync runs the FLIP cycle unconditionally, so if Battery
                        // Reads is Off or recycle auto-disabled it would no-op/RecordFailure
                        // silently. Gate the action on the live recycle state.
                        bool canRead = _config.EnableV3Recycle && !_recycleManager.AutoDisabled;
                        action.Enabled = canRead;
                        if (canRead) action.Click += (_, _) => _ = _recycleManager.ForceReadNowAsync();
                        else action.Text = al + " (enable Battery Reads first)";
                    }
                    item.DropDownItems.Add(action);
                }
            }
        }

        // Remove stale items for devices no longer present
        foreach (var key in _deviceMenuItems.Keys.Except(_deviceBatteries.Keys).ToList())
        {
            _tray.ContextMenuStrip?.Items.Remove(_deviceMenuItems[key]);
            _deviceMenuItems.Remove(key);
        }

        _deviceSection.Text = $"Devices ({_deviceBatteries.Count})";
    }

    static string FormatInterval(TimeSpan t)
        => t.TotalHours >= 1 ? $"{(int)t.TotalHours}h" : $"{(int)t.TotalMinutes}m";

    public void Dispose()
    {
        _recycleManager.BatteryRead -= OnBatteryChanged;
        _recycleManager.Dispose();
        _poller.BatteryChanged -= OnBatteryChanged;
        _poller.Dispose();
        _criticalAlert?.Close();
        _tray.Visible = false;
        _tray.Dispose();
        _currentIcon?.Dispose();
    }

    // --- Icon generation ---
    // Loads the Magic Mouse outline PNG from embedded resources and tints it by battery level.
    // White interior pixels become the tier color; black border pixels stay black.
    // Falls back to the simple battery-bar if the resource is missing.
    //
    // Tint colors (applied via ColorMatrix — white→color, black stays black):
    //   disconnected (-1)  → gray
    //   below threshold    → orange-red
    //   >50%               → green
    //   ≥20%               → yellow
    //   ≥10%               → orange
    //   <10%               → red

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr hIcon);

    static Bitmap? LoadEmbedded(string name)
    {
        try
        {
            var stream = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream($"MagicMouseTray.{name}");
            return stream is null ? null : new Bitmap(stream);
        }
        catch { return null; }
    }

    static Bitmap? GetOutline()
    {
        if (_mouseOutline != null) return _mouseOutline;
        lock (_bitmapLock)
        {
            _mouseOutline ??= LoadEmbedded("magic-mouse.png");
            return _mouseOutline;
        }
    }

    static Icon MakeIcon(int pct, bool isLow, bool driverMissing = false)
    {
        using var bmp = new Bitmap(16, 16, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(Color.Transparent);

        var (r, gv, b) = TintColor(pct, isLow);
        var baseImg = GetOutline();

        if (baseImg != null)
        {
            // ColorMatrix: white→tint color, black stays black, alpha preserved
            using var ia = new ImageAttributes();
            ia.SetColorMatrix(new ColorMatrix(new float[][]
            {
                new float[] { r,   0f,  0f, 0f, 0f },
                new float[] { 0f, gv,   0f, 0f, 0f },
                new float[] { 0f,  0f,  b,  0f, 0f },
                new float[] { 0f,  0f,  0f, 1f, 0f },
                new float[] { 0f,  0f,  0f, 0f, 1f },
            }));
            g.DrawImage(baseImg,
                new Rectangle(0, 0, 16, 16),
                0, 0, baseImg.Width, baseImg.Height,
                GraphicsUnit.Pixel, ia);
        }
        else
        {
            // Fallback: simple colored rectangle if resource missing
            using var fb = new SolidBrush(Color.FromArgb(
                (int)(r * 255), (int)(gv * 255), (int)(b * 255)));
            g.FillRectangle(fb, 1, 1, 14, 14);
        }

        // Driver-missing badge: 3×3 yellow dot in top-right corner
        if (driverMissing)
        {
            using var dot = new SolidBrush(Color.FromArgb(255, 220, 30));
            g.FillRectangle(dot, 13, 0, 3, 3);
        }

        var hIcon = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(hIcon).Clone();
        DestroyIcon(hIcon);
        return icon;
    }

    static (float R, float G, float B) TintColor(int pct, bool isLow) => (pct, isLow) switch
    {
        (-1, _)       => (0.65f, 0.65f, 0.65f),  // gray — disconnected
        (_, true)     => (1.0f,  0.25f, 0.05f),  // orange-red — below threshold
        ( > 50, _)    => (0.25f, 1.0f,  0.25f),  // green
        ( >= 20, _)   => (1.0f,  1.0f,  0.1f),   // yellow
        ( >= 10, _)   => (1.0f,  0.55f, 0.0f),   // orange
        _             => (1.0f,  0.15f, 0.15f),  // red — critical
    };
}
