namespace OsbManager.Core.Telemetry.Diagnostics;

public enum ProcessRole
{
    Browser,
    Gpu,
    Renderer,
    Utility,
    Other,
}

public sealed record ProcessReading(int Pid, ProcessRole Role, long PrivateBytes, double CpuSeconds);

public sealed record PerfSample(DateTimeOffset At, IReadOnlyList<ProcessReading> Browser, ProcessReading? App, PerfWindows Windows);

public sealed class PerfCollector
{
    public static readonly TimeSpan SampleStep = TimeSpan.FromSeconds(60);

    private const double Megabyte = 1024 * 1024;
    private static readonly TimeSpan Tolerance = TimeSpan.FromSeconds(5);

    private readonly object sync = new();
    private readonly List<PerfEntry> ready = [];
    private readonly List<double> rendererAll = [];
    private readonly List<double> gpu = [];
    private readonly List<double> utility = [];
    private readonly List<double> browserTotal = [];
    private readonly List<double> app = [];
    private readonly Dictionary<int, CpuSpan> cpu = [];
    private IReadOnlyList<double> rendererEach = [];
    private PerfWindows windows = new(0, 0, 0, 0);
    private DateTimeOffset spanStart;
    private DateTimeOffset lastSampleAt;
    private int samples;
    private IReadOnlyList<double>? jsUsed;
    private IReadOnlyList<double>? jsTotal;
    private IReadOnlyList<double>? wasm;
    private bool pageMemoryRequested;

    public int Samples
    {
        get { lock (sync) { return samples; } }
    }

    public int ReadyCount
    {
        get { lock (sync) { return ready.Count; } }
    }

    public DateTimeOffset? SpanStart
    {
        get { lock (sync) { return samples == 0 ? null : spanStart; } }
    }

    public void Add(PerfSample sample)
    {
        lock (sync)
        {
            if (samples == 0)
            {
                spanStart = sample.At;
            }
            samples++;
            lastSampleAt = sample.At;
            windows = sample.Windows;
            var renderers = sample.Browser.Where(r => r.Role == ProcessRole.Renderer).Select(r => r.PrivateBytes / Megabyte).ToList();
            rendererEach = renderers;
            rendererAll.AddRange(renderers);
            gpu.Add(Sum(sample.Browser, ProcessRole.Gpu));
            utility.Add(Sum(sample.Browser, ProcessRole.Utility));
            browserTotal.Add(sample.Browser.Sum(r => r.PrivateBytes) / Megabyte);
            if (sample.App is { } self)
            {
                app.Add(self.PrivateBytes / Megabyte);
            }
            foreach (var reading in sample.Browser.Append(sample.App).OfType<ProcessReading>())
            {
                cpu[reading.Pid] = cpu.TryGetValue(reading.Pid, out var span)
                    ? span with { Role = reading.Role, LastCpu = reading.CpuSeconds, LastAt = sample.At }
                    : new CpuSpan(reading.Role, reading.CpuSeconds, sample.At, reading.CpuSeconds, sample.At, reading.Pid == sample.App?.Pid);
            }
        }
    }

    public bool NeedsPageMemory(TimeSpan interval, TimeSpan lead)
    {
        lock (sync)
        {
            if (samples == 0 || pageMemoryRequested || lastSampleAt - spanStart + SampleStep < interval - lead)
            {
                return false;
            }
            pageMemoryRequested = true;
            return true;
        }
    }

    public void SetPageMemory(IReadOnlyList<double> usedMegabytes, IReadOnlyList<double> totalMegabytes, IReadOnlyList<double> wasmMegabytes)
    {
        lock (sync)
        {
            jsUsed = usedMegabytes;
            jsTotal = totalMegabytes;
            wasm = wasmMegabytes;
        }
    }

    public bool TryComplete(TimeSpan interval)
    {
        lock (sync)
        {
            if (samples == 0 || lastSampleAt - spanStart + SampleStep + Tolerance < interval)
            {
                return false;
            }
            var entry = Build();
            ready.Add(entry);
            while (ready.Count > DiagnosticFormats.MaxPerf)
            {
                ready.RemoveAt(0);
            }
            Reset();
            return true;
        }
    }

    public IReadOnlyList<PerfEntry> PeekReady()
    {
        lock (sync)
        {
            return [.. ready];
        }
    }

    public IReadOnlyList<PerfEntry> TakeReady()
    {
        lock (sync)
        {
            var taken = ready.ToList();
            ready.Clear();
            return taken;
        }
    }

    public void Return(IEnumerable<PerfEntry> entries)
    {
        lock (sync)
        {
            ready.InsertRange(0, entries);
            while (ready.Count > DiagnosticFormats.MaxPerf)
            {
                ready.RemoveAt(0);
            }
        }
    }

    public void Clear()
    {
        lock (sync)
        {
            ready.Clear();
            Reset();
        }
    }

    private PerfEntry Build()
    {
        var span = (int)Math.Clamp(Math.Round((lastSampleAt - spanStart + SampleStep).TotalSeconds), 60, 86400);
        var rendererCpu = cpu.Values.Where(c => c.Role == ProcessRole.Renderer).Select(Percent).Where(p => p is not null).Select(p => p!.Value).ToList();
        return new PerfEntry
        {
            At = DiagnosticFormats.Minute(spanStart),
            SpanSeconds = span,
            Samples = Math.Clamp(samples, 1, 1440),
            Windows = windows,
            Memory = new PerfMemory
            {
                Renderer = rendererAll.Count == 0 ? null : Role(rendererAll),
                RendererEach = rendererEach,
                Gpu = gpu.Any(v => v > 0) ? Role(gpu) : null,
                BrowserTotal = Role(browserTotal),
                Utility = utility.Any(v => v > 0) ? Role(utility) : null,
                App = app.Count == 0 ? null : Role(app),
            },
            JsHeapUsedEach = jsUsed,
            JsHeapTotalEach = jsTotal,
            WasmEach = wasm,
            Cpu = new PerfCpu
            {
                RendererEach = rendererCpu,
                Gpu = RoleCpu(ProcessRole.Gpu),
                BrowserTotal = RoleCpu(role: null, includeApp: false),
                App = cpu.Values.Where(c => c.IsApp).Select(Percent).FirstOrDefault(p => p is not null),
            },
        };
    }

    private double? RoleCpu(ProcessRole? role, bool includeApp = true)
    {
        var values = cpu.Values.Where(c => (role is null || c.Role == role) && (includeApp || !c.IsApp)).Select(Percent).Where(p => p is not null).Select(p => p!.Value).ToList();
        return values.Count == 0 ? null : values.Sum();
    }

    private static double? Percent(CpuSpan span)
    {
        var wall = (span.LastAt - span.FirstAt).TotalSeconds;
        return wall <= 0 ? null : Math.Max(0, (span.LastCpu - span.FirstCpu) / wall * 100);
    }

    private static RoleMemory Role(List<double> values)
    {
        var sorted = values.Order().ToList();
        return new RoleMemory(sorted[(sorted.Count - 1) / 2], sorted[^1]);
    }

    private static double Sum(IReadOnlyList<ProcessReading> readings, ProcessRole role) =>
        readings.Where(r => r.Role == role).Sum(r => r.PrivateBytes) / Megabyte;

    private void Reset()
    {
        rendererAll.Clear();
        gpu.Clear();
        utility.Clear();
        browserTotal.Clear();
        app.Clear();
        cpu.Clear();
        rendererEach = [];
        jsUsed = jsTotal = wasm = null;
        samples = 0;
        pageMemoryRequested = false;
    }

    private readonly record struct CpuSpan(ProcessRole Role, double FirstCpu, DateTimeOffset FirstAt, double LastCpu, DateTimeOffset LastAt, bool IsApp);
}
