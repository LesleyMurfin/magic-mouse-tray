// SPDX-License-Identifier: MIT
namespace MagicMouseTray;

// Polls all discovered Apple HID battery devices at adaptive intervals driven by
// DrainRateTracker. Records each reading into DrainRateTracker so subsequent
// intervals reflect the observed drain rate.
//
// BatteryChanged is raised from a thread-pool thread — callers must marshal
// to the UI thread before touching WPF/NotifyIcon objects (done in TrayApp).
//
// v3 Magic Mouse in Mode B returns pct=-2 (unreadable) — not recorded into
// DrainRateTracker; V3RecycleManager owns v3 drain tracking.
internal sealed class AdaptivePoller : IDisposable
{
    // Fired once per discovered device per poll cycle.
    // percent sentinel values: -1=not found/disconnected, -2=present but unreadable (Mode B).
    internal event Action<int, string>? BatteryChanged;

    // Last computed interval — readable by TrayApp for tooltip.
    internal TimeSpan LastInterval { get; private set; } = TimeSpan.FromMinutes(5);

    readonly Config _config;
    CancellationTokenSource _cts = new();
    Task? _pollTask;

    internal AdaptivePoller(Config config) => _config = config;

    internal void Start() => _pollTask = PollLoop(_cts.Token);

    // Cancels the current wait and polls immediately. Safe to call from any thread.
    internal void RefreshNow()
    {
        var old = Interlocked.Exchange(ref _cts, new CancellationTokenSource());
        old.Cancel();
        old.Dispose();
        _pollTask = PollLoop(_cts.Token);
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _pollTask?.Wait(TimeSpan.FromSeconds(5)); } catch { }
        _cts.Dispose();
    }

    async Task PollLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var devices = DeviceRegistry.Discover();

            int lowestPct = -1;
            string lowestDevice = string.Empty;

            if (devices.Count == 0)
            {
                BatteryChanged?.Invoke(-1, string.Empty);
            }
            else
            {
                foreach (var device in devices)
                {
                    int pct = device.GetBatteryPercent();
                    BatteryChanged?.Invoke(pct, device.DeviceName);

                    if (pct >= 0)
                    {
                        // Record into drain tracker (skip v3 Mode-B -2 and -1 failures)
                        DrainRateTracker.Record(device.DeviceName, pct);

                        if (lowestPct < 0 || pct < lowestPct)
                        {
                            lowestPct = pct;
                            lowestDevice = device.DeviceName;
                        }
                    }
                }
            }

            // Interval driven by the lowest readable device (non-v3 path — v3 cadence
            // is owned by V3RecycleManager). Use DrainRateTracker for non-v3 devices.
            var lowestIsV3 = devices.FirstOrDefault(d => d.DeviceName == lowestDevice)
                                     ?.Kind == DeviceKind.MagicMouseV3;
            var interval = DrainRateTracker.GetNextInterval(
                lowestDevice, lowestPct, _config.Threshold, lowestIsV3);
            LastInterval = interval;

            Logger.Log($"POLL_SCHEDULED devices={devices.Count} lowest_pct={lowestPct} next_in={interval}");

            try { await Task.Delay(interval, ct); }
            catch (TaskCanceledException) { break; }
        }
    }
}
