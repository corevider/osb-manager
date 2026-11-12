#if DEBUG
namespace OsbManager;

internal sealed class ScaledTimeProvider(double scale) : TimeProvider
{
    private readonly DateTimeOffset origin = TimeProvider.System.GetUtcNow();
    private readonly long originStamp = TimeProvider.System.GetTimestamp();

    public override DateTimeOffset GetUtcNow() => origin + TimeSpan.FromTicks((long)((TimeProvider.System.GetTimestamp() - originStamp) * (TimeSpan.TicksPerSecond / (double)TimeProvider.System.TimestampFrequency) * scale));

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) =>
        new ScaledTimer(TimeProvider.System.CreateTimer(callback, state, Shrink(dueTime), Shrink(period)), Shrink);

    private TimeSpan Shrink(TimeSpan value) => value == Timeout.InfiniteTimeSpan ? value : TimeSpan.FromTicks((long)(value.Ticks / scale));

    private sealed class ScaledTimer(ITimer inner, Func<TimeSpan, TimeSpan> shrink) : ITimer
    {
        public bool Change(TimeSpan dueTime, TimeSpan period) => inner.Change(shrink(dueTime), shrink(period));

        public void Dispose() => inner.Dispose();

        public ValueTask DisposeAsync() => inner.DisposeAsync();
    }
}

internal static class TelemetryTestSwitches
{
    public static Uri? BaseUrl { get; } = Uri.TryCreate(Environment.GetEnvironmentVariable("OSBMANAGER_TEST_API_URL"), UriKind.Absolute, out var url) ? url : null;

    public static double TimeScale { get; } = double.TryParse(Environment.GetEnvironmentVariable("OSBMANAGER_TEST_TIME_SCALE"), System.Globalization.CultureInfo.InvariantCulture, out var scale) && scale >= 1 ? scale : 1;

    public static bool ConsentOnAtStart { get; } = Environment.GetEnvironmentVariable("OSBMANAGER_TEST_CONSENT") == "1";

    public static int? WithdrawAfterSeconds { get; } = int.TryParse(Environment.GetEnvironmentVariable("OSBMANAGER_TEST_WITHDRAW_AFTER"), out var seconds) && seconds > 0 ? seconds : null;

    public static string? LatencyLog { get; } = Environment.GetEnvironmentVariable("OSBMANAGER_TEST_LATENCY_LOG");

    public static string? DialogShots { get; } = Environment.GetEnvironmentVariable("OSBMANAGER_TEST_DIALOG_SHOTS");
}
#endif
