using System.Text.Encodings.Web;
using System.Text.Json;

namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed record DiagnosticBody(byte[] Body, IReadOnlyList<DiagnosticEvent> Events, int PerfCount, DroppedCounts Dropped, int OsbPerfCount = 0);

public static class DiagnosticJson
{
    private static readonly JsonWriterOptions WriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static DiagnosticBody Batch(DiagnosticBatch batch, PrivateTerms terms, DateTimeOffset now)
    {
        var oversize = 0;
        var events = new List<DiagnosticEvent>();
        foreach (var candidate in batch.Events.Take(DiagnosticFormats.MaxEvents))
        {
            if (!InWindow(candidate.At, now) || DiagnosticScrubber.Scrub(candidate, terms) is not { } clean)
            {
                continue;
            }
            if (Fit(clean) is { } fitted)
            {
                events.Add(fitted);
            }
            else
            {
                oversize++;
            }
        }
        oversize += Math.Max(0, batch.Events.Count - DiagnosticFormats.MaxEvents);
        var perf = batch.Perf.Take(DiagnosticFormats.MaxPerf)
            .Where(p => InWindow(p.At, now) && Serialise(w => WritePerf(w, p)).Length <= DiagnosticFormats.MaxPerfBytes)
            .ToList();
        var osbPerf = batch.OsbPerf.Take(1)
            .Where(p => InWindow(p.Entry.At, now) && DiagnosticFormats.IsVersion(p.AppVersion) && DiagnosticScrubber.IsClean(p.AppVersion, terms)
                && Serialise(w => WritePerf(w, p.Entry, p.AppVersion)).Length <= OsbPageBatch.MaxPerfBytes)
            .ToList();
        if (!DiagnosticFormats.IsVersion(batch.AppVersion) || !DiagnosticFormats.IsHex16(batch.Run))
        {
            throw new ArgumentException("The batch needs a valid app version and run key.", nameof(batch));
        }

        while (true)
        {
            var dropped = batch.Dropped.Add(new DroppedCounts(0, oversize, 0));
            var body = Serialise(w => WriteBatch(w, batch, events, perf, osbPerf, dropped));
            if (body.Length <= DiagnosticFormats.SoftBodyBytes)
            {
                return new DiagnosticBody(body, events, perf.Count, dropped, osbPerf.Count);
            }
            var withTrail = events.FindLastIndex(e => e.Trail is { Count: > 0 });
            if (withTrail >= 0)
            {
                events[withTrail] = events[withTrail] with { Trail = null };
            }
            else if (events.Count > 0)
            {
                events.RemoveAt(0);
                oversize++;
            }
            else if (perf.Count > 0)
            {
                perf.RemoveAt(perf.Count - 1);
            }
            else if (osbPerf.Count > 0)
            {
                osbPerf.Clear();
            }
            else
            {
                return new DiagnosticBody(body, events, 0, dropped);
            }
        }
    }

    public static byte[]? Event(DiagnosticEvent candidate, PrivateTerms terms)
    {
        if (DiagnosticScrubber.Scrub(candidate, terms) is not { } clean || Fit(clean) is not { } fitted)
        {
            return null;
        }
        return Serialise(w => WriteEvent(w, fitted));
    }

    public static DiagnosticEvent? ParseEvent(ReadOnlySpan<byte> json)
    {
        try
        {
            using var document = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions { MaxDepth = 8 });
            return DiagnosticJsonReader.Event(document.RootElement);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException or KeyNotFoundException or ArgumentException)
        {
            return null;
        }
    }

    private static DiagnosticEvent? Fit(DiagnosticEvent e)
    {
        if (Serialise(w => WriteEvent(w, e)).Length <= DiagnosticFormats.MaxEventBytes)
        {
            return e;
        }
        var bare = e with { Trail = null };
        return Serialise(w => WriteEvent(w, bare)).Length <= DiagnosticFormats.MaxEventBytes ? bare : null;
    }

    private static bool InWindow(DateTimeOffset at, DateTimeOffset now) =>
        at >= now - DiagnosticFormats.MaxAge && at <= now + DiagnosticFormats.MaxAhead;

    private static byte[] Serialise(Action<Utf8JsonWriter> write)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, WriterOptions))
        {
            write(writer);
        }
        return stream.ToArray();
    }

    private static void WriteBatch(
        Utf8JsonWriter w,
        DiagnosticBatch batch,
        IReadOnlyList<DiagnosticEvent> events,
        IReadOnlyList<PerfEntry> perf,
        IReadOnlyList<OsbPerfEntry> osbPerf,
        DroppedCounts dropped)
    {
        w.WriteStartObject();
        w.WriteNumber("schema", 1);
        w.WriteString("app", batch.App);
        w.WriteString("app_version", batch.AppVersion);
        w.WriteString("run", batch.Run);
        WriteEnv(w, batch.Env);
        w.WriteStartArray("events");
        foreach (var e in events)
        {
            WriteEvent(w, e);
        }
        w.WriteEndArray();
        if (perf.Count > 0)
        {
            w.WriteStartArray("perf");
            foreach (var p in perf)
            {
                WritePerf(w, p);
            }
            w.WriteEndArray();
        }
        if (osbPerf.Count > 0)
        {
            w.WriteStartArray("osb_perf");
            foreach (var p in osbPerf)
            {
                WritePerf(w, p.Entry, p.AppVersion);
            }
            w.WriteEndArray();
        }
        w.WriteStartObject("dropped");
        w.WriteNumber("rate_limited", Math.Clamp(dropped.RateLimited, 0, DiagnosticFormats.MaxCount));
        w.WriteNumber("oversize", Math.Clamp(dropped.Oversize, 0, DiagnosticFormats.MaxCount));
        w.WriteNumber("sampled_out", Math.Clamp(dropped.SampledOut, 0, DiagnosticFormats.MaxCount));
        w.WriteEndObject();
        w.WriteEndObject();
    }

    private static void WriteEnv(Utf8JsonWriter w, DiagnosticEnv env)
    {
        w.WriteStartObject("env");
        if (DiagnosticFormats.IsOsBuild(env.OsBuild))
        {
            w.WriteString("os_build", env.OsBuild);
        }
        if (DiagnosticFormats.IsVersion(env.WebView2))
        {
            w.WriteString("webview2", env.WebView2);
        }
        if (DiagnosticFormats.IsVersion(env.DotNet))
        {
            w.WriteString("dotnet", env.DotNet);
        }
        if (env.RamGb is { } ram && DiagnosticFormats.RamBuckets.Contains(ram))
        {
            w.WriteNumber("ram_gb", ram);
        }
        if (env.Cores is { } cores && DiagnosticFormats.CoreBuckets.Contains(cores))
        {
            w.WriteNumber("cores", cores);
        }
        if (env.GpuVendor is { } vendor && DiagnosticFormats.GpuVendors.Contains(vendor))
        {
            w.WriteString("gpu_vendor", vendor);
        }
        w.WriteEndObject();
    }

    private static void WriteEvent(Utf8JsonWriter w, DiagnosticEvent e)
    {
        w.WriteStartObject();
        w.WriteString("kind", DiagnosticFormats.WireName(e.Kind));
        w.WriteString("source", DiagnosticFormats.WireName(e.Source));
        w.WriteString("fp", e.Fingerprint);
        w.WriteString("at", DiagnosticFormats.MinuteText(e.At));
        w.WriteNumber("count", e.Count);
        switch (e.Kind)
        {
            case DiagnosticKind.JsError or DiagnosticKind.DotnetException when e.Error is { } error:
                WriteError(w, error);
                break;
            case DiagnosticKind.ProcessFailed when e.Process is { } process:
                w.WriteStartObject("process");
                w.WriteString("kind", process.Kind);
                w.WriteString("reason", process.Reason);
                w.WriteString("exit_code", process.ExitCode);
                if (process.Description is not null)
                {
                    w.WriteString("description", process.Description);
                }
                w.WriteEndObject();
                break;
            case DiagnosticKind.Unresponsive when e.Hang is { } hang:
                w.WriteStartObject("hang");
                w.WriteString("outcome", hang.Outcome);
                w.WriteNumber("waited_s", hang.WaitedSeconds);
                w.WriteEndObject();
                break;
            case DiagnosticKind.GpuFailed when e.Gpu is { } gpu:
                w.WriteStartObject("gpu");
                w.WriteString("code", gpu.Code);
                w.WriteNumber("retries", gpu.Retries);
                w.WriteEndObject();
                break;
            case DiagnosticKind.BotStop when e.Stop is { } stop:
                w.WriteStartObject("stop");
                w.WriteString("code", stop.Code);
                w.WriteString("source", stop.Source);
                w.WriteEndObject();
                break;
            case DiagnosticKind.Warn when e.Warn is { } warn:
                WriteWarn(w, warn);
                break;
            case DiagnosticKind.RunEnd when e.RunEnd is { } end:
                w.WriteStartObject("run_end");
                w.WriteString("outcome", end.Outcome);
                w.WriteNumber("uptime_s", end.UptimeSeconds);
                w.WriteString("previous_version", end.PreviousVersion);
                w.WriteEndObject();
                break;
        }
        if (e.Context is { } context)
        {
            WriteContext(w, context);
        }
        if (e.Trail is { Count: > 0 } trail)
        {
            WriteTrail(w, trail);
        }
        w.WriteEndObject();
    }

    private static void WriteError(Utf8JsonWriter w, ErrorDetail error)
    {
        w.WriteStartObject("error");
        w.WriteString("type", error.Type);
        if (error.Template is not null)
        {
            w.WriteString("template", error.Template);
        }
        if (error.HResult is not null)
        {
            w.WriteString("hresult", error.HResult);
        }
        w.WriteStartArray("inner");
        foreach (var inner in error.Inner ?? [])
        {
            w.WriteStringValue(inner);
        }
        w.WriteEndArray();
        if (error.Module is not null)
        {
            w.WriteString("module", error.Module);
        }
        w.WriteBoolean("handled", error.Handled);
        w.WriteString("origin", error.Origin);
        w.WriteStartArray("frames");
        foreach (var frame in error.Frames)
        {
            w.WriteStringValue(frame);
        }
        w.WriteEndArray();
        w.WriteEndObject();
    }

    private static void WriteWarn(Utf8JsonWriter w, WarnDetail warn)
    {
        w.WriteStartObject("warn");
        w.WriteString("category", warn.Category);
        w.WriteString("code", warn.Code);
        if (warn.ErrorClass is not null)
        {
            w.WriteString("error_class", warn.ErrorClass);
        }
        if (warn.Refusal is { } refusal)
        {
            w.WriteStartObject("refusal");
            w.WriteString("source", refusal.Source);
            w.WriteString("reason", refusal.Reason);
            w.WriteNumber("native", refusal.Native);
            w.WriteEndObject();
        }
        w.WriteEndObject();
    }

    private static void WriteContext(Utf8JsonWriter w, DiagnosticContext c)
    {
        w.WriteStartObject("context");
        OptionalString(w, "phase", c.Phase);
        OptionalString(w, "mode", c.Mode);
        OptionalString(w, "town_phase", c.TownPhase);
        OptionalBool(w, "dead", c.Dead);
        OptionalString(w, "login_stage", c.LoginStage);
        OptionalInt(w, "window", c.Window);
        OptionalInt(w, "windows", c.Windows);
        OptionalBool(w, "light", c.Light);
        OptionalBool(w, "hidden", c.Hidden);
        OptionalInt(w, "uptime_s", c.UptimeSeconds);
        w.WriteEndObject();
    }

    private static void WriteTrail(Utf8JsonWriter w, IReadOnlyList<TrailItem> trail)
    {
        w.WriteStartArray("trail");
        foreach (var t in trail)
        {
            w.WriteStartObject();
            w.WriteNumber("s", t.SecondsBefore);
            w.WriteString("l", t.Level);
            w.WriteString("c", t.Category);
            w.WriteString("k", t.Code);
            OptionalString(w, "o", t.Outcome);
            OptionalString(w, "e", t.ErrorClass);
            if (t.Count > 1)
            {
                w.WriteNumber("n", t.Count);
            }
            OptionalInt(w, "w", t.Window);
            if (t.Numbers is { Count: > 0 } || t.Flags is { Count: > 0 })
            {
                w.WriteStartObject("d");
                foreach (var (key, value) in t.Numbers ?? new Dictionary<string, double>())
                {
                    w.WriteNumber(key, value);
                }
                foreach (var (key, value) in t.Flags ?? new Dictionary<string, bool>())
                {
                    w.WriteBoolean(key, value);
                }
                w.WriteEndObject();
            }
            w.WriteEndObject();
        }
        w.WriteEndArray();
    }

    private static void WritePerf(Utf8JsonWriter w, PerfEntry p, string? appVersion = null)
    {
        w.WriteStartObject();
        if (appVersion is not null)
        {
            w.WriteString("app_version", appVersion);
        }
        w.WriteString("at", DiagnosticFormats.MinuteText(p.At));
        w.WriteNumber("span_s", Math.Clamp(p.SpanSeconds, 60, 86400));
        w.WriteNumber("samples", Math.Clamp(p.Samples, 1, 1440));
        if (p.Windows is { } windows)
        {
            w.WriteStartObject("windows");
            w.WriteNumber("open", Math.Clamp(windows.Open, 0, 64));
            w.WriteNumber("light", Math.Clamp(windows.Light, 0, 64));
            w.WriteNumber("hidden", Math.Clamp(windows.Hidden, 0, 64));
            w.WriteNumber("in_world", Math.Clamp(windows.InWorld, 0, 64));
            w.WriteEndObject();
        }
        if (p.Memory is { } memory)
        {
            w.WriteStartObject("mem_mb");
            if (memory.Renderer is not null || memory.RendererEach is not null)
            {
                w.WriteStartObject("renderer");
                if (memory.Renderer is { } renderer)
                {
                    w.WriteNumber("p50", Megabytes(renderer.P50));
                    w.WriteNumber("max", Megabytes(renderer.Max));
                }
                if (memory.RendererEach is { } each)
                {
                    SortedArray(w, "each", each, Megabytes);
                }
                w.WriteEndObject();
            }
            Role(w, "gpu", memory.Gpu);
            Role(w, "browser_total", memory.BrowserTotal);
            Role(w, "utility", memory.Utility);
            Role(w, "app", memory.App);
            w.WriteEndObject();
        }
        if (p.JsHeapUsedEach is not null || p.JsHeapTotalEach is not null || p.JsHeapUsed is not null || p.JsHeapTotal is not null)
        {
            w.WriteStartObject("js_heap_mb");
            if (p.JsHeapUsedEach is { } used)
            {
                SortedArray(w, "used_each", used, Megabytes);
            }
            if (p.JsHeapTotalEach is { } total)
            {
                SortedArray(w, "total_each", total, Megabytes);
            }
            if (p.JsHeapUsed is { } usedOne)
            {
                w.WriteNumber("used", Megabytes(usedOne));
            }
            if (p.JsHeapTotal is { } totalOne)
            {
                w.WriteNumber("total", Megabytes(totalOne));
            }
            w.WriteEndObject();
        }
        if (p.WasmEach is { } wasm)
        {
            w.WriteStartObject("wasm_mb");
            SortedArray(w, "each", wasm, Megabytes);
            w.WriteEndObject();
        }
        if (p.Cpu is { } cpu)
        {
            w.WriteStartObject("cpu_pct");
            if (cpu.RendererEach is { } each)
            {
                SortedArray(w, "renderer_each", each, CorePercent);
            }
            OptionalNumber(w, "gpu", cpu.Gpu, CorePercent);
            OptionalNumber(w, "browser_total", cpu.BrowserTotal, CorePercent);
            OptionalNumber(w, "app", cpu.App, CorePercent);
            w.WriteEndObject();
        }
        Timing(w, "tick_ms", p.Tick);
        Timing(w, "gap_ms", p.Gap);
        if (p.LongTasks is { } tasks)
        {
            w.WriteStartObject("long_tasks");
            w.WriteNumber("count", Math.Clamp(tasks.Count, 0, DiagnosticFormats.MaxCount));
            w.WriteNumber("total_ms", Milliseconds(tasks.TotalMs));
            w.WriteEndObject();
        }
        w.WriteEndObject();
    }

    private static void Role(Utf8JsonWriter w, string name, RoleMemory? role)
    {
        if (role is null)
        {
            return;
        }
        w.WriteStartObject(name);
        w.WriteNumber("p50", Megabytes(role.P50));
        w.WriteNumber("max", Megabytes(role.Max));
        w.WriteEndObject();
    }

    private static void Timing(Utf8JsonWriter w, string name, PerfTiming? timing)
    {
        if (timing is null)
        {
            return;
        }
        w.WriteStartObject(name);
        w.WriteNumber("p50", Milliseconds(timing.P50));
        w.WriteNumber("p95", Milliseconds(timing.P95));
        w.WriteNumber("p99", Milliseconds(timing.P99));
        w.WriteNumber("max", Milliseconds(timing.Max));
        w.WriteNumber("late_pct", OneDecimal(timing.LatePercent, 100));
        w.WriteEndObject();
    }

    private static void SortedArray(Utf8JsonWriter w, string name, IReadOnlyList<double> values, Func<double, double> clamp)
    {
        w.WriteStartArray(name);
        foreach (var value in values.Select(clamp).Order().Take(DiagnosticFormats.MaxEach))
        {
            w.WriteNumberValue(value);
        }
        w.WriteEndArray();
    }

    private static double Megabytes(double value) => double.IsFinite(value) ? Math.Clamp(Math.Round(value), 0, DiagnosticFormats.MaxMegabytes) : 0;

    private static double CorePercent(double value) => OneDecimal(value, DiagnosticFormats.MaxCorePercent);

    private static double Milliseconds(double value) => OneDecimal(value, DiagnosticFormats.MaxMilliseconds);

    private static double OneDecimal(double value, double max) => double.IsFinite(value) ? Math.Clamp(Math.Round(value, 1), 0, max) : 0;

    private static void OptionalNumber(Utf8JsonWriter w, string name, double? value, Func<double, double> clamp)
    {
        if (value is { } number)
        {
            w.WriteNumber(name, clamp(number));
        }
    }

    private static void OptionalString(Utf8JsonWriter w, string name, string? value)
    {
        if (value is not null)
        {
            w.WriteString(name, value);
        }
    }

    private static void OptionalInt(Utf8JsonWriter w, string name, int? value)
    {
        if (value is { } number)
        {
            w.WriteNumber(name, number);
        }
    }

    private static void OptionalBool(Utf8JsonWriter w, string name, bool? value)
    {
        if (value is { } flag)
        {
            w.WriteBoolean(name, flag);
        }
    }
}
