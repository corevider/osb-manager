using OsbManager.Core.Accounts;
using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class StartQueueTests
{
    private static Account Named(string name) => new() { Id = name.PadRight(12, '0')[..12], Name = name };

    [Fact]
    public void OpensTheFirstWindowAtOnceAndTheNextOnesAGapApart()
    {
        var time = new DateTime(2026, 10, 30, 12, 0, 0, DateTimeKind.Utc);
        var queue = new StartQueue(TimeSpan.FromSeconds(15), () => time);
        Account a = Named("a"), b = Named("b"), c = Named("c");
        queue.Add(a, light: false);
        queue.Add(b, light: true);
        queue.Add(c, light: false);
        queue.Add(b, light: false);

        Assert.Equal(a, queue.TakeDue()?.Account);
        Assert.Null(queue.TakeDue());
        Assert.Equal(TimeSpan.FromSeconds(15), queue.WaitFor(b));
        Assert.Equal(TimeSpan.FromSeconds(30), queue.WaitFor(c));

        time = time.AddSeconds(15);
        var second = queue.TakeDue();
        Assert.Equal(b, second?.Account);
        Assert.True(second?.Light);
        time = time.AddSeconds(14);
        Assert.Null(queue.TakeDue());
        time = time.AddSeconds(1);
        Assert.Equal(c, queue.TakeDue()?.Account);
        Assert.Equal(0, queue.Count);
    }

    [Fact]
    public void ForgetsRemovedAndClearedAccounts()
    {
        var queue = new StartQueue(TimeSpan.FromSeconds(15));
        Account a = Named("a"), b = Named("b");
        queue.Add(a, false);
        queue.Add(b, false);

        Assert.True(queue.Remove(a));
        Assert.False(queue.Contains(a));
        Assert.Null(queue.WaitFor(a));
        queue.Clear();
        Assert.Null(queue.TakeDue());
    }

    [Fact]
    public void FollowsANewAccountOrderForTheWindowsStillWaiting()
    {
        var time = new DateTime(2026, 10, 30, 12, 0, 0, DateTimeKind.Utc);
        var queue = new StartQueue(TimeSpan.FromSeconds(15), () => time);
        Account a = Named("a"), b = Named("b"), c = Named("c"), gone = Named("gone");
        foreach (var account in new[] { a, gone, b, c })
        {
            queue.Add(account, false);
        }

        queue.SortBy([c, a, b]);

        var opened = new List<Account>();
        for (var i = 0; i < 4; i++, time = time.AddSeconds(15))
        {
            opened.Add(queue.TakeDue()!.Value.Account);
        }
        Assert.Equal([c, a, b, gone], opened);
    }
}

public class RendererStatusTests
{
    [Fact]
    public void ReadsLightWaitingAndGpuRetries()
    {
        var status = BotStatus.TryParse("""{"type":"status","lightWaiting":true,"gpu":{"retries":2,"failed":null}}""");

        Assert.True(status!.LightWaiting);
        Assert.Equal(2, status.GpuRetries);
        Assert.Null(status.GpuFailed);
    }

    [Fact]
    public void ReadsARendererFailureAndBoundsTheRetryCount()
    {
        var status = BotStatus.TryParse("""{"type":"status","gpu":{"retries":5000,"failed":"OperationError: CreateDescriptorHeap"}}""");

        Assert.Equal(0, status!.GpuRetries);
        Assert.Equal("OperationError: CreateDescriptorHeap", status.GpuFailed);
    }
}
