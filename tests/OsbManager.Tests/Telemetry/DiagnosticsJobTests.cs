using System.Net;
using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class DiagnosticsJobTests
{
    private static void Queue(TelemetryKit kit, string kind = "RenderProcessExited", string reason = "Crashed")
    {
        kit.Service.Capture.ProcessFailed(kind, reason, 1, null, DiagnosticsKit.Window());
        kit.Drain();
    }

    private static void AddPerfEntry(TelemetryKit kit)
    {
        var source = new FakePerfSource();
        for (var i = 0; i < 30; i++)
        {
            kit.Time.Advance(TimeSpan.FromSeconds(60));
            kit.Service.Perf.Add(source.Read(kit.Time.GetUtcNow())!);
        }
        Assert.True(kit.Service.Perf.TryComplete(TimeSpan.FromSeconds(1800)));
    }

    private static List<TimeSpan> Gaps(IEnumerable<SeenRequest> requests)
    {
        var times = requests.Select(r => r.At).ToList();
        return times.Zip(times.Skip(1), (a, b) => b - a).ToList();
    }

    [Fact]
    public async Task UsageStatisticsGoFirstThenTheDiagnosticsJobRunsAsTheSecondJob()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Publish("a", TelemetryKit.Hunting());
        Queue(kit);

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var endpoints = kit.Server.Requests.Select(r => r.Endpoint).ToList();
        Assert.Equal(["GET /v1/config", "POST /v1/installs", "POST /v1/telemetry", "POST /v1/diagnostics"], endpoints.Take(4));
        Assert.Single(kit.Server.To("POST /v1/installs"));
        var diagnostics = kit.Server.To("POST /v1/diagnostics")[0];
        Assert.StartsWith("Bearer ", diagnostics.Authorization);
        Assert.Equal("application/json", diagnostics.ContentType);
        Assert.True(diagnostics.Body.Length <= 64 * 1024);
    }

    [Fact]
    public async Task DiagnosticsAloneRegisterTheInstallBeforeTheirFirstRequest()
    {
        using var kit = DiagnosticsKit.Granted();
        Queue(kit);

        await kit.RunFor(TimeSpan.FromMinutes(14));

        Assert.Equal(["GET /v1/config", "POST /v1/installs", "POST /v1/diagnostics"], kit.Server.Requests.Select(r => r.Endpoint).Take(3));
        Assert.Empty(kit.Server.To("POST /v1/telemetry"));
    }

    [Fact]
    public async Task DG5_NeverTwoRequestsInFlightWhenBothJobsAreDue()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Publish("a", TelemetryKit.Hunting());
        Queue(kit);
        var most = 0;
        foreach (var endpoint in new[] { "POST /v1/telemetry", "POST /v1/diagnostics", "POST /v1/installs", "GET /v1/config" })
        {
            kit.Server.RouteAsync(endpoint, async (request, ct) =>
            {
                most = Math.Max(most, kit.Server.InFlight);
                await Task.Delay(20, CancellationToken.None);
                return endpoint.Contains("diagnostics") ? FakeServer.Json(HttpStatusCode.Accepted, """{"accepted_events":1,"accepted_perf":0,"next_after_s":600}""")
                    : endpoint.Contains("telemetry") ? FakeServer.Json(HttpStatusCode.Accepted, """{"accepted":1,"next_after_s":600}""")
                    : endpoint.Contains("config") ? FakeServer.Json(HttpStatusCode.OK, FakeServer.ConfigWithDiagnostics())
                    : FakeServer.Json(HttpStatusCode.Created, """{"install_id":"x","status":"quarantined"}""");
            });
        }

        await kit.RunFor(TimeSpan.FromMinutes(14));

        Assert.NotEmpty(kit.Server.To("POST /v1/diagnostics"));
        Assert.NotEmpty(kit.Server.To("POST /v1/telemetry"));
        Assert.Equal(1, most);
    }

    [Fact]
    public async Task DG15_NothingIsSentWhileTheServerFlagIsOffOrTheBlockIsMissingOrMalformed()
    {
        foreach (var config in new[]
        {
            FakeServer.ConfigWithDiagnostics(enabled: false),
            FakeServer.ConfigEnabled,
            FakeServer.ConfigEnabled.Replace("\"client_ok\":true", "\"client_ok\":true,\"diagnostics\":{\"enabled\":\"yes\"}"),
        })
        {
            using var kit = DiagnosticsKit.Granted(config);
            kit.Publish("a", TelemetryKit.Hunting());
            Queue(kit);

            await kit.RunFor(TimeSpan.FromHours(2));

            Assert.Empty(kit.Server.To("POST /v1/diagnostics"));
            Assert.NotEmpty(kit.Server.To("POST /v1/telemetry"));
            Assert.Equal(1, kit.Service.Diagnostics.Limiter.PendingCount);
        }
    }

    [Fact]
    public async Task DG15_ThePerfEntryRidesInTheBatchOnlyWhileTheConfigAllowsPerf()
    {
        foreach (var perf in new[] { true, false })
        {
            using var kit = DiagnosticsKit.Granted(FakeServer.ConfigWithDiagnostics(perf: perf));
            AddPerfEntry(kit);
            Queue(kit);

            await kit.RunFor(TimeSpan.FromMinutes(14));

            var body = Assert.Single(kit.DiagnosticBodies());
            Assert.Equal(perf, body["perf"] is JsonArray { Count: 1 });
        }
    }

    [Fact]
    public async Task APerfEntryAloneIsSentWithoutEvents()
    {
        using var kit = DiagnosticsKit.Granted();
        AddPerfEntry(kit);

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(kit.DiagnosticBodies());
        Assert.Empty(body["events"]!.AsArray());
        Assert.Single(body["perf"]!.AsArray());
        Assert.Empty(DiagnosticsServerRules.Check(body));
    }

    [Fact]
    public async Task F13_ABatchWithoutPerfEntriesLeavesPerfAndOsbPerfOut()
    {
        using var kit = DiagnosticsKit.Granted();
        Queue(kit);

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(kit.DiagnosticBodies());
        Assert.Single(body["events"]!.AsArray());
        Assert.False(body.AsObject().ContainsKey("perf"));
        Assert.False(body.AsObject().ContainsKey("osb_perf"));
        Assert.Empty(DiagnosticsServerRules.Check(body));
    }

    [Fact]
    public async Task F13_AFailedRegistrationIsNotRetriedByTheOtherJobInTheSamePass()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Publish("a", TelemetryKit.Hunting());
        Queue(kit);
        kit.Server.RouteSequence("POST /v1/installs",
            () => FakeServer.Problem(HttpStatusCode.InternalServerError, "unavailable"),
            () => FakeServer.Json(HttpStatusCode.Created, """{"install_id":"x","status":"quarantined"}"""));

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var installs = kit.Server.To("POST /v1/installs");
        Assert.True(installs.Count >= 2);
        Assert.True(installs[1].At - installs[0].At >= TelemetryLimits.MinWait);
        Assert.Single(installs, request => request.At == installs[0].At);
        Assert.NotEmpty(kit.Server.To("POST /v1/telemetry"));
        Assert.NotEmpty(kit.Server.To("POST /v1/diagnostics"));
    }

    [Fact]
    public async Task NoEmptyBatchIsEverSent()
    {
        using var kit = DiagnosticsKit.Granted();

        await kit.RunFor(TimeSpan.FromHours(3));

        Assert.Empty(kit.Server.To("POST /v1/diagnostics"));
    }

    [Fact]
    public async Task AnAcceptedBatchDeletesTheSentPendingFilesAndAFailureKeepsThemAndTheEvents()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Server.RouteSequence("POST /v1/diagnostics",
            () => FakeServer.Problem(HttpStatusCode.InternalServerError, "unavailable"),
            () => FakeServer.Json(HttpStatusCode.Accepted, """{"accepted_events":2,"accepted_perf":0,"next_after_s":600}"""));
        kit.Service.Diagnostics.WritePending(new DiagnosticEvent
        {
            Kind = DiagnosticKind.DotnetException,
            Fingerprint = "a41c09e7b23d5f16",
            At = kit.Time.GetUtcNow(),
            Error = new ErrorDetail("System.InvalidOperationException", "appdomain", false, ["OsbManager.Browser.GameWindow.OnWebMessage+IL_01A3"], [], "0x80131509"),
        });
        Queue(kit);

        await kit.RunFor(TimeSpan.FromHours(1));

        var sent = kit.Server.To("POST /v1/diagnostics");
        Assert.Equal(2, sent.Count);
        foreach (var request in sent)
        {
            var events = JsonNode.Parse(request.BodyText)!["events"]!.AsArray();
            Assert.Equal(2, events.Count);
        }
        Assert.Empty(Directory.EnumerateFiles(kit.Paths.Diagnostics, "pending-*.json"));
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
    }

    [Fact]
    public async Task APendingFileSurvivesAFailedSend()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Server.Route("POST /v1/diagnostics", _ => FakeServer.Problem(HttpStatusCode.InternalServerError, "unavailable"));
        kit.Service.Diagnostics.WritePending(new DiagnosticEvent
        {
            Kind = DiagnosticKind.RunEnd,
            Fingerprint = "0c8d1e2f3a4b5c6d",
            At = kit.Time.GetUtcNow(),
            RunEnd = new RunEndDetail("unclean", 600, "1.2.0"),
        });

        await kit.RunFor(TimeSpan.FromHours(1));

        Assert.NotEmpty(kit.Server.To("POST /v1/diagnostics"));
        Assert.Single(Directory.EnumerateFiles(kit.Paths.Diagnostics, "pending-*.json"));
    }

    [Fact]
    public async Task DG14_DiagnosticsFailuresBackOffAndNeverMoveTheUsageSchedule()
    {
        var failing = DiagnosticsKit.Granted();
        var healthy = DiagnosticsKit.Granted();
        using (failing)
        using (healthy)
        {
            foreach (var kit in new[] { failing, healthy })
            {
                kit.Publish("a", TelemetryKit.Hunting());
                Queue(kit);
            }
            failing.Server.Route("POST /v1/diagnostics", _ => FakeServer.Problem(HttpStatusCode.InternalServerError, "unavailable"));

            await failing.RunFor(TimeSpan.FromHours(12));
            await healthy.RunFor(TimeSpan.FromHours(12));

            var gaps = Gaps(failing.Server.To("POST /v1/diagnostics"));
            Assert.True(gaps.Count >= 3);
            Assert.All(gaps, g => Assert.True(g >= TimeSpan.FromSeconds(60)));
            Assert.Equal(
                healthy.Server.To("POST /v1/telemetry").Select(r => r.At).ToList(),
                failing.Server.To("POST /v1/telemetry").Select(r => r.At).ToList());
        }
    }

    [Fact]
    public async Task DG14_RetryAfterOnTooManyRequestsIsHonouredForDiagnostics()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Server.RouteSequence("POST /v1/diagnostics",
            () => FakeServer.Problem(HttpStatusCode.TooManyRequests, "rate_limited", 120),
            () => FakeServer.Json(HttpStatusCode.Accepted, """{"accepted_events":1,"accepted_perf":0,"next_after_s":600}"""));
        Queue(kit);

        await kit.RunFor(TimeSpan.FromMinutes(15));

        var sent = kit.Server.To("POST /v1/diagnostics");
        Assert.True(sent.Count >= 2);
        Assert.InRange((sent[1].At - sent[0].At).TotalSeconds, 120, 121);
    }

    [Fact]
    public async Task DG15_ServiceUnavailableDisabledStopsDiagnosticsUntilTheNextConfigRead()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Server.RouteSequence("POST /v1/diagnostics",
            () => FakeServer.Problem(HttpStatusCode.ServiceUnavailable, "disabled", 3600),
            () => FakeServer.Json(HttpStatusCode.Accepted, """{"accepted_events":1,"accepted_perf":0,"next_after_s":600}"""));
        Queue(kit);

        await kit.RunFor(TimeSpan.FromHours(8));

        var diagnostics = kit.Server.To("POST /v1/diagnostics");
        Assert.Equal(2, diagnostics.Count);
        var configReads = kit.Server.To("GET /v1/config").Select(r => r.At).ToList();
        Assert.Contains(configReads, at => at > diagnostics[0].At && at <= diagnostics[1].At);
        Assert.True(diagnostics[1].At - diagnostics[0].At >= TimeSpan.FromHours(1));
    }

    [Fact]
    public async Task DG21_ConsentRequiredSendsOneConsentUpdateThenRetriesAndASecondOneStopsUntilRestart()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Server.Route("POST /v1/diagnostics", _ => FakeServer.Problem(HttpStatusCode.Forbidden, "consent_required"));
        Queue(kit);

        await kit.RunFor(TimeSpan.FromHours(6));

        var sent = kit.Server.To("POST /v1/diagnostics");
        Assert.Equal(2, sent.Count);
        Assert.Single(kit.Server.To("PUT /v1/installs/me/consent"));
        Assert.True(sent[1].At - sent[0].At >= TimeSpan.FromSeconds(540));
        var consent = JsonNode.Parse(kit.Server.To("PUT /v1/installs/me/consent")[0].BodyText)!;
        Assert.Equal(2, consent["usage_version"]!.GetValue<int>());
    }

    [Fact]
    public async Task DG21_TheFirstConsentRequiredIsFollowedByASuccessfulRetry()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Server.RouteSequence("POST /v1/diagnostics",
            () => FakeServer.Problem(HttpStatusCode.Forbidden, "consent_required"),
            () => FakeServer.Json(HttpStatusCode.Accepted, """{"accepted_events":1,"accepted_perf":0,"next_after_s":600}"""));
        Queue(kit);

        await kit.RunFor(TimeSpan.FromHours(3));

        Assert.Equal(2, kit.Server.To("POST /v1/diagnostics").Count);
        Assert.Single(kit.Server.To("PUT /v1/installs/me/consent"));
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
    }

    [Fact]
    public async Task ARejectedBatchIsDroppedAndNeverStopsUsageStatistics()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Server.Route("POST /v1/diagnostics", _ => FakeServer.Problem(HttpStatusCode.BadRequest, "invalid"));
        Queue(kit);

        await kit.RunFor(TimeSpan.FromHours(4));

        Assert.Single(kit.Server.To("POST /v1/diagnostics"));
        Assert.NotEmpty(kit.Server.To("POST /v1/telemetry"));
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
    }

    [Fact]
    public async Task DG16_WithdrawingWhileADiagnosticsRequestIsInFlightAbortsItWipesEverythingAndSendsOneDelete()
    {
        using var kit = DiagnosticsKit.Granted();
        var aborted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        kit.Server.RouteAsync("POST /v1/diagnostics", async (_, ct) =>
        {
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            }
            catch (OperationCanceledException)
            {
                aborted.TrySetResult(true);
                throw;
            }
            return new HttpResponseMessage(HttpStatusCode.OK);
        });
        Queue(kit);
        kit.Service.Diagnostics.WritePending(new DiagnosticEvent
        {
            Kind = DiagnosticKind.RunEnd,
            Fingerprint = "0c8d1e2f3a4b5c6d",
            At = kit.Time.GetUtcNow(),
            RunEnd = new RunEndDetail("unclean", 600, "1.2.0"),
        });
        kit.Service.Start();
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Service.SchedulerWaits >= 1));
        kit.Time.AdvanceToNextRepeating(TimeSpan.FromHours(1));
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("POST /v1/diagnostics").Count == 1 && kit.Server.InFlight == 1));

        await kit.Service.WithdrawAsync();

        Assert.True(await Task.WhenAny(aborted.Task, Task.Delay(4000)) == aborted.Task);
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.InFlight == 0));
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.False(Directory.Exists(kit.Paths.Diagnostics) && Directory.EnumerateFileSystemEntries(kit.Paths.Diagnostics).Any());
        var count = kit.Server.Requests.Count;
        kit.Time.Advance(TimeSpan.FromDays(2));
        await Task.Delay(50);
        Assert.Equal(count, kit.Server.Requests.Count);
        Assert.Single(kit.Server.To("DELETE /v1/installs/me"));
        Assert.Single(kit.Server.To("POST /v1/diagnostics"));
    }

    [Fact]
    public async Task DG24_ShowWhatIsSentShowsTheNextBatchExactlyAsSentAndSendsNothing()
    {
        using var kit = DiagnosticsKit.Granted();
        AddPerfEntry(kit);
        Queue(kit);
        Queue(kit, "UtilityProcessExited", "Unresponsive");
        kit.Store.StoreConfig(kit.Store.Credentials!.Id, TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes(FakeServer.ConfigWithDiagnostics()))!);

        var before = kit.Server.Requests.Count;
        var preview = kit.Service.PreviewNextDiagnostics();
        var again = kit.Service.PreviewNextDiagnostics();

        Assert.NotNull(preview);
        Assert.Equal(preview, again);
        Assert.Equal(before, kit.Server.Requests.Count);
        Assert.Equal(2, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Equal(1, kit.Service.Perf.ReadyCount);

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var sent = JsonNode.Parse(kit.Server.To("POST /v1/diagnostics")[0].BodyText)!;
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(preview!), sent));
    }

    [Fact]
    public void ThePreviewIsEmptyWithoutConsentWithoutTheServerFlagAndWithoutAnythingToSend()
    {
        using var off = DiagnosticsKit.Granted(grant: false);
        Assert.Null(off.Service.PreviewNextDiagnostics());

        using var gated = DiagnosticsKit.Granted();
        Queue(gated);
        Assert.Null(gated.Service.PreviewNextDiagnostics());

        using var empty = DiagnosticsKit.Granted();
        empty.Store.StoreConfig(empty.Store.Credentials!.Id, TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes(FakeServer.ConfigWithDiagnostics()))!);
        Assert.Null(empty.Service.PreviewNextDiagnostics());
    }

    [Fact]
    public async Task DG15_ASampledOutRunRecordsAndSendsNothing()
    {
        using var kit = DiagnosticsKit.Granted(FakeServer.ConfigWithDiagnostics(sample: 0));
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Service.Capture.Start();

        await kit.RunFor(TimeSpan.FromMinutes(5));
        Queue(kit);
        await kit.RunFor(TimeSpan.FromHours(2), startService: false);

        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Empty(kit.Server.To("POST /v1/diagnostics"));
    }

    [Fact]
    public async Task EventsRecordedBeforeConsentNeverAppearInAnyBatch()
    {
        using var kit = DiagnosticsKit.Granted(grant: false);
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 1, null, DiagnosticsKit.Window());
        kit.Service.Capture.Crash(new InvalidOperationException("x"), "appdomain");

        kit.Store.Grant(false);
        await kit.RunFor(TimeSpan.FromHours(2));

        Assert.Empty(kit.Server.To("POST /v1/diagnostics"));
    }
}
