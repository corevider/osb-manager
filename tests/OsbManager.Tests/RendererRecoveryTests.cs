using OsbManager.Core;
using OsbManager.Core.Rendering;
using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class RendererQueueTests
{
    private DateTime time = new(2026, 11, 6, 13, 34, 0, DateTimeKind.Utc);
    private readonly List<string> granted = [];

    private RendererQueue Queue() => new(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(20), () => time);

    private void Ask(RendererQueue queue, string window, string id) => queue.Request(window, id, () => granted.Add(window + ":" + id));

    [Fact]
    public void LetsOneWindowStartItsRendererAtATimeWithAGap()
    {
        var queue = Queue();
        Ask(queue, "a", "1");
        Ask(queue, "b", "1");
        Ask(queue, "c", "1");

        Assert.Equal(["a:1"], granted);
        Assert.True(queue.IsWaiting("b"));

        queue.Release("a", "1");
        Assert.Equal(["a:1"], granted);
        time = time.AddSeconds(1);
        queue.Pump();
        Assert.Equal(["a:1"], granted);
        time = time.AddSeconds(1);
        queue.Pump();
        Assert.Equal(["a:1", "b:1"], granted);
        Assert.Equal("b", queue.Holder);
        Assert.True(queue.IsWaiting("c"));
    }

    [Fact]
    public void TakesTheSlotBackFromAPageThatDiedHoldingIt()
    {
        var queue = Queue();
        Ask(queue, "a", "1");
        Ask(queue, "b", "1");

        time = time.AddSeconds(19);
        queue.Pump();
        Assert.Equal("a", queue.Holder);

        time = time.AddSeconds(1);
        queue.Pump();
        Assert.Null(queue.Holder);
        time = time.AddSeconds(2);
        queue.Pump();
        Assert.Equal(["a:1", "b:1"], granted);
    }

    [Fact]
    public void AClosedWindowFreesItsSlotAtOnceAndLeavesTheOthersQueued()
    {
        var queue = Queue();
        Ask(queue, "a", "1");
        Ask(queue, "b", "1");
        Ask(queue, "c", "1");

        queue.Forget("a");

        Assert.Null(queue.Holder);
        Assert.True(queue.IsWaiting("b"));
        Assert.True(queue.IsWaiting("c"));
        time = time.AddSeconds(2);
        queue.Pump();
        Assert.Equal(["a:1", "b:1"], granted);
    }

    [Fact]
    public void AWindowThatIsForgottenWhileWaitingDoesNotTouchTheHolder()
    {
        var queue = Queue();
        Ask(queue, "a", "1");
        Ask(queue, "b", "1");

        queue.Forget("b");

        Assert.Equal("a", queue.Holder);
        Assert.False(queue.IsWaiting("b"));
    }

    [Fact]
    public void IgnoresAHandBackForAnOlderRequest()
    {
        var queue = Queue();
        Ask(queue, "a", "1");
        Ask(queue, "b", "1");

        queue.Release("a", "old");
        queue.Release("b", "1");

        Assert.Equal("a", queue.Holder);
        Assert.False(queue.IsWaiting("b"));
    }

    [Fact]
    public void ANewRequestOfAWindowReplacesItsOlderOne()
    {
        var queue = Queue();
        Ask(queue, "a", "1");
        Ask(queue, "b", "1");
        Ask(queue, "b", "2");
        queue.Release("a", "1");
        time = time.AddSeconds(2);
        queue.Pump();

        Assert.Equal(["a:1", "b:2"], granted);
    }
}

public class RendererRecoveryTests
{
    private static readonly BotStatus Loading = new() { Phase = "signed-out" };
    private static readonly BotStatus Failed = new() { GpuRetries = 6, GpuRetryLimit = 6, GpuFailed = "requestDevice: CreateDescriptorHeap CheckOutOfMemory" };
    private static readonly BotStatus InWorld = new() { InWorld = true, Phase = "world" };

    [Fact]
    public void ReloadsThenRestartsThenGivesUp()
    {
        var recovery = new RendererRecovery();

        Assert.Equal(RendererStep.Reload, recovery.Observe(Loading, Failed, restartAllowed: true));
        Assert.Equal(RendererStep.None, recovery.Observe(Failed, Failed, restartAllowed: true));
        Assert.Equal(RendererStep.Restart, recovery.Observe(Loading, Failed, restartAllowed: true));
        Assert.Equal(RendererStep.GiveUp, recovery.Observe(null, Failed, restartAllowed: true));
        Assert.True(recovery.GaveUp);
    }

    [Fact]
    public void WithRestartOffItGivesUpAfterTheReload()
    {
        var recovery = new RendererRecovery();

        Assert.Equal(RendererStep.Reload, recovery.Observe(Loading, Failed, restartAllowed: false));
        Assert.Equal(RendererStep.GiveUp, recovery.Observe(Loading, Failed, restartAllowed: false));
        Assert.False(recovery.Restarted);
    }

    [Fact]
    public void ReachingTheWorldStartsTheLadderOver()
    {
        var recovery = new RendererRecovery();
        recovery.Observe(Loading, Failed, true);
        recovery.Observe(Loading, Failed, true);

        Assert.Equal(RendererStep.None, recovery.Observe(Loading, InWorld, true));
        Assert.False(recovery.Reloaded || recovery.Restarted || recovery.GaveUp);
        Assert.Equal(RendererStep.Reload, recovery.Observe(InWorld, Failed, true));
    }

    [Fact]
    public void RetriesThatSucceedNeedNoStep()
    {
        var recovery = new RendererRecovery();

        Assert.Equal(RendererStep.None, recovery.Observe(Loading, new BotStatus { GpuRetries = 3, GpuRetryIn = 30 }, true));
        Assert.Equal(RendererStep.None, recovery.Observe(Loading, new BotStatus { GpuRetries = 3 }, true));
    }

    [Fact]
    public void OneAccountsRecoveryLeavesAnotherAlone()
    {
        var failing = new RendererRecovery();
        var healthy = new RendererRecovery();

        failing.Observe(Loading, Failed, true);
        failing.Observe(Loading, Failed, true);

        Assert.True(failing.Restarted);
        Assert.False(healthy.Reloaded || healthy.Restarted || healthy.GaveUp);
        Assert.Null(healthy.StateText(InWorld, waitingForSlot: false, "In game"));
    }

    [Fact]
    public void ShowsTheRecoveryInTheStatusTab()
    {
        var recovery = new RendererRecovery();

        Assert.Equal("Renderer failed, retrying in 60 s", recovery.StateText(new BotStatus { GpuRetries = 5, GpuRetryIn = 60 }, false, "Loading"));
        Assert.Equal("Waiting for another window's renderer", recovery.StateText(Loading, true, "Login"));
        Assert.Null(recovery.StateText(Loading, false, "Login"));

        recovery.Observe(Loading, Failed, true);
        Assert.Equal("Renderer failed, recovering", recovery.StateText(Failed, false, "Loading"));
        Assert.Equal("Reloaded after renderer failure (Loading)", recovery.StateText(Loading, false, "Loading"));

        recovery.Observe(Loading, Failed, true);
        Assert.Equal("Restarted after renderer failure (Logging in)", recovery.StateText(null, false, "Logging in"));
        Assert.Null(recovery.StateText(InWorld, false, "In game"));

        recovery.Observe(Loading, Failed, true);
        Assert.Equal("Renderer failed, use Reload", recovery.StateText(Failed, false, "Loading"));
    }

    [Fact]
    public void WritesTheRecoveryToTheLog()
    {
        Assert.Equal(
            "test: the graphics card was full when the game started its renderer; trying again in 60 s (5 of 6).",
            RendererTexts.Retrying("test", 5, 6, 60));
        Assert.Equal(
            "test: the graphics card was full when the game started its renderer; trying again in 4 s (1 of 1).",
            RendererTexts.Retrying("test", 1, 0, 4));
        Assert.Equal("test: the game's renderer could not start (OutOfMemory).", RendererTexts.Failed("test", "OutOfMemory"));
        Assert.Equal("test: reloading the game page to start the renderer again.", RendererTexts.Step("test", RendererStep.Reload, false));
        Assert.Contains("restarting the game window with the same profile and saved login", RendererTexts.Step("test", RendererStep.Restart, false));
        Assert.Contains("after a reload and a window restart.", RendererTexts.Step("test", RendererStep.GiveUp, restarted: true));
        Assert.Contains("after a reload; automatic window restart is off.", RendererTexts.Step("test", RendererStep.GiveUp, restarted: false));
    }
}

public class RendererMessageTests
{
    [Fact]
    public void ReadsTheRetryScheduleFromTheStatusAndBoundsIt()
    {
        var status = BotStatus.TryParse("""{"type":"status","gpu":{"retries":5,"limit":6,"failed":null,"retryIn":60}}""")!;
        Assert.Equal(5, status.GpuRetries);
        Assert.Equal(6, status.GpuRetryLimit);
        Assert.Equal(60, status.GpuRetryIn);

        var old = BotStatus.TryParse("""{"type":"status","gpu":{"retries":1,"failed":null}}""")!;
        Assert.Equal(0, old.GpuRetryLimit);
        Assert.Equal(0, old.GpuRetryIn);

        var wild = BotStatus.TryParse("""{"type":"status","gpu":{"retries":1,"limit":5000,"retryIn":-3}}""")!;
        Assert.Equal(0, wild.GpuRetryLimit);
        Assert.Equal(0, wild.GpuRetryIn);
    }

    [Theory]
    [InlineData("""{"type":"gpu-slot","id":"k3j2h1"}""", false, "k3j2h1")]
    [InlineData("""{"type":"gpu-slot-done","id":"k3j2h1"}""", true, "k3j2h1")]
    public void ReadsSlotMessages(string json, bool done, string id)
    {
        Assert.Equal(new RendererSlotMessage(done, id), RendererSlotMessage.TryParse(json));
    }

    [Theory]
    [InlineData("""{"type":"gpu-slot"}""")]
    [InlineData("""{"type":"gpu-slot","id":""}""")]
    [InlineData("""{"type":"gpu-slot","id":"a b"}""")]
    [InlineData("""{"type":"gpu-slot","id":"<script>"}""")]
    [InlineData("""{"type":"gpu-slot","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")]
    [InlineData("""{"type":"gpu-slot","id":7}""")]
    [InlineData("""{"type":"status","id":"a"}""")]
    [InlineData("""["gpu-slot"]""")]
    [InlineData("not json")]
    [InlineData(null)]
    public void RejectsAnythingElse(string? json)
    {
        Assert.Null(RendererSlotMessage.TryParse(json));
    }

    [Fact]
    public void GrantsWithTheRequestId()
    {
        Assert.Equal("""{"type":"gpu-slot","id":"k3j2h1"}""", RendererSlotMessage.Grant("k3j2h1"));
    }

    [Fact]
    public void RestartsAfterARendererFailureByDefaultAndKeepsTheChoice()
    {
        using var temp = new TempDirectory();
        File.WriteAllText(temp.File("settings.json"), """{"frameLimit":60}""");
        var settings = AppSettings.Load(temp.File("settings.json"));
        Assert.True(settings.RestartAfterRendererFailure);
        Assert.True(AppSettings.Load(temp.File("missing.json")).RestartAfterRendererFailure);

        settings.RestartAfterRendererFailure = false;
        settings.Save();

        Assert.False(AppSettings.Load(temp.File("settings.json")).RestartAfterRendererFailure);
    }
}
