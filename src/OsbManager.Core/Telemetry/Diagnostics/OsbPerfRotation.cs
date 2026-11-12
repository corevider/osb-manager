namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed class OsbPerfRotation
{
    public static readonly TimeSpan AnswerGrace = TimeSpan.FromMinutes(5);

    public static readonly TimeSpan PresentFor = TimeSpan.FromSeconds(15);

    private readonly object sync = new();
    private readonly Dictionary<int, DateTimeOffset> present = [];
    private Ask? current;
    private Ask? previous;
    private int lastAsked;
    private long nextId;
    private TimeSpan span;

    public void Present(int window, DateTimeOffset now)
    {
        lock (sync)
        {
            present[window] = now;
        }
    }

    public void Gone(int window)
    {
        lock (sync)
        {
            present.Remove(window);
        }
    }

    public void Tick(DateTimeOffset now, TimeSpan perfSpan, bool enabled)
    {
        lock (sync)
        {
            if (!enabled)
            {
                current = null;
                previous = null;
                return;
            }
            span = perfSpan;
            if (current is { } running && now - running.At < span)
            {
                return;
            }
            var candidates = present.Where(p => now - p.Value < PresentFor).Select(p => p.Key).Order().ToList();
            if (candidates.Count == 0)
            {
                if (current is not null)
                {
                    previous = current;
                    current = null;
                }
                return;
            }
            var next = candidates.FirstOrDefault(w => w > lastAsked, candidates[0]);
            if (current is not null)
            {
                previous = current;
            }
            current = new Ask(next, ++nextId, now);
            lastAsked = next;
        }
    }

    public long Wanted(int? window, DateTimeOffset now)
    {
        if (window is not { } ordinal)
        {
            return 0;
        }
        lock (sync)
        {
            if (current is { Answered: false } ask && ask.Window == ordinal)
            {
                return ask.Id;
            }
            return Waiting(previous, ordinal, now) ? previous!.Id : 0;
        }
    }

    public bool Accept(int? window, DateTimeOffset now)
    {
        if (window is not { } ordinal)
        {
            return false;
        }
        lock (sync)
        {
            if (Waiting(previous, ordinal, now))
            {
                previous!.Answered = true;
                if (current is { Answered: false } same && same.Window == ordinal)
                {
                    current = new Ask(ordinal, ++nextId, same.At);
                }
                return true;
            }
            if (current is { Answered: false } ask && ask.Window == ordinal)
            {
                ask.Answered = true;
                return true;
            }
            return false;
        }
    }

    private bool Waiting(Ask? ask, int window, DateTimeOffset now) =>
        ask is { Answered: false } && ask.Window == window && now - ask.At < span + AnswerGrace;

    private sealed class Ask(int window, long id, DateTimeOffset at)
    {
        public int Window { get; } = window;
        public long Id { get; } = id;
        public DateTimeOffset At { get; } = at;
        public bool Answered { get; set; }
    }
}
