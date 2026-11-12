namespace OsbManager.Core.Telemetry.Diagnostics;

public static class TrailCodes
{
    public const string WindowStart = "window.start";
    public const string WindowClosed = "window.closed";
    public const string WindowRendererExited = "window.renderer-exited";
    public const string WindowUnresponsive = "window.unresponsive";
    public const string WindowResponding = "window.responding";
    public const string WindowReload = "window.reload";
    public const string WindowRestart = "window.restart";
    public const string WindowGaveUp = "window.gave-up";
    public const string LoginReload = "login.reload";
    public const string GpuRetry = "gpu.retry";
    public const string UpdateDownload = "update.download";
    public const string UpdateFailed = "update.failed";
    public const string ScriptInstallFailed = "script.install-failed";
    public const string ScriptUpdateFailed = "script.update-failed";
    public const string SettingsLightOn = "settings.light-on";
    public const string SettingsFpsLimit = "settings.fps-limit";

    public static string LoginFailed(string? stage) => "login.failed:" + (DiagnosticScrubber.LoginStage(stage) ?? DiagnosticScrubber.Other);

    public static string GpuFailed(string? text) => "gpu.failed:" + (DiagnosticScrubber.GpuFailure(text) ?? DiagnosticScrubber.Other);

    public static string Category(string code)
    {
        var dot = code.IndexOf('.', StringComparison.Ordinal);
        return dot > 0 ? code[..dot] : code;
    }
}

public sealed class DiagnosticTrail
{
    public const int Capacity = DiagnosticFormats.MaxManagerTrail;

    private readonly object sync = new();
    private readonly Entry[] entries = new Entry[Capacity];
    private readonly TimeProvider time;
    private readonly Func<bool> recording;
    private int next;
    private int count;

    public DiagnosticTrail(TimeProvider time, Func<bool>? recording = null)
    {
        this.time = time;
        this.recording = recording ?? (() => true);
    }

    public int Count
    {
        get { lock (sync) { return count; } }
    }

    public void Add(string level, string code, int? window = null)
    {
        if (!DiagnosticFormats.TrailLevels.Contains(level) || !DiagnosticFormats.IsCode(code) || !recording())
        {
            return;
        }
        var now = time.GetUtcNow();
        lock (sync)
        {
            if (count > 0)
            {
                ref var newest = ref entries[(next + Capacity - 1) % Capacity];
                if (newest.Level == level && newest.Code == code && newest.Window == window)
                {
                    newest = newest with { At = now, Count = Math.Min(newest.Count + 1, DiagnosticFormats.MaxCount) };
                    return;
                }
            }
            entries[next] = new Entry(now, level, code, window, 1);
            next = (next + 1) % Capacity;
            count = Math.Min(count + 1, Capacity);
        }
    }

    public void Info(string code, int? window = null) => Add("info", code, window);

    public void Warning(string code, int? window = null) => Add("warn", code, window);

    public void Error(string code, int? window = null) => Add("error", code, window);

    public IReadOnlyList<TrailItem> Snapshot(DateTimeOffset eventAt)
    {
        var result = new List<TrailItem>(Capacity);
        lock (sync)
        {
            for (var i = 0; i < count; i++)
            {
                var entry = entries[(next - count + i + Capacity) % Capacity];
                var before = (int)Math.Round((entry.At - eventAt).TotalSeconds);
                if (before > 0 || before < -86400)
                {
                    continue;
                }
                result.Add(new TrailItem(before, entry.Level, TrailCodes.Category(entry.Code), entry.Code, entry.Count, entry.Window));
            }
        }
        return result;
    }

    public void Clear()
    {
        lock (sync)
        {
            Array.Clear(entries);
            next = 0;
            count = 0;
        }
    }

    private readonly record struct Entry(DateTimeOffset At, string Level, string Code, int? Window, int Count);
}
