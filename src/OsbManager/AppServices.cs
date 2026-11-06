using System.Globalization;
using System.Reflection;
using OsbManager.Browser;
using OsbManager.Core;
using OsbManager.Core.Rendering;
using OsbManager.Core.Accounts;
using OsbManager.Core.Cache;
using OsbManager.Core.Scripts;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Updates;

namespace OsbManager;

internal sealed class AppServices : IDisposable
{
    public const string ApiBaseUrl = "https://api.osb.lol/v1";

    public static string AppVersion { get; } = ReadVersion();

    public static string UserAgent { get; } = AppIdentity.UserAgent(AppVersion);

    private AppServices(AppPaths paths, AppLog log, AccountStore accounts, ScriptStore scripts, SharedAssetCache cache, HttpRangeFetcher fetcher, HttpClient http, BrowserHost browser)
    {
        Paths = paths;
        Log = log;
        Accounts = accounts;
        Scripts = scripts;
        Cache = cache;
        Fetcher = fetcher;
        Http = http;
        Browser = browser;
    }

    public AppPaths Paths { get; }
    public AppLog Log { get; }
    public AccountStore Accounts { get; }
    public ScriptStore Scripts { get; }
    public SharedAssetCache Cache { get; }
    public HttpRangeFetcher Fetcher { get; }
    public HttpClient Http { get; }
    public BrowserHost Browser { get; }
    public RendererQueue Renderers { get; } = new();
    public ICredentialProtector Protector { get; } = new DpapiProtector();
    public AppSettings Settings { get; private init; } = new();
    public SoxLog Sox { get; private init; } = null!;
    public TelemetryService Telemetry { get; private init; } = null!;
    public TimeProvider Time { get; private init; } = TimeProvider.System;
    public UpdateService Updates { get; private init; } = null!;

    /// <summary>The character each open account's window reports, by account id.</summary>
    public System.Collections.Concurrent.ConcurrentDictionary<string, string> Characters { get; } = new();

    /// <summary>Character names that belong to this app's accounts, for telling our SoX drops from other players'.</summary>
    public IReadOnlyCollection<string> OurCharacters() =>
        Characters.Values.Concat(Accounts.Accounts.Select(a => a.Character)).Where(n => !string.IsNullOrWhiteSpace(n)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    public static AppServices Create(AppPaths paths, StartupOptions options)
    {
        paths.EnsureCreated();
        var log = new AppLog(paths.Logs);
        log.Info($"Started with data folder {paths.Root}.");
        var time = TelemetryTime();
        var fetcher = new HttpRangeFetcher(UserAgent);
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        var settings = AppSettings.Load(paths.SettingsFile);
        return new AppServices(
            paths,
            log,
            AccountStore.Load(paths.AccountsFile),
            new ScriptStore(paths.Scripts, log.Warn),
            new SharedAssetCache(paths.PackCache, fetcher, log.Warn),
            fetcher,
            http,
            new BrowserHost(paths, options.DebugPort))
        {
            Settings = settings,
            Sox = new SoxLog(paths.SoxFile),
            Telemetry = CreateTelemetry(paths, log, time),
            Time = time,
            Updates = CreateUpdates(settings, log),
        };
    }

    private static TimeProvider TelemetryTime()
    {
#if DEBUG
        return TelemetryTestSwitches.TimeScale > 1 ? new ScaledTimeProvider(TelemetryTestSwitches.TimeScale) : TimeProvider.System;
#else
        return TimeProvider.System;
#endif
    }

    private static TelemetryService CreateTelemetry(AppPaths paths, AppLog log, TimeProvider time)
    {
#if DEBUG
        var baseUrl = TelemetryTestSwitches.BaseUrl ?? new Uri(ApiBaseUrl);
#else
        var baseUrl = new Uri(ApiBaseUrl);
#endif
        var privacy = PrivacyStore.Load(paths.PrivacyFile, new InstallKeyProtector(), time, log.Warn);
        var service = new TelemetryService(
            privacy,
            TelemetryClient.Create(baseUrl, UserAgent, time),
            new StatusRegistry(),
            new ReportOutbox(paths.Outbox, time),
            AppVersion,
            CultureInfo.CurrentUICulture.TwoLetterISOLanguageName,
            time,
            Random.Shared.NextDouble,
            log.Info);
#if DEBUG
        if (TelemetryTestSwitches.ConsentOnAtStart && !privacy.State.Granted)
        {
            service.Accept(characters: false);
        }
#endif
        return service;
    }

    private static UpdateService CreateUpdates(AppSettings settings, AppLog log)
    {
        var options = new UpdateServiceOptions(AppVersion, UpdatePlatform.WindowsX64, UpdateKeys.Release, UserAgent, UpdateHttp.CreateHandler(), TimeProvider.System);
#if DEBUG
        if (UpdateTestSwitches.Feed is { } feed)
        {
            options = options with
            {
                CurrentVersion = UpdateTestSwitches.Version ?? AppVersion,
                PublicKeys = UpdateTestSwitches.Key is { } key ? [key] : UpdateKeys.Release,
                Handler = new UpdateTestFeed(feed),
                FirstDelay = UpdateTestSwitches.FirstDelay ?? UpdateScheduler.DefaultFirstDelay,
            };
        }
#endif
        return new UpdateService(options, () => settings.CheckForUpdates, log.Info);
    }

    private static string ReadVersion()
    {
        var informational = typeof(AppServices).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        var version = informational?.Split('+')[0];
        return string.IsNullOrWhiteSpace(version) ? "0.0.0" : version;
    }

    public void Dispose()
    {
        Updates.Dispose();
        Telemetry.Dispose();
        Cache.Dispose();
        Fetcher.Dispose();
        Http.Dispose();
    }
}
