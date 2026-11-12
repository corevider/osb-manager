using System.Threading.Channels;

namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed class DiagnosticsInbox : IDisposable
{
    public const int Capacity = 64;

    private readonly DiagnosticsHub hub;
    private readonly Channel<Action> channel;
    private readonly object sync = new();
    private Task? reader;
    private int outstanding;
    private bool disposed;

    public DiagnosticsInbox(DiagnosticsHub hub)
    {
        this.hub = hub;
        channel = Channel.CreateBounded<Action>(
            new BoundedChannelOptions(Capacity) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true, SingleWriter = false },
            _ =>
            {
                Interlocked.Decrement(ref outstanding);
                hub.Limiter.CountDropped(1);
            });
    }

    public bool Post(Action work)
    {
        if (disposed || !hub.Recording)
        {
            return false;
        }
        EnsureReader();
        Interlocked.Increment(ref outstanding);
        return channel.Writer.TryWrite(work);
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
        channel.Writer.TryComplete();
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
        await foreach (var work in channel.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                if (hub.Recording)
                {
                    work();
                }
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
}
