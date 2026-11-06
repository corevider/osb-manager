namespace OsbManager.Core.Telemetry;

public static class Backoff
{
    public static TimeSpan Next(int failures, double random)
    {
        var exponent = Math.Clamp(failures, 1, 20);
        var ceiling = TimeSpan.FromTicks(Math.Min(TelemetryLimits.BackoffCap.Ticks, TelemetryLimits.BackoffBase.Ticks * (1L << exponent)));
        var wait = TimeSpan.FromTicks((long)(ceiling.Ticks * Math.Clamp(random, 0, 1)));
        return wait < TelemetryLimits.MinWait ? TelemetryLimits.MinWait : wait;
    }

    public static TimeSpan RetryAfter(TimeSpan? header, double random, int failures) =>
        header is { } value
            ? Clamp(value)
            : Next(failures, random);

    public static TimeSpan Clamp(TimeSpan wait) =>
        wait < TelemetryLimits.MinWait ? TelemetryLimits.MinWait : wait > TelemetryLimits.MaxWait ? TelemetryLimits.MaxWait : wait;

    public static TimeSpan Jitter(TimeSpan interval, double random) =>
        TimeSpan.FromTicks((long)(interval.Ticks * (0.9 + 0.2 * Math.Clamp(random, 0, 1))));

    public static TimeSpan StartDelay(double random) =>
        TelemetryLimits.StartDelayMin + TimeSpan.FromTicks((long)((TelemetryLimits.StartDelayMax - TelemetryLimits.StartDelayMin).Ticks * Math.Clamp(random, 0, 1)));
}
