#if DEBUG
using System.Diagnostics;
using System.Globalization;

namespace OsbManager;

internal static class LatencyProbe
{
    private static readonly object Sync = new();
    private static readonly List<string> Pending = [];
    private static readonly Dictionary<string, double> LastArrival = new();
    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static readonly string? Path = TelemetryTestSwitches.LatencyLog;
    private static readonly System.Threading.Timer? Flusher = Path is null ? null : new System.Threading.Timer(_ => Flush(), null, 5000, 5000);

    public static bool Enabled => Path is not null;

    public static void Interval(string kind, double expectedMilliseconds)
    {
        if (!Enabled)
        {
            return;
        }
        var now = Clock.Elapsed.TotalMilliseconds;
        lock (Sync)
        {
            if (LastArrival.TryGetValue(kind, out var last))
            {
                Pending.Add($"{kind},{(now - last - expectedMilliseconds).ToString("F3", CultureInfo.InvariantCulture)},{now.ToString("F0", CultureInfo.InvariantCulture)}");
            }
            LastArrival[kind] = now;
        }
    }

    public static MessageScope Message(string window) => new(window);

    public static void Flush()
    {
        if (Path is null)
        {
            return;
        }
        string[] lines;
        lock (Sync)
        {
            lines = [.. Pending];
            Pending.Clear();
        }
        if (lines.Length > 0)
        {
            File.AppendAllLines(Path, lines);
        }
        GC.KeepAlive(Flusher);
    }

    internal readonly struct MessageScope : IDisposable
    {
        private readonly string window;
        private readonly double started;

        public MessageScope(string window)
        {
            this.window = window;
            started = Clock.Elapsed.TotalMilliseconds;
            Interval("webview_gap:" + window, 1000);
        }

        public void Dispose()
        {
            if (!Enabled)
            {
                return;
            }
            lock (Sync)
            {
                Pending.Add($"webview_handler,{(Clock.Elapsed.TotalMilliseconds - started).ToString("F3", CultureInfo.InvariantCulture)},{started.ToString("F0", CultureInfo.InvariantCulture)}");
            }
        }
    }
}
#endif
