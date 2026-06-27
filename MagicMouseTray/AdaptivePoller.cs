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

    // Per-device read budget. A synchronous HID IOCTL (HidD_GetFeature / HidD_GetInputReport)
    // can block indefinitely on a wedged device, and before this guard one stuck device froze
    // the whole poll loop so POLL_SCHEDULED never fired and no battery ever reached the tray.
    static readonly TimeSpan DeviceReadTimeout = TimeSpan.FromSeconds(5);

    internal AdaptivePoller(Config config) => _config = config;

    // Reads one device's battery with a hard timeout and exception guard so a single slow or
    // throwing device can't stall the poll loop. On timeout/throw the device is logged (so the
    // culprit is identifiable) and treated as unreadable (-1), matching the disconnected sentinel.
    static int ReadBatteryGuarded(IBatteryDevice device, TimeSpan timeout)
    {
        try
        {
            var read = Task.Run(device.GetBatteryPercent);
            if (read.Wait(timeout))
                return read.Result;

            Logger.Log($"POLL_DEVICE_TIMEOUT device={device.DeviceName} after={timeout} (read abandoned, treated as -1)");
            return -1;
        }
        catch (Exception ex)
        {
            Logger.Log($"POLL_DEVICE_ERROR device={device.DeviceName} err={ex.GetBaseException().Message}");
            return -1;
        }
    }

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
        // Detach from the caller (TrayApp ctor via Start(), or RefreshNow()) so the first cycle
        // runs on a thread-pool thread rather than synchronously up to the first await. This honors
        // the "BatteryChanged is raised from a thread-pool thread" contract and keeps tray startup
        // from blocking on device I/O or re-entering a half-constructed TrayApp.
        await Task.Yield();

        while (!ct.IsCancellationRequested)
        {
            // Default to the last good interval so a faulted cycle still re-polls instead of
            // spinning. The whole cycle body is guarded: PollLoop is an unobserved Task, so any
            // throw here (Discover, a device read, or the BatteryChanged dispatch) would otherwise
            // fault it silently and stop polling forever — the keyboard-never-surfaces stall.
            var interval = LastInterval;
            try
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
                        int pct = ReadBatteryGuarded(device, DeviceReadTimeout);
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
                interval = DrainRateTracker.GetNextInterval(
                    lowestDevice, lowestPct, _config.Threshold, lowestIsV3);
                LastInterval = interval;

                Logger.Log($"POLL_SCHEDULED devices={devices.Count} lowest_pct={lowestPct} next_in={interval}");
            }
            catch (Exception ex)
            {
                var root = ex.GetBaseException();
                Logger.Log($"POLL_CYCLE_ERROR type={root.GetType().Name} err={root.Message}");
            }

            try { await Task.Delay(interval, ct); }
            catch (TaskCanceledException) { break; }
        }
    }
}
