using System.IO.Compression;

namespace OsbManager.Core.Updates;

/// <summary>
/// Replaces the running Windows exe: the new exe is staged next to it as name.new.exe, the running one is renamed to
/// name.prev.exe and the new one takes its name. A failure before the swap changes nothing; after it, RollBack puts
/// the previous exe back. The leftovers are removed at the next start.
/// </summary>
public sealed class ExeSwap
{
    public const long MaxExeBytes = 400L * 1024 * 1024;
    public const string ZipEntryName = "OsbManager.exe";

    public ExeSwap(string exePath)
    {
        ExePath = Path.GetFullPath(exePath);
        Folder = Path.GetDirectoryName(ExePath) ?? throw new ArgumentException("The exe has no folder.", nameof(exePath));
        var name = Path.GetFileNameWithoutExtension(ExePath);
        StagedPath = Path.Combine(Folder, name + ".new.exe");
        PreviousPath = Path.Combine(Folder, name + ".prev.exe");
    }

    public string ExePath { get; }

    public string Folder { get; }

    public string StagedPath { get; }

    public string PreviousPath { get; }

    public static bool CanWrite(string folder)
    {
        var probe = Path.Combine(folder, $".osb-write-test-{Guid.NewGuid():N}");
        try
        {
            using (new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose))
            {
            }
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>Copies the exe out of the verified zip to the staged path. The running exe is not touched.</summary>
    public void Stage(string zipPath)
    {
        const string exeName = ZipEntryName;
        try
        {
            using var archive = ZipFile.OpenRead(zipPath);
            var entries = archive.Entries.Where(e => string.Equals(e.FullName, exeName, StringComparison.OrdinalIgnoreCase)).ToList();
            if (entries.Count != 1)
            {
                throw new UpdateException($"The update zip does not contain exactly one {exeName}.");
            }
            var entry = entries[0];
            if (entry.Length <= 0 || entry.Length > MaxExeBytes)
            {
                throw new UpdateException($"The {exeName} in the update zip has an unexpected size.");
            }
            File.Delete(StagedPath);
            entry.ExtractToFile(StagedPath, overwrite: false);
            if (new FileInfo(StagedPath).Length != entry.Length)
            {
                throw new UpdateException($"The {exeName} in the update zip could not be extracted completely.");
            }
        }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            DeleteQuietly(StagedPath);
            throw new UpdateException($"Could not prepare the update: {e.Message}", e);
        }
        catch
        {
            DeleteQuietly(StagedPath);
            throw;
        }
    }

    /// <summary>Puts the staged exe in place. If the second rename fails, the previous exe is put back before this throws.</summary>
    public void Swap()
    {
        if (!File.Exists(StagedPath))
        {
            throw new UpdateException("The new exe has not been prepared.");
        }
        DeleteQuietly(PreviousPath);
        try
        {
            File.Move(ExePath, PreviousPath);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new UpdateException($"Could not move the running exe aside: {e.Message}. Nothing was changed.", e);
        }
        try
        {
            File.Move(StagedPath, ExePath);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            RollBack();
            throw new UpdateException($"Could not put the new exe in place: {e.Message}. The previous exe was restored.", e);
        }
    }

    /// <summary>Restores the previous exe after a swap whose new exe did not start.</summary>
    public void RollBack()
    {
        if (!File.Exists(PreviousPath))
        {
            return;
        }
        if (File.Exists(ExePath))
        {
            File.Move(ExePath, StagedPath, overwrite: true);
        }
        File.Move(PreviousPath, ExePath);
        DeleteQuietly(StagedPath);
    }

    /// <summary>Removes the previous and staged exes left by an earlier update; files still in use are left for next time.</summary>
    public int CleanUp()
    {
        var removed = 0;
        foreach (var path in new[] { PreviousPath, StagedPath })
        {
            if (File.Exists(path) && DeleteQuietly(path))
            {
                removed++;
            }
        }
        return removed;
    }

    private static bool DeleteQuietly(string path)
    {
        try
        {
            File.Delete(path);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
