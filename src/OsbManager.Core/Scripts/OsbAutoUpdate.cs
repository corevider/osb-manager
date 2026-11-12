using OsbManager.Core.Updates;

namespace OsbManager.Core.Scripts;

public enum OsbUpdateOutcome
{
    NotApplicable,
    Disabled,
    Busy,
    UpToDate,
    Updated,
    Failed,
}

public sealed record OsbUpdateResult(
    OsbUpdateOutcome Outcome,
    string? OldVersion = null,
    string? NewVersion = null,
    Exception? Error = null,
    bool FirstFailureInStreak = false);

public sealed class OsbAutoUpdate
{
    public const int MaxMetaBytes = 256 << 10;
    public const string MetaFileName = "osb.meta.js";

    private readonly ScriptStore scripts;
    private readonly HttpClient http;
    private readonly ScriptJobs jobs;
    private readonly Func<bool> enabled;
    private readonly string? addressOverride;
    private int running;
    private bool failing;

    public OsbAutoUpdate(ScriptStore scripts, HttpClient http, ScriptJobs jobs, Func<bool> enabled, string? addressOverride = null)
    {
        this.scripts = scripts;
        this.http = http;
        this.jobs = jobs;
        this.enabled = enabled;
        this.addressOverride = addressOverride;
    }

    public async Task<OsbUpdateResult> CheckAsync(CancellationToken cancellation = default)
    {
        if (!enabled())
        {
            return new OsbUpdateResult(OsbUpdateOutcome.Disabled);
        }
        if (jobs.Busy || Interlocked.CompareExchange(ref running, 1, 0) != 0)
        {
            return new OsbUpdateResult(OsbUpdateOutcome.Busy);
        }
        try
        {
            using var job = jobs.Begin();
            return await RunAsync(cancellation);
        }
        finally
        {
            Volatile.Write(ref running, 0);
        }
    }

    private async Task<OsbUpdateResult> RunAsync(CancellationToken cancellation)
    {
        var osb = scripts.Scripts.FirstOrDefault(BotScripts.IsOsb);
        if (osb is null || ResolveAddresses(osb) is not { } addresses)
        {
            return new OsbUpdateResult(OsbUpdateOutcome.NotApplicable);
        }
        var installed = osb.Meta.Version;
        try
        {
            var announced = await ReadAnnouncedVersionAsync(addresses.Meta, osb, cancellation);
            if (!UpdateVersion.TryParse(installed, out var current))
            {
                throw new FormatException($"The installed OSB version \"{installed}\" is not understood.");
            }
            if (announced <= current)
            {
                failing = false;
                return new OsbUpdateResult(OsbUpdateOutcome.UpToDate, installed, installed);
            }
            var updated = await scripts.InstallFromUrlAsync(addresses.Download, http, cancellation, addressOverride is not null,
                meta => IsAcceptable(meta, osb, announced));
            failing = false;
            return new OsbUpdateResult(OsbUpdateOutcome.Updated, installed, updated.Meta.Version);
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellation.IsCancellationRequested)
        {
            var first = !failing;
            failing = true;
            return new OsbUpdateResult(OsbUpdateOutcome.Failed, installed, Error: error, FirstFailureInStreak: first);
        }
    }

    private (string Meta, string Download)? ResolveAddresses(InstalledScript osb)
    {
        if (addressOverride is not null)
        {
            var meta = new Uri(new Uri(addressOverride), MetaFileName).ToString();
            return (meta, addressOverride);
        }
        var update = osb.Meta.UpdateUrl;
        var download = osb.Meta.DownloadUrl;
        return IsOsbHttps(update) && IsOsbHttps(download) ? (update!, download!) : null;
    }

    private async Task<UpdateVersion> ReadAnnouncedVersionAsync(string metaUrl, InstalledScript osb, CancellationToken cancellation)
    {
        var text = await ScriptStore.DownloadTextAsync(metaUrl, http, MaxMetaBytes, cancellation, addressOverride is not null);
        var meta = UserScriptMeta.Parse(text);
        if (!IsOsbIdentity(meta, osb) || !UpdateVersion.TryParse(meta.Version, out var version))
        {
            throw new InvalidDataException("The update file does not announce an OSB version.");
        }
        return version;
    }

    private static bool IsAcceptable(UserScriptMeta meta, InstalledScript osb, UpdateVersion announced) =>
        IsOsbIdentity(meta, osb) && UpdateVersion.TryParse(meta.Version, out var version) && version >= announced;

    private static bool IsOsbIdentity(UserScriptMeta meta, InstalledScript osb) =>
        meta.Name == osb.Meta.Name && string.Equals(meta.Namespace, BotScripts.OsbNamespace, StringComparison.OrdinalIgnoreCase);

    private static bool IsOsbHttps(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps && BotScripts.IsOsbUrl(url);
}
