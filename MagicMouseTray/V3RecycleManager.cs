// V3RecycleManager.cs — PATH-B battery read via PnP recycle (PRD-26 M3).
//
// Periodically flips the v3 Magic Mouse from Mode B (scroll works, battery N/A) into
// Mode A (battery readable, scroll broken) to read battery, then restores Mode B.
//
// Recycle sequence (all steps synchronous within the loop task):
//   0. Pre-check: confirm device is in Mode B (IsV3InModeA() == false)
//   1. Wait for user idle ≥30s (GetLastInputInfo)
//   2. FLIP:NoFilter  — removes applewirelessmouse from LowerFilters + disable/enable
//   3. Verify Mode A reached: poll HID paths for col02 presence (P95 <500ms, timeout 2s)
//   4. Read battery via DeviceRegistry.Discover() → first MagicMouseV3 device
//   5. FLIP:AppleFilter — re-adds filter + disable/enable (Mode B restore)
//   6. Verify Mode B restored: poll HID paths, confirm unified path openable (timeout 5s)
//      mouhid.sys binds asynchronously — exit=0 from MM-Dev-Cycle ≠ mouhid bound.
//      Up to 3 FLIP:AppleFilter retries if Mode B not confirmed (live fix: 2026-05-06).
//   7. Raise BatteryRead(pct, name) — TrayApp updates display
//
// Failure model:
//   - Up to 3 battery-read retry attempts per cycle (500ms delay between)
//   - FLIP:NoFilter failure → RecordFailure + return immediately (task broken)
//   - Mode B restore failure → critical toast + RecordFailure + return (unsafe state)
//   - Consecutive failure cap: 3 → log + reset counter
//   - 24h failure rate: >10 failures → auto-disable + toast
//
// Note: SelfHealManager.OnBatteryObserved sees pct>=0 (split mode) during the recycle window
// (~8–16s). Because SelfHealManager requires 2 *consecutive* AdaptivePoller poll events showing
// split before triggering, and the recycle completes within seconds, there is no interference.
//
// Mode A entry recovery (2026-05-08): if the device is found in Mode A at cycle start
// (e.g., post-reboot, prior cycle crashed mid-flip), the cycle now reads battery directly
// from col02 and then restores Mode B — instead of skipping and waiting for SelfHealManager.
// This eliminates a deadlock observed when SelfHealManager fails to fire post-boot: the
// recycler used to skip every cycle indefinitely, leaving stale battery cache and no alerts.
using System.Runtime.InteropServices;
using System.Threading;

namespace MagicMouseTray;

internal sealed class V3RecycleManager : IDisposable
{
    internal event Action<int, string>? BatteryRead;

    const int IdleThresholdMs    = 30_000; // 30s
    const int RetryDelayMs       = 500;
    const int MaxRetries         = 3;
    const int MaxRestoreAttempts = 3;      // FLIP:AppleFilter retries for Mode B restore
    const int ModeAVerifyMs      = 5_000;  // poll budget for Mode A + col02 DN_STARTED (empirical: ~16ms path + ~1000ms pipeline ready)
    const int ModeBVerifyMs      = 8_000;  // poll budget for Mode B confirmation. LowerFilters is registry-based (set before disable+enable by FLIP:AppleFilter, available immediately). HID path settling after re-enable is ~1-4s empirically, 8s is conservative.
    const int ConsecutiveFailCap = 3;
    const int DailyFailCap       = 10;    // >10 failures in 24h → auto-disable

    CancellationTokenSource _cts = new();
    Task _loop;
    int _consecutiveFailures = 0;
    bool _autoDisabled = false;

    // 24h failure tracking: timestamps of recent failures
    readonly Queue<DateTime> _failureTimestamps = new();

    readonly Config _config;
    int _lastKnownPct = -1;
    string _lastKnownDevice = "Magic Mouse 2024";

    // Exposed for TrayApp tooltip — set after each cycle completes.
    internal TimeSpan NextInterval { get; private set; } = DrainRateTracker.CeilingNormal;

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

    // Force an immediate battery read cycle, bypassing idle wait.
    // Used by the tray menu "Read Battery Now" action and for testing.
    internal async Task ForceReadNowAsync()
    {
        Logger.Log("V3RECYCLE force-triggered by user");
        await ExecuteRecycleCycle(_cts.Token);
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

            var interval = DrainRateTracker.GetNextInterval(
                _lastKnownDevice, _lastKnownPct, _config.Threshold, isV3: true);
            NextInterval = interval;
            Logger.Log($"V3RECYCLE next in {interval} pct={_lastKnownPct} rate={DrainRateTracker.GetDrainRatePctPerHour(_lastKnownDevice):F3}%/h");
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

        // Pre-check 1: BT stack health — BTHENUM parent must be DN_STARTED before we flip.
        // If BTHENUM is not started, the wedge is pre-existing; flipping would fail and
        // leave the device in an unknown state. Let SelfHealManager handle recovery.
        bool btHealthy = await Task.Run(HidNative.IsV3BtStackHealthy, ct);
        Logger.Log($"V3RECYCLE pre-check BTHENUM healthy={btHealthy}");
        if (!btHealthy)
        {
            // Pre-existing wedge — not caused by this manager. Do NOT count against
            // the failure budget; SelfHealManager handles BTHENUM recovery.
            Logger.Log("V3RECYCLE pre-check: BTHENUM not DN_STARTED — skipping cycle, BT stack wedged");
            return;
        }

        // Pre-check 2: device state at entry.
        // - Mode B (normal): full cycle = FLIP:NoFilter -> read -> FLIP:AppleFilter
        // - Mode A (recovery): skip the FLIP:NoFilter step on attempt 1, read directly,
        //   then FLIP:AppleFilter to restore. Earlier code skipped the cycle entirely
        //   and deferred to SelfHealManager — that created a deadlock when SelfHeal
        //   failed to fire post-reboot, leaving battery stale forever.
        bool startedInModeA = await Task.Run(IsV3InModeA, ct);
        if (startedInModeA)
        {
            Logger.Log("V3RECYCLE pre-check: device already in Mode A — read battery directly, then restore Mode B");
        }

        for (int attempt = 1; attempt <= MaxRetries; attempt++)
        {
            if (ct.IsCancellationRequested) return;

            if (attempt > 1)
            {
                Logger.Log($"V3RECYCLE retry attempt {attempt}/{MaxRetries}");
                try { await Task.Delay(RetryDelayMs, ct); } catch { return; }
            }

            // Step 1: Flip to Mode A — unless we started there on attempt 1.
            // On retries (attempt > 1), the previous attempt restored Mode B, so we
            // always need FLIP:NoFilter to get back into Mode A.
            bool needsFlipToA = !(startedInModeA && attempt == 1);

            if (needsFlipToA)
            {
                bool flipOk = await Task.Run(
                    () => SelfHealRequest.SubmitFlipAndWait(FlipPhase.NoFilter, 30_000), ct);

                if (!flipOk)
                {
                    Logger.Log($"V3RECYCLE FLIP:NoFilter failed attempt={attempt}");
                    // Task failure is not transient — retrying won't help
                    RecordFailure("FLIP:NoFilter failed");
                    return;
                }
            }
            else
            {
                Logger.Log("V3RECYCLE skip FLIP:NoFilter — device already in Mode A at cycle entry");
            }

            // Step 2: Verify Mode A reached (col02 collection visible in HID paths)
            // mouhid releases the device during disable/enable — poll until col02 appears
            bool modeAReached = await Task.Run(() => WaitForModeA(ModeAVerifyMs), ct);
            Logger.Log($"V3RECYCLE mode_a_reached={modeAReached} attempt={attempt}");

            // Step 3: Read battery (only if Mode A confirmed — col02 must be present)
            string deviceName = string.Empty;
            int pct = -1;

            if (modeAReached)
            {
                // In Mode A, both col01 (mouse) and col02 (vendor battery) HID paths are present.
                // DeviceRegistry.Discover() returns the first VID/PID match — col01 may precede col02
                // in SetupDi enumeration order. col01's UsagePage is the standard HID mouse page, so
                // GetBatteryPercent() returns -1 silently (splitVendor=false). Target col02 explicitly.
                var col02Path = HidNative.EnumerateHidPaths()
                    .FirstOrDefault(p => IsV3Path(p) &&
                        p.Contains("col02", StringComparison.OrdinalIgnoreCase));

                if (col02Path is not null)
                {
                    deviceName = "Magic Mouse 2024";
                    Logger.Log($"V3RECYCLE col02 path found: {col02Path}");
                    var dev = new MouseBatteryDevice(col02Path, deviceName, DeviceKind.MagicMouseV3);
                    // HID report pipeline may not be ready immediately after col02 DN_STARTED.
                    // Empirical: GLE=121 (attempt 1) → GLE=21 (attempts 2-3) → success at ~1000ms.
                    // 5 retries at 500ms covers 0–2500ms; readTry=3 (~1000ms) should succeed.
                    for (int readTry = 1; readTry <= 5 && pct < 0; readTry++)
                    {
                        if (readTry > 1) Thread.Sleep(500);
                        pct = dev.GetBatteryPercent();
                        Logger.Log($"V3RECYCLE battery read: device={deviceName} pct={pct} attempt={attempt} readTry={readTry}");
                    }
                }
                else
                {
                    Logger.Log($"V3RECYCLE col02 path not found in HID enumeration attempt={attempt}");
                }
            }

            // Step 4: ALWAYS restore Mode B — Mode B is the safe state.
            // FLIP:AppleFilter exit=0 does NOT guarantee mouhid.sys has rebound (async).
            // RestoreModeBWithRetry retries FLIP:AppleFilter and verifies with HID path polling.
            bool restored = await Task.Run(RestoreModeBWithRetry, ct);

            if (!restored)
            {
                Logger.Log("V3RECYCLE CRITICAL: Mode B restore failed after all retries — mouhid may not be bound");
                ToastNotifier.ShowError("Magic Mouse Battery",
                    "Mouse scroll may be broken. Unplug/replug cable or toggle Battery Reads in menu.");
                RecordFailure("Mode B restore failed");
                return; // Do NOT retry battery read — device state is unknown
            }

            Logger.Log("V3RECYCLE Mode B confirmed restored");

            // Step 5: Evaluate result
            if (pct >= 0)
            {
                _lastKnownPct = pct;
                _lastKnownDevice = deviceName;
                _consecutiveFailures = 0;
                DrainRateTracker.Record(deviceName, pct);
                BatteryRead?.Invoke(pct, deviceName);
                Logger.Log($"V3RECYCLE cycle SUCCESS pct={pct} rate={DrainRateTracker.GetDrainRatePctPerHour(deviceName):F3}%/h hoursLeft={DrainRateTracker.GetHoursToThreshold(deviceName, pct, _config.Threshold):F1}");
                return;
            }

            // Battery read failed but Mode B is intact — retry the full cycle
        }

        // All retries exhausted with successful Mode B restores each time
        RecordFailure("all retries exhausted");
    }

    // Attempts FLIP:AppleFilter up to MaxRestoreAttempts times, verifying Mode B after each.
    // mouhid.sys binds asynchronously — WaitForModeB polls until the unified path is accessible.
    bool RestoreModeBWithRetry()
    {
        for (int i = 1; i <= MaxRestoreAttempts; i++)
        {
            if (i > 1)
            {
                Logger.Log($"V3RECYCLE FLIP:AppleFilter retry {i}/{MaxRestoreAttempts} — Mode B not yet confirmed");
                Thread.Sleep(500);
            }

            bool flipOk = SelfHealRequest.SubmitFlipAndWait(FlipPhase.AppleFilter, 30_000);
            Logger.Log($"V3RECYCLE FLIP:AppleFilter attempt={i} ok={flipOk}");

            if (WaitForModeB(ModeBVerifyMs))
                return true;

            Logger.Log($"V3RECYCLE Mode B not confirmed after FLIP:AppleFilter attempt={i}/{MaxRestoreAttempts}");
        }

        return false;
    }

    // Polls until v3 col02 path exists AND its devnode has DN_STARTED.
    // col02 appears in HID enumeration before the HID class driver finishes initialising
    // the device — DN_STARTED is the empirical proof the stack is ready for GetInputReport.
    static bool WaitForModeA(int timeoutMs)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        do
        {
            if (HidNative.IsV3Col02Ready()) return true;
            Thread.Sleep(100);
        } while (Environment.TickCount64 < deadline);
        return false;
    }

    // Polls until the v3 unified path appears (no col0x) and applewirelessmouse.sys is
    // in the kernel stack (Mode B). Empirical P95 latency: ~563ms (2026-05-07).
    // Returns true if Mode B confirmed within timeoutMs.
    static bool WaitForModeB(int timeoutMs)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        do
        {
            if (IsV3InModeB()) return true;
            Thread.Sleep(100);
        } while (Environment.TickCount64 < deadline);
        return false;
    }

    // True if any HID path is a v3 Magic Mouse in Mode A (col02 collection present in path).
    static bool IsV3InModeA() =>
        HidNative.EnumerateHidPaths().Any(p =>
            IsV3Path(p) &&
            p.Contains("col02", StringComparison.OrdinalIgnoreCase));

    // True if a v3 Magic Mouse is in Mode B: unified HID path exists (no col0x splits)
    // AND applewirelessmouse.sys is in the active kernel stack (DEVPKEY_Device_Stack).
    // DEVPKEY_Device_Stack is the authoritative Mode B discriminator — the entry only
    // appears after the filter driver loads following FLIP:AppleFilter + enable.
    // mouhid.sys DN_STARTED (Mouse class device) is a false positive in Mode A: mouhid
    // stays bound to col01 and DN_STARTED remains True even when the device is in Mode A.
    // Empirical: real WaitForModeB latency ~563ms (confirmed 2026-05-07).
    static bool IsV3InModeB()
    {
        var v3Paths = HidNative.EnumerateHidPaths()
            .Where(IsV3Path)
            .ToList();

        if (v3Paths.Count == 0) return false;

        // In Mode B all v3 HID paths are unified — no &col0x collection suffixes
        if (v3Paths.Any(p => p.Contains("&col0", StringComparison.OrdinalIgnoreCase)))
            return false;

        // Confirm applewirelessmouse.sys is in the active kernel stack
        return HidNative.IsApplewirelessmouseInStack();
    }

    // True if the HID device path belongs to a Magic Mouse v3 (BT or USB).
    static bool IsV3Path(string path) =>
        (path.Contains("0001004c", StringComparison.OrdinalIgnoreCase) &&
         path.Contains("pid&0323", StringComparison.OrdinalIgnoreCase)) ||
        (path.Contains("vid_05ac", StringComparison.OrdinalIgnoreCase) &&
         path.Contains("pid_0323", StringComparison.OrdinalIgnoreCase));

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
            Logger.Log($"V3RECYCLE {ConsecutiveFailCap} consecutive failures — pausing until next cadence interval");
            _consecutiveFailures = 0; // reset so next successful cycle clears the count
        }

        if (_failureTimestamps.Count >= DailyFailCap)
        {
            _autoDisabled = true;
            Logger.Log($"V3RECYCLE auto-disabled: {DailyFailCap}+ failures in 24h");
            ToastNotifier.ShowError("Magic Mouse Battery", "Battery reads failing too often — auto-disabled. Re-enable in settings.");
        }
    }

    // --- Cursor-position idle detection ---
    // GetLastInputInfo is system-wide: keyboard, any HID device, keep-alive apps all reset it.
    // For recycle purposes we only care that the mouse cursor has not moved — if the cursor
    // is stationary the mouse flip is safe regardless of other input activity.

    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT lpPoint);

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X; public int Y; }

    static POINT   _lastCursorPos;
    static long    _lastCursorMoveTick = Environment.TickCount64;

    static int GetIdleMs()
    {
        GetCursorPos(out var pos);
        if (pos.X != _lastCursorPos.X || pos.Y != _lastCursorPos.Y)
        {
            _lastCursorPos = pos;
            _lastCursorMoveTick = Environment.TickCount64;
        }
        return (int)(Environment.TickCount64 - _lastCursorMoveTick);
    }
}
