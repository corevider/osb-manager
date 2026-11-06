using System.Security.Cryptography;
using System.Text;
using OsbManager.Browser;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class PrivacyStoreTests
{
    private static PrivacyStore Load(TempDirectory directory, FakeTimeProvider? time = null, List<string>? log = null) =>
        PrivacyStore.Load(directory.File("privacy.json"), new InstallKeyProtector(), time ?? new FakeTimeProvider(), log is null ? null : log.Add);

    [Fact]
    public void ConsentIsOffWhenThereIsNoFile()
    {
        using var directory = new TempDirectory();

        var state = Load(directory).State;

        Assert.Equal(ConsentStatus.Undecided, state.Status);
        Assert.False(state.Granted);
        Assert.True(state.NeedsAnswer);
        Assert.Null(state.InstallId);
        Assert.Null(Load(directory).Credentials);
    }

    [Fact]
    public void TheInstallKeyRoundTripsThroughDpapiAndIsNeverWrittenInThePlain()
    {
        using var directory = new TempDirectory();
        var store = Load(directory);

        store.Grant(characters: false);
        var credentials = store.Credentials!;
        var text = File.ReadAllText(directory.File("privacy.json"));

        Assert.DoesNotContain(credentials.Key, text);
        Assert.Contains("protectedInstallKey", text);
        var reloaded = Load(directory).Credentials;
        Assert.Equal(credentials, reloaded);
        Assert.Equal(32, credentials.KeyBytes().Length);
        Assert.Equal(43, credentials.Key.Length);
        Assert.DoesNotContain('=', credentials.Key);
        Assert.Matches("^[A-Za-z0-9_-]{43}$", credentials.Key);
    }

    [Fact]
    public void TheInstallKeyUsesItsOwnEntropyNotTheLoginOne()
    {
        var sealedKey = new InstallKeyProtector().Protect("kq3Vt3N1rA8b0bq3QyU2sQj3XcYw8m3cXzq8b6F0wJs");
        var bytes = Convert.FromBase64String(sealedKey);

        Assert.Equal("kq3Vt3N1rA8b0bq3QyU2sQj3XcYw8m3cXzq8b6F0wJs",
            Encoding.UTF8.GetString(ProtectedData.Unprotect(bytes, "OsbManager.installkey.v1"u8.ToArray(), DataProtectionScope.CurrentUser)));
        Assert.Throws<CryptographicException>(() => ProtectedData.Unprotect(bytes, "OsbManager.login.v1"u8.ToArray(), DataProtectionScope.CurrentUser));
        Assert.Null(new InstallKeyProtector().Unprotect("not base64!"));
        Assert.Null(new InstallKeyProtector().Unprotect(Convert.ToBase64String(new byte[40])));
    }

    [Fact]
    public void TheInstallIdIsAVersionFourUuid()
    {
        var id = PrivacyStore.NewInstallId();

        Assert.True(Guid.TryParseExact(id, "D", out _));
        Assert.Equal('4', id[14]);
        Assert.Contains(id[19], "89ab");
        Assert.NotEqual(id, PrivacyStore.NewInstallId());
    }

    [Theory]
    [InlineData("{not json")]
    [InlineData("")]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("{\"usageConsentVersion\": \"yes\"}")]
    public void ACorruptPrivacyFileFallsBackToConsentOff(string content)
    {
        using var directory = new TempDirectory();
        File.WriteAllText(directory.File("privacy.json"), content);

        var store = Load(directory);

        Assert.False(store.State.Granted);
        Assert.Null(store.Credentials);
        Assert.Equal(ConsentStatus.Undecided, store.State.Status);
    }

    [Theory]
    [InlineData("""{"usageConsentVersion":1,"installId":"3f0b2c1e-7d4a-4c55-9a51-2b8f7e4c9d10"}""")]
    [InlineData("""{"usageConsentVersion":1,"installId":"3f0b2c1e-7d4a-4c55-9a51-2b8f7e4c9d10","protectedInstallKey":"AAAA"}""")]
    [InlineData("""{"usageConsentVersion":1,"installId":"not-a-guid","protectedInstallKey":"AAAA"}""")]
    [InlineData("""{"usageConsentVersion":1,"protectedInstallKey":"AAAA"}""")]
    public void ConsentWithoutAValidIdentityIsOff(string content)
    {
        using var directory = new TempDirectory();
        File.WriteAllText(directory.File("privacy.json"), content);
        var log = new List<string>();

        var store = Load(directory, log: log);

        Assert.False(store.State.Granted);
        Assert.Null(store.Credentials);
        Assert.NotEmpty(log);
    }

    [Fact]
    public void AKeyThatThisWindowsUserCannotOpenTurnsConsentOff()
    {
        using var directory = new TempDirectory();
        var store = Load(directory);
        store.Grant(false);
        var id = store.Credentials!.Id;
        File.WriteAllText(directory.File("privacy.json"),
            $$"""{"usageConsentVersion":1,"installId":"{{id}}","protectedInstallKey":"{{Convert.ToBase64String(RandomNumberGenerator.GetBytes(80))}}"}""");

        Assert.False(Load(directory).State.Granted);
    }

    [Fact]
    public void GrantingRecordsTheVersionAndTheTime()
    {
        using var directory = new TempDirectory();
        var time = new FakeTimeProvider();
        var store = Load(directory, time);

        var state = store.Grant(characters: false);

        Assert.True(state.Granted);
        Assert.Equal(TelemetryLimits.ConsentVersion, state.UsageConsentVersion);
        Assert.Equal(time.GetUtcNow(), state.UsageConsentedAt);
        Assert.False(state.CharactersConsent);
        Assert.Null(state.CharactersConsentedAt);
        Assert.False(state.Registered);
        Assert.Equal(TelemetryLimits.ConsentVersion, Load(directory).State.UsageConsentVersion);
    }

    [Fact]
    public void TheSecondConsentNeedsTheFirstAndIsRecordedSeparately()
    {
        using var directory = new TempDirectory();
        var time = new FakeTimeProvider();
        var store = Load(directory, time);

        Assert.False(store.SetCharacters(true));
        store.Grant(false);
        time.Advance(TimeSpan.FromMinutes(3));
        Assert.True(store.SetCharacters(true));

        var state = Load(directory, time).State;
        Assert.True(state.CharactersConsent);
        Assert.Equal(time.GetUtcNow(), state.CharactersConsentedAt);
        store.SetCharacters(false);
        Assert.False(Load(directory, time).State.CharactersConsent);
    }

    [Fact]
    public void DecliningIsRememberedAndKeepsEverythingOff()
    {
        using var directory = new TempDirectory();
        var store = Load(directory);

        store.Decline();

        var reloaded = Load(directory);
        Assert.Equal(ConsentStatus.Declined, reloaded.State.Status);
        Assert.False(reloaded.State.NeedsAnswer);
        Assert.Null(reloaded.State.InstallId);
        Assert.Null(reloaded.Credentials);
    }

    [Fact]
    public void WithdrawingWipesTheIdAndTheKeyFromMemoryAndFromTheFile()
    {
        using var directory = new TempDirectory();
        var store = Load(directory);
        store.Grant(true);
        store.MarkRegistered(store.Credentials!.Id, true);
        var old = store.Credentials!;

        var result = store.Withdraw();

        Assert.Equal(old, result.Credentials);
        Assert.True(result.WasRegistered);
        Assert.Null(store.Credentials);
        Assert.Equal(ConsentStatus.Withdrawn, store.State.Status);
        Assert.False(store.State.CharactersConsent);
        var text = File.ReadAllText(directory.File("privacy.json"));
        Assert.DoesNotContain(old.Id, text);
        Assert.DoesNotContain("installId\": \"", text);
        Assert.Equal(ConsentStatus.Withdrawn, Load(directory).State.Status);
    }

    [Fact]
    public void ARegistrationAnswerForAWithdrawnIdentityChangesNothing()
    {
        using var directory = new TempDirectory();
        var store = Load(directory);
        store.Grant(false);
        var old = store.Credentials!;
        store.Withdraw();

        store.MarkRegistered(old.Id, false);
        store.RecordSend(old.Id, "sent", sent: true);
        store.StoreConfig(old.Id, TelemetryConfig.Disabled);

        Assert.False(store.State.Registered);
        Assert.Null(store.State.LastSentAt);
        Assert.Null(store.State.Config);
    }

    private sealed class BrokenProtector : OsbManager.Core.Accounts.ICredentialProtector
    {
        public string Protect(string secret) => throw new CryptographicException("no key store");

        public string? Unprotect(string protectedSecret) => null;
    }

    [Fact]
    public void WhenTheKeyCannotBeProtectedConsentStaysOffAndNothingIsStored()
    {
        using var directory = new TempDirectory();
        var log = new List<string>();
        var store = PrivacyStore.Load(directory.File("privacy.json"), new BrokenProtector(), new FakeTimeProvider(), log.Add);

        var state = store.Grant(true);

        Assert.False(state.Granted);
        Assert.Null(store.Credentials);
        Assert.Null(state.InstallId);
        Assert.NotEmpty(log);
        Assert.False(File.Exists(directory.File("privacy.json")));
    }

    [Fact]
    public void AnUnwritableFileDoesNotStopTheConsentFromBeingHonoured()
    {
        using var directory = new TempDirectory();
        Directory.CreateDirectory(directory.File("privacy.json"));
        var log = new List<string>();
        var store = Load(directory, log: log);

        store.Grant(false);
        store.Withdraw();

        Assert.False(store.State.Granted);
        Assert.NotEmpty(log);
    }
}
