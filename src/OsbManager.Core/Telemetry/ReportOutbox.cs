using System.Text.Json;

namespace OsbManager.Core.Telemetry;

public sealed class OutboxEntry
{
    public string Id { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset NextAttemptAt { get; set; }
    public int Attempts { get; set; }
    public bool Anonymous { get; set; }
    public string ReportJson { get; set; } = "";
    public string? LastNote { get; set; }
    public bool HasScreenshot { get; set; }
}

public enum EnqueueOutcome
{
    Queued,
    Full,
    TooLarge,
    Failed,
}

/// <summary>
/// Reports the user sent that could not be delivered yet. At most five wait here; each is a JSON file written atomically
/// (its screenshot is a PNG next to it). A report older than 72 hours moves to failed/ and waits for the user.
/// </summary>
public sealed class ReportOutbox
{
    public const int MaxPending = 5;
    public const int MaxReportBytes = 900 * 1024;

    private readonly object sync = new();
    private readonly string directory;
    private readonly string failedDirectory;
    private readonly TimeProvider time;

    public ReportOutbox(string directory, TimeProvider time)
    {
        this.directory = directory;
        failedDirectory = Path.Combine(directory, "failed");
        this.time = time;
    }

    public event Action? Changed;

    public EnqueueOutcome Enqueue(byte[] reportJson, byte[]? screenshot, bool anonymous, out string id, TimeSpan retryIn = default, string? note = null)
    {
        id = Guid.NewGuid().ToString("N");
        if (reportJson.Length + (screenshot?.Length ?? 0) > MaxReportBytes)
        {
            return EnqueueOutcome.TooLarge;
        }
        EnqueueOutcome outcome;
        lock (sync)
        {
            outcome = ReadAll(directory).Count >= MaxPending ? EnqueueOutcome.Full : Write(reportJson, screenshot, anonymous, id, retryIn, note);
        }
        if (outcome == EnqueueOutcome.Queued)
        {
            Changed?.Invoke();
        }
        return outcome;
    }

    private EnqueueOutcome Write(byte[] reportJson, byte[]? screenshot, bool anonymous, string id, TimeSpan retryIn, string? note)
    {
        var now = time.GetUtcNow();
        var entry = new OutboxEntry
        {
            Id = id,
            CreatedAt = now,
            NextAttemptAt = now + retryIn,
            Attempts = note is null ? 0 : 1,
            LastNote = note,
            Anonymous = anonymous,
            ReportJson = System.Text.Encoding.UTF8.GetString(reportJson),
            HasScreenshot = screenshot is not null,
        };
        try
        {
            Directory.CreateDirectory(directory);
            if (screenshot is not null)
            {
                WriteAtomic(ScreenshotPath(directory, id), screenshot);
            }
            WriteEntry(directory, entry);
            return EnqueueOutcome.Queued;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Delete(directory, id);
            return EnqueueOutcome.Failed;
        }
    }

    public IReadOnlyList<OutboxEntry> Pending()
    {
        lock (sync)
        {
            return ReadAll(directory);
        }
    }

    public IReadOnlyList<OutboxEntry> Failed()
    {
        lock (sync)
        {
            return ReadAll(failedDirectory);
        }
    }

    public byte[]? Screenshot(OutboxEntry entry, bool failed)
    {
        lock (sync)
        {
            var path = ScreenshotPath(failed ? failedDirectory : directory, entry.Id);
            return entry.HasScreenshot && File.Exists(path) ? File.ReadAllBytes(path) : null;
        }
    }

    public DateTimeOffset? NextAttemptAt()
    {
        lock (sync)
        {
            var pending = ReadAll(directory);
            return pending.Count == 0 ? null : pending.Min(e => e.NextAttemptAt);
        }
    }

    public void RecordAttempt(string id, TimeSpan retryIn, string note, bool anonymous)
    {
        lock (sync)
        {
            var entry = ReadAll(directory).FirstOrDefault(e => e.Id == id);
            if (entry is null)
            {
                return;
            }
            entry.Attempts++;
            entry.NextAttemptAt = time.GetUtcNow() + retryIn;
            entry.LastNote = note;
            entry.Anonymous |= anonymous;
            WriteEntry(directory, entry);
        }
    }

    public void Remove(string id)
    {
        lock (sync)
        {
            Delete(directory, id);
        }
        Changed?.Invoke();
    }

    public int MoveExpired()
    {
        var moved = 0;
        lock (sync)
        {
            var now = time.GetUtcNow();
            foreach (var entry in ReadAll(directory).Where(e => now - e.CreatedAt >= TelemetryLimits.ReportExpiry))
            {
                Directory.CreateDirectory(failedDirectory);
                if (entry.HasScreenshot && File.Exists(ScreenshotPath(directory, entry.Id)))
                {
                    File.Move(ScreenshotPath(directory, entry.Id), ScreenshotPath(failedDirectory, entry.Id), overwrite: true);
                }
                File.Move(EntryPath(directory, entry.Id), EntryPath(failedDirectory, entry.Id), overwrite: true);
                moved++;
            }
        }
        if (moved > 0)
        {
            Changed?.Invoke();
        }
        return moved;
    }

    public bool SendAgain(string id)
    {
        lock (sync)
        {
            if (ReadAll(directory).Count >= MaxPending)
            {
                return false;
            }
            var entry = ReadAll(failedDirectory).FirstOrDefault(e => e.Id == id);
            if (entry is null)
            {
                return false;
            }
            Directory.CreateDirectory(directory);
            var now = time.GetUtcNow();
            entry.CreatedAt = now;
            entry.NextAttemptAt = now;
            entry.Attempts = 0;
            if (entry.HasScreenshot && File.Exists(ScreenshotPath(failedDirectory, id)))
            {
                File.Move(ScreenshotPath(failedDirectory, id), ScreenshotPath(directory, id), overwrite: true);
            }
            WriteEntry(directory, entry);
            File.Delete(EntryPath(failedDirectory, id));
        }
        Changed?.Invoke();
        return true;
    }

    public void DeleteFailed(string id)
    {
        lock (sync)
        {
            Delete(failedDirectory, id);
        }
        Changed?.Invoke();
    }

    public void ClearAll()
    {
        lock (sync)
        {
            foreach (var folder in new[] { directory, failedDirectory })
            {
                if (!Directory.Exists(folder))
                {
                    continue;
                }
                foreach (var file in Directory.EnumerateFiles(folder))
                {
                    TryDelete(file);
                }
            }
        }
        Changed?.Invoke();
    }

    private static string EntryPath(string folder, string id) => Path.Combine(folder, id + ".json");

    private static string ScreenshotPath(string folder, string id) => Path.Combine(folder, id + ".png");

    private static void Delete(string folder, string id)
    {
        TryDelete(EntryPath(folder, id));
        TryDelete(ScreenshotPath(folder, id));
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

    private static List<OutboxEntry> ReadAll(string folder)
    {
        var entries = new List<OutboxEntry>();
        if (!Directory.Exists(folder))
        {
            return entries;
        }
        foreach (var path in Directory.EnumerateFiles(folder, "*.json"))
        {
            try
            {
                var entry = JsonFile.Read<OutboxEntry>(path);
                if (entry is not null && entry.Id == Path.GetFileNameWithoutExtension(path))
                {
                    entries.Add(entry);
                }
            }
            catch (Exception e) when (e is JsonException or IOException)
            {
            }
        }
        return [.. entries.OrderBy(e => e.CreatedAt)];
    }

    private static void WriteEntry(string folder, OutboxEntry entry) =>
        WriteAtomic(EntryPath(folder, entry.Id), JsonSerializer.SerializeToUtf8Bytes(entry, JsonFile.Options));

    private static void WriteAtomic(string path, byte[] bytes)
    {
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, path, overwrite: true);
    }
}
