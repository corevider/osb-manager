using OsbManager.Core.Updates;
using OsbManager.Tests.Telemetry;

namespace OsbManager.Tests.Updates;

public class UpdateServiceTests
{
    private static UpdateService Service(FakeGitHub github, FakeTimeProvider time, Func<bool> enabled, string? key, List<string>? log = null) =>
        new(new UpdateServiceOptions("1.0.2", UpdatePlatform.WindowsX64, key is null ? [] : [key], "OSBManager/1.0.2 (Windows)", github, time)
        {
            FirstDelay = TimeSpan.FromMinutes(2),
            Interval = TimeSpan.FromHours(6),
            BusyRetry = TimeSpan.FromMinutes(1),
        }, enabled, message => log?.Add(message));

    private static async Task Settle(FakeGitHub github, int expected)
    {
        for (var i = 0; i < 200 && github.Seen.Count < expected; i++)
        {
            await Task.Delay(10);
        }
        await Task.Delay(50);
    }

    [Fact]
    public async Task MakesNoRequestWhenTheSettingIsOff()
    {
        using var key = new TestKey();
        var github = new FakeGitHub();
        new FakeRelease().Publish(github, key);
        var time = new FakeTimeProvider();
        using var service = Service(github, time, () => false, key.PublicKey);
        var checks = 0;
        service.Checked += (_, _) => checks++;

        service.Start();
        for (var i = 0; i < 40; i++)
        {
            time.Advance(TimeSpan.FromHours(6));
        }
        await Task.Delay(100);

        Assert.Empty(github.Seen);
        Assert.Equal(0, checks);
    }

    [Fact]
    public async Task MakesNoRequestWithoutAReleaseKey()
    {
        var github = new FakeGitHub();
        var time = new FakeTimeProvider();
        using var service = Service(github, time, () => true, key: null);

        service.Start();
        time.Advance(TimeSpan.FromDays(3));
        var manual = await service.CheckNowAsync(CancellationToken.None);

        Assert.Empty(github.Seen);
        Assert.NotNull(service.Problem);
        Assert.Equal(UpdateCheckStatus.Failed, manual.Status);
    }

    [Fact]
    public async Task ChecksAfterTheFirstDelayAndThenEverySixHours()
    {
        using var key = new TestKey();
        var github = new FakeGitHub();
        new FakeRelease("1.0.2").Publish(github, key);
        var time = new FakeTimeProvider();
        using var service = Service(github, time, () => true, key.PublicKey);
        var results = new List<UpdateCheckResult>();
        service.Checked += (result, byUser) => { lock (results) { results.Add(result); } Assert.False(byUser); };

        service.Start();
        time.Advance(TimeSpan.FromSeconds(119));
        Assert.Empty(github.Seen);

        time.Advance(TimeSpan.FromSeconds(1));
        await Settle(github, 3);
        Assert.Equal(3, github.Seen.Count(r => r.Url.Host != "release-assets.githubusercontent.com"));

        time.Advance(TimeSpan.FromHours(6));
        await Settle(github, 9);
        lock (results)
        {
            Assert.Equal(2, results.Count);
            Assert.All(results, r => Assert.Equal(UpdateCheckStatus.UpToDate, r.Status));
        }
    }

    [Fact]
    public async Task WaitsWhileAGameWindowStarts()
    {
        using var key = new TestKey();
        var github = new FakeGitHub();
        new FakeRelease().Publish(github, key);
        var time = new FakeTimeProvider();
        using var service = Service(github, time, () => true, key.PublicKey);
        service.Busy = true;

        service.Start();
        time.Advance(TimeSpan.FromMinutes(10));
        await Task.Delay(50);
        Assert.Empty(github.Seen);

        service.Busy = false;
        time.Advance(TimeSpan.FromMinutes(1));
        await Settle(github, 1);
        Assert.NotEmpty(github.Seen);
    }

    [Fact]
    public async Task SwitchingTheSettingOffStopsLaterChecks()
    {
        using var key = new TestKey();
        var github = new FakeGitHub();
        new FakeRelease("1.0.2").Publish(github, key);
        var time = new FakeTimeProvider();
        var enabled = true;
        using var service = Service(github, time, () => enabled, key.PublicKey);

        service.Start();
        time.Advance(TimeSpan.FromMinutes(2));
        await Settle(github, 3);
        var before = github.Seen.Count;
        enabled = false;
        time.Advance(TimeSpan.FromDays(2));
        await Task.Delay(100);

        Assert.Equal(before, github.Seen.Count);
    }

    [Fact]
    public async Task AManualCheckReportsToTheListenerAsRequestedByTheUser()
    {
        using var key = new TestKey();
        var github = new FakeGitHub();
        new FakeRelease().Publish(github, key);
        using var service = Service(github, new FakeTimeProvider(), () => false, key.PublicKey);
        bool? byUser = null;
        service.Checked += (_, user) => byUser = user;

        var result = await service.CheckNowAsync(CancellationToken.None);

        Assert.Equal(UpdateCheckStatus.Available, result.Status);
        Assert.True(byUser);
    }
}
