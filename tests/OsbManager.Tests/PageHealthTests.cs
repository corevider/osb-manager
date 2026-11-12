using OsbManager.Core.Accounts;
using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class PageHealthTests
{
    private DateTime time = new(2026, 11, 8, 11, 13, 50, DateTimeKind.Utc);

    private PageHealth Health() => new(() => time);

    private void Wait(int seconds) => time = time.AddSeconds(seconds);

    [Fact]
    public void WaitsForAPageThatStopsRespondingThenReloadsRestartsAndGivesUp()
    {
        var health = Health();
        health.PageStarted();
        health.Reported(inWorld: true);

        Assert.True(health.MarkUnresponsive());
        Assert.False(health.MarkUnresponsive());
        Wait(59);
        Assert.Equal(PageStep.None, health.Tick());
        Assert.Equal("Not responding for 59 s, waiting", health.StateText("Not responding", inWorld: false));

        Wait(1);
        Assert.Equal(PageStep.Reload, health.Tick());
        Assert.Equal(PageProblem.Silent, health.LastProblem);
        health.PageStarted();
        Wait(89);
        Assert.Equal(PageStep.None, health.Tick());
        Assert.Equal("Reloaded after the page stopped responding (Loading)", health.StateText("Loading", inWorld: false));

        Wait(1);
        Assert.Equal(PageStep.Restart, health.Tick());
        Wait(40);
        health.PageStarted();
        Wait(89);
        Assert.Equal(PageStep.None, health.Tick());
        Assert.Equal("Restarted after the page stopped responding (Starting)", health.StateText("Starting", inWorld: false));

        Wait(1);
        Assert.Equal(PageStep.GiveUp, health.Tick());
        Assert.Equal("Not responding, use Reload", health.StateText("Not responding", inWorld: false));
        Wait(600);
        Assert.Equal(PageStep.None, health.Tick());
    }

    [Fact]
    public void APageThatRespondsAgainInTimeIsLeftAlone()
    {
        var health = Health();
        health.PageStarted();
        health.Reported(inWorld: true);
        health.MarkUnresponsive();
        Wait(30);

        Assert.True(health.Reported(inWorld: true));
        for (var second = 0; second < 120; second++)
        {
            Wait(1);
            Assert.False(health.Reported(inWorld: true));
            Assert.Equal(PageStep.None, health.Tick());
        }
        Wait(9);
        Assert.Null(health.StateText("In game", inWorld: true));
        Assert.False(health.Reloaded);
    }

    [Fact]
    public void ALoadingPageThatNeverReportedIsNotReloadedForBeingQuiet()
    {
        var health = Health();
        health.PageStarted();
        Wait(600);

        Assert.Equal(PageStep.None, health.Tick());
        Assert.Null(health.StateText("Loading", inWorld: false));
    }

    [Fact]
    public void AnEndedPageProcessIsReloadedAtOnce()
    {
        var health = Health();
        health.PageStarted();
        health.Reported(inWorld: true);
        health.MarkCrashed();

        Assert.Equal("Page crashed, reloading", health.StateText("In game", inWorld: false));
        Assert.Equal(PageStep.Reload, health.Tick());
        Assert.Equal(PageProblem.Crashed, health.LastProblem);
        health.PageStarted();
        Wait(5);
        health.Reported(inWorld: false);
        Assert.Equal(PageStep.None, health.Tick());
        Assert.Equal("Reloaded after the page stopped responding (Login)", health.StateText("Login", inWorld: false));
    }

    [Fact]
    public void ReachingTheWorldStartsTheLadderOver()
    {
        var health = Health();
        health.PageStarted();
        health.Reported(inWorld: true);
        health.MarkCrashed();
        health.Tick();
        health.PageStarted();
        health.Reported(inWorld: true);

        Assert.False(health.Reloaded);
        health.MarkCrashed();
        Assert.Equal(PageStep.Reload, health.Tick());
    }

    [Fact]
    public void OneUnresponsiveWindowDoesNotCloseOrRestartTheOthers()
    {
        var names = new[] { "bot", "test", "runecaller", "emberveil", "bard", "lutewind", "ashmoor" };
        var health = names.ToDictionary(name => name, _ => Health());
        var restarts = new WindowRestarts();
        var open = names.ToHashSet();
        var reloaded = new List<string>();
        foreach (var page in health.Values)
        {
            page.PageStarted();
            page.Reported(inWorld: true);
        }

        health["emberveil"].MarkUnresponsive();
        for (var second = 0; second < 300; second++)
        {
            Wait(1);
            foreach (var name in open.ToList())
            {
                if (name != "emberveil")
                {
                    health[name].Reported(inWorld: true);
                }
                switch (health[name].Tick())
                {
                    case PageStep.Reload:
                        reloaded.Add(name);
                        health[name].PageStarted();
                        break;
                    case PageStep.Restart:
                        Assert.True(restarts.Request(name));
                        open.Remove(name);
                        Assert.True(restarts.TakeOnClose(name, quitting: false));
                        open.Add(name);
                        health[name].PageStarted();
                        break;
                }
            }
        }

        Assert.Equal(["emberveil"], reloaded);
        Assert.Equal(names.ToHashSet(), open);
        Assert.True(health["emberveil"].GaveUp);
        foreach (var name in names.Where(name => name != "emberveil"))
        {
            Assert.False(health[name].Reloaded || health[name].Restarted || health[name].GaveUp);
            Assert.False(restarts.TakeOnClose(name, quitting: false));
        }
    }

    [Fact]
    public void ClosingAllWindowsOrQuittingCancelsAPendingRestart()
    {
        var restarts = new WindowRestarts();

        Assert.True(restarts.Request("emberveil"));
        Assert.False(restarts.Request("emberveil"));
        Assert.True(restarts.IsRestarting("emberveil"));
        Assert.False(restarts.IsRestarting("bot"));
        restarts.Clear();
        Assert.False(restarts.TakeOnClose("emberveil", quitting: false));

        restarts.Request("emberveil");
        Assert.False(restarts.TakeOnClose("emberveil", quitting: true));
        Assert.False(restarts.TakeOnClose("bot", quitting: false));
    }

    [Fact]
    public void WritesTheStepsToTheLog()
    {
        Assert.Equal(
            "emberveil: the page is not responding (RenderProcessUnresponsive); waiting up to 60 s before reloading this window only.",
            PageTexts.Unresponsive("emberveil", "RenderProcessUnresponsive"));
        Assert.Equal("emberveil: the page did not respond for 60 s; reloading this window only.", PageTexts.Step("emberveil", PageStep.Reload, PageProblem.Silent));
        Assert.Equal("emberveil: the page process ended; reloading this window only.", PageTexts.Step("emberveil", PageStep.Reload, PageProblem.Crashed));
        Assert.Contains("restarting this window with the same profile and saved login", PageTexts.Step("emberveil", PageStep.Restart, PageProblem.Silent));
        Assert.Contains("after a reload and a window restart", PageTexts.Step("emberveil", PageStep.GiveUp, PageProblem.Silent));
        Assert.Equal("emberveil: the page responds again.", PageTexts.Responding("emberveil"));
    }
}
