using System.Net;
using System.Text.Json.Nodes;
using OsbManager.Core;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class ClientCaseTests
{
    private static readonly TimeSpan OneMinute = TimeSpan.FromMinutes(1);

    private static TelemetryKit ConsentedKit(double random = 0.5, IStatusSource? source = null, bool characters = false)
    {
        var kit = new TelemetryKit(random, source);
        kit.Store.Grant(characters);
        kit.Publish("account-a", TelemetryKit.Hunting());
        return kit;
    }

    private static List<TimeSpan> Gaps(IEnumerable<SeenRequest> requests)
    {
        var times = requests.Select(r => r.At).ToList();
        return times.Zip(times.Skip(1), (a, b) => b - a).ToList();
    }

    [Fact]
    public async Task C1_FreshInstallWithConsentOffMakesNoRequestInThirtyMinutes()
    {
        using var kit = new TelemetryKit();
        kit.Publish("account-a", TelemetryKit.Hunting());
        kit.Service.Start();

        for (var minute = 0; minute < 30; minute++)
        {
            kit.Time.Advance(OneMinute);
            await Task.Delay(2);
        }

        Assert.Empty(kit.Server.Requests);
        Assert.Equal(0, kit.Service.SchedulerWaits);
        Assert.Equal(0, kit.Time.RepeatingTimers);
    }

    [Fact]
    public async Task C2_ConsentOnRegistersOnceThenSendsAfterTheStartDelayOffTheCallingThread()
    {
        using var kit = ConsentedKit();
        var gameThread = Environment.CurrentManagedThreadId;
        var started = kit.Time.GetUtcNow();

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var first = kit.Server.Requests.Take(3).Select(r => r.Endpoint).ToList();
        Assert.Equal(["GET /v1/config", "POST /v1/installs", "POST /v1/telemetry"], first);
        Assert.Single(kit.Server.To("POST /v1/installs"));
        var delay = kit.Server.Requests[0].At - started;
        Assert.InRange(delay, TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(180));
        Assert.All(kit.Server.Requests, r =>
        {
            Assert.NotEqual(gameThread, r.ThreadId);
            Assert.False(r.HadSynchronizationContext);
            Assert.Equal("OSBManager/1.2.0 (Windows)", r.UserAgent);
        });
        var credentials = kit.Store.Credentials!;
        Assert.Equal("Bearer " + credentials.Bearer, kit.Server.To("POST /v1/telemetry")[0].Authorization);
        Assert.True(kit.Store.State.Registered);
        Assert.True(kit.Server.To("POST /v1/telemetry").Count >= 2);
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(0.5)]
    [InlineData(1.0)]
    public async Task C3_RepeatedServerErrorsBackOffWithFullJitterAndNeverWithinSixtySeconds(double random)
    {
        using var kit = ConsentedKit(random);
        kit.Server.FailEverything(HttpStatusCode.InternalServerError);

        await kit.RunFor(TimeSpan.FromHours(48));

        var gaps = Gaps(kit.Server.Requests);
        Assert.True(gaps.Count >= 8);
        Assert.All(gaps, gap => Assert.InRange(gap, OneMinute, TimeSpan.FromHours(6) + TimeSpan.FromSeconds(1)));
        if (random == 1.0)
        {
            var expected = new[] { 120, 240, 480, 960, 1920, 3840, 7680, 15360, 21600 };
            for (var i = 0; i < expected.Length; i++)
            {
                Assert.InRange(gaps[i].TotalSeconds, expected[i] - 1, expected[i] + 1);
            }
        }
        if (random == 0.0)
        {
            Assert.All(gaps, gap => Assert.InRange(gap.TotalSeconds, 60, 61));
        }
        Assert.All(kit.Server.Requests, r => Assert.Equal("GET /v1/config", r.Endpoint));
    }

    [Fact]
    public async Task C4_ARequestThatNeverGetsAnAnswerIsAbortedAtFifteenSecondsAndTheCallerIsNotBlocked()
    {
        using var kit = ConsentedKit();
        kit.Server.HangEverything();
        kit.Service.Start();
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Service.SchedulerWaits >= 1));

        Assert.True(kit.Time.AdvanceToNextRepeating(TimeSpan.FromHours(1)));
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.InFlight == 1));
        var sentAt = kit.Time.GetUtcNow();

        kit.Time.Advance(TimeSpan.FromSeconds(14.9));
        await Task.Delay(30);
        Assert.Equal(1, kit.Server.InFlight);

        kit.Time.Advance(TimeSpan.FromSeconds(0.2));
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.InFlight == 0 && kit.Service.SchedulerWaits >= 2));
        Assert.Single(kit.Server.Requests);

        var before = kit.Service.SchedulerWaits;
        Assert.True(kit.Time.AdvanceToNextRepeating(TimeSpan.FromHours(7)));
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.Requests.Count == 2));
        Assert.True(kit.Server.Requests[1].At - sentAt >= TimeSpan.FromSeconds(60));
        Assert.True(before >= 1);
    }

    [Fact]
    public async Task C5_RetryAfterOnTooManyRequestsIsHonoured()
    {
        using var kit = ConsentedKit();
        kit.Server.RouteSequence("POST /v1/telemetry",
            () => FakeServer.Problem(HttpStatusCode.TooManyRequests, "rate_limited", 120),
            () => FakeServer.Json(HttpStatusCode.Accepted, """{"accepted":1,"next_after_s":600}"""));

        await kit.RunFor(TimeSpan.FromMinutes(15));

        var telemetry = kit.Server.To("POST /v1/telemetry");
        Assert.True(telemetry.Count >= 2);
        var gap = telemetry[1].At - telemetry[0].At;
        Assert.InRange(gap.TotalSeconds, 120, 121);
    }

    [Fact]
    public async Task C6_ServiceUnavailableDisabledStopsTelemetryUntilTheNextConfigRead()
    {
        using var kit = ConsentedKit();
        kit.Server.RouteSequence("POST /v1/telemetry",
            () => FakeServer.Problem(HttpStatusCode.ServiceUnavailable, "disabled", 3600),
            () => FakeServer.Json(HttpStatusCode.Accepted, """{"accepted":1,"next_after_s":600}"""));

        await kit.RunFor(TimeSpan.FromHours(3));

        var endpoints = kit.Server.Requests.Select(r => r.Endpoint).ToList();
        var firstTelemetry = endpoints.IndexOf("POST /v1/telemetry");
        Assert.Equal("GET /v1/config", endpoints[firstTelemetry + 1]);
        Assert.Equal("POST /v1/telemetry", endpoints[firstTelemetry + 2]);
        var gap = kit.Server.Requests[firstTelemetry + 1].At - kit.Server.Requests[firstTelemetry].At;
        Assert.True(gap >= TimeSpan.FromSeconds(3600));
    }

    [Fact]
    public async Task C7_ConfigThatDisablesTelemetryStopsEverythingExceptConfigReads()
    {
        using var kit = ConsentedKit();
        kit.Server.Route("GET /v1/config", _ => FakeServer.Json(HttpStatusCode.OK, """{"schema":1,"telemetry":{"enabled":false,"interval_s":600},"reports":{"enabled":false,"screenshots":false},"client_ok":true,"message":null}"""));

        await kit.RunFor(TimeSpan.FromHours(24));

        Assert.Empty(kit.Server.To("POST /v1/telemetry"));
        Assert.Empty(kit.Server.To("POST /v1/installs"));
        var reads = kit.Server.To("GET /v1/config").Count;
        Assert.InRange(reads, 4, 5);
    }

    [Fact]
    public async Task C7_ClientThatIsTooOldSendsNothing()
    {
        using var kit = ConsentedKit();
        kit.Server.Route("GET /v1/config", _ => FakeServer.Json(HttpStatusCode.OK, """{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true,"screenshots":true},"client_ok":false,"message":"Update OSB Manager."}"""));

        await kit.RunFor(TimeSpan.FromHours(12));

        Assert.Empty(kit.Server.To("POST /v1/telemetry"));
        Assert.Equal("Update OSB Manager.", kit.Store.State.Config!.Message);
    }

    [Fact]
    public async Task C8_ConfigIntervalOfTenSecondsIsRaisedToThreeHundred()
    {
        using var kit = ConsentedKit(random: 0.0);
        kit.Server.Route("GET /v1/config", _ => FakeServer.Json(HttpStatusCode.OK, """{"schema":1,"telemetry":{"enabled":true,"interval_s":10},"reports":{"enabled":true,"screenshots":true},"client_ok":true,"message":null}"""));
        kit.Server.Route("POST /v1/telemetry", _ => FakeServer.Json(HttpStatusCode.Accepted, """{"accepted":1,"next_after_s":0}"""));

        await kit.RunFor(TimeSpan.FromHours(2));

        var gaps = Gaps(kit.Server.To("POST /v1/telemetry"));
        Assert.True(gaps.Count >= 20);
        Assert.All(gaps, gap => Assert.InRange(gap.TotalSeconds, 269, 331));
        Assert.Equal(300, kit.Store.State.Config!.IntervalSeconds);
    }

    [Fact]
    public async Task C9_AnUnauthorizedAnswerReRegistersOnceAndTheSecondOneStopsSending()
    {
        using var kit = ConsentedKit();
        kit.Server.Route("POST /v1/telemetry", _ => FakeServer.Problem(HttpStatusCode.Unauthorized, "unauthorized"));

        await kit.RunFor(TimeSpan.FromHours(48));

        Assert.Equal(2, kit.Server.To("POST /v1/installs").Count);
        Assert.Equal(2, kit.Server.To("POST /v1/telemetry").Count);
        Assert.Equal("POST /v1/telemetry", kit.Server.Requests[^1].Endpoint);
        Assert.Contains(kit.LogLines, line => line.Contains("stopped"));
    }

    [Fact]
    public async Task C10_AConflictOnRegistrationCreatesANewIdAndKeyAndRegistersAgain()
    {
        using var kit = ConsentedKit();
        var originalId = kit.Store.Credentials!.Id;
        kit.Server.RouteSequence("POST /v1/installs",
            () => FakeServer.Problem(HttpStatusCode.Conflict, "install_conflict"),
            () => FakeServer.Json(HttpStatusCode.Created, """{"install_id":"x","status":"quarantined"}"""));

        await kit.RunFor(TimeSpan.FromMinutes(5));

        var registrations = kit.Server.To("POST /v1/installs");
        Assert.Equal(2, registrations.Count);
        var first = JsonNode.Parse(registrations[0].BodyText)!;
        var second = JsonNode.Parse(registrations[1].BodyText)!;
        Assert.Equal(originalId, (string)first["install_id"]!);
        Assert.NotEqual((string)first["install_id"]!, (string)second["install_id"]!);
        Assert.NotEqual((string)first["install_key"]!, (string)second["install_key"]!);
        Assert.Equal((string)second["install_id"]!, kit.Store.Credentials!.Id);
        Assert.Contains((string)second["install_id"]!, kit.Server.To("POST /v1/telemetry")[0].Authorization);
    }

    [Fact]
    public async Task C11_CharactersAreAbsentWithoutTheSecondConsentAndPresentWithIt()
    {
        using var kit = ConsentedKit();
        await kit.RunFor(TimeSpan.FromMinutes(25));
        var withoutConsent = kit.Server.To("POST /v1/telemetry");
        Assert.NotEmpty(withoutConsent);
        Assert.All(withoutConsent, r =>
        {
            Assert.DoesNotContain("character", r.BodyText);
            Assert.DoesNotContain("Example", r.BodyText);
        });

        kit.Service.SetCharacters(true);
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("PUT /v1/installs/me/consent").Count == 1));
        Assert.Contains("\"characters\":true", kit.Server.To("PUT /v1/installs/me/consent")[0].BodyText);
        var before = kit.Server.To("POST /v1/telemetry").Count;
        await kit.RunFor(TimeSpan.FromMinutes(25), startService: false);
        var withConsent = kit.Server.To("POST /v1/telemetry").Skip(before).ToList();
        Assert.NotEmpty(withConsent);
        Assert.All(withConsent, r => Assert.Equal("Example", (string)JsonNode.Parse(r.BodyText)!["accounts"]![0]!["character"]!["name"]!));

        kit.Service.SetCharacters(false);
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("PUT /v1/installs/me/consent").Count == 2));
        Assert.Contains("\"characters\":false", kit.Server.To("PUT /v1/installs/me/consent")[1].BodyText);
        before = kit.Server.To("POST /v1/telemetry").Count;
        await kit.RunFor(TimeSpan.FromMinutes(25), startService: false);
        Assert.All(kit.Server.To("POST /v1/telemetry").Skip(before), r => Assert.DoesNotContain("character", r.BodyText));
    }

    [Fact]
    public async Task C12_WithdrawingConsentSendsDeleteAndWipesTheLocalIdAndKeyEvenWhenDeleteFails()
    {
        using var kit = ConsentedKit();
        kit.Server.Route("DELETE /v1/installs/me", _ => new HttpResponseMessage(HttpStatusCode.InternalServerError));
        await kit.RunFor(TimeSpan.FromMinutes(15));
        var credentials = kit.Store.Credentials!;
        Assert.True(kit.Store.State.Registered);

        var result = await kit.Service.WithdrawAsync();

        Assert.Equal(DeletionResult.Failed, result);
        var delete = kit.Server.To("DELETE /v1/installs/me");
        Assert.Single(delete);
        Assert.Equal("Bearer " + credentials.Bearer, delete[0].Authorization);
        Assert.Null(kit.Store.Credentials);
        Assert.Null(kit.Store.State.InstallId);
        Assert.False(kit.Store.State.Granted);
        var file = File.ReadAllText(kit.Paths.PrivacyFile);
        Assert.DoesNotContain(credentials.Id, file);
        Assert.DoesNotContain(credentials.Key, file);
        Assert.Equal(credentials.Id, kit.Service.FailedDeletionInstallId);
        var requests = kit.Server.Requests.Count;
        await kit.RunFor(TimeSpan.FromHours(24), startService: false);
        Assert.Equal(requests, kit.Server.Requests.Count);
    }

    [Fact]
    public async Task C12_WithdrawingWhileTheServerNeverAnswersWipesLocallyAtOnce()
    {
        using var kit = ConsentedKit();
        await kit.RunFor(TimeSpan.FromMinutes(15));
        kit.Server.Hang("DELETE /v1/installs/me");
        var id = kit.Store.Credentials!.Id;

        var pending = kit.Service.WithdrawAsync();

        Assert.Null(kit.Store.Credentials);
        Assert.False(kit.Store.State.Granted);
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.InFlight == 1));
        kit.Time.Advance(TimeSpan.FromSeconds(15.1));
        Assert.Equal(DeletionResult.Failed, await pending);
        Assert.Equal(id, kit.Service.FailedDeletionInstallId);
    }

    [Fact]
    public async Task C13_APayloadOverTheLimitIsCutToTheAccountsThatFit()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.2.0", time, maxBytes: 3000);
        var snapshots = Enumerable.Range(0, 20)
            .Select(i => new AccountSnapshot($"account-{i}", "ExampleServer", TelemetryKit.Hunting($"Character{i}"), time.GetUtcNow().AddSeconds(-i)))
            .ToList();

        var batch = builder.Build(snapshots, new byte[32], includeCharacters: true);

        Assert.NotNull(batch);
        Assert.True(batch.Body.Length <= 3000);
        Assert.InRange(batch.Accounts, 1, 19);
        Assert.Equal(batch.Accounts, JsonNode.Parse(batch.Body)!["accounts"]!.AsArray().Count);
        Assert.True(TelemetryLimits.SoftBodyBytes < TelemetryLimits.MaxBodyBytes);
        await Task.CompletedTask;
    }

    [Fact]
    public void C13_TwentyFullAccountsStayUnderTheServerLimit()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.2.0", time);
        var longName = new string('x', 32);
        var snapshots = Enumerable.Range(0, 40)
            .Select(i => new AccountSnapshot($"account-{i}", longName, TelemetryKit.Hunting(longName), time.GetUtcNow()))
            .ToList();

        var batch = builder.Build(snapshots, new byte[32], includeCharacters: true);

        Assert.NotNull(batch);
        Assert.Equal(20, batch.Accounts);
        Assert.True(batch.Body.Length <= TelemetryLimits.MaxBodyBytes);
    }

    [Fact]
    public async Task C16_ThreeUnexpectedErrorsSwitchTelemetryOffAndTheRestKeepsWorking()
    {
        var source = new ThrowingSource();
        using var kit = ConsentedKit(source: source);

        await kit.RunFor(TimeSpan.FromHours(48));

        Assert.True(kit.Service.DisabledByFailSafe);
        Assert.Equal(3, source.Calls);
        Assert.Single(kit.LogLines, line => line.Contains("switched off"));
        kit.Statuses.Publish("account-b", "", TelemetryKit.Hunting(), DateTimeOffset.UtcNow);
        Assert.Equal(2, kit.Statuses.Snapshot().Count);
        Assert.Empty(kit.Server.To("POST /v1/telemetry"));
    }

    [Fact]
    public async Task C17_ARedirectAnswerIsAFailureAndIsNotFollowed()
    {
        using var kit = ConsentedKit();
        kit.Server.Route("GET /v1/config", _ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.Found);
            response.Headers.Location = new Uri("https://evil.example/collect");
            return response;
        });

        await kit.RunFor(TimeSpan.FromHours(6));

        Assert.NotEmpty(kit.Server.Requests);
        Assert.All(kit.Server.Requests, r => Assert.Equal("/v1/config", r.Path));
        Assert.All(Gaps(kit.Server.Requests), gap => Assert.True(gap >= OneMinute));
        Assert.Empty(kit.Server.To("POST /v1/telemetry"));
    }

    private sealed class ThrowingSource : IStatusSource
    {
        private int calls;

        public int Calls => Volatile.Read(ref calls);

        public IReadOnlyList<AccountSnapshot> Snapshot()
        {
            Interlocked.Increment(ref calls);
            throw new InvalidOperationException("injected");
        }
    }
}
