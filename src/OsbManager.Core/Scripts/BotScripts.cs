namespace OsbManager.Core.Scripts;

/// <summary>Tells the OSB bot and the previous bot apart, and decides what the Scripts tab says about them.</summary>
public static class BotScripts
{
    public const string OsbUrl = "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js";
    public const string OsbNamespace = "https://github.com/corevider/osb";

    private static readonly string[] RepositoryHosts = ["raw.githubusercontent.com", "github.com"];

    public static bool IsNixxaneUrl(string? url) => InRepository(url, "nixxane", "opensro-bot-lean");

    public static bool IsOsbUrl(string? url) => InRepository(url, "corevider", "osb");

    public static bool IsNixxane(InstalledScript script) => IsNixxaneUrl(script.SourceUrl) || IsNixxaneUrl(script.UpdateSource);

    public static bool IsOsb(InstalledScript script) =>
        IsOsbUrl(script.SourceUrl) || IsOsbUrl(script.UpdateSource) ||
        string.Equals(script.Meta.Namespace, OsbNamespace, StringComparison.OrdinalIgnoreCase);

    public static bool ShouldOfferReplacement(IEnumerable<InstalledScript> scripts, BotNoticeChoice choice) =>
        choice == BotNoticeChoice.Undecided && scripts.Any(IsNixxane);

    public static bool BothEnabled(IEnumerable<InstalledScript> scripts)
    {
        var enabled = scripts.Where(s => s.Enabled).ToList();
        return enabled.Any(IsNixxane) && enabled.Any(IsOsb);
    }

    /// <summary>
    /// Installs OSB, then turns the previous bot off. Its script stays installed. When OSB cannot be
    /// installed, nothing changes and the exception reaches the caller.
    /// </summary>
    public static async Task<InstalledScript> ReplaceWithOsbAsync(ScriptStore scripts, HttpClient http, AppSettings settings, string osbUrl, bool allowLoopbackHttp = false)
    {
        using var batch = scripts.BatchChanges();
        var osb = await scripts.InstallFromUrlAsync(osbUrl, http, allowLoopbackHttp: allowLoopbackHttp);
        foreach (var script in scripts.Scripts.Where(s => IsNixxane(s) && s.Enabled).ToList())
        {
            scripts.SetEnabled(script, false);
        }
        settings.BotNotice = BotNoticeChoice.Replaced;
        settings.Save();
        return osb;
    }

    public static void KeepNixxane(AppSettings settings)
    {
        settings.BotNotice = BotNoticeChoice.Kept;
        settings.Save();
    }

    private static bool InRepository(string? url, string owner, string repository)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || !RepositoryHosts.Contains(uri.Host, StringComparer.OrdinalIgnoreCase))
        {
            return false;
        }
        var segments = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return segments.Length >= 2
            && string.Equals(segments[0], owner, StringComparison.OrdinalIgnoreCase)
            && string.Equals(segments[1], repository, StringComparison.OrdinalIgnoreCase);
    }
}
