using System.Text.Encodings.Web;
using System.Text.Json;

namespace OsbManager.Core.Telemetry.Diagnostics;

public static class DiagnosticEnvironment
{
    public static DiagnosticEnv FromThisMachine(string? webView2Version)
    {
        var os = Environment.OSVersion.Version;
        return new DiagnosticEnv(
            DiagnosticFormats.IsOsBuild(os.ToString(3)) ? os.ToString(3) : null,
            DiagnosticFormats.IsVersion(webView2Version) ? webView2Version : null,
            Environment.Version.ToString(3),
            DiagnosticFormats.RamBucket(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes),
            DiagnosticFormats.CoreBucket(Environment.ProcessorCount));
    }
}

public sealed class PreparedDiagnostics
{
    internal PreparedDiagnostics(
        byte[] body,
        CancellationToken session,
        IReadOnlyList<DiagnosticEvent> taken,
        DroppedCounts dropped,
        IReadOnlyList<PerfEntry> perf,
        IReadOnlyList<string> pendingIds,
        OsbPerfEntry? osbPerf = null)
    {
        OsbPerf = osbPerf;
        Body = body;
        Session = session;
        Taken = taken;
        Dropped = dropped;
        Perf = perf;
        PendingIds = pendingIds;
    }

    public byte[] Body { get; }
    public CancellationToken Session { get; }
    internal IReadOnlyList<DiagnosticEvent> Taken { get; }
    internal DroppedCounts Dropped { get; }
    internal IReadOnlyList<PerfEntry> Perf { get; }
    internal IReadOnlyList<string> PendingIds { get; }
    internal OsbPerfEntry? OsbPerf { get; }
}

public sealed class DiagnosticsUploader
{
    private static readonly JsonSerializerOptions Indented = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly DiagnosticsHub hub;
    private readonly PerfCollector perf;
    private readonly Lazy<DiagnosticEnv> env;
    private readonly string appVersion;
    private readonly TimeProvider time;

    public DiagnosticsUploader(DiagnosticsHub hub, PerfCollector perf, Func<DiagnosticEnv> env, string appVersion, TimeProvider time)
    {
        this.hub = hub;
        this.perf = perf;
        this.env = new Lazy<DiagnosticEnv>(env);
        this.appVersion = appVersion;
        this.time = time;
    }

    public void ApplyConfig(DiagnosticsConfig config) => hub.Limiter.SamplePercent = config.SamplePercent;

    public bool HasSomethingToSend(DiagnosticsConfig config) => Build(config, take: false) is not null;

    public string? Preview(DiagnosticsConfig config)
    {
        if (Build(config, take: false) is not { } prepared)
        {
            return null;
        }
        using var document = JsonDocument.Parse(prepared.Body);
        return JsonSerializer.Serialize(document.RootElement, Indented);
    }

    public PreparedDiagnostics? Prepare(DiagnosticsConfig config) => Build(config, take: true);

    public void Commit(PreparedDiagnostics prepared)
    {
        foreach (var id in prepared.PendingIds)
        {
            hub.Pending.Delete(id);
        }
    }

    public void Return(PreparedDiagnostics prepared)
    {
        if (prepared.Session.IsCancellationRequested || !hub.Recording)
        {
            return;
        }
        hub.Limiter.Return(prepared.Taken, prepared.Dropped);
        perf.Return(prepared.Perf);
        if (prepared.OsbPerf is { } osb)
        {
            hub.ReturnOsbPerf(osb);
        }
    }

    private PreparedDiagnostics? Build(DiagnosticsConfig config, bool take)
    {
        if (!hub.Recording || !config.Enabled)
        {
            return null;
        }
        var session = hub.Session;
        var events = new List<DiagnosticEvent>();
        var pendingIds = new List<string>();
        foreach (var file in hub.Pending.Load())
        {
            pendingIds.Add(file.Id);
            if (DiagnosticJson.ParseEvent(file.Content) is { } parsed)
            {
                events.Add(parsed);
            }
        }
        var room = Math.Max(0, DiagnosticFormats.MaxEvents - events.Count);
        var (peeked, _) = hub.Limiter.Peek(room);
        var perfReady = config.Perf ? perf.PeekReady() : [];
        var osbReady = config.Perf ? hub.PeekOsbPerf() : null;
        if (events.Count == 0 && peeked.Count == 0 && perfReady.Count == 0 && osbReady is null)
        {
            return null;
        }
        IReadOnlyList<DiagnosticEvent> taken = peeked;
        var dropped = new DroppedCounts();
        IReadOnlyList<PerfEntry> perfTaken = perfReady;
        if (take)
        {
            (taken, dropped) = hub.Limiter.Take(room);
            perfTaken = config.Perf ? perf.TakeReady() : [];
            osbReady = config.Perf ? hub.TakeOsbPerf() : null;
        }
        else
        {
            dropped = hub.Limiter.Peek(room).Dropped;
        }
        var body = DiagnosticJson.Batch(
            new DiagnosticBatch
            {
                AppVersion = appVersion,
                Run = hub.Run,
                Env = hub.GpuVendor is { } vendor ? env.Value with { GpuVendor = vendor } : env.Value,
                Events = [.. events, .. taken],
                Perf = perfTaken,
                OsbPerf = osbReady is null ? [] : [osbReady],
                Dropped = dropped,
            },
            hub.Terms,
            time.GetUtcNow());
        if (body.Events.Count == 0 && body.PerfCount == 0 && body.OsbPerfCount == 0)
        {
            if (take)
            {
                foreach (var id in pendingIds)
                {
                    hub.Pending.Delete(id);
                }
            }
            return null;
        }
        return new PreparedDiagnostics(body.Body, session, taken, dropped, perfTaken, pendingIds, body.OsbPerfCount > 0 ? osbReady : null);
    }
}
