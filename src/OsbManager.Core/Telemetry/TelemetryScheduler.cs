using System.Text.Json;

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
    private readonly SemaphoreSlim wake = new(0);
    private readonly object interruptSync = new();
    private CancellationTokenSource? loopSource;
    private CancellationTokenSource? interrupt;
    private Task? loop;
    private DateTimeOffset? nextDue;
    private DateTimeOffset configDueAt;
    private DateTimeOffset pausedUntil;
    private DateTimeOffset lastLogAt = DateTimeOffset.MinValue;
    private bool featureOff;
    private bool stoppedByServer;
    private int seenEpoch = -1;
    private int failures;
    private int unauthorized;
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
        Action<string> log)
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
        store.Changed += OnPrivacyChanged;
    }

    public bool DisabledByFailSafe { get; private set; }

    internal long WaitsEntered => Interlocked.Read(ref waitsEntered);

    internal int Failures => failures;

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
                }
                using var source = NewInterrupt(ct);
                await WaitUntilAsync(timerFactory(), nextDue.Value, source.Token).ConfigureAwait(false);
                if (!store.State.Granted || store.Epoch != seenEpoch)
                {
                    continue;
                }
                var wait = await CycleAsync(source.Token).ConfigureAwait(false);
                nextDue = Now + wait;
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
                nextDue = Now + Backoff.Next(++failures, random());
            }
        }
    }

    private void ResetSchedule()
    {
        configDueAt = DateTimeOffset.MinValue;
        pausedUntil = DateTimeOffset.MinValue;
        featureOff = false;
        stoppedByServer = false;
        failures = 0;
        unauthorized = 0;
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
        LogLimited($"Usage statistics hit an unexpected error ({e.GetType().Name}).");
        if (unexpected >= UnexpectedLimit && !DisabledByFailSafe)
        {
            DisabledByFailSafe = true;
            log($"Usage statistics are switched off until {AppIdentity.Name} restarts: {UnexpectedLimit} unexpected errors.");
        }
    }

    private void LogLimited(string message)
    {
        var now = Now;
        if (now - lastLogAt >= TimeSpan.FromHours(1))
        {
            lastLogAt = now;
            log(message);
        }
    }

    private bool StillGranted(InstallCredentials credentials) => store.Credentials is { } current && current.Id == credentials.Id;

    private TelemetryConfig EffectiveConfig(PrivacyState state, DateTimeOffset now) =>
        state.Config is { } config && state.ConfigFetchedAt is { } fetched && now - fetched < TelemetryLimits.ConfigMaxAge
            ? config
            : TelemetryConfig.Disabled;

    private async Task<TimeSpan> CycleAsync(CancellationToken ct)
    {
        var now = Now;
        if (stoppedByServer)
        {
            return TelemetryLimits.MaxWait;
        }
        if (pausedUntil > now)
        {
            return pausedUntil - now;
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
            var configWait = await ReadConfigAsync(credentials, ct).ConfigureAwait(false);
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
        if (!config.ClientOk || !config.TelemetryEnabled || featureOff)
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
            var registration = await RegisterAsync(credentials, ct).ConfigureAwait(false);
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

    private async Task<TimeSpan?> ReadConfigAsync(InstallCredentials credentials, CancellationToken ct)
    {
        var response = await client.GetConfigAsync(appVersion, background: true, ct).ConfigureAwait(false);
        if (response.Succeeded)
        {
            var config = TelemetryConfig.TryParse(response.Body) ?? TelemetryConfig.Disabled;
            store.StoreConfig(credentials.Id, config);
            configDueAt = Now + TelemetryLimits.ConfigRefresh;
            featureOff = false;
            failures = 0;
            return null;
        }
        return FailureWait(response);
    }

    private async Task<(TimeSpan? Wait, InstallCredentials Credentials)> RegisterAsync(InstallCredentials credentials, CancellationToken ct)
    {
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
            failures = 0;
            return (null, credentials);
        }
        return (FailureWait(response), credentials);
    }

    private TimeSpan FailureWait(ApiResponse response)
    {
        switch (response.Outcome)
        {
            case ApiOutcome.Busy:
            case ApiOutcome.Cancelled:
                return TelemetryLimits.MinWait;
            case ApiOutcome.HttpError when response.StatusCode == 429:
                return Backoff.RetryAfter(response.RetryAfter, random(), failures + 1);
            case ApiOutcome.HttpError when response.StatusCode == 503:
                if (response.Code == "disabled")
                {
                    featureOff = true;
                }
                return Backoff.RetryAfter(response.RetryAfter, random(), failures + 1);
            case ApiOutcome.HttpError when response.StatusCode == 403:
                pausedUntil = Now + TelemetryLimits.ForbiddenPause;
                return TelemetryLimits.ForbiddenPause;
            case ApiOutcome.HttpError when response.StatusCode is 400 or 404 or 413 or 415:
                return TelemetryLimits.BackoffCap;
        }
        failures++;
        LogLimited("Usage statistics could not reach the server; trying again later.");
        return Backoff.Next(failures, random());
    }

    private TimeSpan AfterTelemetry(ApiResponse response, TelemetryBatch batch, InstallCredentials credentials, TimeSpan interval)
    {
        if (response.Succeeded)
        {
            failures = 0;
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
        var wait = FailureWait(response);
        store.RecordSend(credentials.Id, response.Outcome == ApiOutcome.HttpError && response.StatusCode == 503 && featureOff ? "switched off by the server" : "server unreachable", sent: false);
        if (featureOff)
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
}
