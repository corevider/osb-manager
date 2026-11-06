namespace OsbManager.Core.Telemetry;

/// <summary>Retries queued reports with the backoff. It idles, with no timer and no request, while the outbox is empty.</summary>
public sealed class ReportRetryScheduler : IDisposable
{
    private const int UnexpectedLimit = 3;

    private readonly ReportOutbox outbox;
    private readonly ReportSender sender;
    private readonly TimeProvider time;
    private readonly Func<double> random;
    private readonly Action<string> log;
    private readonly SemaphoreSlim wake = new(0);
    private readonly object interruptSync = new();
    private CancellationTokenSource? loopSource;
    private CancellationTokenSource? interrupt;
    private Task? loop;
    private int unexpected;
    private long waitsEntered;

    public ReportRetryScheduler(ReportOutbox outbox, ReportSender sender, TimeProvider time, Func<double> random, Action<string> log)
    {
        this.outbox = outbox;
        this.sender = sender;
        this.time = time;
        this.random = random;
        this.log = log;
        outbox.Changed += OnOutboxChanged;
    }

    internal long WaitsEntered => Interlocked.Read(ref waitsEntered);

    public void Start()
    {
        if (loop is not null)
        {
            return;
        }
        loopSource = new CancellationTokenSource();
        var token = loopSource.Token;
        var notBefore = time.GetUtcNow() + Backoff.StartDelay(random());
        loop = Task.Run(() => RunAsync(notBefore, token));
    }

    public bool Stop(TimeSpan maxWait)
    {
        outbox.Changed -= OnOutboxChanged;
        loopSource?.Cancel();
        Interrupt();
        try
        {
            wake.Release();
            return loop?.Wait(maxWait) ?? true;
        }
        catch (Exception e) when (e is AggregateException or ObjectDisposedException)
        {
            return true;
        }
    }

    public void Dispose()
    {
        Stop(TimeSpan.FromSeconds(1));
        loopSource?.Dispose();
        wake.Dispose();
    }

    private void OnOutboxChanged()
    {
        ThreadPool.QueueUserWorkItem(_ => Interrupt());
        try
        {
            wake.Release();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private void Interrupt()
    {
        lock (interruptSync)
        {
            try
            {
                interrupt?.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }
    }

    private async Task RunAsync(DateTimeOffset notBefore, CancellationToken ct)
    {
        PeriodicTimer? timer = null;
        try
        {
            await LoopAsync(notBefore, () => timer ??= new PeriodicTimer(TimeSpan.FromHours(1), time), () => { timer?.Dispose(); timer = null; }, ct).ConfigureAwait(false);
        }
        finally
        {
            timer?.Dispose();
        }
    }

    private async Task LoopAsync(DateTimeOffset notBefore, Func<PeriodicTimer> timerFactory, Action dropTimer, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && unexpected < UnexpectedLimit)
        {
            try
            {
                outbox.MoveExpired();
                if (outbox.NextAttemptAt() is not { } next)
                {
                    dropTimer();
                    await wake.WaitAsync(ct).ConfigureAwait(false);
                    continue;
                }
                var due = next > notBefore ? next : notBefore;
                using var source = CancellationTokenSource.CreateLinkedTokenSource(ct);
                lock (interruptSync)
                {
                    interrupt = source;
                }
                while (due - time.GetUtcNow() > TimeSpan.Zero)
                {
                    var timer = timerFactory();
                    var remaining = due - time.GetUtcNow();
                    timer.Period = remaining < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : remaining;
                    Interlocked.Increment(ref waitsEntered);
                    await timer.WaitForNextTickAsync(source.Token).ConfigureAwait(false);
                }
                foreach (var entry in outbox.Pending().Where(e => e.NextAttemptAt <= time.GetUtcNow()))
                {
                    if (await sender.TrySendQueuedAsync(entry, source.Token).ConfigureAwait(false))
                    {
                        log("A queued report was sent.");
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception e)
            {
                unexpected++;
                log($"Queued reports hit an unexpected error ({e.GetType().Name}).");
                notBefore = time.GetUtcNow() + Backoff.Next(unexpected, random());
            }
        }
    }
}
