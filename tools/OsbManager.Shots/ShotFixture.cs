using System.Text.Json;
using OsbManager.Core;
using OsbManager.Core.Accounts;
using OsbManager.Core.Cache;
using OsbManager.Core.Status;
using OsbManager.UI;

namespace OsbManager.Shots;

internal sealed record ShotSize(int Width, int Height);

internal sealed record FixtureMemory(double PrivateMb, double WorkingSetMb, double? JsHeapUsedMb = null, double? JsHeapTotalMb = null, double? WasmMb = null, int WasmMemories = 0);

internal sealed record FixtureWindow(string State, bool Light, bool Hidden, BotStatus Status, FixtureMemory Memory);

internal sealed record FixtureAccount(
    string Id,
    string Name,
    string LoginId,
    string Server,
    string Character,
    bool AutoLogin,
    bool SavedPassword,
    bool StartLight,
    FixtureWindow? Window);

internal sealed record FixtureProcesses(FixtureMemory Gpu, FixtureMemory Browser, FixtureMemory App);

internal sealed record FixtureLogLine(string Time, string Level, string Message)
{
    public override string ToString() => $"[{Time}] {Level}: {Message}";
}

internal sealed record ShotCrop(int X, int Y, int Width, int Height);

internal sealed record FixtureShot(string File, string Tab, string Left = "Accounts", int LeftWidth = 230, ShotSize? Size = null, ShotCrop? Crop = null);

/// <summary>Made-up accounts, bot reports, SoX drops, log lines and memory numbers for the screenshot tool.</summary>
internal sealed record ShotFixture(
    ShotSize ClientSize,
    float Scale,
    DateTime SessionStart,
    string Selected,
    bool HideStar,
    IReadOnlyList<FixtureAccount> Accounts,
    IReadOnlyList<SoxDrop> Sox,
    CacheCounters Cache,
    FixtureProcesses Processes,
    IReadOnlyList<FixtureLogLine> Log,
    IReadOnlyList<IReadOnlyList<string>> Scripts,
    IReadOnlyList<FixtureShot> Shots)
{
    private const string PasswordMarker = "screenshot-fixture-no-password";

    private static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip };

    private static readonly JsonSerializerOptions DataOptions = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public static ShotFixture Load(string path) =>
        JsonSerializer.Deserialize<ShotFixture>(File.ReadAllText(path), Options) ?? throw new InvalidDataException($"{path} is empty.");

    /// <summary>Writes the settings and the SoX list into a new data folder before the app services read them.</summary>
    public void WriteData(AppPaths paths)
    {
        paths.EnsureCreated();
        var settings = AppSettings.Load(paths.SettingsFile);
        settings.CheckForUpdates = false;
        settings.HideStarSox = HideStar;
        settings.Save();
        File.WriteAllText(paths.SoxFile, JsonSerializer.Serialize(Sox, DataOptions));
        File.WriteAllText(paths.AccountsFile, JsonSerializer.Serialize(Accounts.Select(ToAccount).ToList(), DataOptions));
    }

    public ShowcaseFeed Feed(AccountStore store)
    {
        var windows = new List<IGameView>();
        var memory = new List<AccountMemory>();
        foreach (var account in Accounts.Where(a => a.Window is not null))
        {
            var stored = store.Accounts.Single(a => a.Id == account.Id);
            var window = account.Window!;
            windows.Add(new ShowcaseWindow(stored, window.Light, window.Hidden, window.Status, window.State));
            memory.Add(new AccountMemory(
                account.Name,
                window.Light,
                window.Hidden,
                Process(window.Memory),
                Bytes(window.Memory.JsHeapUsedMb),
                Bytes(window.Memory.JsHeapTotalMb),
                Bytes(window.Memory.WasmMb),
                window.Memory.WasmMemories));
        }
        var report = new MemoryReport(new DateTimeOffset(SessionStart), memory, Process(Processes.Gpu), Process(Processes.Browser), Process(Processes.App));
        return new ShowcaseFeed(windows, Cache, report, SessionStart);
    }

    private static Account ToAccount(FixtureAccount account) => new()
    {
        Id = account.Id,
        Name = account.Name,
        LoginId = account.LoginId,
        Server = account.Server,
        Character = account.Character,
        AutoLogin = account.AutoLogin,
        StartLight = account.StartLight,
        ProtectedPassword = account.SavedPassword ? PasswordMarker : null,
    };

    private static ProcessMemory Process(FixtureMemory memory) => new(Bytes(memory.PrivateMb)!.Value, Bytes(memory.WorkingSetMb)!.Value);

    private static long? Bytes(double? megabytes) => megabytes is { } value ? (long)Math.Round(value * 1048576) : null;
}

internal sealed record ShowcaseWindow(Account Account, bool Light, bool Hidden, BotStatus? Status, string StateText) : IGameView
{
    public bool InGame => Status?.InWorld == true;
}
