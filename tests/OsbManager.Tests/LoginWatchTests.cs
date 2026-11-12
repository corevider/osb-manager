using OsbManager.Core.Accounts;
using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class LoginWatchTests
{
    private static readonly BotStatus NotStarted = new() { Phase = "signed-out", LoginStage = "off", Linked = true };
    private static readonly BotStatus Busy = new() { Phase = "authenticating", LoginStage = "waiting", Linked = true };
    private static readonly BotStatus Typing = new() { Phase = "signed-out", LoginStage = "connecting", Linked = true };
    private static readonly BotStatus InWorld = new() { Phase = "world", LoginStage = "done", InWorld = true, Character = "Hunter" };

    private DateTime time = new(2026, 11, 8, 11, 14, 15, DateTimeKind.Utc);

    private LoginWatch Watch() => new(() => time);

    private void Wait(int seconds) => time = time.AddSeconds(seconds);

    [Fact]
    public void SendsTheLoginSettingsAgainWhileThePageHasNotStartedTheLogin()
    {
        var watch = Watch();

        Assert.Equal(LoginAction.SendSettings, watch.Observe(NotStarted, autoLogin: true));
        Wait(1);
        Assert.Equal(LoginAction.None, watch.Observe(NotStarted, autoLogin: true));
        Wait(14);
        Assert.Equal(LoginAction.SendSettings, watch.Observe(NotStarted, autoLogin: true));
        Assert.Equal(LoginAction.None, watch.Observe(Typing, autoLogin: true));
        Assert.Equal(LoginAction.None, watch.Observe(NotStarted, autoLogin: false));
    }

    [Fact]
    public void ReloadsAPageStuckBeforeTheLoginOnceThenSaysWhy()
    {
        var watch = Watch();
        for (var second = 0; second < 179; second++)
        {
            Assert.NotEqual(LoginAction.Reload, watch.Observe(Busy, autoLogin: true));
            Wait(1);
        }
        Assert.Equal("Logging in (authenticating)", watch.StateText(Busy, true, true, "authenticating"));
        Wait(1);

        Assert.Equal(LoginAction.Reload, watch.Observe(Busy, autoLogin: true));
        Assert.False(watch.TakeWarning(Busy));
        Assert.Equal("Logging in (authenticating)", watch.StateText(Busy, true, true, "authenticating"));

        Wait(180);
        Assert.NotEqual(LoginAction.Reload, watch.Observe(NotStarted, autoLogin: true));
        Assert.True(watch.TakeWarning(NotStarted));
        Assert.False(watch.TakeWarning(NotStarted));
        Assert.Equal("Not logged in (login screen not found)", watch.StateText(NotStarted, true, true, "Login"));
        Wait(600);
        Assert.NotEqual(LoginAction.Reload, watch.Observe(NotStarted, autoLogin: true));
    }

    [Fact]
    public void ALoginThatIsRunningIsNeverReloaded()
    {
        var watch = Watch();
        Wait(600);

        Assert.Equal(LoginAction.None, watch.Observe(Typing, autoLogin: true));
        Assert.Equal(LoginAction.None, watch.Observe(Typing with { LoginStage = "choose", Phase = "character-select" }, autoLogin: true));
        Assert.Equal(LoginAction.None, watch.Observe(Typing with { LoginStage = "failed" }, autoLogin: true));
        Assert.Equal(LoginAction.None, watch.Observe(NotStarted, autoLogin: false));
    }

    [Fact]
    public void ShowsNotLoggedInWithTheReasonAfterThreeMinutes()
    {
        var watch = Watch();
        Assert.Null(watch.StateText(NotStarted, true, true, "Login"));
        Assert.Equal("Login (auto login off)", watch.StateText(NotStarted, false, true, "Login"));
        Assert.Equal("Login (no saved login)", watch.StateText(NotStarted, true, false, "Login"));
        Assert.Null(watch.StateText(Typing, true, true, "Logging in"));
        Assert.Null(watch.StateText(null, true, true, "Loading"));

        Wait(180);
        Assert.Equal("Not logged in (auto login off)", watch.StateText(NotStarted, false, true, "Login"));
        Assert.Equal("Not logged in (no saved login)", watch.StateText(NotStarted, true, false, "Login"));
        Assert.Equal("Not logged in (login screen not found)", watch.StateText(NotStarted, true, true, "Login"));
        Assert.Equal("Not logged in (the game stayed at authenticating)", watch.StateText(Busy, true, true, "authenticating"));
        Assert.Equal("Not logged in (login did not finish)", watch.StateText(Typing, true, true, "Logging in"));
        Assert.Equal("Not logged in (choose a character)", watch.StateText(Typing with { LoginStage = "choose" }, true, true, "Choose a character"));
        Assert.Equal("Not logged in (auto login stopped)", watch.StateText(Typing with { LoginStage = "failed" }, true, true, "Auto login stopped"));
        Assert.Null(watch.StateText(InWorld, true, true, "In game"));
    }

    [Fact]
    public void CountsFromTheMomentTheCharacterLeftTheWorld()
    {
        var watch = Watch();
        Wait(170);
        watch.Observe(InWorld, autoLogin: true);
        Wait(3600);
        Assert.Null(watch.StateText(InWorld, true, true, "In game"));

        watch.Observe(Typing, autoLogin: true);
        Wait(179);
        Assert.Null(watch.StateText(Typing, true, true, "Logging in"));
        Assert.False(watch.TakeWarning(Typing));
        Wait(1);
        Assert.True(watch.TakeWarning(Typing));
        Assert.Equal("Not logged in (login did not finish)", watch.StateText(Typing, true, true, "Logging in"));
    }

    [Fact]
    public void ANewWindowAfterARestartStartsWithFreshLoginState()
    {
        var before = Watch();
        var gate = new CredentialGate(clock: () => time);
        Assert.True(gate.TryTake());
        before.Observe(Typing, autoLogin: true);
        Wait(180);
        before.Observe(Typing, autoLogin: true);
        Assert.True(before.TakeWarning(Typing));

        Wait(12);
        var after = Watch();
        var freshGate = new CredentialGate(clock: () => time);

        Assert.True(freshGate.TryTake());
        Assert.Equal(LoginAction.SendSettings, after.Observe(NotStarted, autoLogin: true));
        Assert.Null(after.StateText(NotStarted, true, true, "Login"));
        Assert.False(after.TakeWarning(NotStarted));
    }

    [Fact]
    public void WritesTheLoginStateToTheLogWithoutTheLoginDetails()
    {
        Assert.Equal("test: in the game as Hunter.", LoginTexts.InWorld("test", "Hunter"));
        Assert.Equal("test: in the game.", LoginTexts.InWorld("test", null));
        Assert.Equal("test: still not in the game after 3 minutes (login screen not found).", LoginTexts.Warning("test", LoginTexts.NoLoginScreen));
        Assert.Equal(
            "test: reloading the game page once, because the login did not start (the game stayed at authenticating).",
            LoginTexts.Reloading("test", LoginTexts.GameStayed("authenticating")));
    }
}
