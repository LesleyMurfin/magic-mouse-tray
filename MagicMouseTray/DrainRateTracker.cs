// DrainRateTracker.cs — Per-device battery drain rate estimation.
//
// Records (timestamp, pct) pairs per device and computes %/hour drain rate from
// observed history. Both AdaptivePoller and V3RecycleManager call Record() after
// each successful read, then GetNextInterval() to schedule the next poll.
//
// Interval logic:
//   pct >= 20%  → 24h (battery lasts days — daily check is sufficient)
//   pct <  20%  → rate-based if ≥2 readings exist:
//                   hoursToThreshold / 3  (3 checks before hitting threshold)
//                 fallback formula if no rate data:
//                   3h × 2^((pct − 20) / 10)
//                   at 20%=3h, 10%=1.5h, 5%=~64m, 2%=~50m
//   pct <  0    → minInterval (device not found — recheck soon)
//
// Empirical baseline: Magic Mouse v3 drains ~0.33%/hour under normal use
// (2% over 6h observed 2026-05-07). At that rate 20%→threshold(15%)=~15h.

namespace MagicMouseTray;

internal static class DrainRateTracker
{
    const int MaxReadings = 5;

    // Floor intervals by device type — v3 has scroll-glitch cost per recycle
    internal static readonly TimeSpan FloorV3      = TimeSpan.FromMinutes(5);
    internal static readonly TimeSpan FloorNonV3   = TimeSpan.FromMinutes(30);
    internal static readonly TimeSpan CeilingNormal = TimeSpan.FromHours(24);

    readonly record struct Reading(DateTime Time, int Pct);

    static readonly Dictionary<string, Queue<Reading>> _history =
        new(StringComparer.OrdinalIgnoreCase);
    static readonly object _lock = new();

    // Record a successful battery reading for a device.
    internal static void Record(string device, int pct)
    {
        if (pct < 0 || string.IsNullOrEmpty(device)) return;
        lock (_lock)
        {
            if (!_history.TryGetValue(device, out var q))
                _history[device] = q = new Queue<Reading>(MaxReadings);
            q.Enqueue(new Reading(DateTime.UtcNow, pct));
            while (q.Count > MaxReadings) q.Dequeue();
        }
    }

    // Returns %/hour drain rate (positive = battery decreasing). 0 if insufficient data.
    internal static double GetDrainRatePctPerHour(string device)
    {
        lock (_lock)
        {
            if (!_history.TryGetValue(device, out var q) || q.Count < 2) return 0;
            var arr  = q.ToArray();
            var hours = (arr[^1].Time - arr[0].Time).TotalHours;
            if (hours < 0.1) return 0; // less than 6 minutes — noise
            var drop = arr[0].Pct - arr[^1].Pct;
            return drop > 0 ? drop / hours : 0;
        }
    }

    // Returns estimated hours remaining until pct hits threshold. -1 if unknown.
    internal static double GetHoursToThreshold(string device, int pct, int threshold)
    {
        if (pct <= threshold) return 0;
        var rate = GetDrainRatePctPerHour(device);
        if (rate <= 0.001) return -1;
        return (pct - threshold) / rate;
    }

    // Next check interval. isV3=true applies the higher floor (scroll-glitch cost).
    internal static TimeSpan GetNextInterval(string device, int pct, int threshold, bool isV3)
    {
        var floor = isV3 ? FloorV3 : FloorNonV3;

        if (pct < 0) return floor;          // disconnected — poll at floor rate
        if (pct >= threshold) return CeilingNormal; // healthy — once a day

        TimeSpan interval;
        var rate = GetDrainRatePctPerHour(device);

        if (rate > 0.001)
        {
            // Rate-based: target 3 checks before hitting threshold
            var hoursLeft = Math.Max(0, pct - threshold) / rate;
            interval = TimeSpan.FromHours(hoursLeft / 3.0);
        }
        else
        {
            // No rate data — exponential formula anchored at threshold=3h
            var hours = 3.0 * Math.Pow(2.0, (pct - (double)threshold) / 10.0);
            interval = TimeSpan.FromHours(hours);
        }

        if (interval < floor)           return floor;
        if (interval > CeilingNormal)   return CeilingNormal;
        return interval;
    }
}
