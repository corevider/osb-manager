using System.Text;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class ReportOutboxTests
{
    private static byte[] Json(string text = "report") => Encoding.UTF8.GetBytes($"{{\"description\":\"{text}\"}}");

    [Fact]
    public void AtMostFiveReportsWait()
    {
        using var directory = new TempDirectory();
        var outbox = new ReportOutbox(directory.Path, new FakeTimeProvider());

        for (var i = 0; i < 5; i++)
        {
            Assert.Equal(EnqueueOutcome.Queued, outbox.Enqueue(Json(), null, true, out _));
        }

        Assert.Equal(EnqueueOutcome.Full, outbox.Enqueue(Json(), null, true, out _));
        Assert.Equal(5, outbox.Pending().Count);
    }

    [Fact]
    public void AReportOver900KilobytesIsRefused()
    {
        using var directory = new TempDirectory();
        var outbox = new ReportOutbox(directory.Path, new FakeTimeProvider());

        Assert.Equal(EnqueueOutcome.TooLarge, outbox.Enqueue(Json(), new byte[ReportOutbox.MaxReportBytes], true, out _));
        Assert.Equal(EnqueueOutcome.Queued, outbox.Enqueue(Json(), new byte[700 * 1024], true, out _));
        Assert.Empty(Directory.GetFiles(directory.Path, "*.tmp"));
    }

    [Fact]
    public void WritesAreAtomicAndTheScreenshotIsKeptNextToTheReport()
    {
        using var directory = new TempDirectory();
        var outbox = new ReportOutbox(directory.Path, new FakeTimeProvider());
        var png = Enumerable.Range(0, 1000).Select(i => (byte)i).ToArray();

        outbox.Enqueue(Json("with picture"), png, false, out var id);

        Assert.Empty(Directory.GetFiles(directory.Path, "*.tmp"));
        Assert.True(File.Exists(Path.Combine(directory.Path, id + ".json")));
        Assert.Equal(png, outbox.Screenshot(outbox.Pending()[0], failed: false));
        Assert.Contains("with picture", outbox.Pending()[0].ReportJson);
    }

    [Fact]
    public void AReportOlderThanSeventyTwoHoursMovesToTheFailedFolder()
    {
        using var directory = new TempDirectory();
        var time = new FakeTimeProvider();
        var outbox = new ReportOutbox(directory.Path, time);
        outbox.Enqueue(Json(), [1, 2, 3], true, out var id);

        time.Advance(TimeSpan.FromHours(71.9));
        Assert.Equal(0, outbox.MoveExpired());
        time.Advance(TimeSpan.FromHours(0.2));
        Assert.Equal(1, outbox.MoveExpired());

        Assert.Empty(outbox.Pending());
        Assert.Single(outbox.Failed());
        Assert.True(File.Exists(Path.Combine(directory.Path, "failed", id + ".json")));
        Assert.True(File.Exists(Path.Combine(directory.Path, "failed", id + ".png")));
        Assert.False(File.Exists(Path.Combine(directory.Path, id + ".json")));
    }

    [Fact]
    public void AFailedReportCanBeSentAgainOrDeleted()
    {
        using var directory = new TempDirectory();
        var time = new FakeTimeProvider();
        var outbox = new ReportOutbox(directory.Path, time);
        outbox.Enqueue(Json("one"), null, true, out var first);
        outbox.Enqueue(Json("two"), null, true, out var second);
        time.Advance(TimeSpan.FromHours(80));
        outbox.MoveExpired();

        Assert.True(outbox.SendAgain(first));
        outbox.DeleteFailed(second);

        Assert.Single(outbox.Pending());
        Assert.Equal(0, outbox.Pending()[0].Attempts);
        Assert.Equal(time.GetUtcNow(), outbox.Pending()[0].CreatedAt);
        Assert.Empty(outbox.Failed());
    }

    [Fact]
    public void ClearAllRemovesEveryFile()
    {
        using var directory = new TempDirectory();
        var time = new FakeTimeProvider();
        var outbox = new ReportOutbox(directory.Path, time);
        outbox.Enqueue(Json(), [1], true, out _);
        outbox.Enqueue(Json(), null, true, out _);
        time.Advance(TimeSpan.FromHours(80));
        outbox.MoveExpired();
        outbox.Enqueue(Json(), [2], true, out _);

        outbox.ClearAll();

        Assert.Empty(Directory.EnumerateFiles(directory.Path, "*", SearchOption.AllDirectories));
        Assert.Empty(outbox.Pending());
        Assert.Empty(outbox.Failed());
    }

    [Fact]
    public void AnOutboxThatCannotBeWrittenReportsAFailureAndLeavesNothingBehind()
    {
        using var directory = new TempDirectory();
        var blocked = Path.Combine(directory.Path, "outbox");
        File.WriteAllText(blocked, "not a folder");
        var outbox = new ReportOutbox(blocked, new FakeTimeProvider());

        var outcome = outbox.Enqueue(Json(), [1], true, out _);

        Assert.Equal(EnqueueOutcome.Failed, outcome);
        Assert.Empty(outbox.Pending());
    }

    [Fact]
    public void AnUnreadableFileIsIgnored()
    {
        using var directory = new TempDirectory();
        var outbox = new ReportOutbox(directory.Path, new FakeTimeProvider());
        File.WriteAllText(Path.Combine(directory.Path, "broken.json"), "{nope");
        outbox.Enqueue(Json(), null, true, out _);

        Assert.Single(outbox.Pending());
    }
}
