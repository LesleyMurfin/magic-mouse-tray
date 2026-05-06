// SPDX-License-Identifier: MIT
namespace MagicMouseTray;

// Polls all discovered Apple HID battery devices at adaptive intervals.
// Tiers: >50%=2h  |  20-50%=30m  |  10-20%=10m  |  <10% or disconnected=5m
//
// BatteryChanged is raised from a thread-pool thread — callers must marshal
// to the UI thread before touching WPF/NotifyIcon objects (done in TrayApp).
//
// Interval is driven by the lowest battery level across all discovered devices.
// pct=-1 (no devices) falls into the <10 tier — recheck frequently.
internal sealed class AdaptivePoller : IDisposable
{
    // Fired once per discovered device per poll cycle.
    // percent sentinel values: -1=not found/disconnected, -2=present but unreadable (Mode B).
    internal event Action<int, string>? BatteryChanged;

    CancellationTokenSource _cts = new();
    Task? _pollTask;

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
            if (devices.Count == 0)
            {
                // No devices — fire a single synthetic event so callers can clear state
                BatteryChanged?.Invoke(-1, string.Empty);
            }
            else
            {
                foreach (var device in devices)
                {
                    int pct = device.GetBatteryPercent();
                    BatteryChanged?.Invoke(pct, device.DeviceName);
                    if (pct >= 0 && (lowestPct < 0 || pct < lowestPct))
                        lowestPct = pct;
                }
            }

            var interval = GetInterval(lowestPct);
            Logger.Log($"POLL_SCHEDULED devices={devices.Count} lowest_pct={lowestPct} next_in={interval}");

            try { await Task.Delay(interval, ct); }
            catch (TaskCanceledException) { break; }
        }
    }

    // Returns the polling interval based on the lowest battery level across all devices.
    // lowestPct=-1 (no devices or all unreadable) → recheck frequently.
    internal static TimeSpan GetInterval(int lowestPct) => lowestPct switch
    {
        > 50  => TimeSpan.FromHours(2),
        >= 20 => TimeSpan.FromMinutes(30),
        >= 10 => TimeSpan.FromMinutes(10),
        _     => TimeSpan.FromMinutes(5),
    };
}
