namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed class DiagnosticsHub : IDisposable
{
    private readonly object sync = new();
    private readonly Func<bool> consentOn;
    private CancellationTokenSource session = new();
    private bool active;
    private int faults;
    private volatile string? gpuVendor;
    private OsbPerfEntry? osbPerf;

    public DiagnosticsHub(string folder, PrivateTerms terms, TimeProvider time, Func<bool> consentOn, int sampleDraw)
    {
        this.consentOn = consentOn;
        Terms = terms;
        Time = time;
        Run = DiagnosticFormats.NewRunKey();
        Trail = new DiagnosticTrail(time, () => Recording);
        Limiter = new DiagnosticLimiter(time, sampleDraw);
        Pending = new PendingDiagnostics(folder, time, () => Recording);
        active = consentOn();
        if (!active)
        {
            Wipe();
        }
    }

    public const int FaultLimit = 3;

    public event Action? Wiped;

    public event Action? Began;

    public PrivateTerms Terms { get; }
    public TimeProvider Time { get; }
    public string Run { get; }
    public DiagnosticTrail Trail { get; }
    public DiagnosticLimiter Limiter { get; }
    public PendingDiagnostics Pending { get; }

    public bool Recording
    {
        get { lock (sync) { return active && faults < FaultLimit && consentOn(); } }
    }

    public bool Faulted
    {
        get { lock (sync) { return faults >= FaultLimit; } }
    }

    public void ReportFault()
    {
        lock (sync)
        {
            faults++;
        }
    }

    public string? GpuVendor
    {
        get => gpuVendor;
        set
        {
            if (value is null || (Recording && DiagnosticFormats.GpuVendors.Contains(value)))
            {
                gpuVendor = value;
            }
        }
    }

    public void KeepOsbPerf(OsbPerfEntry entry)
    {
        lock (sync)
        {
            if (active && faults < FaultLimit && consentOn())
            {
                osbPerf = entry;
            }
        }
    }

    public OsbPerfEntry? PeekOsbPerf()
    {
        lock (sync)
        {
            return osbPerf;
        }
    }

    public OsbPerfEntry? TakeOsbPerf()
    {
        lock (sync)
        {
            var taken = osbPerf;
            osbPerf = null;
            return taken;
        }
    }

    public void ReturnOsbPerf(OsbPerfEntry entry)
    {
        lock (sync)
        {
            osbPerf ??= entry;
        }
    }

    public CancellationToken Session
    {
        get { lock (sync) { return session.Token; } }
    }

    public RecordOutcome? Record(DiagnosticEvent candidate)
    {
        if (!Recording || DiagnosticScrubber.Scrub(candidate, Terms) is not { } clean)
        {
            return null;
        }
        return Limiter.Record(clean);
    }

    public bool WritePending(DiagnosticEvent candidate) =>
        Recording && DiagnosticJson.Event(candidate, Terms) is { } bytes && Pending.Write(bytes);

    public void OnConsentChanged()
    {
        var on = consentOn();
        bool begin;
        lock (sync)
        {
            begin = on && !active;
            active = on;
        }
        if (begin)
        {
            Clear();
            Began?.Invoke();
            return;
        }
        if (!on)
        {
            Wipe();
        }
    }

    public void Wipe()
    {
        CancellationTokenSource old;
        lock (sync)
        {
            old = session;
            session = new CancellationTokenSource();
        }
        old.Cancel();
        old.Dispose();
        Clear();
        Pending.WipeAll();
        Wiped?.Invoke();
    }

    public void Dispose()
    {
        lock (sync)
        {
            session.Dispose();
        }
    }

    private void Clear()
    {
        gpuVendor = null;
        lock (sync)
        {
            osbPerf = null;
        }
        Trail.Clear();
        Limiter.Clear();
    }
}
