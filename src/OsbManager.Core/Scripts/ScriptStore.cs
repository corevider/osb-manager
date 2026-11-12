using System.Security.Cryptography;

namespace OsbManager.Core.Scripts;

public sealed class InstalledScript
{
    internal InstalledScript(ScriptEntry entry, UserScriptMeta meta, string injection)
    {
        Entry = entry;
        Meta = meta;
        Injection = injection;
    }

    internal ScriptEntry Entry { get; }
    public string Id => Entry.Id;
    public bool Enabled => Entry.Enabled;
    public string? SourceUrl => Entry.SourceUrl;
    public UserScriptMeta Meta { get; }
    public string Injection { get; }

    public string? UpdateSource => Meta.DownloadUrl ?? SourceUrl;

    public IReadOnlyList<string> Warnings =>
    [
        .. Meta.UnsupportedGrants.Select(g => "unsupported @grant " + g),
        .. Meta.Requires.Count > 0 ? new[] { "@require is not loaded" } : [],
    ];
}

internal sealed class ScriptEntry
{
    public string Id { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public string? SourceUrl { get; set; }
}

/// <summary>Installed userscripts, kept as files next to a small JSON index.</summary>
public sealed class ScriptStore
{
    public const int MaxScriptBytes = 16 << 20;

    private readonly string directory;
    private readonly string indexPath;
    private readonly List<InstalledScript> scripts = [];
    private int batchDepth;
    private bool changedInBatch;

    public ScriptStore(string directory, Action<string> log)
    {
        this.directory = directory;
        indexPath = Path.Combine(directory, "scripts.json");
        Directory.CreateDirectory(directory);
        foreach (var entry in JsonFile.Read<List<ScriptEntry>>(indexPath) ?? [])
        {
            try
            {
                if (entry is null || !IsValidId(entry.Id))
                {
                    continue;
                }
                var source = File.ReadAllText(SourcePath(entry.Id));
                var meta = UserScriptMeta.Parse(source);
                scripts.Add(new InstalledScript(entry, meta, ScriptInjection.Build(meta, source)));
            }
            catch (Exception e) when (e is IOException or FormatException or UnauthorizedAccessException)
            {
                log($"Skipped installed script {entry.Id}: {e.Message}");
            }
        }
    }

    public event Action? Changed;

    public IReadOnlyList<InstalledScript> Scripts => scripts;

    public IEnumerable<string> EnabledInjections => scripts.Where(s => s.Enabled).Select(s => s.Injection);

    /// <summary>Installs a script, replacing an installed one with the same name and namespace.</summary>
    public InstalledScript Install(string source, string? sourceUrl)
    {
        var meta = UserScriptMeta.Parse(source);
        var injection = ScriptInjection.Build(meta, source);
        var existing = scripts.FindIndex(s => s.Meta.Name == meta.Name && s.Meta.Namespace == meta.Namespace);
        var entry = existing >= 0
            ? scripts[existing].Entry
            : new ScriptEntry { Id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(6)) };
        entry.SourceUrl = sourceUrl ?? entry.SourceUrl;
        var installed = new InstalledScript(entry, meta, injection);
        File.WriteAllText(SourcePath(entry.Id), source);
        if (existing >= 0)
        {
            scripts[existing] = installed;
        }
        else
        {
            scripts.Add(installed);
        }
        Save();
        return installed;
    }

    public async Task<InstalledScript> InstallFromUrlAsync(string url, HttpClient http, CancellationToken cancellation = default, bool allowLoopbackHttp = false, Func<UserScriptMeta, bool>? accept = null)
    {
        var source = await DownloadTextAsync(url, http, MaxScriptBytes, cancellation, allowLoopbackHttp);
        if (accept is not null && !accept(UserScriptMeta.Parse(source)))
        {
            throw new InvalidDataException("The downloaded script is not the expected one.");
        }
        return Install(source, new Uri(url).ToString());
    }

    public static async Task<string> DownloadTextAsync(string url, HttpClient http, int maxBytes, CancellationToken cancellation = default, bool allowLoopbackHttp = false)
    {
        var secure = Uri.TryCreate(url, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttps || allowLoopbackHttp && uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback);
        if (!secure)
        {
            throw new FormatException("Use an https:// address.");
        }
        using var response = await http.GetAsync(uri!, HttpCompletionOption.ResponseHeadersRead, cancellation);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > maxBytes)
        {
            throw new InvalidDataException("The script is too large.");
        }
        var source = await response.Content.ReadAsStringAsync(cancellation);
        if (source.Length > maxBytes)
        {
            throw new InvalidDataException("The script is too large.");
        }
        return source;
    }

    public void SetEnabled(InstalledScript script, bool enabled)
    {
        script.Entry.Enabled = enabled;
        Save();
    }

    public void Remove(InstalledScript script)
    {
        if (scripts.Remove(script))
        {
            File.Delete(SourcePath(script.Id));
            Save();
        }
    }

    /// <summary>Holds back <see cref="Changed"/> until the returned scope is disposed, then raises it once.</summary>
    public IDisposable BatchChanges()
    {
        batchDepth++;
        return new ChangeBatch(this);
    }

    private void Save()
    {
        JsonFile.Write(indexPath, scripts.Select(s => s.Entry).ToList());
        if (batchDepth > 0)
        {
            changedInBatch = true;
        }
        else
        {
            Changed?.Invoke();
        }
    }

    private void EndBatch()
    {
        if (--batchDepth == 0 && changedInBatch)
        {
            changedInBatch = false;
            Changed?.Invoke();
        }
    }

    private sealed class ChangeBatch(ScriptStore store) : IDisposable
    {
        private bool disposed;

        public void Dispose()
        {
            if (!disposed)
            {
                disposed = true;
                store.EndBatch();
            }
        }
    }

    private string SourcePath(string id) => Path.Combine(directory, id + ".user.js");

    private static bool IsValidId(string id) => id.Length == 12 && id.All(char.IsAsciiHexDigitLower);
}
