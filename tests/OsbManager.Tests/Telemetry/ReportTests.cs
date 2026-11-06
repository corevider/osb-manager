using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class ReportTests
{
    private static byte[] ReportJson(string description = "The bot stops after the town trip.") =>
        ReportPayload.Build(ReportKind.Bug, description, ReportDiagnostics.Build("1.2.0", "10.0.26300", ".NET 10.0.0", [], []), "1.2.0", "en");

    private static async Task RunRetries(TelemetryKit kit, TimeSpan duration)
    {
        var end = kit.Time.GetUtcNow() + duration;
        while (kit.Time.GetUtcNow() < end)
        {
            var before = kit.Service.RetryWaits;
            if (!kit.Time.AdvanceToNextRepeating(end - kit.Time.GetUtcNow()))
            {
                kit.Time.Advance(end - kit.Time.GetUtcNow());
                return;
            }
            if (!await TelemetryKit.SettleAsync(() => (kit.Service.RetryWaits > before || kit.Outbox.Pending().Count == 0) && kit.Time.OneShotTimers == 0 && kit.Server.InFlight == 0))
            {
                return;
            }
        }
    }

    [Fact]
    public async Task ASentReportCarriesTheJsonPartAndTheScreenshotAsMultipartAndReturnsTheCode()
    {
        using var kit = new TelemetryKit();
        var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 1, 2, 3 };

        var outcome = await kit.Service.Reports.SendNewAsync(ReportJson(), png, CancellationToken.None);

        Assert.Equal(ReportResult.Sent, outcome.Result);
        Assert.Equal("R-7K3Q9XAB", outcome.Code);
        var request = Assert.Single(kit.Server.To("POST /v1/reports"));
        Assert.Equal("multipart/form-data", request.ContentType);
        Assert.Contains("name=report", request.BodyText);
        Assert.Contains("name=screenshot", request.BodyText);
        Assert.Contains("image/png", request.BodyText);
        Assert.Contains("The bot stops after the town trip.", request.BodyText);
    }

    [Fact]
    public async Task AReportWithoutUsageConsentIsAnonymous()
    {
        using var kit = new TelemetryKit();

        var outcome = await kit.Service.Reports.SendNewAsync(ReportJson(), null, CancellationToken.None);

        Assert.True(outcome.Anonymous);
        Assert.True(kit.Service.Reports.WouldBeAnonymous);
        Assert.Null(kit.Server.To("POST /v1/reports")[0].Authorization);
        Assert.Single(kit.Server.Requests);
    }

    [Fact]
    public async Task AReportFromARegisteredInstallCarriesTheInstallKey()
    {
        using var kit = new TelemetryKit();
        kit.Store.Grant(false);
        kit.Publish("a", TelemetryKit.Hunting());
        await kit.RunFor(TimeSpan.FromMinutes(5));
        Assert.False(kit.Service.Reports.WouldBeAnonymous);

        var outcome = await kit.Service.Reports.SendNewAsync(ReportJson(), null, CancellationToken.None);

        Assert.False(outcome.Anonymous);
        Assert.Equal("Bearer " + kit.Store.Credentials!.Bearer, kit.Server.To("POST /v1/reports")[0].Authorization);
    }

    [Fact]
    public async Task C14_AReportWhileOfflineWaitsInTheOutboxIsRetriedWithBackoffAndMovesToFailedAfterSeventyTwoHours()
    {
        using var kit = new TelemetryKit(random: 1.0);
        kit.Server.FailEverything(HttpStatusCode.InternalServerError);
        kit.Service.Start();

        var outcome = await kit.Service.Reports.SendNewAsync(ReportJson(), [1, 2, 3], CancellationToken.None);

        Assert.Equal(ReportResult.Queued, outcome.Result);
        Assert.Single(kit.Outbox.Pending());
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Service.RetryWaits >= 1));

        await RunRetries(kit, TimeSpan.FromHours(71));

        var times = kit.Server.To("POST /v1/reports").Select(r => r.At).ToList();
        Assert.True(times.Count >= 8);
        var gaps = times.Zip(times.Skip(1), (a, b) => b - a).ToList();
        Assert.All(gaps, gap => Assert.InRange(gap, TimeSpan.FromSeconds(60), TimeSpan.FromHours(6) + TimeSpan.FromSeconds(1)));
        Assert.Single(kit.Outbox.Pending());
        Assert.Empty(kit.Outbox.Failed());

        await RunRetries(kit, TimeSpan.FromHours(8));

        Assert.Empty(kit.Outbox.Pending());
        var failed = Assert.Single(kit.Outbox.Failed());
        Assert.True(kit.Outbox.Failed()[0].Attempts >= 8);
        Assert.True(File.Exists(Path.Combine(kit.Paths.OutboxFailed, failed.Id + ".json")));

        kit.Server.Route("POST /v1/reports", _ => FakeServer.Json(HttpStatusCode.Created, """{"code":"R-AAAAAAAA","screenshot":"stored"}"""));
        var requests = kit.Server.To("POST /v1/reports").Count;
        Assert.True(kit.Outbox.SendAgain(failed.Id));
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("POST /v1/reports").Count == requests + 1 && kit.Outbox.Pending().Count == 0));
        Assert.Empty(kit.Outbox.Failed());
    }

    [Fact]
    public async Task C14_NoMoreThanFiveReportsAreKeptWhileOffline()
    {
        using var kit = new TelemetryKit();
        kit.Server.FailEverything(HttpStatusCode.ServiceUnavailable);

        var outcomes = new List<ReportResult>();
        for (var i = 0; i < 6; i++)
        {
            outcomes.Add((await kit.Service.Reports.SendNewAsync(ReportJson("report " + i), null, CancellationToken.None)).Result);
        }

        Assert.Equal(5, outcomes.Count(o => o == ReportResult.Queued));
        Assert.Equal(ReportResult.QueueFull, outcomes[5]);
        Assert.Equal(5, kit.Outbox.Pending().Count);
    }

    [Fact]
    public async Task ARejectedReportIsNotKept()
    {
        using var kit = new TelemetryKit();
        kit.Server.Route("POST /v1/reports", _ => FakeServer.Problem(HttpStatusCode.BadRequest, "invalid_request"));

        var outcome = await kit.Service.Reports.SendNewAsync(ReportJson(), null, CancellationToken.None);

        Assert.Equal(ReportResult.Rejected, outcome.Result);
        Assert.Empty(kit.Outbox.Pending());
    }

    [Fact]
    public async Task ARetryAfterOnAReportIsHonouredByTheRetryLoop()
    {
        using var kit = new TelemetryKit(random: 0.0);
        kit.Server.RouteSequence("POST /v1/reports",
            () => FakeServer.Problem(HttpStatusCode.TooManyRequests, "rate_limited", 900),
            () => FakeServer.Problem(HttpStatusCode.TooManyRequests, "rate_limited", 900),
            () => FakeServer.Json(HttpStatusCode.Created, """{"code":"R-AAAAAAAA","screenshot":"none"}"""));
        kit.Service.Start();
        await kit.Service.Reports.SendNewAsync(ReportJson(), null, CancellationToken.None);
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Service.RetryWaits >= 1));

        await RunRetries(kit, TimeSpan.FromHours(3));

        var times = kit.Server.To("POST /v1/reports").Select(r => r.At).ToList();
        Assert.Equal(3, times.Count);
        Assert.True(times[2] - times[1] >= TimeSpan.FromSeconds(900));
        Assert.Empty(kit.Outbox.Pending());
    }

    [Fact]
    public void TheDescriptionIsCleanedAndCutAtTwoThousandCharacters()
    {
        var text = "line one\r\nline two\u0007\t" + new string('x', 3000);

        var clean = ReportPayload.CleanDescription(text);

        Assert.Equal(2000, clean.Length);
        Assert.StartsWith("line one\nline two\t", clean);
        Assert.DoesNotContain('\u0007', clean);
        Assert.DoesNotContain('\r', clean);
    }

    [Fact]
    public void ThePreviewIsExactlyTheJsonThatIsSent()
    {
        var diagnostics = ReportDiagnostics.Build("1.2.0", "10.0.26300", ".NET 10.0.0", [], []);

        var json = ReportPayload.Build(ReportKind.Feature, "Please add a dark theme.", diagnostics, "1.2.0", "tr");

        Assert.Equal(Encoding.UTF8.GetString(json), ReportPayload.Preview(json));
        Assert.Equal("feature", (string)JsonNode.Parse(json)!["kind"]!);
        Assert.Contains("\n", ReportPayload.Preview(json));
    }
}
