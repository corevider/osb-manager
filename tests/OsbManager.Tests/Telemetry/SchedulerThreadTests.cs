using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class SchedulerThreadTests
{
    private sealed class CountingContext : SynchronizationContext
    {
        private int posts;

        public int Posts => Volatile.Read(ref posts);

        public override void Post(SendOrPostCallback d, object? state)
        {
            Interlocked.Increment(ref posts);
            base.Post(d, state);
        }

        public override void Send(SendOrPostCallback d, object? state)
        {
            Interlocked.Increment(ref posts);
            base.Send(d, state);
        }
    }

    private sealed class SpySource(IStatusSource inner) : IStatusSource
    {
        private readonly List<int> threads = [];

        public IReadOnlyList<int> Threads
        {
            get { lock (threads) { return [.. threads]; } }
        }

        public IReadOnlyList<AccountSnapshot> Snapshot()
        {
            lock (threads)
            {
                threads.Add(Environment.CurrentManagedThreadId);
            }
            return inner.Snapshot();
        }
    }

    [Fact]
    public async Task TheSchedulerNeverRunsOnTheThreadThatCreatedItAndNeverCapturesItsContext()
    {
        var context = new CountingContext();
        TelemetryKit? kit = null;
        SpySource? spy = null;
        var creatorThread = 0;
        var ready = new ManualResetEventSlim();
        var release = new ManualResetEventSlim();
        var creator = new Thread(() =>
        {
            SynchronizationContext.SetSynchronizationContext(context);
            creatorThread = Environment.CurrentManagedThreadId;
            var registry = new StatusRegistry();
            spy = new SpySource(registry);
            kit = new TelemetryKit(source: spy);
            kit.Store.Grant(false);
            registry.Publish("account-a", "Srv", TelemetryKit.Hunting(), kit.Time.GetUtcNow().AddDays(30));
            kit.Statuses.Publish("account-a", "Srv", TelemetryKit.Hunting(), kit.Time.GetUtcNow().AddDays(30));
            kit.Service.Start();
            ready.Set();
            release.Wait();
        });
        creator.Start();
        ready.Wait();

        await kit!.RunFor(TimeSpan.FromMinutes(25), startService: false);

        Assert.True(kit.Server.Requests.Count >= 3);
        Assert.All(kit.Server.Requests, r =>
        {
            Assert.NotEqual(creatorThread, r.ThreadId);
            Assert.False(r.HadSynchronizationContext);
        });
        Assert.NotEmpty(spy!.Threads);
        Assert.DoesNotContain(creatorThread, spy.Threads);
        Assert.Equal(0, context.Posts);
        release.Set();
        creator.Join();
        kit.Dispose();
    }

    [Fact]
    public async Task StoppingTheServiceReturnsWithinOneSecondEvenWhileARequestHangs()
    {
        using var kit = new TelemetryKit();
        kit.Store.Grant(false);
        kit.Publish("a", TelemetryKit.Hunting());
        kit.Server.HangEverything();
        kit.Service.Start();
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Service.SchedulerWaits >= 1));
        kit.Time.AdvanceToNextRepeating(TimeSpan.FromHours(1));
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.InFlight == 1));

        var watch = System.Diagnostics.Stopwatch.StartNew();
        kit.Service.Stop(TimeSpan.FromSeconds(1));

        Assert.True(watch.ElapsedMilliseconds < 1500);
        Assert.True(await TelemetryKit.SettleAsync(() => kit.Server.InFlight == 0));
    }
}
