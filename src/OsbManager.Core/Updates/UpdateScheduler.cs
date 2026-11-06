namespace OsbManager.Core.Updates;

/// <summary>
/// Runs the update check a short while after start and then every few hours. When the setting is off it makes no
/// request; while a game window is starting it waits and tries again shortly.
/// </summary>
public sealed class UpdateScheduler : IDisposable
{
    public static readonly TimeSpan DefaultFirstDelay = TimeSpan.FromMinutes(2);
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromHours(6);
    public static readonly TimeSpan DefaultBusyRetry = TimeSpan.FromMinutes(1);

    private readonly Func<bool> enabled;
    private readonly Func<bool> busy;
    private readonly Func<CancellationToken, Task> check;
    private readonly TimeProvider time;
    private readonly CancellationTokenSource stopping = new();
    private readonly object sync = new();
    private ITimer? timer;
    private bool disposed;

    public UpdateScheduler(Func<bool> enabled, Func<bool> busy, Func<CancellationToken, Task> check, TimeProvider time)
    {
        this.enabled = enabled;
        this.busy = busy;
        this.check = check;
        this.time = time;
    }

    public TimeSpan FirstDelay { get; init; } = DefaultFirstDelay;

    public TimeSpan Interval { get; init; } = DefaultInterval;

    public TimeSpan BusyRetry { get; init; } = DefaultBusyRetry;

    public void Start()
    {
        lock (sync)
        {
            if (disposed || timer is not null)
            {
                return;
            }
            timer = time.CreateTimer(_ => Tick(), null, FirstDelay, Timeout.InfiniteTimeSpan);
        }
    }

    private void Tick()
    {
        if (stopping.IsCancellationRequested)
        {
            return;
        }
        if (!enabled())
        {
            Schedule(Interval);
            return;
        }
        if (busy())
        {
            Schedule(BusyRetry);
            return;
        }
        Task task;
        try
        {
            task = check(stopping.Token);
        }
        catch (Exception e) when (e is UpdateException or OperationCanceledException)
        {
            task = Task.CompletedTask;
        }
        task.ContinueWith(_ => Schedule(Interval), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    private void Schedule(TimeSpan due)
    {
        lock (sync)
        {
            if (!disposed)
            {
                timer?.Change(due, Timeout.InfiniteTimeSpan);
            }
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            timer?.Dispose();
        }
        stopping.Cancel();
        stopping.Dispose();
    }
}
