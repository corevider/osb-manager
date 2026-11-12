namespace OsbManager.Core.Telemetry.Diagnostics;

public enum RecordOutcome
{
    Added,
    Merged,
    RateLimited,
    SampledOut,
}

public sealed class DiagnosticLimiter
{
    public const int MaxPerHour = 30;
    public const int MaxPerDay = 200;
    public const int MaxPending = MaxPerDay + 10;
    public static readonly TimeSpan Hour = TimeSpan.FromHours(1);
    public static readonly TimeSpan Day = TimeSpan.FromDays(1);

    private readonly object sync = new();
    private readonly TimeProvider time;
    private readonly Dictionary<string, DiagnosticEvent> pending = new(StringComparer.Ordinal);
    private readonly List<string> order = [];
    private readonly Dictionary<string, DateTimeOffset> lastSent = new(StringComparer.Ordinal);
    private readonly HashSet<string> trailSent = new(StringComparer.Ordinal);
    private readonly Queue<DateTimeOffset> accepted = new();
    private int rateLimited;
    private int oversize;

    public DiagnosticLimiter(TimeProvider time, int sampleDraw = 0, int samplePercent = 100)
    {
        this.time = time;
        SampleDraw = sampleDraw;
        SamplePercent = samplePercent;
    }

    public int SampleDraw { get; }

    public int SamplePercent { get; set; }

    public int PendingCount
    {
        get { lock (sync) { return pending.Count; } }
    }

    public static bool SampledIn(int draw, int percent) => draw < Math.Clamp(percent, 0, 100);

    public RecordOutcome Record(DiagnosticEvent candidate)
    {
        if (!SampledIn(SampleDraw, SamplePercent))
        {
            return RecordOutcome.SampledOut;
        }
        var now = time.GetUtcNow();
        lock (sync)
        {
            if (pending.TryGetValue(candidate.Fingerprint, out var existing))
            {
                pending[candidate.Fingerprint] = existing with { Count = (int)Math.Min((long)existing.Count + candidate.Count, DiagnosticFormats.MaxCount) };
                return RecordOutcome.Merged;
            }
            var limited = candidate.Kind != DiagnosticKind.RunEnd;
            if (limited)
            {
                Expire(now);
                if (accepted.Count >= MaxPerDay || accepted.Count(t => now - t < Hour) >= MaxPerHour || pending.Count >= MaxPending)
                {
                    rateLimited++;
                    return RecordOutcome.RateLimited;
                }
                accepted.Enqueue(now);
            }
            var withTrail = candidate.Trail is { Count: > 0 } && trailSent.Add(candidate.Fingerprint);
            pending[candidate.Fingerprint] = withTrail ? candidate : candidate with { Trail = null };
            order.Add(candidate.Fingerprint);
            return RecordOutcome.Added;
        }
    }

    public void CountDropped(int count)
    {
        if (count > 0)
        {
            lock (sync)
            {
                rateLimited = (int)Math.Min((long)rateLimited + count, DiagnosticFormats.MaxCount);
            }
        }
    }

    public void CountOversize(int count)
    {
        if (count > 0)
        {
            lock (sync)
            {
                oversize = (int)Math.Min((long)oversize + count, DiagnosticFormats.MaxCount);
            }
        }
    }

    public (IReadOnlyList<DiagnosticEvent> Events, DroppedCounts Dropped) Peek(int max = DiagnosticFormats.MaxEvents)
    {
        var now = time.GetUtcNow();
        lock (sync)
        {
            var taken = new List<DiagnosticEvent>();
            foreach (var fingerprint in order)
            {
                if (taken.Count >= max)
                {
                    break;
                }
                if (lastSent.TryGetValue(fingerprint, out var sent) && now - sent < Hour)
                {
                    continue;
                }
                taken.Add(pending[fingerprint]);
            }
            return (taken, new DroppedCounts(rateLimited, oversize));
        }
    }

    public (IReadOnlyList<DiagnosticEvent> Events, DroppedCounts Dropped) Take(int max = DiagnosticFormats.MaxEvents)
    {
        var now = time.GetUtcNow();
        lock (sync)
        {
            var taken = new List<DiagnosticEvent>();
            foreach (var fingerprint in order.ToList())
            {
                if (taken.Count >= max)
                {
                    break;
                }
                if (lastSent.TryGetValue(fingerprint, out var sent) && now - sent < Hour)
                {
                    continue;
                }
                taken.Add(pending[fingerprint]);
                pending.Remove(fingerprint);
                order.Remove(fingerprint);
                lastSent[fingerprint] = now;
            }
            var dropped = new DroppedCounts(rateLimited, oversize);
            rateLimited = 0;
            oversize = 0;
            return (taken, dropped);
        }
    }

    public void Return(IEnumerable<DiagnosticEvent> events, DroppedCounts dropped)
    {
        lock (sync)
        {
            foreach (var e in events.Reverse())
            {
                lastSent.Remove(e.Fingerprint);
                if (pending.TryGetValue(e.Fingerprint, out var existing))
                {
                    pending[e.Fingerprint] = e with { Count = (int)Math.Min((long)existing.Count + e.Count, DiagnosticFormats.MaxCount) };
                    order.Remove(e.Fingerprint);
                }
                else
                {
                    pending[e.Fingerprint] = e;
                }
                order.Insert(0, e.Fingerprint);
            }
            rateLimited = (int)Math.Min((long)rateLimited + dropped.RateLimited, DiagnosticFormats.MaxCount);
            oversize = (int)Math.Min((long)oversize + dropped.Oversize, DiagnosticFormats.MaxCount);
        }
    }

    public void Clear()
    {
        lock (sync)
        {
            pending.Clear();
            order.Clear();
            lastSent.Clear();
            trailSent.Clear();
            accepted.Clear();
            rateLimited = 0;
            oversize = 0;
        }
    }

    private void Expire(DateTimeOffset now)
    {
        while (accepted.Count > 0 && now - accepted.Peek() >= Day)
        {
            accepted.Dequeue();
        }
    }
}
