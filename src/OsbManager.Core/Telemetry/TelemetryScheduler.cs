using System.Text.Json;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Core.Telemetry;

/// <summary>
/// Sends usage statistics in the background. It does nothing, and holds no timer, while consent is off. With consent it waits
/// a random start delay, reads the config, registers once and then sends one batch per interval, one request at a time.
/// It runs on the thread pool and never touches the UI thread.
/// </summary>
public sealed class TelemetryScheduler : IDisposable
{
    private const int UnexpectedLimit = 3;

    private readonly PrivacyStore store;
    private readonly TelemetryClient client;
    private readonly IStatusSource statuses;
    private readonly TelemetryPayloadBuilder builder;
    private readonly string appVersion;
    private readonly string locale;
    private readonly TimeProvider time;
    private readonly Func<double> random;
    private readonly Action<string> log;
    private readonly DiagnosticsHub? hub;
    private readonly DiagnosticsUploader? diagnostics;
    private readonly JobState usage = new("Usage statistics");
    private readonly JobState reports = new("Error reports and performance data");
    private readonly SemaphoreSlim wake = new(0);
    private readonly object interruptSync = new();
    private CancellationTokenSource? loopSource;
    private CancellationTokenSource? interrupt;
    private Task? loop;
    private DateTimeOffset? nextDue;
    private DateTimeOffset? diagnosticsDue;
    private DateTimeOffset configDueAt;
    private DateTimeOffset registrationPausedUntil;
    private bool stoppedByServer;
    private bool diagnosticsStopped;
    private int seenEpoch = -1;
    private int unauthorized;
    private int diagnosticsUnauthorized;
    private int diagnosticsForbidden;
    private int unexpected;
    private long waitsEntered;

    public TelemetryScheduler(
        PrivacyStore store,
        TelemetryClient client,
        IStatusSource statuses,
        TelemetryPayloadBuilder builder,
        string appVersion,
        string locale,
        TimeProvider time,
        Func<double> random,
        Action<string> log,
        DiagnosticsHub? hub = null,
        DiagnosticsUploader? diagnostics = null)
    {
        this.store = store;
        this.client = client;
        this.statuses = statuses;
        this.builder = builder;
        this.appVersion = appVersion;
        this.locale = locale;
        this.time = time;
        this.random = random;
        this.log = log;
        this.hub = hub;
        this.diagnostics = diagnostics;
        store.Changed += OnPrivacyChanged;
    }

    public bool DisabledByFailSafe { get; private set; }

    internal long WaitsEntered => Interlocked.Read(ref waitsEntered);

    internal int Failures => usage.Failures;

    internal int DiagnosticsFailures => reports.Failures;

    public bool DiagnosticsStopped => diagnosticsStopped;

    private DateTimeOffset Now => time.GetUtcNow();

    public void Start()
    {
        if (loop is not null)
        {
            return;
        }
        loopSource = new CancellationTokenSource();
        var token = loopSource.Token;
        loop = Task.Run(() => RunAsync(token));
    }

    public bool Stop(TimeSpan maxWait)
    {
        store.Changed -= OnPrivacyChanged;
        loopSource?.Cancel();
        Interrupt();
        wake.Release();
        try
        {
            return loop?.Wait(maxWait) ?? true;
        }
        catch (AggregateException)
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

    public async Task<bool> SyncCharactersConsentAsync(CancellationToken ct)
    {
        var state = store.State;
        if (!state.Granted || !state.Registered || state.ServerKnowsCharacters == state.CharactersConsent || store.Credentials is not { } credentials)
        {
            return true;
        }
        var result = await client.UpdateConsentAsync(credentials, state.CharactersConsent, background: false, ct).ConfigureAwait(false);
        if (result.Succeeded)
        {
            store.MarkCharactersSynced(credentials.Id, state.CharactersConsent);
            return true;
        }
        return false;
    }

    private void OnPrivacyChanged()
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

    private CancellationTokenSource NewInterrupt(CancellationToken ct)
    {
        var source = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lock (interruptSync)
        {
            interrupt = source;
        }
        return source;
    }

    private async Task RunAsync(CancellationToken ct)
    {
        PeriodicTimer? timer = null;
        try
        {
            await LoopAsync(() => timer ??= new PeriodicTimer(TimeSpan.FromHours(1), time), () => { timer?.Dispose(); timer = null; }, ct).ConfigureAwait(false);
        }
        finally
        {
            timer?.Dispose();
        }
    }

    private async Task LoopAsync(Func<PeriodicTimer> timerFactory, Action dropTimer, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && !DisabledByFailSafe)
        {
            try
            {
                if (!store.State.Granted)
                {
                    nextDue = null;
                    diagnosticsDue = null;
                    seenEpoch = -1;
                    dropTimer();
                    await wake.WaitAsync(ct).ConfigureAwait(false);
                    continue;
                }
                var epoch = store.Epoch;
                if (nextDue is null || epoch != seenEpoch)
                {
                    seenEpoch = epoch;
                    ResetSchedule();
                    nextDue = Now + Backoff.StartDelay(random());
                    diagnosticsDue = nextDue;
                }
                using var source = NewInterrupt(ct);
                var due = diagnostics is not null && diagnosticsDue is { } diagnosticsAt && diagnosticsAt < nextDue.Value ? diagnosticsAt : nextDue.Value;
                await WaitUntilAsync(timerFactory(), due, source.Token).ConfigureAwait(false);
                if (!store.State.Granted || store.Epoch != seenEpoch)
                {
                    continue;
                }
                if (Now >= nextDue.Value)
                {
                    var wait = await CycleAsync(source.Token).ConfigureAwait(false);
                    nextDue = Now + wait;
                }
                if (diagnostics is not null && diagnosticsDue is { } pending && Now >= pending && store.State.Granted && store.Epoch == seenEpoch)
                {
                    diagnosticsDue = Now + await RunDiagnosticsAsync(source.Token).ConfigureAwait(false);
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
                RecordUnexpected(e);
                nextDue = Now + Backoff.Next(++usage.Failures, random());
            }
        }
    }

    private void ResetSchedule()
    {
        configDueAt = DateTimeOffset.MinValue;
        registrationPausedUntil = DateTimeOffset.MinValue;
        usage.Reset();
        reports.Reset();
        stoppedByServer = false;
        diagnosticsStopped = false;
        unauthorized = 0;
        diagnosticsUnauthorized = 0;
        diagnosticsForbidden = 0;
    }

    private async Task WaitUntilAsync(PeriodicTimer timer, DateTimeOffset due, CancellationToken ct)
    {
        while (true)
        {
            var remaining = due - Now;
            if (remaining <= TimeSpan.Zero)
            {
                return;
            }
            timer.Period = remaining < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : remaining;
            Interlocked.Increment(ref waitsEntered);
            await timer.WaitForNextTickAsync(ct).ConfigureAwait(false);
        }
    }

    private void RecordUnexpected(Exception e)
    {
        unexpected++;
        LogLimited(usage, $"Usage statistics hit an unexpected error ({e.GetType().Name}).");
        if (unexpected >= UnexpectedLimit && !DisabledByFailSafe)
        {
            DisabledByFailSafe = true;
            log($"Usage statistics are switched off until {AppIdentity.Name} restarts: {UnexpectedLimit} unexpected errors.");
        }
    }

    private void LogLimited(JobState job, string message)
    {
        var now = Now;
        if (now - job.LastLogAt >= TimeSpan.FromHours(1))
        {
            job.LastLogAt = now;
            log(message);
        }
    }

    private bool StillGranted(InstallCredentials credentials) => store.Credentials is { } current && current.Id == credentials.Id;

    private TelemetryConfig EffectiveConfig(PrivacyState state, DateTimeOffset now) =>
        state.Config is { } config && state.ConfigFetchedAt is { } fetched && now - fetched < TelemetryLimits.ConfigMaxAge
            ? config
            : TelemetryConfig.Disabled;

    private async Task<TimeSpan> RunDiagnosticsAsync(CancellationToken ct)
    {
        try
        {
            return await DiagnosticsCycleAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception e)
        {
            hub?.ReportFault();
            LogLimited(reports, $"{reports.Name} hit an unexpected error ({e.GetType().Name}).");
            if (hub?.Faulted == true)
            {
                log($"{reports.Name} are switched off until {AppIdentity.Name} restarts: {DiagnosticsHub.FaultLimit} unexpected errors.");
            }
            return Backoff.Next(++reports.Failures, random());
        }
    }

    private async Task<TimeSpan> DiagnosticsCycleAsync(CancellationToken ct)
    {
        if (diagnostics is null || hub is null)
        {
            return TelemetryLimits.MaxWait;
        }
        if (diagnosticsStopped || hub.Faulted)
        {
            return TelemetryLimits.MaxWait;
        }
        var now = Now;
        if (reports.PausedUntil > now)
        {
            return reports.PausedUntil - now;
        }
        if (store.Credentials is not { } credentials || !hub.Recording)
        {
            return TelemetryLimits.MinWait;
        }
        var config = EffectiveConfig(store.State, now);
        var settings = config.Diagnostics;
        diagnostics.ApplyConfig(settings);
        if (!config.ClientOk || !settings.Enabled || reports.FeatureOff)
        {
            var untilRead = configDueAt - now;
            return untilRead < TelemetryLimits.MinWait ? TelemetryLimits.MinWait : untilRead;
        }
        var interval = TimeSpan.FromSeconds(settings.IntervalSeconds);
        if (!diagnostics.HasSomethingToSend(settings))
        {
            return Backoff.Jitter(interval, random());
        }
        if (!StillGranted(credentials))
        {
            return TelemetryLimits.MinWait;
        }
        if (!store.State.Registered)
        {
            var registration = await RegisterAsync(credentials, reports, ct).ConfigureAwait(false);
            if (registration.Wait is { } wait)
            {
                return wait;
            }
            credentials = registration.Credentials;
        }
        if (diagnostics.Prepare(settings) is not { } prepared)
        {
            return Backoff.Jitter(interval, random());
        }
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, prepared.Session);
        var response = await client.SendDiagnosticsAsync(credentials, prepared.Body, linked.Token).ConfigureAwait(false);
        return await AfterDiagnosticsAsync(response, prepared, credentials, interval, ct).ConfigureAwait(false);
    }

    private async Task<TimeSpan> AfterDiagnosticsAsync(ApiResponse response, PreparedDiagnostics prepared, InstallCredentials credentials, TimeSpan interval, CancellationToken ct)
    {
        if (response.Succeeded)
        {
            reports.Failures = 0;
            diagnosticsUnauthorized = 0;
            diagnostics!.Commit(prepared);
            return Backoff.Jitter(TimeSpan.FromSeconds(Math.Max(interval.TotalSeconds, NextAfter(response.Body))), random());
        }
        if (response.Outcome == ApiOutcome.HttpError && response.StatusCode is 400 or 404 or 413 or 415)
        {
            diagnostics!.Commit(prepared);
            LogLimited(reports, $"{reports.Name} were rejected by the server ({response.StatusCode}); they are dropped.");
            return Backoff.Next(++reports.Failures, random());
        }
        diagnostics!.Return(prepared);
        switch (response.Outcome)
        {
            case ApiOutcome.Busy:
            case ApiOutcome.Cancelled:
                return TelemetryLimits.MinWait;
            case ApiOutcome.HttpError when response.StatusCode == 401:
                store.MarkUnregistered(credentials.Id);
                if (++diagnosticsUnauthorized >= 2)
                {
                    diagnosticsStopped = true;
                    log($"{reports.Name} stopped: the server did not accept this install.");
                    return TelemetryLimits.MaxWait;
                }
                return TelemetryLimits.MinWait;
            case ApiOutcome.HttpError when response.StatusCode == 403 && response.Code == "consent_required":
                return await AfterConsentRequiredAsync(credentials, interval, ct).ConfigureAwait(false);
        }
        return FailureWait(response, reports);
    }

    private async Task<TimeSpan> AfterConsentRequiredAsync(InstallCredentials credentials, TimeSpan interval, CancellationToken ct)
    {
        if (++diagnosticsForbidden >= 2)
        {
            diagnosticsStopped = true;
            log($"{reports.Name} stopped: the server says consent is missing.");
            return TelemetryLimits.MaxWait;
        }
        var state = store.State;
        if (StillGranted(credentials))
        {
            await client.UpdateConsentAsync(credentials, state.CharactersConsent, background: true, ct).ConfigureAwait(false);
        }
        return Backoff.Jitter(interval, random());
    }

    private async Task<TimeSpan> CycleAsync(CancellationToken ct)
    {
        var now = Now;
        if (stoppedByServer)
        {
            return TelemetryLimits.MaxWait;
        }
        if (usage.PausedUntil > now)
        {
            return usage.PausedUntil - now;
        }
        if (store.Credentials is not { } credentials)
        {
            return TelemetryLimits.MinWait;
        }
        if (configDueAt <= now)
        {
            if (!StillGranted(credentials))
            {
                return TelemetryLimits.MinWait;
            }
            var configWait = await ReadConfigAsync(credentials, usage, ct).ConfigureAwait(false);
            if (configWait is { } wait)
            {
                if (EffectiveConfig(store.State, Now) == TelemetryConfig.Disabled)
                {
                    return wait;
                }
                configDueAt = Now + wait;
            }
            now = Now;
        }
        var config = EffectiveConfig(store.State, now);
        if (!config.ClientOk || !config.TelemetryEnabled || usage.FeatureOff)
        {
            var untilRead = configDueAt - now;
            return untilRead < TelemetryLimits.MinWait ? TelemetryLimits.MinWait : untilRead;
        }
        var interval = TimeSpan.FromSeconds(config.IntervalSeconds);
        var includeCharacters = store.State.CharactersConsent;
        var batch = builder.Build(statuses.Snapshot(), credentials.KeyBytes(), includeCharacters);
        if (batch is null)
        {
            return Backoff.Jitter(interval, random());
        }
        if (!StillGranted(credentials))
        {
            return TelemetryLimits.MinWait;
        }
        if (!store.State.Registered)
        {
            var registration = await RegisterAsync(credentials, usage, ct).ConfigureAwait(false);
            if (registration.Wait is { } wait)
            {
                return wait;
            }
            if (registration.Credentials != credentials)
            {
                credentials = registration.Credentials;
                batch = builder.Build(statuses.Snapshot(), credentials.KeyBytes(), includeCharacters);
                if (batch is null)
                {
                    return Backoff.Jitter(interval, random());
                }
            }
        }
        await SyncCharactersConsentBackgroundAsync(ct).ConfigureAwait(false);
        if (!StillGranted(credentials))
        {
            return TelemetryLimits.MinWait;
        }
        var response = await client.SendTelemetryAsync(credentials, batch.Body, ct).ConfigureAwait(false);
        return AfterTelemetry(response, batch, credentials, interval);
    }

    private async Task SyncCharactersConsentBackgroundAsync(CancellationToken ct)
    {
        var state = store.State;
        if (!state.Registered || state.ServerKnowsCharacters == state.CharactersConsent || store.Credentials is not { } credentials)
        {
            return;
        }
        var result = await client.UpdateConsentAsync(credentials, state.CharactersConsent, background: true, ct).ConfigureAwait(false);
        if (result.Succeeded)
        {
            store.MarkCharactersSynced(credentials.Id, state.CharactersConsent);
        }
    }

    private async Task<TimeSpan?> ReadConfigAsync(InstallCredentials credentials, JobState job, CancellationToken ct)
    {
        var response = await client.GetConfigAsync(appVersion, background: true, ct).ConfigureAwait(false);
        if (response.Succeeded)
        {
            var config = TelemetryConfig.TryParse(response.Body) ?? TelemetryConfig.Disabled;
            store.StoreConfig(credentials.Id, config);
            diagnostics?.ApplyConfig(config.Diagnostics);
            configDueAt = Now + TelemetryLimits.ConfigRefresh;
            usage.FeatureOff = false;
            reports.FeatureOff = false;
            job.Failures = 0;
            return null;
        }
        return FailureWait(response, job);
    }

    private async Task<(TimeSpan? Wait, InstallCredentials Credentials)> RegisterAsync(InstallCredentials credentials, JobState job, CancellationToken ct)
    {
        var paused = registrationPausedUntil - Now;
        if (paused > TimeSpan.Zero)
        {
            return (paused, credentials);
        }
        var characters = store.State.CharactersConsent;
        var response = await client.RegisterAsync(credentials, appVersion, locale, characters, background: true, ct).ConfigureAwait(false);
        if (response.IsStatus(409))
        {
            var replacement = store.ReplaceIdentity(credentials.Id);
            if (replacement is null)
            {
                return (TelemetryLimits.MinWait, credentials);
            }
            credentials = replacement;
            response = await client.RegisterAsync(credentials, appVersion, locale, characters, background: true, ct).ConfigureAwait(false);
        }
        if (response.Succeeded)
        {
            store.MarkRegistered(credentials.Id, characters);
            job.Failures = 0;
            registrationPausedUntil = DateTimeOffset.MinValue;
            return (null, credentials);
        }
        var wait = FailureWait(response, job);
        registrationPausedUntil = Now + wait;
        return (wait, credentials);
    }

    private TimeSpan FailureWait(ApiResponse response, JobState job)
    {
        switch (response.Outcome)
        {
            case ApiOutcome.Busy:
            case ApiOutcome.Cancelled:
                return TelemetryLimits.MinWait;
            case ApiOutcome.HttpError when response.StatusCode == 429:
                return Backoff.RetryAfter(response.RetryAfter, random(), job.Failures + 1);
            case ApiOutcome.HttpError when response.StatusCode == 503:
                if (response.Code == "disabled")
                {
                    job.FeatureOff = true;
                }
                return Backoff.RetryAfter(response.RetryAfter, random(), job.Failures + 1);
            case ApiOutcome.HttpError when response.StatusCode == 403:
                job.PausedUntil = Now + TelemetryLimits.ForbiddenPause;
                return TelemetryLimits.ForbiddenPause;
            case ApiOutcome.HttpError when response.StatusCode is 400 or 404 or 413 or 415:
                return TelemetryLimits.BackoffCap;
        }
        job.Failures++;
        LogLimited(job, $"{job.Name} could not reach the server; trying again later.");
        return Backoff.Next(job.Failures, random());
    }

    private TimeSpan AfterTelemetry(ApiResponse response, TelemetryBatch batch, InstallCredentials credentials, TimeSpan interval)
    {
        if (response.Succeeded)
        {
            usage.Failures = 0;
            unauthorized = 0;
            batch.Commit();
            store.RecordSend(credentials.Id, "sent", sent: true);
            return Backoff.Jitter(TimeSpan.FromSeconds(Math.Max(interval.TotalSeconds, NextAfter(response.Body))), random());
        }
        switch (response.Outcome)
        {
            case ApiOutcome.Busy:
            case ApiOutcome.Cancelled:
                return TelemetryLimits.MinWait;
            case ApiOutcome.HttpError when response.StatusCode == 401:
                store.MarkUnregistered(credentials.Id);
                if (++unauthorized >= 2)
                {
                    stoppedByServer = true;
                    store.RecordSend(credentials.Id, "stopped: the server does not accept this install", sent: false);
                    log("Usage statistics stopped: the server did not accept this install.");
                    return TelemetryLimits.MaxWait;
                }
                return TelemetryLimits.MinWait;
            case ApiOutcome.HttpError when response.StatusCode is 400 or 404 or 413 or 415:
                store.RecordSend(credentials.Id, $"rejected by the server ({response.StatusCode})", sent: false);
                return Backoff.Jitter(interval, random());
        }
        var wait = FailureWait(response, usage);
        store.RecordSend(credentials.Id, response.Outcome == ApiOutcome.HttpError && response.StatusCode == 503 && usage.FeatureOff ? "switched off by the server" : "server unreachable", sent: false);
        if (usage.FeatureOff)
        {
            configDueAt = Now + wait;
        }
        return wait;
    }

    private static double NextAfter(byte[] body)
    {
        try
        {
            using var document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 4 });
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("next_after_s", out var value)
                && value.TryGetInt64(out var seconds)
                    ? Math.Clamp(seconds, 0, (long)TelemetryLimits.MaxWait.TotalSeconds)
                    : 0;
        }
        catch (JsonException)
        {
            return 0;
        }
    }

    private sealed class JobState(string name)
    {
        public string Name { get; } = name;
        public int Failures;
        public bool FeatureOff;
        public DateTimeOffset PausedUntil;
        public DateTimeOffset LastLogAt = DateTimeOffset.MinValue;

        public void Reset()
        {
            Failures = 0;
            FeatureOff = false;
            PausedUntil = DateTimeOffset.MinValue;
        }
    }
}
