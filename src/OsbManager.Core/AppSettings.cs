using System.Text.Json.Serialization;

namespace OsbManager.Core;

public enum BotNoticeChoice
{
    Undecided,
    Kept,
    Replaced,
}

public enum OsbFirstInstallState
{
    Skipped,
    Pending,
    Done,
}

/// <summary>App-wide preferences kept in settings.json.</summary>
public sealed class AppSettings
{
    public static readonly IReadOnlyList<int> FrameLimits = [30, 60, 120, 0];
    public const int DefaultFrameLimit = 60;

    private string path = "";

    /// <summary>Most frames per second a game window draws; 0 follows the monitor.</summary>
    public int FrameLimit { get; set; } = DefaultFrameLimit;

    /// <summary>Lets the game window use less memory while it is minimised, as light mode does. Off until measured in the world.</summary>
    public bool LowMemoryWhenHidden { get; set; }

    /// <summary>Restarts a game window, with the same profile and saved login, when its renderer cannot start even after a reload.</summary>
    public bool RestartAfterRendererFailure { get; set; } = true;

    /// <summary>Looks for a signed OSB Manager release a while after start and every few hours. Off means no update requests.</summary>
    public bool CheckForUpdates { get; set; } = true;

    public bool UpdateOsbAutomatically { get; set; } = true;

    /// <summary>The SoX list hides Seal of Star entries; they are still recorded.</summary>
    public bool HideStarSox { get; set; }

    /// <summary>What the operator answered to the notice that OSB replaces the previous bot.</summary>
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public BotNoticeChoice BotNotice { get; set; } = BotNoticeChoice.Undecided;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public OsbFirstInstallState OsbFirstInstall { get; set; } = OsbFirstInstallState.Skipped;

    public static AppSettings Load(string path)
    {
        AppSettings settings;
        try
        {
            settings = JsonFile.Read<AppSettings>(path) ?? new AppSettings { OsbFirstInstall = OsbFirstInstallState.Pending };
        }
        catch (System.Text.Json.JsonException)
        {
            settings = new AppSettings();
        }
        if (!FrameLimits.Contains(settings.FrameLimit))
        {
            settings.FrameLimit = DefaultFrameLimit;
        }
        settings.path = path;
        return settings;
    }

    public void Save() => JsonFile.Write(path, this);
}
