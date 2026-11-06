using OsbManager.Core.Accounts;
using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class AccountLoginTests
{
    [Fact]
    public void StoresOnlyTheProtectedPassword()
    {
        using var temp = new TempDirectory();
        var path = temp.File("accounts.json");
        var store = AccountStore.Load(path);
        var account = store.Add("hunter");

        store.UpdateLogin(account, new LoginDetails(" demo_account ", "s3cret-pass", "GlobalOfficial", "hunter", AutoLogin: true), new FakeProtector());

        var json = File.ReadAllText(path);
        Assert.DoesNotContain("s3cret-pass", json);
        var reloaded = Assert.Single(AccountStore.Load(path).Accounts);
        Assert.Equal("demo_account", reloaded.LoginId);
        Assert.True(reloaded.AutoLogin);
        Assert.True(reloaded.HasCredentials);
        Assert.Equal("s3cret-pass", AccountStore.RevealPassword(reloaded, new FakeProtector()));
    }

    [Fact]
    public void KeepsTheSavedPasswordWhenNoneIsEntered()
    {
        using var temp = new TempDirectory();
        var store = AccountStore.Load(temp.File("accounts.json"));
        var account = store.Add("hunter");
        var protector = new FakeProtector();
        store.UpdateLogin(account, new LoginDetails("demo_account", "first", "", "", AutoLogin: true), protector);

        store.UpdateLogin(account, new LoginDetails("demo_account", null, "", "healer", AutoLogin: true), protector);

        Assert.Equal("first", AccountStore.RevealPassword(account, protector));
        Assert.Equal("healer", account.Character);
    }

    [Fact]
    public void ForgettingThePasswordTurnsAutomaticLoginOff()
    {
        using var temp = new TempDirectory();
        var store = AccountStore.Load(temp.File("accounts.json"));
        var account = store.Add("hunter");
        store.UpdateLogin(account, new LoginDetails("demo_account", "pw", "", "", AutoLogin: true), new FakeProtector());

        store.ClearPassword(account);

        Assert.False(account.HasCredentials);
        Assert.False(account.AutoLogin);
        Assert.Null(AccountStore.RevealPassword(account, new FakeProtector()));
    }

    [Fact]
    public void ClearingTheLoginIdDropsThePassword()
    {
        using var temp = new TempDirectory();
        var store = AccountStore.Load(temp.File("accounts.json"));
        var account = store.Add("hunter");
        store.UpdateLogin(account, new LoginDetails("demo_account", "pw", "", "", AutoLogin: false), new FakeProtector());

        store.UpdateLogin(account, new LoginDetails("", null, "", "", AutoLogin: false), new FakeProtector());

        Assert.Null(account.ProtectedPassword);
    }

    [Fact]
    public void ReturnsNullWhenThePasswordCannotBeDecrypted()
    {
        var account = new Account { Id = "000000000000", Name = "hunter", LoginId = "demo_account", ProtectedPassword = "not-ours" };

        Assert.Null(AccountStore.RevealPassword(account, new FakeProtector()));
    }

    [Theory]
    [InlineData("", "pw", true, false, "Automatic login needs a login ID and a password.")]
    [InlineData("demo_account", null, true, false, "Automatic login needs a login ID and a password.")]
    [InlineData("ege\tcan", "pw", false, false, "Use a login ID of at most 256 characters, without control characters.")]
    public void ExplainsInvalidLoginSettings(string loginId, string? password, bool autoLogin, bool saved, string problem)
    {
        Assert.Equal(problem, AccountStore.LoginProblem(new LoginDetails(loginId, password, "", "", autoLogin), saved));
    }

    [Fact]
    public void AcceptsAutomaticLoginWithASavedPassword()
    {
        Assert.Null(AccountStore.LoginProblem(new LoginDetails("demo_account", null, "", "", AutoLogin: true), hasSavedPassword: true));
        Assert.NotNull(AccountStore.LoginProblem(new LoginDetails("demo_account", new string('x', 1025), "", "", false), false));
        Assert.NotNull(AccountStore.LoginProblem(new LoginDetails("demo_account", "pw", "", new string('c', 65), false), false));
    }

    private sealed class FakeProtector : ICredentialProtector
    {
        public string Protect(string secret) => "enc:" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(secret));

        public string? Unprotect(string protectedSecret) =>
            protectedSecret.StartsWith("enc:", StringComparison.Ordinal)
                ? System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(protectedSecret[4..]))
                : null;
    }
}

public class CredentialGateTests
{
    [Fact]
    public void AllowsFewRequestsSpacedApart()
    {
        var time = new DateTime(2026, 10, 29, 12, 0, 0, DateTimeKind.Utc);
        var gate = new CredentialGate(maxPerWindow: 3, window: TimeSpan.FromMinutes(10), minimumGap: TimeSpan.FromSeconds(15), clock: () => time);

        Assert.True(gate.TryTake());
        time = time.AddSeconds(5);
        Assert.False(gate.TryTake());
        time = time.AddSeconds(15);
        Assert.True(gate.TryTake());
        time = time.AddSeconds(20);
        Assert.True(gate.TryTake());
        time = time.AddSeconds(20);
        Assert.False(gate.TryTake());
        time = time.AddMinutes(10);
        Assert.True(gate.TryTake());
    }
}

public class LoginStatusTests
{
    [Fact]
    public void ReadsTheLoginStage()
    {
        var status = BotStatus.TryParse("""{"type":"status","linked":true,"login":{"stage":"failed","message":"Login did not work after 2 tries."}}""");

        Assert.True(status!.Linked);
        Assert.Equal("failed", status.LoginStage);
        Assert.Equal("Login did not work after 2 tries.", status.LoginMessage);
    }

    [Fact]
    public void BoundsTheLoginMessage()
    {
        var status = BotStatus.TryParse("{\"type\":\"status\",\"login\":{\"stage\":\"failed\",\"message\":\"" + new string('m', 500) + "\"}}");

        Assert.Equal(200, status!.LoginMessage!.Length);
    }

    [Theory]
    [InlineData("""{"type":"credentials-request"}""", "credentials-request")]
    [InlineData("""{"type":"status"}""", "status")]
    [InlineData("""{"kind":"x"}""", null)]
    [InlineData("""["credentials-request"]""", null)]
    [InlineData("broken", null)]
    public void ReadsTheMessageType(string json, string? type)
    {
        Assert.Equal(type, BotStatus.MessageType(json));
    }
}
