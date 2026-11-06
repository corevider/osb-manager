using System.Net;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class ConsentGateTests
{
    public static TheoryData<string> OffStates => new() { "undecided", "declined", "withdrawn", "corrupt-file", "granted-then-withdrawn-before-first-send" };

    private static async Task<TelemetryKit> KitInState(string state)
    {
        var kit = new TelemetryKit(privacyFile: state == "corrupt-file" ? "{ this is not json" : null);
        switch (state)
        {
            case "declined":
                kit.Store.Decline();
                break;
            case "withdrawn":
                kit.Store.Grant(true);
                kit.Store.Withdraw();
                break;
            case "granted-then-withdrawn-before-first-send":
                kit.Store.Grant(true);
                kit.Service.Start();
                await Task.Delay(20);
                kit.Time.Advance(TimeSpan.FromSeconds(30));
                var result = await kit.Service.WithdrawAsync();
                Assert.Equal(DeletionResult.NothingToDelete, result);
                break;
        }
        return kit;
    }

    private static IEnumerable<BotStatus> Lifecycle()
    {
        yield return new BotStatus { Phase = "signed-out" };
        yield return new BotStatus { Phase = "signed-out", LoginStage = "connecting" };
        yield return new BotStatus { Phase = "character-select" };
        yield return TelemetryKit.Hunting();
        yield return TelemetryKit.Hunting() with { Hunting = false, TownTrip = true };
        yield return TelemetryKit.Hunting() with { Dead = true };
        yield return new BotStatus { InWorld = true, Phase = "world", GpuFailed = "adapter lost", GpuRetries = 3 };
        yield return new BotStatus { Phase = "\u0000weird", Level = 99999, Gold = long.MinValue };
    }

    [Theory]
    [MemberData(nameof(OffStates))]
    public async Task WithoutConsentTheWholeLifecycleMakesNoRequestAtAll(string state)
    {
        using var kit = await KitInState(state);
        kit.Service.Start();
        var step = 0;

        for (var tick = 0; tick < 24 * 6; tick++)
        {
            foreach (var status in Lifecycle())
            {
                kit.Publish("account-" + step++ % 3, status);
            }
            kit.Statuses.Remove("account-1");
            kit.Time.Advance(TimeSpan.FromMinutes(10));
            await Task.Delay(1);
        }
        _ = kit.Service.PreviewNextPayload();
        _ = ReportPayload.Build(ReportKind.Bug, "draft that is never sent", ReportDiagnostics.Build("1.2.0", "10", ".NET", [], []), "1.2.0", "en");
        _ = kit.Service.Reports.WouldBeAnonymous;
        kit.Service.SetCharacters(true);
        kit.Service.Stop(TimeSpan.FromSeconds(1));

        Assert.Empty(kit.Server.Requests);
        Assert.Equal(0, kit.Service.RetryWaits);
        Assert.False(kit.Store.State.Granted);
        Assert.Null(kit.Store.Credentials);
        Assert.False(kit.Store.State.CharactersConsent);
        Assert.Empty(kit.Outbox.Pending());
    }

    [Fact]
    public async Task WithoutConsentTheSchedulerHoldsNoTimerAndWaitsForNothing()
    {
        using var kit = new TelemetryKit();
        kit.Publish("a", TelemetryKit.Hunting());

        kit.Service.Start();
        await Task.Delay(30);
        kit.Time.Advance(TimeSpan.FromDays(2));
        await Task.Delay(30);

        Assert.Equal(0, kit.Service.SchedulerWaits);
        Assert.Equal(0, kit.Time.RepeatingTimers);
        Assert.Equal(0, kit.Time.OneShotTimers);
        Assert.Empty(kit.Server.Requests);
    }

    [Fact]
    public async Task TurningConsentOnStartsTheStartDelayAndOnlyThenTheFirstRequest()
    {
        using var kit = new TelemetryKit();
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Service.Start();
        await Task.Delay(20);
        kit.Time.Advance(TimeSpan.FromHours(3));
        Assert.Empty(kit.Server.Requests);

        kit.Service.Accept(characters: false);
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Service.SchedulerWaits >= 1));
        await Task.Delay(20);
        Assert.Empty(kit.Server.Requests);

        kit.Time.Advance(TimeSpan.FromSeconds(59));
        await Task.Delay(20);
        Assert.Empty(kit.Server.Requests);
        await kit.RunFor(TimeSpan.FromMinutes(5), startService: false);
        Assert.NotEmpty(kit.Server.Requests);
    }

    [Fact]
    public async Task WithdrawingStopsAllSendingAtOnceAndDropsTheQueuedReports()
    {
        using var kit = new TelemetryKit();
        kit.Store.Grant(false);
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Server.Route("POST /v1/reports", _ => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
        await kit.RunFor(TimeSpan.FromMinutes(5));
        for (var i = 0; i < 3; i++)
        {
            await kit.Service.Reports.SendNewAsync(ReportPayload.Build(ReportKind.Bug, "queued " + i, ReportDiagnostics.Build("1", "1", "1", [], []), "1.2.0", "en"), [1, 2, 3], CancellationToken.None);
        }
        Assert.Equal(3, kit.Outbox.Pending().Count);
        Assert.NotEmpty(Directory.GetFiles(kit.Paths.Outbox));

        await kit.Service.WithdrawAsync();
        var requests = kit.Server.Requests.Count;
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Time.Advance(TimeSpan.FromDays(3));
        await Task.Delay(50);

        Assert.Empty(kit.Outbox.Pending());
        Assert.Empty(kit.Outbox.Failed());
        Assert.Empty(Directory.GetFiles(kit.Paths.Outbox));
        Assert.Equal(requests, kit.Server.Requests.Count);
        Assert.Single(kit.Server.To("DELETE /v1/installs/me"));
    }

    [Fact]
    public async Task ARequestThatIsInFlightWhenConsentIsWithdrawnIsAbortedAndNothingFollows()
    {
        using var kit = new TelemetryKit();
        kit.Store.Grant(false);
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Server.Hang("POST /v1/telemetry");
        kit.Service.Start();
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Service.SchedulerWaits >= 1));
        kit.Time.AdvanceToNextRepeating(TimeSpan.FromHours(1));
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("POST /v1/telemetry").Count == 1 && kit.Server.InFlight == 1));

        await kit.Service.WithdrawAsync();

        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.InFlight == 0));
        var count = kit.Server.Requests.Count;
        kit.Time.Advance(TimeSpan.FromDays(2));
        await Task.Delay(50);
        Assert.Equal(count, kit.Server.Requests.Count);
    }

    [Fact]
    public async Task OnlyAnExplicitSendMakesARequestWithoutConsentAndItIsAnonymous()
    {
        using var kit = new TelemetryKit();
        kit.Service.Start();
        _ = ReportPayload.Build(ReportKind.Bug, "typing…", ReportDiagnostics.Build("1", "1", "1", [], []), "1.2.0", "en");
        await Task.Delay(20);
        Assert.Empty(kit.Server.Requests);

        await kit.Service.Reports.SendNewAsync(ReportPayload.Build(ReportKind.Bug, "now sent", ReportDiagnostics.Build("1", "1", "1", [], []), "1.2.0", "en"), null, CancellationToken.None);

        var request = Assert.Single(kit.Server.Requests);
        Assert.Equal("POST /v1/reports", request.Endpoint);
        Assert.Null(request.Authorization);
    }
}
