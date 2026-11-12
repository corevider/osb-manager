namespace OsbManager.Core.Status;

public enum PageStep
{
    None,
    Reload,
    Restart,
    GiveUp,
}

public enum PageProblem
{
    None,
    Silent,
    Crashed,
}

/// <summary>
/// One account's way back when its game page stops responding or its page process ends. It only ever acts on that
/// account's own window: wait, reload the page, restart the window with the same profile, then stop and ask the player.
/// A page that reports again is fine; reaching the game world starts the ladder over. It is kept across a window restart.
/// </summary>
public sealed class PageHealth
{
    public static readonly TimeSpan SilenceLimit = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan ProofLimit = TimeSpan.FromSeconds(90);
    public static readonly TimeSpan QuietShown = TimeSpan.FromSeconds(10);

    private readonly Func<DateTime> clock;
    private DateTime lastSign;
    private bool reported;
    private DateTime? unresponsiveSince;
    private bool crashed;
    private DateTime? stepAt;

    public PageHealth(Func<DateTime>? clock = null)
    {
        this.clock = clock ?? (() => DateTime.UtcNow);
        lastSign = this.clock();
    }

    public bool Reloaded { get; private set; }
    public bool Restarted { get; private set; }
    public bool GaveUp { get; private set; }

    /// <summary>Why the last step was taken.</summary>
    public PageProblem LastProblem { get; private set; }

    /// <summary>True while the browser says the page does not respond and no report has come since.</summary>
    public bool Unresponsive => unresponsiveSince is not null;

    /// <summary>A window or a new page in it starts loading; the silence is counted from now.</summary>
    public void PageStarted()
    {
        var now = clock();
        lastSign = now;
        reported = false;
        crashed = false;
        unresponsiveSince = null;
        if (stepAt is not null)
        {
            stepAt = now;
        }
    }

    /// <summary>The page sent a report, so it responds. Returns true when it had been reported as not responding.</summary>
    public bool Reported(bool inWorld)
    {
        var wasUnresponsive = unresponsiveSince is not null;
        lastSign = clock();
        reported = true;
        unresponsiveSince = null;
        crashed = false;
        stepAt = null;
        GaveUp = false;
        if (inWorld)
        {
            Reloaded = Restarted = false;
        }
        return wasUnresponsive;
    }

    /// <summary>The browser says the page does not respond. Returns true the first time until it responds again.</summary>
    public bool MarkUnresponsive()
    {
        if (unresponsiveSince is not null)
        {
            return false;
        }
        unresponsiveSince = clock();
        return true;
    }

    public void MarkCrashed() => crashed = true;

    /// <summary>What to do now; called about once a second.</summary>
    public PageStep Tick()
    {
        if (GaveUp)
        {
            return PageStep.None;
        }
        var now = clock();
        if (stepAt is { } at)
        {
            return now - at >= ProofLimit ? Next(PageProblem.Silent) : PageStep.None;
        }
        if (crashed)
        {
            return Next(PageProblem.Crashed);
        }
        return now - lastSign >= SilenceLimit && (reported || unresponsiveSince is not null) ? Next(PageProblem.Silent) : PageStep.None;
    }

    /// <summary>The Status tab text while the page is not responding or being recovered, or null to show the normal state.</summary>
    public string? StateText(string normal, bool inWorld)
    {
        if (GaveUp)
        {
            return PageTexts.GaveUpState;
        }
        if (crashed)
        {
            return PageTexts.CrashedState;
        }
        var quiet = clock() - lastSign;
        if (stepAt is null && (unresponsiveSince is not null || reported && quiet >= QuietShown))
        {
            return PageTexts.WaitingState((int)quiet.TotalSeconds);
        }
        if (inWorld)
        {
            return null;
        }
        if (Restarted)
        {
            return $"{PageTexts.RestartedState} ({normal})";
        }
        return Reloaded ? $"{PageTexts.ReloadedState} ({normal})" : null;
    }

    private PageStep Next(PageProblem problem)
    {
        LastProblem = problem;
        crashed = false;
        unresponsiveSince = null;
        if (!Reloaded)
        {
            Reloaded = true;
            stepAt = clock();
            return PageStep.Reload;
        }
        if (!Restarted)
        {
            Restarted = true;
            stepAt = clock();
            return PageStep.Restart;
        }
        GaveUp = true;
        stepAt = null;
        return PageStep.GiveUp;
    }
}

/// <summary>The page health texts for the Status tab and the log.</summary>
public static class PageTexts
{
    public const string CrashedState = "Page crashed, reloading";
    public const string GaveUpState = "Not responding, use Reload";
    public const string ReloadedState = "Reloaded after the page stopped responding";
    public const string RestartedState = "Restarted after the page stopped responding";

    public static string WaitingState(int seconds) => $"Not responding for {seconds} s, waiting";

    public static string Unresponsive(string account, string kind) =>
        $"{account}: the page is not responding ({kind}); waiting up to {(int)PageHealth.SilenceLimit.TotalSeconds} s before reloading this window only.";

    public static string Responding(string account) => $"{account}: the page responds again.";

    public static string Step(string account, PageStep step, PageProblem problem) => step switch
    {
        PageStep.Reload when problem == PageProblem.Crashed => $"{account}: the page process ended; reloading this window only.",
        PageStep.Reload => $"{account}: the page did not respond for {(int)PageHealth.SilenceLimit.TotalSeconds} s; reloading this window only.",
        PageStep.Restart => $"{account}: the page still did not respond after a reload; restarting this window with the same profile and saved login.",
        PageStep.GiveUp => $"{account}: the page still does not respond after a reload and a window restart. Use Reload, or close and start this account again.",
        _ => "",
    };
}
