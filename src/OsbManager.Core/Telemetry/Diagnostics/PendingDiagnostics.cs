using System.Globalization;
using System.Security.Cryptography;

namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed record PendingFile(string Id, DateTimeOffset WrittenAt, byte[] Content);

public sealed class PendingDiagnostics
{
    public const int MaxFiles = 10;
    public const int MaxFileBytes = 16 * 1024;
    public const string Prefix = "pending-";
    public const string Extension = ".json";
    public static readonly TimeSpan Expiry = TimeSpan.FromDays(7);

    private readonly object sync = new();
    private readonly string folder;
    private readonly TimeProvider time;
    private readonly Func<bool> consentOn;

    public PendingDiagnostics(string folder, TimeProvider time, Func<bool> consentOn)
    {
        this.folder = folder;
        this.time = time;
        this.consentOn = consentOn;
    }

    public string Folder => folder;

    public bool Write(byte[] content)
    {
        if (content.Length == 0 || content.Length > MaxFileBytes)
        {
            return false;
        }
        lock (sync)
        {
            if (!consentOn())
            {
                return false;
            }
            try
            {
                Directory.CreateDirectory(folder);
                var now = time.GetUtcNow();
                var name = Prefix + now.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture) + "-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant() + Extension;
                var path = Path.Combine(folder, name);
                var temp = path + ".tmp";
                using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    stream.Write(content);
                }
                File.Move(temp, path);
                var files = Files().OrderByDescending(f => f.WrittenAt).ThenByDescending(f => f.Path, StringComparer.Ordinal).ToList();
                foreach (var old in files.Skip(MaxFiles))
                {
                    TryDelete(old.Path);
                }
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return false;
            }
        }
    }

    public IReadOnlyList<PendingFile> Load()
    {
        lock (sync)
        {
            if (!consentOn())
            {
                WipeLocked();
                return [];
            }
            var now = time.GetUtcNow();
            var result = new List<PendingFile>();
            foreach (var file in Files().OrderBy(f => f.WrittenAt).ThenBy(f => f.Path, StringComparer.Ordinal))
            {
                if (now - file.WrittenAt >= Expiry || file.WrittenAt - now > TimeSpan.FromDays(1))
                {
                    TryDelete(file.Path);
                    continue;
                }
                try
                {
                    var info = new FileInfo(file.Path);
                    if (info.Length is 0 or > MaxFileBytes)
                    {
                        TryDelete(file.Path);
                        continue;
                    }
                    result.Add(new PendingFile(Path.GetFileName(file.Path), file.WrittenAt, File.ReadAllBytes(file.Path)));
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }
            }
            return result.TakeLast(MaxFiles).ToList();
        }
    }

    public void Delete(string id)
    {
        if (id.IndexOfAny(['\\', '/']) >= 0 || !id.StartsWith(Prefix, StringComparison.Ordinal) || !id.EndsWith(Extension, StringComparison.Ordinal))
        {
            return;
        }
        lock (sync)
        {
            TryDelete(Path.Combine(folder, id));
        }
    }

    public void WipeAll()
    {
        lock (sync)
        {
            WipeLocked();
        }
    }

    public int Count()
    {
        lock (sync)
        {
            return Files().Count();
        }
    }

    private void WipeLocked()
    {
        if (!Directory.Exists(folder))
        {
            return;
        }
        try
        {
            foreach (var path in Directory.EnumerateFiles(folder))
            {
                TryDelete(path);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    private IEnumerable<(string Path, DateTimeOffset WrittenAt)> Files()
    {
        if (!Directory.Exists(folder))
        {
            return [];
        }
        var result = new List<(string, DateTimeOffset)>();
        foreach (var path in Directory.EnumerateFiles(folder, Prefix + "*" + Extension))
        {
            var name = Path.GetFileNameWithoutExtension(path);
            var parts = name[Prefix.Length..].Split('-');
            if (parts.Length == 2 && long.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) && seconds is > 0 and < 253_402_300_799)
            {
                result.Add((path, DateTimeOffset.FromUnixTimeSeconds(seconds)));
            }
            else
            {
                TryDelete(path);
            }
        }
        return result;
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
