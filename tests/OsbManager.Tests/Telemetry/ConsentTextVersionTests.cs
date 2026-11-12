using System.Text.Json.Nodes;
using OsbManager.Browser;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class ConsentTextVersionTests
{
    private const string OldIdentityId = "3f0b2c1e-7d4a-4c55-9a51-2b8f7e4c9d10";

    private static string PrivacyFileWith(string? textId, bool registered = false, int version = 2)
    {
        var sealedKey = new InstallKeyProtector().Protect(PrivacyStore.NewInstallKey());
        var file = new JsonObject
        {
            ["usageConsentVersion"] = version,
            ["usageConsentedAt"] = "2026-10-01T10:00:00+00:00",
            ["decision"] = "Granted",
            ["installId"] = OldIdentityId,
            ["protectedInstallKey"] = sealedKey,
            ["registered"] = registered,
        };
        if (textId is not null)
        {
            file["usageConsentTextId"] = textId;
        }
        return file.ToJsonString();
    }

    private static PrivacyStore Load(TempDirectory directory, string content)
    {
        File.WriteAllText(directory.File("privacy.json"), content);
        return PrivacyStore.Load(directory.File("privacy.json"), new InstallKeyProtector(), new FakeTimeProvider());
    }

    [Fact]
    public void GrantingStoresTheTextVersionIdBesideTheWireVersion()
    {
        using var directory = new TempDirectory();
        var store = PrivacyStore.Load(directory.File("privacy.json"), new InstallKeyProtector(), new FakeTimeProvider());

        var state = store.Grant(characters: false);

        Assert.Equal("2026-11-12.1", TelemetryLimits.ConsentTextId);
        Assert.Equal(2, TelemetryLimits.ConsentVersion);
        Assert.Equal(TelemetryLimits.ConsentTextId, state.UsageConsentTextId);
        Assert.Equal(2, state.UsageConsentVersion);
        var text = File.ReadAllText(directory.File("privacy.json"));
        Assert.Contains("usageConsentTextId", text);
        Assert.Contains("2026-11-12.1", text);
        var reloaded = PrivacyStore.Load(directory.File("privacy.json"), new InstallKeyProtector(), new FakeTimeProvider()).State;
        Assert.True(reloaded.Granted);
        Assert.Equal("2026-11-12.1", reloaded.UsageConsentTextId);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("2026-10-31.9")]
    [InlineData("2026-11-03.1")]
    [InlineData("2026-11-04.0")]
    [InlineData("2026-11-04.1")]
    [InlineData("2026-11-12.0")]
    public void AConsentGivenToAnOlderOrUnknownTextCountsAsNoConsent(string? storedTextId)
    {
        using var directory = new TempDirectory();

        var store = Load(directory, PrivacyFileWith(storedTextId));

        Assert.False(store.State.Granted);
        Assert.Equal(ConsentStatus.Outdated, store.State.Status);
        Assert.True(store.State.NeedsAnswer);
        Assert.False(store.State.CharactersConsent);
        Assert.Null(store.Credentials);
    }

    [Theory]
    [InlineData("2026-11-12.1")]
    [InlineData("2026-11-12.2")]
    [InlineData("2027-02-01.1")]
    public void AConsentGivenToTheCurrentOrANewerTextStaysValid(string storedTextId)
    {
        using var directory = new TempDirectory();

        var store = Load(directory, PrivacyFileWith(storedTextId));

        Assert.True(store.State.Granted);
        Assert.NotNull(store.Credentials);
    }

    [Fact]
    public void AcceptingAgainRecordsTheCurrentTextAndKeepsTheInstall()
    {
        using var directory = new TempDirectory();
        var store = Load(directory, PrivacyFileWith(null));

        var state = store.Grant(characters: false);

        Assert.True(state.Granted);
        Assert.Equal(TelemetryLimits.ConsentTextId, state.UsageConsentTextId);
        Assert.Equal(OldIdentityId, state.InstallId);
        Assert.False(state.Registered);
    }

    [Fact]
    public async Task AnOutdatedConsentMakesNoRequestEvenWithGamesRunning()
    {
        using var kit = new TelemetryKit(privacyFile: PrivacyFileWith(null, registered: true));
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Service.Start();

        await Task.Delay(30);
        kit.Time.Advance(TimeSpan.FromDays(2));
        await Task.Delay(30);
        _ = kit.Service.PreviewNextPayload();
        kit.Service.SetCharacters(true);
        kit.Service.Stop(TimeSpan.FromSeconds(1));

        Assert.Equal(ConsentStatus.Outdated, kit.Store.State.Status);
        Assert.Empty(kit.Server.Requests);
        Assert.Equal(0, kit.Service.SchedulerWaits);
        Assert.Null(kit.Service.PreviewNextPayload());
    }

    [Fact]
    public async Task DecliningAnOutdatedConsentEndsTheOldOneAndDeletesTheServerRecord()
    {
        using var kit = new TelemetryKit(privacyFile: PrivacyFileWith("2026-10-01.1", registered: true));

        kit.Service.Decline();

        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("DELETE /v1/installs/me").Count == 1));
        Assert.Single(kit.Server.Requests);
        Assert.False(kit.Store.State.NeedsAnswer);
        Assert.Null(kit.Store.State.InstallId);
        Assert.Null(kit.Store.Credentials);
    }

    [Fact]
    public void DecliningAnOutdatedConsentOfAnInstallTheServerNeverSawSendsNothing()
    {
        using var kit = new TelemetryKit(privacyFile: PrivacyFileWith(null));

        kit.Service.Decline();

        Assert.False(kit.Store.State.NeedsAnswer);
        Assert.Null(kit.Store.State.InstallId);
        Assert.Empty(kit.Server.Requests);
    }

    [Fact]
    public async Task DecliningAnOutdatedConsentKeepsTheReportsTheUserAlreadyQueued()
    {
        using var kit = new TelemetryKit(privacyFile: PrivacyFileWith(null));
        kit.Outbox.Enqueue(ReportPayload.Build(ReportKind.Bug, "queued before", ReportDiagnostics.Build("1.2.0", "10", ".NET", [], []), "1.2.0", "en"), null, true, out _);

        kit.Service.Decline();
        await Task.Delay(30);

        Assert.Single(kit.Outbox.Pending());
    }
}
