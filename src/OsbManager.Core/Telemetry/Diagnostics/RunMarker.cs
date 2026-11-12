using System.Globalization;
using System.Text.Json;

namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed record PreviousRun(string Version, DateTimeOffset StartedAt, DateTimeOffset AliveAt, bool Crashed, bool EndedCleanly = false)
{
    public string Outcome => Crashed ? "crash" : EndedCleanly ? "clean" : "unclean";

    public int UptimeSeconds => (int)Math.Clamp((AliveAt - StartedAt).TotalSeconds, 0, DiagnosticFormats.MaxUptimeSeconds);
}

public sealed class RunMarker
{
    public const string FileName = "run.json";

    private readonly object sync = new();
    private readonly string path;
    private readonly string folder;
    private readonly TimeProvider time;
    private readonly Func<bool> recording;
    private string? version;
    private DateTimeOffset startedAt;
    private bool written;
    private bool crashed;
    private bool endedCleanly;

    public RunMarker(string folder, TimeProvider time, Func<bool> recording)
    {
        this.folder = folder;
        this.time = time;
        this.recording = recording;
        path = Path.Combine(folder, FileName);
    }

    public bool Written
    {
        get { lock (sync) { return written; } }
    }

    public PreviousRun? ReadPrevious()
    {
        lock (sync)
        {
            if (!recording())
            {
                return null;
            }
            try
            {
                if (!File.Exists(path) || new FileInfo(path).Length > 1024)
                {
                    return null;
                }
                using var document = JsonDocument.Parse(File.ReadAllBytes(path), new JsonDocumentOptions { MaxDepth = 4 });
                var root = document.RootElement;
                var previous = new PreviousRun(
                    root.GetProperty("version").GetString() ?? "",
                    ParseTime(root.GetProperty("started")),
                    ParseTime(root.GetProperty("alive")),
                    root.TryGetProperty("crashed", out var flag) && flag.ValueKind == JsonValueKind.True,
                    root.TryGetProperty("clean", out var clean) && clean.ValueKind == JsonValueKind.True);
                var now = time.GetUtcNow();
                return DiagnosticFormats.IsVersion(previous.Version)
                    && previous.AliveAt >= previous.StartedAt
                    && now - previous.AliveAt < DiagnosticFormats.MaxAge
                    && previous.AliveAt - now < DiagnosticFormats.MaxAhead
                        ? previous
                        : null;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or KeyNotFoundException or FormatException)
            {
                return null;
            }
        }
    }

    public bool Begin(string runVersion)
    {
        lock (sync)
        {
            if (!recording() || !DiagnosticFormats.IsVersion(runVersion))
            {
                return false;
            }
            version = runVersion;
            startedAt = DiagnosticFormats.Minute(time.GetUtcNow());
            crashed = false;
            endedCleanly = false;
            return Write();
        }
    }

    public void Touch()
    {
        lock (sync)
        {
            if (written && recording())
            {
                Write();
            }
        }
    }

    public void MarkCrashed()
    {
        lock (sync)
        {
            crashed = true;
            if (written)
            {
                Write();
            }
        }
    }

    public void Clean()
    {
        lock (sync)
        {
            if (crashed)
            {
                return;
            }
            if (written && recording())
            {
                endedCleanly = true;
                Write();
                return;
            }
            Delete();
        }
    }

    public void Forget()
    {
        lock (sync)
        {
            written = false;
        }
    }

    private bool Write()
    {
        if (version is null)
        {
            return false;
        }
        try
        {
            Directory.CreateDirectory(folder);
            var temp = path + ".tmp";
            var json = JsonSerializer.SerializeToUtf8Bytes(new
            {
                version,
                started = DiagnosticFormats.MinuteText(startedAt),
                alive = DiagnosticFormats.MinuteText(time.GetUtcNow()),
                crashed,
                clean = endedCleanly,
            });
            using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(json);
            }
            File.Move(temp, path, overwrite: true);
            written = true;
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private void Delete()
    {
        written = false;
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static DateTimeOffset ParseTime(JsonElement element) =>
        DateTimeOffset.Parse(element.GetString() ?? "", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
}
