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

namespace MagicMouseTray;

internal static class SelfHealRequest
{
    const string QueueDir = @"C:\mm-dev-queue";
    const string RequestFile = @"C:\mm-dev-queue\request.txt";
    const string ResultFile  = @"C:\mm-dev-queue\result.txt";
    const string TaskName = "MM-Dev-Cycle";

    // Phase that triggers a no-op LowerFilters mutation + a forced disable+enable.
    // mm-state-flip.ps1 detects "already in target state" but still runs the
    // recycle, which is exactly what we want.
    const string Phase = "FLIP:AppleFilter";

    /// <summary>
    /// Submits a recycle request via the MM-Dev-Cycle queue + triggers the task.
    /// Returns true if the queue was written + task triggered. Does NOT wait for
    /// completion — caller polls result.txt or waits for next BatteryChanged.
    /// </summary>
    internal static bool RequestRecycle()
    {
        try
        {
            if (!Directory.Exists(QueueDir))
            {
                Logger.Log($"SELFHEAL queue dir missing at {QueueDir} — task not installed?");
                return false;
            }

            var nonce = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
            File.WriteAllText(RequestFile, $"{Phase}|{nonce}");
            Logger.Log($"SELFHEAL request queued: phase={Phase} nonce={nonce}");

            // Trigger via schtasks.exe /run — non-elevated invocation works because
            // the task has Principal RunLevel=HighestAvailable.
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
            if (p is null)
            {
                Logger.Log("SELFHEAL Process.Start returned null");
                return false;
            }

            // Don't block the poll thread — fire and forget; the task runs async.
            p.WaitForExit(5000);
            if (p.ExitCode != 0)
            {
                Logger.Log($"SELFHEAL schtasks.exe exit={p.ExitCode}");
                return false;
            }

            return true;
        }
        catch (Exception ex)
        {
            Logger.Log($"SELFHEAL request exception: {ex.Message}");
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
