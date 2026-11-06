namespace OsbManager.Core.Status;

public sealed record StatsLine(long Milliseconds, long Kills, long? Experience, long? Gold, long Deaths, long Sox);

public sealed record StatsTotal(long Milliseconds, long Kills, double? KillsPerHour, long Experience, double? ExperiencePerHour,
    long Gold, double? GoldPerHour, long Deaths, long Sox);

/// <summary>
/// The "All characters" row. The accounts hunt at the same time, so its hunting time is the longest session, not the sum,
/// and each per-hour figure is the sum of the accounts' own rates.
/// </summary>
public static class StatsTotals
{
    public static double? Rate(long? value, long milliseconds) =>
        value is null || milliseconds < 30_000 ? null : value.Value * 3_600_000.0 / milliseconds;

    public static StatsTotal Sum(IReadOnlyCollection<StatsLine> lines)
    {
        static double? Total(IEnumerable<double?> rates)
        {
            var known = rates.Where(r => r is not null).ToList();
            return known.Count == 0 ? null : known.Sum();
        }
        return new StatsTotal(
            lines.Count == 0 ? 0 : lines.Max(l => l.Milliseconds),
            lines.Sum(l => l.Kills),
            Total(lines.Select(l => Rate(l.Kills, l.Milliseconds))),
            lines.Sum(l => l.Experience ?? 0),
            Total(lines.Select(l => Rate(l.Experience, l.Milliseconds))),
            lines.Sum(l => l.Gold ?? 0),
            Total(lines.Select(l => Rate(l.Gold, l.Milliseconds))),
            lines.Sum(l => l.Deaths),
            lines.Sum(l => l.Sox));
    }
}
