using System.Diagnostics;
using OsbManager.Browser;
using OsbManager.Core;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

internal sealed class TelemetryKit : IDisposable
{
    public const string AppVersion = "1.2.0";

    private readonly TempDirectory directory = new();
    private readonly List<string> log = [];

    public TelemetryKit(double random = 0.5, IStatusSource? source = null, string? privacyFile = null)
    {
        Time = new FakeTimeProvider();
        Server = new FakeServer(Time);
        Paths = new AppPaths(directory.Path);
        if (privacyFile is not null)
        {
            File.WriteAllText(Paths.PrivacyFile, privacyFile);
        }
        Store = PrivacyStore.Load(Paths.PrivacyFile, new InstallKeyProtector(), Time, Log);
        Client = new TelemetryClient(new Uri("https://api.test/v1"), AppIdentity.UserAgent(AppVersion), Server, Time);
        Outbox = new ReportOutbox(Paths.Outbox, Time);
        Random = () => random;
        Service = new TelemetryService(Store, Client, Statuses, Outbox, AppVersion, "en", Time, () => Random(), Log, source);
    }

    public FakeTimeProvider Time { get; }
    public FakeServer Server { get; }
    public AppPaths Paths { get; }
    public PrivacyStore Store { get; }
    public TelemetryClient Client { get; }
    public ReportOutbox Outbox { get; }
    public StatusRegistry Statuses { get; } = new();
    public TelemetryService Service { get; }
    public Func<double> Random { get; set; }

    public IReadOnlyList<string> LogLines
    {
        get { lock (log) { return [.. log]; } }
    }

    public static BotStatus Hunting(string character = "Example", int level = 87) => new()
    {
        BotVersion = "2.0.4", Phase = "world", Character = character, InWorld = true, Level = level, Gold = 123456789,
        HpPercent = 92, MpPercent = 70, Hunting = true, ReturnScrolls = 12, ReverseScrolls = 3,
        Session = new SessionStats(5_400_000, 812, 1, 48211933, 2210450, 0),
    };

    public void Publish(string accountId, BotStatus status, string server = "ExampleServer") =>
        Statuses.Publish(accountId, server, status, Time.GetUtcNow().AddDays(60));

    public void Log(string line)
    {
        lock (log)
        {
            log.Add(line);
        }
    }

    public async Task RunFor(TimeSpan duration, bool startService = true)
    {
        if (startService)
        {
            Service.Start();
        }
        var end = Time.GetUtcNow() + duration;
        while (Time.GetUtcNow() < end)
        {
            await SettleAsync(() => Time.RepeatingTimers > 0 && Time.OneShotTimers == 0 && Server.InFlight == 0, 1500);
            var before = Service.SchedulerWaits;
            if (!Time.AdvanceToNextRepeating(end - Time.GetUtcNow()))
            {
                Time.Advance(end - Time.GetUtcNow());
                return;
            }
            if (!await SettleAsync(() => (Service.SchedulerWaits > before || Service.DisabledByFailSafe) && Time.OneShotTimers == 0 && Server.InFlight == 0))
            {
                return;
            }
        }
    }

    public static async Task<bool> SettleAsync(Func<bool> condition, int milliseconds = 4000)
    {
        var watch = Stopwatch.StartNew();
        while (!condition())
        {
            if (watch.ElapsedMilliseconds > milliseconds)
            {
                return false;
            }
            await Task.Delay(1);
        }
        return true;
    }

    public void Dispose()
    {
        Service.Dispose();
        directory.Dispose();
    }
}
