using System.Text.Json;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Core.Telemetry;

public enum DeletionResult
{
    NothingToDelete,
    Deleted,
    Failed,
}

public sealed record ExportResult(bool Succeeded, byte[] Data);

public sealed record DiagnosticsSetup(string Folder, PrivateTerms Terms, Func<DiagnosticEnv>? Env = null, TimeProvider? SamplerTime = null, TimeProvider? WireTime = null);

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
    private readonly TimeProvider wireTime;
    private readonly TelemetryScheduler scheduler;
    private readonly ReportRetryScheduler retry;

    public TelemetryService(
        PrivacyStore privacy,
        TelemetryClient client,
        StatusRegistry statuses,
        ReportOutbox outbox,
        DiagnosticsSetup diagnostics,
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
        wireTime = diagnostics.WireTime ?? time;
        Reports = new ReportSender(client, privacy, outbox, time, random);
        Diagnostics = new DiagnosticsHub(diagnostics.Folder, diagnostics.Terms, wireTime, () => privacy.State.Granted, (int)Math.Clamp(random() * 100, 0, 99));
        privacy.Changed += Diagnostics.OnConsentChanged;
        Perf = new PerfCollector();
        Capture = new DiagnosticsCapture(Diagnostics, Perf, appVersion, wireTime, diagnostics.SamplerTime ?? TimeProvider.System);
        Uploader = new DiagnosticsUploader(Diagnostics, Perf, diagnostics.Env ?? (() => DiagnosticEnvironment.FromThisMachine(null)), appVersion, wireTime);
        PageBatches = new OsbPageBatchReceiver(Diagnostics, wireTime);
        Uploader.ApplyConfig(CurrentDiagnosticsConfig());
        Capture.Configure(CurrentDiagnosticsConfig, null, null);
        scheduler = new TelemetryScheduler(privacy, client, statusSource ?? statuses, new TelemetryPayloadBuilder(appVersion, time), appVersion, locale, time, random, log, Diagnostics, Uploader);
        retry = new ReportRetryScheduler(outbox, Reports, time, random, log);
    }

    public PrivacyStore Privacy { get; }
    public StatusRegistry Statuses { get; }
    public ReportOutbox Outbox { get; }
    public ReportSender Reports { get; }
    public DiagnosticsHub Diagnostics { get; }
    public DiagnosticsCapture Capture { get; }
    public DiagnosticsUploader Uploader { get; }
    public OsbPageBatchReceiver PageBatches { get; }
    public PerfCollector Perf { get; }
    public string? FailedDeletionInstallId { get; private set; }
    public bool DisabledByFailSafe => scheduler.DisabledByFailSafe;

    internal long SchedulerWaits => scheduler.WaitsEntered;

    internal long RetryWaits => retry.WaitsEntered;

    public void Start()
    {
        scheduler.Start();
        retry.Start();
        Capture.Start();
    }

    public void Stop(TimeSpan maxWait)
    {
        scheduler.Stop(maxWait);
        retry.Stop(maxWait);
        Capture.Stop();
    }

    public void ConfigureDiagnostics(IPerfSource? perfSource, Func<IReadOnlyList<string>>? terms) =>
        Capture.Configure(CurrentDiagnosticsConfig, perfSource, terms);

    public DiagnosticsConfig CurrentDiagnosticsConfig()
    {
        var state = Privacy.State;
        return state.Granted && state.Config is { ClientOk: true } config && state.ConfigFetchedAt is { } fetched && time.GetUtcNow() - fetched < TelemetryLimits.ConfigMaxAge
            ? config.Diagnostics
            : DiagnosticsConfig.Disabled;
    }

    public void TickOsbPerf()
    {
        var config = CurrentDiagnosticsConfig();
        var on = Diagnostics.Recording && config.Enabled && config.Perf
            && DiagnosticLimiter.SampledIn(Diagnostics.Limiter.SampleDraw, config.SamplePercent);
        PageBatches.Rotation.Tick(wireTime.GetUtcNow(), TimeSpan.FromSeconds(config.PerfIntervalSeconds), on);
    }

    public string? PreviewNextDiagnostics() => Privacy.State.Granted ? Uploader.Preview(CurrentDiagnosticsConfig()) : null;

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
        Privacy.Changed -= Diagnostics.OnConsentChanged;
        scheduler.Dispose();
        retry.Dispose();
        client.Dispose();
        PageBatches.Dispose();
        Capture.Dispose();
        Diagnostics.Dispose();
    }
}
