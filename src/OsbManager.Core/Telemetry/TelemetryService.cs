using System.Text.Json;

namespace OsbManager.Core.Telemetry;

public enum DeletionResult
{
    NothingToDelete,
    Deleted,
    Failed,
}

public sealed record ExportResult(bool Succeeded, byte[] Data);

/// <summary>
/// The app-facing side of usage statistics and reports: consent changes, the background loops and the user's data
/// requests. Consent changes are cheap and may be called from the UI thread; everything that talks to the network
/// runs on the thread pool.
/// </summary>
public sealed class TelemetryService : IDisposable
{
    private static readonly JsonSerializerOptions Indented = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly TelemetryClient client;
    private readonly string appVersion;
    private readonly TimeProvider time;
    private readonly TelemetryScheduler scheduler;
    private readonly ReportRetryScheduler retry;

    public TelemetryService(
        PrivacyStore privacy,
        TelemetryClient client,
        StatusRegistry statuses,
        ReportOutbox outbox,
        string appVersion,
        string locale,
        TimeProvider time,
        Func<double> random,
        Action<string> log,
        IStatusSource? statusSource = null)
    {
        Privacy = privacy;
        Statuses = statuses;
        Outbox = outbox;
        this.client = client;
        this.appVersion = appVersion;
        this.time = time;
        Reports = new ReportSender(client, privacy, outbox, time, random);
        scheduler = new TelemetryScheduler(privacy, client, statusSource ?? statuses, new TelemetryPayloadBuilder(appVersion, time), appVersion, locale, time, random, log);
        retry = new ReportRetryScheduler(outbox, Reports, time, random, log);
    }

    public PrivacyStore Privacy { get; }
    public StatusRegistry Statuses { get; }
    public ReportOutbox Outbox { get; }
    public ReportSender Reports { get; }
    public string? FailedDeletionInstallId { get; private set; }
    public bool DisabledByFailSafe => scheduler.DisabledByFailSafe;

    internal long SchedulerWaits => scheduler.WaitsEntered;

    internal long RetryWaits => retry.WaitsEntered;

    public void Start()
    {
        scheduler.Start();
        retry.Start();
    }

    public void Stop(TimeSpan maxWait)
    {
        scheduler.Stop(maxWait);
        retry.Stop(maxWait);
    }

    public string? PreviewNextPayload()
    {
        var state = Privacy.State;
        if (!state.Granted || Privacy.Credentials is not { } credentials)
        {
            return null;
        }
        var batch = new TelemetryPayloadBuilder(appVersion, time).Build(Statuses.Snapshot(), credentials.KeyBytes(), state.CharactersConsent);
        if (batch is null)
        {
            return null;
        }
        using var document = JsonDocument.Parse(batch.Body);
        return JsonSerializer.Serialize(document.RootElement, Indented);
    }

    public void Accept(bool characters)
    {
        FailedDeletionInstallId = null;
        Privacy.Grant(characters);
    }

    public void Decline()
    {
        if (Privacy.State.Status == ConsentStatus.Outdated)
        {
            _ = WithdrawAsync(clearOutbox: false);
            return;
        }
        Privacy.Decline();
    }

    public void SetCharacters(bool on)
    {
        if (Privacy.SetCharacters(on))
        {
            Task.Run(() => scheduler.SyncCharactersConsentAsync(CancellationToken.None));
        }
    }

    public Task<DeletionResult> WithdrawAsync() => WithdrawAsync(clearOutbox: true);

    private Task<DeletionResult> WithdrawAsync(bool clearOutbox)
    {
        var result = Privacy.Withdraw();
        if (clearOutbox)
        {
            Outbox.ClearAll();
        }
        FailedDeletionInstallId = null;
        if (!result.WasRegistered || result.Credentials is not { } credentials)
        {
            return Task.FromResult(DeletionResult.NothingToDelete);
        }
        return Task.Run(async () =>
        {
            var response = await client.DeleteInstallAsync(credentials, CancellationToken.None).ConfigureAwait(false);
            if (response.Succeeded || response.IsStatus(404) || response.IsStatus(401))
            {
                return DeletionResult.Deleted;
            }
            FailedDeletionInstallId = credentials.Id;
            return DeletionResult.Failed;
        });
    }

    public async Task<ExportResult> ExportAsync(CancellationToken ct)
    {
        if (Privacy.Credentials is not { } credentials || !Privacy.State.Registered)
        {
            return new ExportResult(false, []);
        }
        var response = await client.ExportAsync(credentials, ct).ConfigureAwait(false);
        return new ExportResult(response.Succeeded, response.Body);
    }

    public void Dispose()
    {
        scheduler.Dispose();
        retry.Dispose();
        client.Dispose();
    }
}
