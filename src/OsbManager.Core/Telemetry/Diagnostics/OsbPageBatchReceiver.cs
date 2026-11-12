using System.Threading.Channels;

namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed record PageBatchCounts(int Accepted, int Invalid, int Oversize, int TooFrequent, int AfterOff, int PerfAccepted = 0, int PerfNotAsked = 0, int Mapped = 0);

public sealed class OsbPageBatchReceiver : IDisposable
{
    public const int QueueCapacity = 4;

    public static readonly TimeSpan MinGap = TimeSpan.FromSeconds(55);

    private readonly DiagnosticsHub hub;
    private readonly TimeProvider time;
    private readonly Channel<Item> channel;
    private readonly Dictionary<int, DateTimeOffset> lastByWindow = [];
    private readonly object sync = new();
    private Task? reader;
    private int outstanding;
    private int accepted;
    private int invalid;
    private int oversize;
    private int tooFrequent;
    private int afterOff;
    private int perfAccepted;
    private int perfNotAsked;
    private int mapped;
    private bool disposed;

    public OsbPageBatchReceiver(DiagnosticsHub hub, TimeProvider time)
    {
        this.hub = hub;
        this.time = time;
        channel = Channel.CreateBounded<Item>(
            new BoundedChannelOptions(QueueCapacity) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true, SingleWriter = false },
            _ =>
            {
                Interlocked.Decrement(ref outstanding);
                Interlocked.Increment(ref tooFrequent);
                hub.Limiter.CountDropped(1);
            });
        hub.Wiped += Forget;
    }

    public OsbPerfRotation Rotation { get; } = new();

    public PageBatchCounts Counts => new(
        Volatile.Read(ref accepted), Volatile.Read(ref invalid), Volatile.Read(ref oversize), Volatile.Read(ref tooFrequent), Volatile.Read(ref afterOff),
        Volatile.Read(ref perfAccepted), Volatile.Read(ref perfNotAsked), Volatile.Read(ref mapped));

    public bool Offer(string json, int? window) => Push(json, window, null, OsbPageBatch.MaxBytes);

    public bool OfferPerf(string json, int? window, string? osbVersion) => Push(json, window, osbVersion ?? "", OsbPageBatch.MaxPerfBytes);

    private bool Push(string json, int? window, string? osbVersion, int maxBytes)
    {
        if (disposed || !hub.Recording)
        {
            Interlocked.Increment(ref afterOff);
            return false;
        }
        if (json.Length > maxBytes)
        {
            Interlocked.Increment(ref oversize);
            hub.Limiter.CountOversize(1);
            return false;
        }
        EnsureReader();
        Interlocked.Increment(ref outstanding);
        return channel.Writer.TryWrite(new Item(json, window, hub.Session, time.GetUtcNow(), osbVersion));
    }

    public bool Drain(TimeSpan maxWait)
    {
        var deadline = Environment.TickCount64 + (long)maxWait.TotalMilliseconds;
        while (Volatile.Read(ref outstanding) > 0)
        {
            if (Environment.TickCount64 > deadline)
            {
                return false;
            }
            Thread.Sleep(2);
        }
        return true;
    }

    public void Dispose()
    {
        disposed = true;
        hub.Wiped -= Forget;
        channel.Writer.TryComplete();
    }

    internal void Process(Item item)
    {
        if (item.Session.IsCancellationRequested || !hub.Recording)
        {
            Interlocked.Increment(ref afterOff);
            return;
        }
        if (item.OsbVersion is not null)
        {
            ProcessPerf(item);
            return;
        }
        var key = item.Window ?? 0;
        lock (sync)
        {
            if (lastByWindow.TryGetValue(key, out var previous) && item.At - previous < MinGap)
            {
                Interlocked.Increment(ref tooFrequent);
                hub.Limiter.CountDropped(1);
                return;
            }
        }
        if (System.Text.Encoding.UTF8.GetByteCount(item.Json) > OsbPageBatch.MaxBytes)
        {
            Interlocked.Increment(ref oversize);
            hub.Limiter.CountOversize(1);
            return;
        }
        if (OsbPageBatch.Parse(item.Json, time.GetUtcNow(), out var changed) is not { } events)
        {
            Interlocked.Increment(ref invalid);
            return;
        }
        lock (sync)
        {
            lastByWindow[key] = item.At;
        }
        Interlocked.Add(ref mapped, changed);
        foreach (var e in events)
        {
            if (item.Session.IsCancellationRequested)
            {
                return;
            }
            hub.Record(e with { Context = (e.Context ?? new DiagnosticContext()) with { Window = item.Window } });
        }
        Interlocked.Increment(ref accepted);
    }

    private void ProcessPerf(Item item)
    {
        if (System.Text.Encoding.UTF8.GetByteCount(item.Json) > OsbPageBatch.MaxPerfBytes)
        {
            Interlocked.Increment(ref oversize);
            hub.Limiter.CountOversize(1);
            return;
        }
        if (!Rotation.Accept(item.Window, item.At))
        {
            Interlocked.Increment(ref perfNotAsked);
            hub.Limiter.CountDropped(1);
            return;
        }
        if (OsbPageBatch.ParsePerf(item.Json, time.GetUtcNow()) is not { } entry
            || DiagnosticScrubber.Version(item.OsbVersion, hub.Terms) is not { } version)
        {
            Interlocked.Increment(ref invalid);
            return;
        }
        if (item.Session.IsCancellationRequested)
        {
            return;
        }
        hub.KeepOsbPerf(new OsbPerfEntry(entry, version));
        Interlocked.Increment(ref perfAccepted);
    }

    private void Forget()
    {
        lock (sync)
        {
            lastByWindow.Clear();
        }
    }

    private void EnsureReader()
    {
        if (reader is not null)
        {
            return;
        }
        lock (sync)
        {
            reader ??= Task.Run(ReadAsync);
        }
    }

    private async Task ReadAsync()
    {
        await foreach (var item in channel.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                Process(item);
            }
            catch (Exception)
            {
                hub.ReportFault();
            }
            finally
            {
                Interlocked.Decrement(ref outstanding);
            }
        }
    }

    internal sealed record Item(string Json, int? Window, CancellationToken Session, DateTimeOffset At, string? OsbVersion = null);
}
