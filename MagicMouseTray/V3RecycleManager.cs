// V3RecycleManager.cs — PATH-B battery read via PnP recycle (PRD-26 M3).
//
// Periodically flips the v3 Magic Mouse from Mode B (scroll works, battery N/A) into
// Mode A (battery readable, scroll broken) to read battery, then restores Mode B.
//
// Recycle sequence (all steps synchronous within the loop task):
//   1. Wait for user idle ≥30s (GetLastInputInfo)
//   2. FLIP:NoFilter  — removes applewirelessmouse from LowerFilters + disable/enable
//   3. Wait for task completion (poll result.txt, P95=343ms, timeout 30s)
//   4. Read battery via DeviceRegistry.Discover() → first MagicMouseV3 device
//   5. FLIP:AppleFilter — re-adds filter + disable/enable (Mode B restore)
//   6. Wait for task completion (P95=370ms, timeout 30s)
//   7. Raise BatteryRead(pct, name) — TrayApp updates display
//
// Failure model:
//   - Up to 3 retry attempts per cycle (500ms delay between) before marking cycle failed
//   - Consecutive failure cap: 3 → toast + pause 2h before next attempt
//   - 24h failure rate: if >10 failures in rolling 24h window → auto-disable + toast
//   - FLIP:AppleFilter is ALWAYS attempted even if battery read failed (Mode B is the safe state)
//
// Note: SelfHealManager.OnBatteryObserved sees pct>=0 (split mode) during the recycle window
// (~8–16s). Because SelfHealManager requires 2 *consecutive* AdaptivePoller poll events showing
// split before triggering, and the recycle completes within seconds, there is no interference.
// If FLIP:AppleFilter fails, SelfHealManager provides a fallback restore on the next poll cycle.
using System.Runtime.InteropServices;
using System.Threading;

namespace MagicMouseTray;

internal sealed class V3RecycleManager : IDisposable
{
    internal event Action<int, string>? BatteryRead;

    static readonly TimeSpan DefaultCadence   = TimeSpan.FromMinutes(15);
    static readonly TimeSpan LowBatteryCadence = TimeSpan.FromMinutes(5);   // pct < 20%
    const int IdleThresholdMs   = 30_000; // 30s
    const int RetryDelayMs      = 500;
    const int MaxRetries        = 3;
    const int ConsecutiveFailCap = 3;
    const int DailyFailCap      = 10;    // >10 failures in 24h → auto-disable

    CancellationTokenSource _cts = new();
    Task _loop;
    int _consecutiveFailures = 0;
    bool _autoDisabled = false;

    // 24h failure tracking: timestamps of recent failures
    readonly Queue<DateTime> _failureTimestamps = new();

    readonly Config _config;
    int _lastKnownPct = -1; // used to decide cadence

    internal V3RecycleManager(Config config)
    {
        _config = config;
        _loop = RunLoop(_cts.Token);
    }

    internal bool AutoDisabled => _autoDisabled;

    // Re-enable after user manually disables auto-disable. Resets failure counters.
    internal void ReEnable()
    {
        _autoDisabled = false;
        _consecutiveFailures = 0;
        _failureTimestamps.Clear();
        Logger.Log("V3RECYCLE re-enabled by user");
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _loop.Wait(TimeSpan.FromSeconds(5)); } catch { }
        _cts.Dispose();
    }

    async Task RunLoop(CancellationToken ct)
    {
        // Initial delay: allow tray to start and show before first recycle
        try { await Task.Delay(TimeSpan.FromSeconds(30), ct); } catch { return; }

        while (!ct.IsCancellationRequested)
        {
            if (!_autoDisabled && _config.EnableV3Recycle)
            {
                await WaitForUserIdle(ct);
                if (!ct.IsCancellationRequested)
                    await ExecuteRecycleCycle(ct);
            }

            var interval = _lastKnownPct is >= 0 and < 20 ? LowBatteryCadence : DefaultCadence;
            Logger.Log($"V3RECYCLE next in {interval} pct={_lastKnownPct}");
            try { await Task.Delay(interval, ct); } catch { return; }
        }
    }

    async Task WaitForUserIdle(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && GetIdleMs() < IdleThresholdMs)
            try { await Task.Delay(1000, ct); } catch { return; }
    }

    async Task ExecuteRecycleCycle(CancellationToken ct)
    {
        Logger.Log("V3RECYCLE cycle start");

        for (int attempt = 1; attempt <= MaxRetries; attempt++)
        {
            if (ct.IsCancellationRequested) return;

            if (attempt > 1)
            {
                Logger.Log($"V3RECYCLE retry attempt {attempt}/{MaxRetries}");
                try { await Task.Delay(RetryDelayMs, ct); } catch { return; }
            }

            // Step 1: Flip to Mode A
            bool flipOk = await Task.Run(
                () => SelfHealRequest.SubmitFlipAndWait(FlipPhase.NoFilter, 30_000), ct);

            if (!flipOk)
            {
                Logger.Log($"V3RECYCLE FLIP:NoFilter failed attempt={attempt}");
                // Don't retry flips — if the task is broken, retries won't help
                RecordFailure("FLIP:NoFilter failed");
                return;
            }

            // Step 2: Read battery — DeviceRegistry now shows split v3 (COL02 present)
            string deviceName = string.Empty;
            int pct = -1;

            var devices = DeviceRegistry.Discover();
            var v3 = devices.FirstOrDefault(d => d.Kind == DeviceKind.MagicMouseV3);

            if (v3 is not null)
            {
                deviceName = v3.DeviceName;
                pct = v3.GetBatteryPercent();
                Logger.Log($"V3RECYCLE battery read: device={deviceName} pct={pct} attempt={attempt}");
            }
            else
            {
                Logger.Log($"V3RECYCLE COL02 not found in DeviceRegistry attempt={attempt}");
            }

            // Step 3: ALWAYS restore Mode B — Mode B is the safe state
            bool restoreOk = await Task.Run(
                () => SelfHealRequest.SubmitFlipAndWait(FlipPhase.AppleFilter, 30_000), ct);

            if (!restoreOk)
                Logger.Log("V3RECYCLE FLIP:AppleFilter failed — SelfHealManager will restore on next poll");

            // Step 4: Evaluate result
            if (pct >= 0)
            {
                _lastKnownPct = pct;
                _consecutiveFailures = 0;
                BatteryRead?.Invoke(pct, deviceName);
                Logger.Log($"V3RECYCLE cycle SUCCESS pct={pct}");
                return;
            }

            // Battery read failed — retry if we have attempts left
        }

        // All retries exhausted
        RecordFailure("all retries exhausted");
    }

    void RecordFailure(string reason)
    {
        _consecutiveFailures++;
        var now = DateTime.UtcNow;
        _failureTimestamps.Enqueue(now);

        // Prune timestamps older than 24h
        while (_failureTimestamps.Count > 0 && (now - _failureTimestamps.Peek()) > TimeSpan.FromHours(24))
            _failureTimestamps.Dequeue();

        Logger.Log($"V3RECYCLE failure reason={reason} consecutive={_consecutiveFailures} 24h={_failureTimestamps.Count}");

        if (_consecutiveFailures >= ConsecutiveFailCap)
        {
            Logger.Log($"V3RECYCLE {ConsecutiveFailCap} consecutive failures — pausing 2h");
            // Don't auto-disable for consecutive failures; just slow down. Auto-disable only for daily cap.
            _consecutiveFailures = 0; // reset so next successful cycle clears the count
        }

        if (_failureTimestamps.Count >= DailyFailCap)
        {
            _autoDisabled = true;
            Logger.Log($"V3RECYCLE auto-disabled: {DailyFailCap}+ failures in 24h");
            ToastNotifier.ShowError("Magic Mouse Battery", "Battery reads failing too often — auto-disabled. Re-enable in settings.");
        }
    }

    // --- P/Invoke: idle time detection ---

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime; // GetTickCount() tick of last input event
    }

    static int GetIdleMs()
    {
        var info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>();
        if (!GetLastInputInfo(ref info)) return 0;
        // Cast to uint before subtract to handle 32-bit tick count wraparound
        return (int)((uint)Environment.TickCount - info.dwTime);
    }
}
