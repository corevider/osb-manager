using OsbManager.Core.Status;

namespace OsbManager.Core.Telemetry.Diagnostics;

public interface IPerfSource
{
    PerfSample? Read(DateTimeOffset now);
}

public sealed class WindowOrdinals
{
    private readonly object sync = new();
    private readonly Dictionary<string, int> ordinals = new(StringComparer.Ordinal);

    public int? Of(string accountId)
    {
        lock (sync)
        {
            if (ordinals.TryGetValue(accountId, out var known))
            {
                return known;
            }
            var next = ordinals.Count + 1;
            if (next > DiagnosticFormats.MaxEach)
            {
                return null;
            }
            ordinals[accountId] = next;
            return next;
        }
    }
}

public static class DiagnosticContexts
{
    public static DiagnosticContext For(BotStatus? status, bool light, bool hidden, int? window, int windows) => new()
    {
        Phase = DiagnosticScrubber.Phase(status?.Phase),
        LoginStage = DiagnosticScrubber.LoginStage(status?.LoginStage),
        Dead = status is null ? null : status.Dead,
        Window = window,
        Windows = Math.Clamp(windows, 0, DiagnosticFormats.MaxEach),
        Light = light,
        Hidden = hidden,
    };
}

public sealed class DiagnosticsCapture : IDisposable
{
    public static readonly TimeSpan SampleStep = PerfCollector.SampleStep;
    public static readonly TimeSpan PageReadLead = TimeSpan.FromSeconds(120);

    private readonly object sync = new();
    private readonly DiagnosticsHub hub;
    private readonly string appVersion;
    private readonly TimeProvider time;
    private readonly TimeProvider timerTime;
    private readonly DateTimeOffset startedAt;
    private CancellationTokenSource? sampler;
    private Func<IReadOnlyList<string>>? termSource;
    private Func<DiagnosticsConfig>? config;
    private IPerfSource? source;
    private bool started;
    private bool disposed;

    public DiagnosticsCapture(DiagnosticsHub hub, PerfCollector perf, string appVersion, TimeProvider time, TimeProvider? timerTime = null)
    {
        this.hub = hub;
        this.appVersion = appVersion;
        this.time = time;
        this.timerTime = timerTime ?? TimeProvider.System;
        Perf = perf;
        Marker = new RunMarker(hub.Pending.Folder, time, () => hub.Recording);
        Inbox = new DiagnosticsInbox(hub);
        startedAt = time.GetUtcNow();
        hub.Wiped += OnWiped;
        hub.Began += OnBegan;
    }

    public PerfCollector Perf { get; }
    public RunMarker Marker { get; }
    public DiagnosticsInbox Inbox { get; }
    public Action? RequestPageMemory { get; set; }

    public void Configure(Func<DiagnosticsConfig> configSource, IPerfSource? perfSource, Func<IReadOnlyList<string>>? terms)
    {
        config = configSource;
        source = perfSource;
        termSource = terms;
    }

    public void Start()
    {
        lock (sync)
        {
            if (started)
            {
                return;
            }
            started = true;
        }
        BeginRun();
    }

    public void Stop()
    {
        lock (sync)
        {
            started = false;
        }
        StopSampler();
        Inbox.Drain(TimeSpan.FromSeconds(1));
        Marker.Clean();
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        hub.Wiped -= OnWiped;
        hub.Began -= OnBegan;
        StopSampler();
        Inbox.Dispose();
    }

    public void Learn(string? term) => Inbox.Post(() => hub.Terms.Add(term));

    public void RefreshTerms() => Inbox.Post(AddSourceTerms);

    public void Trail(string level, string code, int? window = null) => Inbox.Post(() => hub.Trail.Add(level, code, window));

    public void ProcessFailed(string kindName, string reasonName, int exitCode, string? description, DiagnosticContext? context)
    {
        Inbox.Post(() =>
        {
            var detail = new ProcessDetail(
                DiagnosticScrubber.ProcessKind(kindName),
                DiagnosticScrubber.ProcessReason(reasonName),
                DiagnosticFormats.ExitCode(exitCode),
                DiagnosticScrubber.ProcessDescription(description));
            hub.Record(Event(DiagnosticKind.ProcessFailed, DiagnosticFingerprint.ForProcess(detail), context) with { Process = detail });
        });
    }

    public void Unresponsive(string outcome, int waitedSeconds, DiagnosticContext? context)
    {
        Inbox.Post(() => hub.Record(Event(DiagnosticKind.Unresponsive, DiagnosticFingerprint.ForHang(outcome), context) with { Hang = new HangDetail(outcome, waitedSeconds) }));
    }

    public void GpuFailed(string? failureText, int retries, DiagnosticContext? context)
    {
        Inbox.Post(() =>
        {
            var code = DiagnosticScrubber.GpuFailure(failureText) ?? DiagnosticScrubber.Other;
            hub.Record(Event(DiagnosticKind.GpuFailed, DiagnosticFingerprint.ForGpu(code), context) with { Gpu = new GpuDetail(code, retries) });
        });
    }

    public void Exception(Exception exception, string origin, bool handled, DiagnosticContext? context = null)
    {
        Inbox.Post(() =>
        {
            var error = DiagnosticScrubber.Exception(exception, origin, handled);
            hub.Record(Event(DiagnosticKind.DotnetException, DiagnosticFingerprint.ForException(error), context) with { Error = error });
        });
    }

    public void Crash(Exception exception, string origin)
    {
        if (!hub.Recording)
        {
            return;
        }
        try
        {
            var error = DiagnosticScrubber.Exception(exception, origin, handled: false);
            hub.WritePending(Event(DiagnosticKind.DotnetException, DiagnosticFingerprint.ForException(error), null) with { Error = error });
            Marker.MarkCrashed();
        }
        catch (Exception)
        {
            hub.ReportFault();
        }
    }

    public void SampleOnce()
    {
        if (!hub.Recording)
        {
            return;
        }
        EnsureMarker();
        Marker.Touch();
        var settings = config?.Invoke() ?? DiagnosticsConfig.Disabled;
        if (!settings.Enabled || !settings.Perf || !DiagnosticLimiter.SampledIn(hub.Limiter.SampleDraw, settings.SamplePercent) || source is null)
        {
            return;
        }
        if (source.Read(time.GetUtcNow()) is { } sample)
        {
            Perf.Add(sample);
        }
        var interval = TimeSpan.FromSeconds(settings.PerfIntervalSeconds);
        if (Perf.NeedsPageMemory(interval, PageReadLead))
        {
            RequestPageMemory?.Invoke();
        }
        Perf.TryComplete(interval);
    }

    private DiagnosticEvent Event(DiagnosticKind kind, string fingerprint, DiagnosticContext? context)
    {
        var now = time.GetUtcNow();
        return new DiagnosticEvent
        {
            Kind = kind,
            Fingerprint = fingerprint,
            At = DiagnosticFormats.Minute(now),
            Context = (context ?? new DiagnosticContext()) with { UptimeSeconds = DiagnosticFormats.RoundUptime((now - startedAt).TotalSeconds) },
            Trail = hub.Trail.Snapshot(now),
        };
    }

    private void BeginRun()
    {
        if (!Inbox.Post(StartRun))
        {
            return;
        }
        StartSampler();
    }

    private void StartRun()
    {
        AddSourceTerms();
        if (Marker.ReadPrevious() is { } previous)
        {
            hub.WritePending(new DiagnosticEvent
            {
                Kind = DiagnosticKind.RunEnd,
                Fingerprint = DiagnosticFingerprint.ForRunEnd(previous.Outcome),
                At = DiagnosticFormats.Minute(previous.AliveAt),
                RunEnd = new RunEndDetail(previous.Outcome, previous.UptimeSeconds, previous.Version),
            });
        }
        Marker.Begin(appVersion);
    }

    private void EnsureMarker()
    {
        if (!Marker.Written)
        {
            Marker.Begin(appVersion);
        }
    }

    private void AddSourceTerms()
    {
        if (termSource?.Invoke() is { } terms)
        {
            hub.Terms.AddRange(terms);
        }
    }

    private void OnBegan()
    {
        bool run;
        lock (sync)
        {
            run = started;
        }
        if (run)
        {
            BeginRun();
        }
    }

    private void OnWiped()
    {
        Marker.Forget();
        Perf.Clear();
        StopSampler();
    }

    private void StartSampler()
    {
        lock (sync)
        {
            if (sampler is not null || disposed)
            {
                return;
            }
            sampler = new CancellationTokenSource();
            var token = sampler.Token;
            Task.Run(() => SampleLoopAsync(token));
        }
    }

    private void StopSampler()
    {
        CancellationTokenSource? old;
        lock (sync)
        {
            old = sampler;
            sampler = null;
        }
        old?.Cancel();
        old?.Dispose();
    }

    private async Task SampleLoopAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(SampleStep, timerTime);
        try
        {
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                try
                {
                    SampleOnce();
                }
                catch (Exception)
                {
                    hub.ReportFault();
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }
}
