namespace OsbManager.Core.Telemetry.Diagnostics;

public enum DiagnosticKind
{
    JsError,
    DotnetException,
    ProcessFailed,
    Unresponsive,
    GpuFailed,
    BotStop,
    Warn,
    RunEnd,
}

public enum DiagnosticSource
{
    Manager,
    Osb,
}

public sealed record DiagnosticEnv(
    string? OsBuild = null,
    string? WebView2 = null,
    string? DotNet = null,
    int? RamGb = null,
    int? Cores = null,
    string? GpuVendor = null);

public sealed record ErrorDetail(
    string Type,
    string Origin,
    bool Handled,
    IReadOnlyList<string> Frames,
    IReadOnlyList<string>? Inner = null,
    string? HResult = null,
    string? Template = null,
    string? Module = null);

public sealed record ProcessDetail(string Kind, string Reason, string ExitCode, string? Description = null);

public sealed record HangDetail(string Outcome, int WaitedSeconds);

public sealed record GpuDetail(string Code, int Retries);

public sealed record StopDetail(string Code, string Source);

public sealed record RefusalDetail(string Source, string Reason, int Native);

public sealed record WarnDetail(string Category, string Code, string? ErrorClass = null, RefusalDetail? Refusal = null);

public sealed record RunEndDetail(string Outcome, int UptimeSeconds, string PreviousVersion);

public sealed record DiagnosticContext
{
    public string? Phase { get; init; }
    public string? Mode { get; init; }
    public string? TownPhase { get; init; }
    public bool? Dead { get; init; }
    public string? LoginStage { get; init; }
    public int? Window { get; init; }
    public int? Windows { get; init; }
    public bool? Light { get; init; }
    public bool? Hidden { get; init; }
    public int? UptimeSeconds { get; init; }
}

public sealed record TrailItem(
    int SecondsBefore,
    string Level,
    string Category,
    string Code,
    int Count = 1,
    int? Window = null,
    string? Outcome = null,
    string? ErrorClass = null,
    IReadOnlyDictionary<string, double>? Numbers = null,
    IReadOnlyDictionary<string, bool>? Flags = null);

public sealed record DiagnosticEvent
{
    public required DiagnosticKind Kind { get; init; }
    public DiagnosticSource Source { get; init; } = DiagnosticSource.Manager;
    public required string Fingerprint { get; init; }
    public required DateTimeOffset At { get; init; }
    public int Count { get; init; } = 1;
    public ErrorDetail? Error { get; init; }
    public ProcessDetail? Process { get; init; }
    public HangDetail? Hang { get; init; }
    public GpuDetail? Gpu { get; init; }
    public StopDetail? Stop { get; init; }
    public WarnDetail? Warn { get; init; }
    public RunEndDetail? RunEnd { get; init; }
    public DiagnosticContext? Context { get; init; }
    public IReadOnlyList<TrailItem>? Trail { get; init; }
}

public sealed record RoleMemory(double P50, double Max);

public sealed record PerfWindows(int Open, int Light, int Hidden, int InWorld);

public sealed record PerfMemory
{
    public RoleMemory? Renderer { get; init; }
    public IReadOnlyList<double>? RendererEach { get; init; }
    public RoleMemory? Gpu { get; init; }
    public RoleMemory? BrowserTotal { get; init; }
    public RoleMemory? Utility { get; init; }
    public RoleMemory? App { get; init; }
}

public sealed record PerfCpu
{
    public IReadOnlyList<double>? RendererEach { get; init; }
    public double? Gpu { get; init; }
    public double? BrowserTotal { get; init; }
    public double? App { get; init; }
}

public sealed record PerfTiming(double P50, double P95, double P99, double Max, double LatePercent);

public sealed record PerfLongTasks(int Count, double TotalMs);

public sealed record PerfEntry
{
    public required DateTimeOffset At { get; init; }
    public required int SpanSeconds { get; init; }
    public required int Samples { get; init; }
    public PerfWindows? Windows { get; init; }
    public PerfMemory? Memory { get; init; }
    public IReadOnlyList<double>? JsHeapUsedEach { get; init; }
    public IReadOnlyList<double>? JsHeapTotalEach { get; init; }
    public double? JsHeapUsed { get; init; }
    public double? JsHeapTotal { get; init; }
    public IReadOnlyList<double>? WasmEach { get; init; }
    public PerfCpu? Cpu { get; init; }
    public PerfTiming? Tick { get; init; }
    public PerfTiming? Gap { get; init; }
    public PerfLongTasks? LongTasks { get; init; }
}

public sealed record OsbPerfEntry(PerfEntry Entry, string AppVersion);

public sealed record DroppedCounts(int RateLimited = 0, int Oversize = 0, int SampledOut = 0)
{
    public DroppedCounts Add(DroppedCounts other) => new(RateLimited + other.RateLimited, Oversize + other.Oversize, SampledOut + other.SampledOut);
}

public sealed record DiagnosticBatch
{
    public string App { get; init; } = TelemetryLimits.AppName;
    public required string AppVersion { get; init; }
    public required string Run { get; init; }
    public DiagnosticEnv Env { get; init; } = new();
    public IReadOnlyList<DiagnosticEvent> Events { get; init; } = [];
    public IReadOnlyList<PerfEntry> Perf { get; init; } = [];
    public IReadOnlyList<OsbPerfEntry> OsbPerf { get; init; } = [];
    public DroppedCounts Dropped { get; init; } = new();
}
