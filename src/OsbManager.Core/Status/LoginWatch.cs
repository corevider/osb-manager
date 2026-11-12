namespace OsbManager.Core.Status;

public enum LoginAction
{
    None,
    SendSettings,
    Reload,
}

/// <summary>
/// Watches one game window on its way into the world. It sends the login settings again while the page reports that
/// automatic login has not started, reloads a page stuck outside the login once (and gives the new page the same
/// time), and names the reason when the account is still not in the world a few minutes after the window started or
/// the character left the world.
/// </summary>
public sealed class LoginWatch
{
    public static readonly TimeSpan NotLoggedInAfter = TimeSpan.FromMinutes(3);
    public static readonly TimeSpan SettingsGap = TimeSpan.FromSeconds(15);

    private static readonly HashSet<string> ActiveStages = ["title", "server", "credentials", "connecting", "retry", "character", "entering"];

    private readonly Func<DateTime> clock;
    private DateTime? outSince;
    private DateTime lastSettings = DateTime.MinValue;
    private bool reloaded;
    private bool warned;

    public LoginWatch(Func<DateTime>? clock = null)
    {
        this.clock = clock ?? (() => DateTime.UtcNow);
        outSince = this.clock();
    }

    /// <summary>True once the account has been out of the world for the limit; the window logs it once.</summary>
    public bool TakeWarning(BotStatus? status)
    {
        if (warned || !Late(status))
        {
            return false;
        }
        warned = true;
        return true;
    }

    public LoginAction Observe(BotStatus report, bool autoLogin)
    {
        var now = clock();
        if (report.InWorld)
        {
            outSince = null;
            reloaded = warned = false;
            return LoginAction.None;
        }
        outSince ??= now;
        if (!autoLogin)
        {
            return LoginAction.None;
        }
        var notStarted = report.LoginStage is null or "off";
        if (!reloaded && now - outSince >= NotLoggedInAfter && (notStarted || report.LoginStage == "waiting"))
        {
            reloaded = true;
            outSince = now;
            return LoginAction.Reload;
        }
        if (notStarted && now - lastSettings >= SettingsGap)
        {
            lastSettings = now;
            return LoginAction.SendSettings;
        }
        return LoginAction.None;
    }

    /// <summary>The Status tab text while the account is not in the world, or null to show the normal state.</summary>
    public string? StateText(BotStatus? status, bool autoLogin, bool hasLogin, string normal)
    {
        if (status is null || status.InWorld || outSince is null)
        {
            return null;
        }
        var reason = Reason(status, autoLogin, hasLogin);
        if (Late(status))
        {
            return $"{LoginTexts.NotLoggedIn} ({reason})";
        }
        if (!autoLogin || !hasLogin)
        {
            return status.LoginStage is null or "off" && status.Phase is "signed-out" ? $"{normal} ({reason})" : null;
        }
        return status.LoginStage == "waiting" ? $"{LoginTexts.LoggingIn} ({status.Phase ?? "game busy"})" : null;
    }

    public string Reason(BotStatus status, bool autoLogin, bool hasLogin)
    {
        if (!autoLogin)
        {
            return LoginTexts.AutoLoginOff;
        }
        if (!hasLogin)
        {
            return LoginTexts.NoSavedLogin;
        }
        return status.LoginStage switch
        {
            "failed" => LoginTexts.Stopped,
            "choose" => LoginTexts.ChooseCharacter,
            "waiting" => LoginTexts.GameStayed(status.Phase),
            { } stage when ActiveStages.Contains(stage) => LoginTexts.DidNotFinish,
            _ => LoginTexts.NoLoginScreen,
        };
    }

    private bool Late(BotStatus? status) =>
        status is { InWorld: false } && outSince is { } since && clock() - since >= NotLoggedInAfter;
}

/// <summary>The login watch's texts for the Status tab and the log.</summary>
public static class LoginTexts
{
    public const string NotLoggedIn = "Not logged in";
    public const string LoggingIn = "Logging in";
    public const string AutoLoginOff = "auto login off";
    public const string NoSavedLogin = "no saved login";
    public const string Stopped = "auto login stopped";
    public const string ChooseCharacter = "choose a character";
    public const string DidNotFinish = "login did not finish";
    public const string NoLoginScreen = "login screen not found";

    public static string GameStayed(string? phase) => phase is null ? "the game did not answer" : $"the game stayed at {phase}";

    public static string Warning(string account, string reason) =>
        $"{account}: still not in the game after {(int)LoginWatch.NotLoggedInAfter.TotalMinutes} minutes ({reason}).";

    public static string Reloading(string account, string reason) =>
        $"{account}: reloading the game page once, because the login did not start ({reason}).";

    public static string InWorld(string account, string? character) =>
        character is null ? $"{account}: in the game." : $"{account}: in the game as {character}.";
}
