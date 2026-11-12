using System.Text.Json.Nodes;
using OsbManager.Browser;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class DiagnosticsConsentTests
{
    private const string OldIdentityId = "3f0b2c1e-7d4a-4c55-9a51-2b8f7e4c9d10";

    private static string VersionOnePrivacyFile(bool registered = true)
    {
        var sealedKey = new InstallKeyProtector().Protect(PrivacyStore.NewInstallKey());
        return new JsonObject
        {
            ["usageConsentVersion"] = 1,
            ["usageConsentTextId"] = "2026-11-04.1",
            ["usageConsentedAt"] = "2026-11-05T10:00:00+00:00",
            ["decision"] = "Granted",
            ["installId"] = OldIdentityId,
            ["protectedInstallKey"] = sealedKey,
            ["registered"] = registered,
        }.ToJsonString();
    }

    private static DiagnosticEvent Crash(DateTimeOffset at, string fingerprint = "5b0e2a9c41d7f308") => new()
    {
        Kind = DiagnosticKind.ProcessFailed,
        Fingerprint = fingerprint,
        At = at,
        Process = new ProcessDetail("render_process_exited", "out_of_memory", "0xE0000008"),
        Trail = [new TrailItem(-5, "info", "window", TrailCodes.WindowStart, Window: 1)],
    };

    private static void Exercise(TelemetryKit kit)
    {
        var now = kit.Time.GetUtcNow();
        kit.Service.Diagnostics.Trail.Info(TrailCodes.WindowStart, 1);
        kit.Service.Diagnostics.Record(Crash(now));
        kit.Service.Diagnostics.WritePending(Crash(now, "0c8d1e2f3a4b5c6d"));
    }

    private static void AssertNothingRecorded(TelemetryKit kit)
    {
        Assert.False(kit.Service.Diagnostics.Recording);
        Assert.Equal(0, kit.Service.Diagnostics.Trail.Count);
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.False(Directory.Exists(kit.Paths.Diagnostics) && Directory.EnumerateFileSystemEntries(kit.Paths.Diagnostics).Any());
    }

    [Fact]
    public async Task AVersionOneShareIsOutdatedSendsNothingRecordsNothingAndAsksWithTheLeadLine()
    {
        using var kit = new TelemetryKit(privacyFile: VersionOnePrivacyFile());
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Service.Start();

        Exercise(kit);
        await Task.Delay(30);
        kit.Time.Advance(TimeSpan.FromDays(1));
        await Task.Delay(30);
        kit.Service.Stop(TimeSpan.FromSeconds(1));

        var state = kit.Store.State;
        Assert.Equal(ConsentStatus.Outdated, state.Status);
        Assert.True(state.NeedsAnswer);
        Assert.True(state.SharedBefore);
        Assert.False(state.Granted);
        Assert.Null(kit.Store.Credentials);
        Assert.Empty(kit.Server.Requests);
        AssertNothingRecorded(kit);
    }

    [Fact]
    public void AFreshInstallAsksWithoutTheLeadLine()
    {
        using var kit = new TelemetryKit();

        Assert.True(kit.Store.State.NeedsAnswer);
        Assert.False(kit.Store.State.SharedBefore);
    }

    [Theory]
    [InlineData("{ not json")]
    [InlineData("")]
    [InlineData("[]")]
    [InlineData("{\"usageConsentVersion\":2,\"usageConsentTextId\":\"2026-11-12.1\",\"decision\":\"Granted\"}")]
    [InlineData("{\"usageConsentVersion\":2,\"usageConsentTextId\":\"2026-11-12.1\",\"installId\":\"3f0b2c1e-7d4a-4c55-9a51-2b8f7e4c9d10\",\"protectedInstallKey\":\"AQAAANCMnd8BFdERjHoAwE\"}")]
    public void DG2_ACorruptOrUnreadablePrivacyFileIsOffAndRecordsNothing(string content)
    {
        using var kit = new TelemetryKit(privacyFile: content);

        Exercise(kit);

        Assert.False(kit.Store.State.Granted);
        AssertNothingRecorded(kit);
    }

    [Fact]
    public async Task DG2_DeclinedAndWithdrawnRecordNothing()
    {
        using var declined = new TelemetryKit();
        declined.Service.Decline();
        Exercise(declined);
        AssertNothingRecorded(declined);

        using var withdrawn = new TelemetryKit();
        withdrawn.Service.Accept(characters: false);
        await withdrawn.Service.WithdrawAsync();
        Exercise(withdrawn);
        AssertNothingRecorded(withdrawn);
        Assert.Equal(ConsentStatus.Withdrawn, withdrawn.Store.State.Status);
    }

    [Fact]
    public void DG1_ConsentOffWritesNoDiagnosticsFolderEvenForACrash()
    {
        using var kit = new TelemetryKit();

        Exercise(kit);
        kit.Service.Diagnostics.Pending.Write("{}"u8.ToArray());

        Assert.False(Directory.Exists(kit.Paths.Diagnostics));
        Assert.Empty(kit.Server.Requests);
    }

    [Fact]
    public void LeftoverDiagnosticsFilesAreDeletedAtStartWhenConsentIsOff()
    {
        using var directory = new TempDirectory();
        var folder = Path.Combine(directory.Path, "diagnostics");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "pending-1700000000-0a0b0c0d.json"), "{}");
        File.WriteAllText(Path.Combine(folder, "run.json"), "{}");
        var store = PrivacyStore.Load(Path.Combine(directory.Path, "privacy.json"), new InstallKeyProtector(), new FakeTimeProvider());

        using var hub = new DiagnosticsHub(folder, new PrivateTerms(), new FakeTimeProvider(), () => store.State.Granted, 0);

        Assert.Empty(Directory.EnumerateFiles(folder));
    }

    [Fact]
    public void DG4_NothingRecordedBeforeConsentAppearsAfterIt()
    {
        using var kit = new TelemetryKit();
        Exercise(kit);

        kit.Service.Accept(characters: false);

        Assert.True(kit.Service.Diagnostics.Recording);
        Assert.Equal(0, kit.Service.Diagnostics.Trail.Count);
        Assert.Empty(kit.Service.Diagnostics.Limiter.Take().Events);
        Assert.Empty(kit.Service.Diagnostics.Pending.Load());
    }

    [Fact]
    public async Task TurningTheSwitchOnAgainStartsWithEmptyBuffers()
    {
        using var kit = new TelemetryKit();
        kit.Service.Accept(characters: false);
        Exercise(kit);
        Assert.Equal(1, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Single(kit.Service.Diagnostics.Pending.Load());

        await kit.Service.WithdrawAsync();
        Exercise(kit);
        kit.Service.Accept(characters: false);

        Assert.True(kit.Service.Diagnostics.Recording);
        Assert.Equal(0, kit.Service.Diagnostics.Trail.Count);
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Empty(kit.Service.Diagnostics.Pending.Load());
    }

    [Fact]
    public async Task SwitchingOffWipesBuffersAndFilesCancelsTheSessionAndSendsOneDelete()
    {
        using var kit = new TelemetryKit();
        kit.Store.Grant(false);
        kit.Publish("a", TelemetryKit.Hunting());
        await kit.RunFor(TimeSpan.FromMinutes(15));
        Assert.True(kit.Store.State.Registered);
        Exercise(kit);
        File.WriteAllText(Path.Combine(kit.Paths.Diagnostics, "run.json"), "{}");
        var session = kit.Service.Diagnostics.Session;
        var wiped = 0;
        kit.Service.Diagnostics.Wiped += () => wiped++;
        var before = kit.Server.Requests.Count;

        var result = await kit.Service.WithdrawAsync();

        Assert.Equal(DeletionResult.Deleted, result);
        Assert.True(session.IsCancellationRequested);
        Assert.False(kit.Service.Diagnostics.Session.IsCancellationRequested);
        Assert.True(wiped >= 1);
        AssertNothingRecorded(kit);
        Assert.Single(kit.Server.To("DELETE /v1/installs/me"));
        Assert.Equal(before + 1, kit.Server.Requests.Count);
        await kit.RunFor(TimeSpan.FromHours(6), startService: false);
        Assert.Equal(before + 1, kit.Server.Requests.Count);
    }

    [Fact]
    public async Task DecliningTheOutdatedPromptWipesAndDeletesTheOldInstall()
    {
        using var kit = new TelemetryKit(privacyFile: VersionOnePrivacyFile());

        kit.Service.Decline();

        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("DELETE /v1/installs/me").Count == 1));
        Assert.Single(kit.Server.Requests);
        Assert.False(kit.Store.State.NeedsAnswer);
        Assert.False(kit.Store.State.SharedBefore);
        AssertNothingRecorded(kit);
    }

    [Fact]
    public async Task AcceptingTheOutdatedPromptRegistersAgainWithVersionTwo()
    {
        using var kit = new TelemetryKit(privacyFile: VersionOnePrivacyFile());
        kit.Publish("a", TelemetryKit.Hunting());

        kit.Service.Accept(characters: false);
        await kit.RunFor(TimeSpan.FromMinutes(5));

        Assert.True(kit.Store.State.Granted);
        Assert.Equal(2, kit.Store.State.UsageConsentVersion);
        Assert.Equal("2026-11-12.1", kit.Store.State.UsageConsentTextId);
        var register = kit.Server.To("POST /v1/installs");
        Assert.Single(register);
        Assert.Equal(2, (int)JsonNode.Parse(register[0].BodyText)!["consent"]!["usage_version"]!);
        Assert.True(kit.Service.Diagnostics.Recording);
    }

    [Fact]
    public async Task TheConsentChangeRequestSendsVersionTwo()
    {
        using var kit = new TelemetryKit();
        kit.Store.Grant(false);
        kit.Publish("a", TelemetryKit.Hunting());
        await kit.RunFor(TimeSpan.FromMinutes(15));

        kit.Service.SetCharacters(true);

        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.To("PUT /v1/installs/me/consent").Count == 1));
        var body = JsonNode.Parse(kit.Server.To("PUT /v1/installs/me/consent")[0].BodyText)!;
        Assert.Equal(2, (int)body["usage_version"]!);
        Assert.True((bool)body["characters"]!);
    }

    [Fact]
    public async Task TheCharactersSwitchDoesNotResetDiagnostics()
    {
        using var kit = new TelemetryKit();
        kit.Service.Accept(characters: false);
        Exercise(kit);

        kit.Service.SetCharacters(true);
        await Task.Delay(30);

        Assert.Equal(1, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Equal(1, kit.Service.Diagnostics.Trail.Count);
    }
}
