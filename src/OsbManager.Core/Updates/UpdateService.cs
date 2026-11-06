namespace OsbManager.Core.Updates;

/// <summary>
/// Ties the scheduler, the checker and the setting together. Results are raised on a worker thread. Without a
/// release key or a well-formed running version the service never makes a request.
/// </summary>
public sealed class UpdateService : IDisposable
{
    private readonly Func<bool> enabled;
    private readonly Action<string> log;
    private readonly UpdateHttp? http;
    private readonly UpdateScheduler? scheduler;
    private readonly SemaphoreSlim gate = new(1, 1);
    private volatile bool busy;

    public UpdateService(UpdateServiceOptions options, Func<bool> enabled, Action<string> log)
    {
        this.enabled = enabled;
        this.log = log;
        var signature = new UpdateSignature(options.PublicKeys);
        if (signature.KeyCount == 0)
        {
            Problem = "No release key is built in, so updates are not checked.";
            options.Handler.Dispose();
            return;
        }
        if (!UpdateVersion.TryParse(options.CurrentVersion, out var current))
        {
            Problem = $"The running version {options.CurrentVersion} is not a release version, so updates are not checked.";
            options.Handler.Dispose();
            return;
        }
        http = new UpdateHttp(options.Handler, options.Hosts, options.UserAgent);
        Checker = new UpdateChecker(http, options.Platform, current, signature)
        {
            MetadataLimit = options.MetadataTimeout,
            DownloadLimit = options.DownloadTimeout,
        };
        scheduler = new UpdateScheduler(enabled, () => busy, cancellation => RunAsync(requestedByUser: false, cancellation), options.Time)
        {
            FirstDelay = options.FirstDelay,
            Interval = options.Interval,
            BusyRetry = options.BusyRetry,
        };
    }

    /// <summary>Raised on a worker thread after every check that ran; the flag says whether the user asked for it.</summary>
    public event Action<UpdateCheckResult, bool>? Checked;

    public UpdateChecker? Checker { get; }

    public string? Problem { get; }

    /// <summary>True while a game window starts; scheduled checks wait until it is false.</summary>
    public bool Busy
    {
        get => busy;
        set => busy = value;
    }

    public bool AutomaticChecksEnabled => enabled();

    public void Start() => scheduler?.Start();

    public Task<UpdateCheckResult> CheckNowAsync(CancellationToken cancellation) => RunAsync(requestedByUser: true, cancellation);

    private async Task<UpdateCheckResult> RunAsync(bool requestedByUser, CancellationToken cancellation)
    {
        if (Checker is null)
        {
            return new UpdateCheckResult(UpdateCheckStatus.Failed, Problem ?? "Updates are not available.");
        }
        if (!requestedByUser && !enabled())
        {
            return new UpdateCheckResult(UpdateCheckStatus.UpToDate, "Automatic update checks are off.");
        }
        await gate.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            var result = await Checker.CheckAsync(cancellation).ConfigureAwait(false);
            log(result.Message);
            Checked?.Invoke(result, requestedByUser);
            return result;
        }
        finally
        {
            gate.Release();
        }
    }

    public void Dispose()
    {
        scheduler?.Dispose();
        http?.Dispose();
    }
}

public sealed record UpdateServiceOptions(
    string CurrentVersion,
    UpdatePlatform Platform,
    IReadOnlyList<string> PublicKeys,
    string UserAgent,
    HttpMessageHandler Handler,
    TimeProvider Time)
{
    public UpdateHosts Hosts { get; init; } = UpdateHosts.GitHub;
    public TimeSpan FirstDelay { get; init; } = UpdateScheduler.DefaultFirstDelay;
    public TimeSpan Interval { get; init; } = UpdateScheduler.DefaultInterval;
    public TimeSpan BusyRetry { get; init; } = UpdateScheduler.DefaultBusyRetry;
    public TimeSpan MetadataTimeout { get; init; } = UpdateChecker.MetadataTimeout;
    public TimeSpan DownloadTimeout { get; init; } = UpdateChecker.DownloadTimeout;
}
