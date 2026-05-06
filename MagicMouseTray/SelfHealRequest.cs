// SPDX-License-Identifier: MIT
// SelfHealRequest.cs — Phase 4-Ω elevation bridge.
//
// Tray runs in user context; PnP Disable+Enable requires admin. We use the
// existing MM-Dev-Cycle scheduled task pattern (RunLevel=HighestAvailable):
//
//   1. Write request to C:\mm-dev-queue\request.txt
//   2. schtasks.exe /run /tn 'MM-Dev-Cycle' (no UAC prompt — the task is
//      pre-registered with admin rights)
//   3. The task runner picks up FLIP:AppleFilter (or similar) and runs
//      mm-state-flip.ps1 -Mode AppleFilter, which detects LF unchanged
//      and runs disable+enable anyway (the recycle we want)
//   4. result.txt contains "EXITCODE|NONCE" for verification
//
// First-run install: SelfHealInstaller registers the MM-Dev-Cycle task IF NOT
// already registered. This requires one UAC elevation at install time only.
//
// If the scheduled task isn't installed and elevation isn't possible, returns
// false; caller (SelfHealManager) gives up and enters Failed state.

using System.Diagnostics;
using System.IO;
using System.Threading;

namespace MagicMouseTray;

internal enum FlipPhase { NoFilter, AppleFilter }

internal static class SelfHealRequest
{
    const string QueueDir = @"C:\mm-dev-queue";
    const string RequestFile = @"C:\mm-dev-queue\request.txt";
    const string ResultFile  = @"C:\mm-dev-queue\result.txt";
    const string TaskName = "MM-Dev-Cycle";

    // Phase that triggers a no-op LowerFilters mutation + a forced disable+enable.
    // mm-state-flip.ps1 detects "already in target state" but still runs the
    // recycle, which is exactly what we want.
    const string PhaseAppleFilter = "FLIP:AppleFilter";

    // Phase that removes applewirelessmouse from LowerFilters → Mode A (COL02 present).
    // PATH-B: used to expose COL02 for battery read. Requires FLIP:AppleFilter after.
    const string PhaseNoFilter = "FLIP:NoFilter";

    /// <summary>
    /// Submits FLIP:AppleFilter (Mode B restore). Fire-and-forget — does not wait for completion.
    /// Backward-compat wrapper for SelfHealManager.
    /// </summary>
    internal static bool RequestRecycle()
        => TriggerFlip(PhaseAppleFilter);

    /// <summary>
    /// Submits a flip phase and waits for the MM-Dev-Cycle task to report completion.
    /// Polls result.txt for up to timeoutMs. Returns true if task completed with exit 0.
    /// Used by V3RecycleManager for synchronous flip-and-wait sequencing.
    /// </summary>
    internal static bool SubmitFlipAndWait(FlipPhase phase, int timeoutMs = 30_000)
    {
        var phaseStr = phase == FlipPhase.NoFilter ? PhaseNoFilter : PhaseAppleFilter;
        var nonce = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();

        if (!WriteRequest(phaseStr, nonce)) return false;
        if (!StartTask(phaseStr)) return false;

        // Poll result.txt for EXITCODE|NONCE match
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            Thread.Sleep(100);
            try
            {
                if (!File.Exists(ResultFile)) continue;
                var raw = File.ReadAllText(ResultFile).Trim();
                if (!raw.EndsWith($"|{nonce}")) continue;

                var exitCode = int.TryParse(raw.Split('|', 2)[0], out var rc) ? rc : -1;
                Logger.Log($"FLIP phase={phaseStr} exitCode={exitCode} nonce={nonce}");
                return exitCode == 0;
            }
            catch { }
        }

        Logger.Log($"FLIP timeout phase={phaseStr} nonce={nonce} after {timeoutMs}ms");
        return false;
    }

    static bool TriggerFlip(string phase)
    {
        var nonce = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
        if (!WriteRequest(phase, nonce)) return false;
        return StartTask(phase);
    }

    static bool WriteRequest(string phase, string nonce)
    {
        try
        {
            if (!Directory.Exists(QueueDir))
            {
                Logger.Log($"SELFHEAL queue dir missing at {QueueDir} — task not installed?");
                return false;
            }
            File.WriteAllText(RequestFile, $"{phase}|{nonce}");
            Logger.Log($"FLIP queued: phase={phase} nonce={nonce}");
            return true;
        }
        catch (Exception ex)
        {
            Logger.Log($"FLIP write exception: {ex.Message}");
            return false;
        }
    }

    static bool StartTask(string phase)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = $"/run /tn \"{TaskName}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var p = Process.Start(psi);
            if (p is null) { Logger.Log("SELFHEAL Process.Start returned null"); return false; }
            p.WaitForExit(5000);
            if (p.ExitCode != 0) { Logger.Log($"SELFHEAL schtasks.exe exit={p.ExitCode}"); return false; }
            return true;
        }
        catch (Exception ex)
        {
            Logger.Log($"SELFHEAL start exception: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Optional: poll result.txt for the latest result. Useful for diagnostics.
    /// Returns the exit code of the most recent task run, or -1 if unparseable.
    /// </summary>
    internal static int LastTaskExitCode()
    {
        try
        {
            if (!File.Exists(ResultFile)) return -1;
            var raw = File.ReadAllText(ResultFile).Trim();
            var parts = raw.Split('|', 2);
            if (parts.Length == 0) return -1;
            return int.TryParse(parts[0], out var rc) ? rc : -1;
        }
        catch
        {
            return -1;
        }
    }
}
