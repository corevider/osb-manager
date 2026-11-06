using System.Text;
using System.Text.Json;

namespace OsbManager.Core.Telemetry;

public enum ReportResult
{
    Sent,
    Queued,
    QueueFull,
    TooLarge,
    NotSaved,
    Rejected,
    Cancelled,
}

public sealed record ReportOutcome(ReportResult Result, string? Code = null, bool Anonymous = true, string? Detail = null);

/// <summary>
/// Delivers a report the user chose to send. It is called only from the report dialog's Send button and from the outbox
/// retry loop for reports queued by that button; it never reads the config over the network.
/// </summary>
public sealed class ReportSender
{
    private readonly TelemetryClient client;
    private readonly PrivacyStore store;
    private readonly ReportOutbox outbox;
    private readonly TimeProvider time;
    private readonly Func<double> random;

    public ReportSender(TelemetryClient client, PrivacyStore store, ReportOutbox outbox, TimeProvider time, Func<double> random)
    {
        this.client = client;
        this.store = store;
        this.outbox = outbox;
        this.time = time;
        this.random = random;
    }

    public bool WouldBeAnonymous => AuthFor(false) is null;

    public async Task<ReportOutcome> SendNewAsync(byte[] reportJson, byte[]? screenshot, CancellationToken ct)
    {
        var credentials = AuthFor(false);
        var anonymous = credentials is null;
        if (ReportsSwitchedOff())
        {
            return Enqueue(reportJson, screenshot, anonymous, "reports are switched off by the server");
        }
        var response = await client.SendReportAsync(credentials, reportJson, screenshot, ct).ConfigureAwait(false);
        if (response.Succeeded)
        {
            return new ReportOutcome(ReportResult.Sent, Code(response.Body), anonymous);
        }
        switch (response.Outcome)
        {
            case ApiOutcome.Cancelled:
                return new ReportOutcome(ReportResult.Cancelled, Anonymous: anonymous);
            case ApiOutcome.HttpError when response.StatusCode is 400 or 403 or 404 or 413 or 415:
                return new ReportOutcome(ReportResult.Rejected, Anonymous: anonymous, Detail: $"HTTP {response.StatusCode}");
        }
        return Enqueue(reportJson, screenshot, anonymous || response.IsStatus(401), Describe(response));
    }

    public async Task<bool> TrySendQueuedAsync(OutboxEntry entry, CancellationToken ct)
    {
        var credentials = AuthFor(entry.Anonymous);
        var anonymous = credentials is null;
        if (ReportsSwitchedOff())
        {
            outbox.RecordAttempt(entry.Id, Backoff.Next(entry.Attempts + 1, random()), "reports are switched off by the server", anonymous);
            return false;
        }
        var screenshot = outbox.Screenshot(entry, failed: false);
        var response = await client.SendReportAsync(credentials, Encoding.UTF8.GetBytes(entry.ReportJson), screenshot, ct).ConfigureAwait(false);
        if (response.Succeeded)
        {
            outbox.Remove(entry.Id);
            return true;
        }
        switch (response.Outcome)
        {
            case ApiOutcome.Cancelled:
                return false;
            case ApiOutcome.HttpError when response.StatusCode is 400 or 403 or 404 or 413 or 415:
                outbox.Remove(entry.Id);
                return false;
        }
        var retryIn = response.Outcome == ApiOutcome.HttpError && response.StatusCode is 429 or 503
            ? Backoff.RetryAfter(response.RetryAfter, random(), entry.Attempts + 1)
            : Backoff.Next(entry.Attempts + 1, random());
        outbox.RecordAttempt(entry.Id, retryIn, Describe(response), anonymous || response.IsStatus(401));
        return false;
    }

    private InstallCredentials? AuthFor(bool forceAnonymous)
    {
        var state = store.State;
        return !forceAnonymous && state.Granted && state.Registered ? store.Credentials : null;
    }

    private bool ReportsSwitchedOff()
    {
        var state = store.State;
        return state.Config is { } config && state.ConfigFetchedAt is { } fetched
            && time.GetUtcNow() - fetched < TelemetryLimits.ConfigMaxAge
            && (!config.ReportsEnabled || !config.ClientOk);
    }

    private ReportOutcome Enqueue(byte[] reportJson, byte[]? screenshot, bool anonymous, string note)
    {
        switch (outbox.Enqueue(reportJson, screenshot, anonymous, out _, Backoff.Next(1, random()), note))
        {
            case EnqueueOutcome.Full:
                return new ReportOutcome(ReportResult.QueueFull, Anonymous: anonymous, Detail: note);
            case EnqueueOutcome.TooLarge:
                return new ReportOutcome(ReportResult.TooLarge, Anonymous: anonymous, Detail: note);
            case EnqueueOutcome.Failed:
                return new ReportOutcome(ReportResult.NotSaved, Anonymous: anonymous, Detail: note);
        }
        return new ReportOutcome(ReportResult.Queued, Anonymous: anonymous, Detail: note);
    }

    private static string Describe(ApiResponse response) => response.Outcome switch
    {
        ApiOutcome.HttpError => $"HTTP {response.StatusCode}",
        ApiOutcome.Timeout => "timed out",
        ApiOutcome.Busy => "another request was running",
        _ => "server unreachable",
    };

    private static string? Code(byte[] body)
    {
        try
        {
            using var document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 4 });
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("code", out var code)
                && code.ValueKind == JsonValueKind.String
                && code.GetString() is { Length: > 0 and <= 20 } text
                && text.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')
                    ? text
                    : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
