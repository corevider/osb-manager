namespace OsbManager.Tests.Telemetry;

internal sealed class FakeTimeProvider : TimeProvider
{
    private readonly object sync = new();
    private readonly List<FakeTimer> timers = [];
    private DateTimeOffset now;

    public FakeTimeProvider(DateTimeOffset? start = null)
    {
        now = start ?? new DateTimeOffset(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);
    }

    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public override DateTimeOffset GetUtcNow()
    {
        lock (sync)
        {
            return now;
        }
    }

    public override long GetTimestamp() => GetUtcNow().Ticks;

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new FakeTimer(this, callback, state);
        lock (sync)
        {
            timers.Add(timer);
        }
        timer.Change(dueTime, period);
        return timer;
    }

    public int OneShotTimers
    {
        get { lock (sync) { return timers.Count(t => t.Armed && !t.Repeats); } }
    }

    public int RepeatingTimers
    {
        get { lock (sync) { return timers.Count(t => t.Armed && t.Repeats); } }
    }

    public void Advance(TimeSpan by)
    {
        var target = GetUtcNow() + by;
        while (true)
        {
            FakeTimer? next;
            lock (sync)
            {
                next = timers.Where(t => t.Armed && t.Due <= target).OrderBy(t => t.Due).FirstOrDefault();
                if (next is null)
                {
                    now = target;
                    return;
                }
                if (next.Due > now)
                {
                    now = next.Due;
                }
            }
            next.Fire();
        }
    }

    public bool AdvanceToNextRepeating(TimeSpan limit)
    {
        FakeTimer? next;
        lock (sync)
        {
            next = timers.Where(t => t.Armed && t.Repeats).OrderBy(t => t.Due).FirstOrDefault();
        }
        if (next is null || next.Due - GetUtcNow() > limit)
        {
            return false;
        }
        Advance(next.Due - GetUtcNow());
        return true;
    }

    private void Remove(FakeTimer timer)
    {
        lock (sync)
        {
            timers.Remove(timer);
        }
    }

    private sealed class FakeTimer(FakeTimeProvider owner, TimerCallback callback, object? state) : ITimer
    {
        private TimeSpan period = Timeout.InfiniteTimeSpan;

        public bool Armed { get; private set; }
        public bool Repeats => period != Timeout.InfiniteTimeSpan && period > TimeSpan.Zero;
        public DateTimeOffset Due { get; private set; }

        public bool Change(TimeSpan dueTime, TimeSpan newPeriod)
        {
            lock (owner.sync)
            {
                period = newPeriod;
                Armed = dueTime != Timeout.InfiniteTimeSpan;
                Due = Armed ? owner.now + dueTime : DateTimeOffset.MaxValue;
            }
            return true;
        }

        public void Fire()
        {
            lock (owner.sync)
            {
                if (!Armed)
                {
                    return;
                }
                if (Repeats)
                {
                    Due += period;
                }
                else
                {
                    Armed = false;
                }
            }
            callback(state);
        }

        public void Dispose()
        {
            lock (owner.sync)
            {
                Armed = false;
            }
            owner.Remove(this);
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
