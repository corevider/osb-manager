using System.Net;
using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

internal sealed class FakePerfSource : IPerfSource
{
    private int calls;

    public int Calls => calls;

    public PerfSample? Read(DateTimeOffset now)
    {
        var step = Interlocked.Increment(ref calls);
        var cpu = step * 0.6;
        return new PerfSample(
            now,
            [
                new ProcessReading(100, ProcessRole.Browser, 300L << 20, cpu),
                new ProcessReading(101, ProcessRole.Gpu, 300L << 20, cpu),
                new ProcessReading(102, ProcessRole.Renderer, 400L << 20, cpu),
                new ProcessReading(103, ProcessRole.Renderer, (500L + step % 3) << 20, cpu * 2),
                new ProcessReading(104, ProcessRole.Utility, 120L << 20, cpu),
            ],
            new ProcessReading(1, ProcessRole.Other, 95L << 20, cpu / 2),
            new PerfWindows(2, 1, 0, 2));
    }
}

internal static class DiagnosticsKit
{
    public const string CanaryAccount = "CanaryAccountXv";
    public const string CanaryPlayer = "CanaryPlayerZq";
    public const string CanaryUser = "CanaryUserKt";

    public static TelemetryKit Granted(string? config = null, string? root = null, FakeTimeProvider? time = null, double random = 0.5, bool grant = true, FakeTimeProvider? wireTime = null)
    {
        var kit = new TelemetryKit(random, root: root, time: time, wireTime: wireTime);
        kit.Server.Route("GET /v1/config", _ => FakeServer.Json(HttpStatusCode.OK, config ?? FakeServer.ConfigWithDiagnostics()));
        if (grant)
        {
            kit.Store.Grant(false);
        }
        return kit;
    }

    public static void Drain(this TelemetryKit kit) => Assert.True(kit.Service.Capture.Inbox.Drain(TimeSpan.FromSeconds(10)));

    public static string Marker(this TelemetryKit kit) => Path.Combine(kit.Paths.Diagnostics, RunMarker.FileName);

    public static DiagnosticContext Window(int ordinal = 1) => new() { Phase = "world", LoginStage = "done", Window = ordinal, Windows = 2, Light = false, Hidden = false };

    public static IReadOnlyList<JsonNode> DiagnosticBodies(this TelemetryKit kit) =>
        kit.Server.To("POST /v1/diagnostics").Select(r => JsonNode.Parse(r.BodyText)!).ToList();

    public static string EverythingOnDisk(this TelemetryKit kit) =>
        Directory.Exists(kit.Paths.Diagnostics)
            ? string.Join("\n", Directory.EnumerateFiles(kit.Paths.Diagnostics).Select(File.ReadAllText))
            : "";

    public static void AssertNoCanary(string text)
    {
        foreach (var canary in new[] { CanaryAccount, CanaryPlayer, CanaryUser, "CANARY-PC", @"C:\Users", "\\Users\\", "/Users/", "canary.login" })
        {
            Assert.DoesNotContain(canary, text, StringComparison.OrdinalIgnoreCase);
        }
    }
}

public class DiagnosticsCaptureTests
{
    private static Exception ThrownWith(string message)
    {
        try
        {
            throw new InvalidOperationException(message, new IOException(message));
        }
        catch (InvalidOperationException e)
        {
            return e;
        }
    }

    [Fact]
    public void DG1_WithTheSwitchOffNothingIsCapturedTimedOrWritten()
    {
        using var kit = DiagnosticsKit.Granted(grant: false);
        var capture = kit.Service.Capture;
        var perf = new FakePerfSource();
        kit.Service.ConfigureDiagnostics(perf, null);

        capture.Start();
        capture.Trail("info", TrailCodes.WindowStart, 1);
        capture.ProcessFailed("RenderProcessExited", "OutOfMemory", -1, "Network Service", DiagnosticsKit.Window());
        capture.Unresponsive("reloaded", 60, DiagnosticsKit.Window());
        capture.GpuFailed("adapter is null", 3, DiagnosticsKit.Window());
        capture.Exception(ThrownWith("boom"), "caught", true);
        capture.Crash(ThrownWith("crash"), "appdomain");
        capture.Learn(DiagnosticsKit.CanaryPlayer);
        capture.SampleOnce();
        capture.Stop();

        Assert.False(kit.Service.Diagnostics.Recording);
        Assert.Equal(0, perf.Calls);
        Assert.Equal(0, kit.Service.Diagnostics.Trail.Count);
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Equal(0, kit.Service.Perf.Samples);
        Assert.False(Directory.Exists(kit.Paths.Diagnostics));
        Assert.Empty(kit.Server.Requests);
    }

    [Fact]
    public async Task DG1_ALifecycleWithTheSwitchOffSendsNoDiagnosticsRequestAndWritesNoFile()
    {
        using var kit = DiagnosticsKit.Granted(grant: false);
        kit.Service.Capture.Exception(ThrownWith("x"), "caught", true);
        kit.Service.Capture.Crash(ThrownWith("x"), "appdomain");

        await kit.RunFor(TimeSpan.FromHours(1));

        Assert.Empty(kit.Server.Requests);
        Assert.False(Directory.Exists(kit.Paths.Diagnostics));
    }

    [Fact]
    public void ProcessFailureIsRecordedWithKindReasonExitCodeAndAKnownDescriptionOnly()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        kit.Service.Capture.Trail("info", TrailCodes.WindowStart, 3);
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "OutOfMemory", unchecked((int)0xE0000008), $"Network Service of {DiagnosticsKit.CanaryAccount}", DiagnosticsKit.Window(3));
        kit.Service.Capture.ProcessFailed("UtilityProcessExited", "Crashed", -5, "Network Service", DiagnosticsKit.Window(3));
        kit.Drain();

        var events = kit.Service.Diagnostics.Limiter.Peek().Events;

        Assert.Equal(2, events.Count);
        var render = events.Single(e => e.Process!.Kind == "render_process_exited");
        Assert.Equal("out_of_memory", render.Process!.Reason);
        Assert.Equal("0xE0000008", render.Process.ExitCode);
        Assert.Null(render.Process.Description);
        Assert.Equal(3, render.Context!.Window);
        Assert.Contains(render.Trail!, t => t.Code == TrailCodes.WindowStart && t.Window == 3);
        var utility = events.Single(e => e.Process!.Kind == "utility_process_exited");
        Assert.Equal("network-service", utility.Process!.Description);
        Assert.Equal("0xFFFFFFFB", utility.Process.ExitCode);
    }

    [Fact]
    public void HangAndGpuFailuresAreRecordedWithCodesNeverText()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        kit.Service.Capture.Unresponsive("reloaded", 60, DiagnosticsKit.Window(2));
        kit.Service.Capture.GpuFailed($"GPU adapter is null for {DiagnosticsKit.CanaryPlayer}", 3, DiagnosticsKit.Window(2));
        kit.Service.Capture.GpuFailed("something odd about CanaryPlayerZq", 1, DiagnosticsKit.Window(2));
        kit.Drain();

        var events = kit.Service.Diagnostics.Limiter.Peek().Events;

        Assert.Contains(events, e => e.Kind == DiagnosticKind.Unresponsive && e.Hang is { Outcome: "reloaded", WaitedSeconds: 60 });
        Assert.Contains(events, e => e.Kind == DiagnosticKind.GpuFailed && e.Gpu is { Code: "adapter-null", Retries: 3 });
        Assert.Contains(events, e => e.Kind == DiagnosticKind.GpuFailed && e.Gpu is { Code: "other", Retries: 1 });
    }

    [Fact]
    public void ACaughtExceptionKeepsTypeHResultAndOurFramesAndNeverItsMessage()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        kit.Service.Capture.Exception(ThrownWith($@"cannot open C:\Users\{DiagnosticsKit.CanaryUser}\x for {DiagnosticsKit.CanaryAccount}"), "caught", true, DiagnosticsKit.Window());
        kit.Drain();

        var e = Assert.Single(kit.Service.Diagnostics.Limiter.Peek().Events);

        Assert.Equal(DiagnosticKind.DotnetException, e.Kind);
        Assert.Equal("System.InvalidOperationException", e.Error!.Type);
        Assert.Equal("0x80131509", e.Error.HResult);
        Assert.Equal(["System.IO.IOException"], e.Error.Inner);
        Assert.True(e.Error.Handled);
        Assert.Equal("caught", e.Error.Origin);
        Assert.All(e.Error.Frames, f => Assert.DoesNotContain(".cs", f));
        Assert.Contains(e.Error.Frames, f => f.StartsWith("OsbManager.Tests.", StringComparison.Ordinal));
        DiagnosticsKit.AssertNoCanary(System.Text.Encoding.UTF8.GetString(DiagnosticJson.Event(e, kit.Terms)!));
    }

    [Fact]
    public void ASecondCaptureOfTheSameErrorOnlyRaisesTheCount()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        for (var i = 0; i < 5; i++)
        {
            kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 1, null, DiagnosticsKit.Window());
        }
        kit.Drain();

        var e = Assert.Single(kit.Service.Diagnostics.Limiter.Peek().Events);

        Assert.Equal(5, e.Count);
    }

    [Fact]
    public void TheInboxIsBoundedAndCountsWhatItDrops()
    {
        using var kit = DiagnosticsKit.Granted();
        var gate = new ManualResetEventSlim();
        Assert.True(kit.Service.Capture.Inbox.Post(gate.Wait));
        Thread.Sleep(50);
        var accepted = 0;
        for (var i = 0; i < 200; i++)
        {
            kit.Service.Capture.Inbox.Post(() => Interlocked.Increment(ref accepted));
        }
        gate.Set();
        kit.Drain();

        Assert.InRange(accepted, 60, 70);
        Assert.Equal(200 - accepted, kit.Service.Diagnostics.Limiter.Peek().Dropped.RateLimited);
    }

    [Fact]
    public void DG20_ThreeFailuresInsideTheDiagnosticsCodeSwitchItOffAndNothingReportsItself()
    {
        using var kit = DiagnosticsKit.Granted();
        for (var i = 0; i < 3; i++)
        {
            Assert.True(kit.Service.Capture.Inbox.Post(() => throw new InvalidOperationException("diagnostics bug")));
            kit.Drain();
        }

        Assert.True(kit.Service.Diagnostics.Faulted);
        Assert.False(kit.Service.Diagnostics.Recording);
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        kit.Service.Capture.Exception(ThrownWith("later"), "caught", true);
        Assert.False(kit.Service.Capture.Inbox.Post(() => { }));
    }

    [Fact]
    public void ALoginIdOrAccountNameHeldInATrailCodeIsRefused()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        kit.Service.Capture.Trail("info", "login.failed:" + DiagnosticsKit.CanaryAccount, 1);
        kit.Service.Capture.Trail("info", TrailCodes.LoginFailed("Canary Stage Zq"), 1);
        kit.Service.Capture.Trail("warn", TrailCodes.GpuFailed("player CanaryPlayerZq lost"), 1);
        kit.Drain();

        var trail = kit.Service.Diagnostics.Trail.Snapshot(kit.Time.GetUtcNow());

        Assert.Equal(["login.failed:other", "gpu.failed:device-lost"], trail.Select(t => t.Code).Where(c => c.StartsWith("login") || c.StartsWith("gpu")));
        Assert.DoesNotContain(trail, t => t.Code.Contains("canary", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void LearnedAccountAndCharacterNamesMakeFramesAndDetailsDisappear()
    {
        using var kit = DiagnosticsKit.Granted();
        var names = new[] { DiagnosticsKit.CanaryAccount, "canary.login.Wb", "CanaryServerQx" };
        kit.Service.ConfigureDiagnostics(null, () => names);
        kit.Service.Capture.Start();
        kit.Service.Capture.Learn(DiagnosticsKit.CanaryPlayer);
        kit.Drain();

        Assert.True(kit.Terms.Hits($"frame of {DiagnosticsKit.CanaryAccount}"));
        Assert.True(kit.Terms.Hits("canary.login.Wb"));
        Assert.True(kit.Terms.Hits("canaryserverqx"));
        Assert.True(kit.Terms.Hits(DiagnosticsKit.CanaryPlayer.ToUpperInvariant()));
    }

    [Fact]
    public async Task ACrashIsWrittenSynchronouslyAndSentAtTheNextStartThenDeleted()
    {
        using var dir = new TempDirectory();
        var time = new FakeTimeProvider();
        using (var first = DiagnosticsKit.Granted(root: dir.Path, time: time))
        {
            first.Service.Capture.Start();
            first.Drain();
            Assert.True(File.Exists(first.Marker()));
            time.Advance(TimeSpan.FromMinutes(10));
            first.Service.Capture.SampleOnce();

            first.Service.Capture.Crash(ThrownWith($@"C:\Users\{DiagnosticsKit.CanaryUser}\x {DiagnosticsKit.CanaryAccount}"), "appdomain");

            var written = Directory.EnumerateFiles(first.Paths.Diagnostics, "pending-*.json").Single();
            Assert.InRange(new FileInfo(written).Length, 1, PendingDiagnostics.MaxFileBytes);
            DiagnosticsKit.AssertNoCanary(File.ReadAllText(written));
            Assert.Contains("\"crashed\":true", File.ReadAllText(first.Marker()));
        }
        time.Advance(TimeSpan.FromMinutes(5));

        using var second = DiagnosticsKit.Granted(root: dir.Path, time: time, grant: false);
        Assert.True(second.Store.State.Granted);
        second.Service.Capture.Start();
        second.Drain();
        await second.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(second.DiagnosticBodies());
        var events = body["events"]!.AsArray();
        Assert.Contains(events, e => e!["kind"]!.GetValue<string>() == "dotnet_exception" && e["error"]!["origin"]!.GetValue<string>() == "appdomain" && !e["error"]!["handled"]!.GetValue<bool>());
        var runEnd = events.Single(e => e!["kind"]!.GetValue<string>() == "run_end")!["run_end"]!;
        Assert.Equal("crash", runEnd["outcome"]!.GetValue<string>());
        Assert.Equal(600, runEnd["uptime_s"]!.GetValue<int>());
        Assert.Equal(TelemetryKit.AppVersion, runEnd["previous_version"]!.GetValue<string>());
        Assert.Empty(Directory.EnumerateFiles(second.Paths.Diagnostics, "pending-*.json"));
        DiagnosticsKit.AssertNoCanary(second.Server.To("POST /v1/diagnostics")[0].BodyText);
    }

    [Fact]
    public async Task DG18_AKilledProcessIsFoundByTheRunMarkerAndACleanExitSendsACleanRunEnd()
    {
        using var dir = new TempDirectory();
        var time = new FakeTimeProvider();
        using (var killed = DiagnosticsKit.Granted(root: dir.Path, time: time))
        {
            killed.Service.Capture.Start();
            killed.Drain();
            time.Advance(TimeSpan.FromMinutes(7));
            killed.Service.Capture.SampleOnce();
        }
        time.Advance(TimeSpan.FromMinutes(1));

        using (var restarted = DiagnosticsKit.Granted(root: dir.Path, time: time, grant: false))
        {
            restarted.Service.Capture.Start();
            restarted.Drain();
            await restarted.RunFor(TimeSpan.FromMinutes(14), startService: true);
            var body = Assert.Single(restarted.DiagnosticBodies());
            var runEnd = Assert.Single(body["events"]!.AsArray())!["run_end"]!;
            Assert.Equal("unclean", runEnd["outcome"]!.GetValue<string>());
            Assert.Equal(420, runEnd["uptime_s"]!.GetValue<int>());
            restarted.Service.Stop(TimeSpan.FromSeconds(1));
            Assert.Contains("\"clean\":true", File.ReadAllText(restarted.Marker()));
        }
        time.Advance(TimeSpan.FromMinutes(2));

        using var again = DiagnosticsKit.Granted(root: dir.Path, time: time, grant: false);
        again.Service.Capture.Start();
        again.Drain();
        await again.RunFor(TimeSpan.FromMinutes(14));
        var cleanBody = Assert.Single(again.DiagnosticBodies());
        var cleanEnd = Assert.Single(cleanBody["events"]!.AsArray())!["run_end"]!;
        Assert.Equal("clean", cleanEnd["outcome"]!.GetValue<string>());
        Assert.Equal(840, cleanEnd["uptime_s"]!.GetValue<int>());
        Assert.Equal(TelemetryKit.AppVersion, cleanEnd["previous_version"]!.GetValue<string>());
        Assert.Empty(DiagnosticsServerRules.Check(cleanBody));
    }

    [Fact]
    public async Task ACleanExitAfterACrashStaysACrashAndSwitchingOffAtExitDeletesTheMarker()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        kit.Drain();
        kit.Service.Capture.Crash(ThrownWith("x"), "appdomain");
        kit.Service.Stop(TimeSpan.FromSeconds(1));
        Assert.Contains("\"crashed\":true", File.ReadAllText(kit.Marker()));
        Assert.DoesNotContain("\"clean\":true", File.ReadAllText(kit.Marker()));

        using var off = DiagnosticsKit.Granted();
        off.Service.Capture.Start();
        off.Drain();
        Assert.True(File.Exists(off.Marker()));
        await off.Service.WithdrawAsync();
        off.Service.Stop(TimeSpan.FromSeconds(1));
        Assert.False(File.Exists(off.Marker()));
    }

    [Fact]
    public async Task WithTheSwitchOffNoRunMarkerExistsAndTurningItOnStartsOne()
    {
        using var kit = DiagnosticsKit.Granted(grant: false);
        kit.Service.Capture.Start();
        kit.Drain();
        Assert.False(File.Exists(kit.Marker()));

        kit.Store.Grant(false);
        kit.Drain();
        Assert.True(File.Exists(kit.Marker()));

        await kit.Service.WithdrawAsync();
        Assert.False(File.Exists(kit.Marker()));
    }

    [Fact]
    public async Task AnUnclearRunMarkerOlderThanAWeekOrCorruptIsIgnored()
    {
        using var dir = new TempDirectory();
        var time = new FakeTimeProvider();
        using (var first = DiagnosticsKit.Granted(root: dir.Path, time: time))
        {
            first.Service.Capture.Start();
            first.Drain();
        }
        time.Advance(TimeSpan.FromDays(9));
        using (var late = DiagnosticsKit.Granted(root: dir.Path, time: time, grant: false))
        {
            await late.RunFor(TimeSpan.FromMinutes(14));
            late.Drain();
            Assert.Empty(late.Server.To("POST /v1/diagnostics"));
        }
        File.WriteAllText(Path.Combine(dir.Path, "diagnostics", RunMarker.FileName), "{ not json");
        using var corrupt = DiagnosticsKit.Granted(root: dir.Path, time: time, grant: false);
        await corrupt.RunFor(TimeSpan.FromMinutes(14));
        Assert.Empty(corrupt.Server.To("POST /v1/diagnostics"));
    }

    [Fact]
    public void DG8_ThreeHoursWithWindowsOpenGiveAtMostSixPerfEntries()
    {
        using var kit = DiagnosticsKit.Granted();
        var perf = new FakePerfSource();
        kit.Service.ConfigureDiagnostics(perf, null);
        kit.Store.StoreConfig(kit.Store.Credentials!.Id, TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes(FakeServer.ConfigWithDiagnostics()))!);
        kit.Service.Capture.Start();
        kit.Drain();

        var entries = new List<PerfEntry>();
        for (var minute = 0; minute < 180; minute++)
        {
            kit.Time.Advance(TimeSpan.FromSeconds(60));
            kit.Service.Capture.SampleOnce();
            entries.AddRange(kit.Service.Perf.TakeReady());
        }

        Assert.InRange(entries.Count, 5, 6);
        var first = entries[0];
        Assert.Equal(30, first.Samples);
        Assert.Equal(1800, first.SpanSeconds);
        Assert.Equal(new PerfWindows(2, 1, 0, 2), first.Windows);
        Assert.Equal(2, first.Memory!.RendererEach!.Count);
        Assert.Equal(300, first.Memory.Gpu!.P50);
        Assert.Equal(120, first.Memory.Utility!.P50);
        Assert.Equal(95, first.Memory.App!.P50);
        Assert.InRange(first.Memory.BrowserTotal!.P50, 1620, 1622);
        Assert.Equal(1.0, first.Cpu!.Gpu!.Value, 0.2);
        Assert.Equal([1.0, 2.0], first.Cpu.RendererEach!.Select(v => Math.Round(v)).ToArray());
        Assert.Equal(0.5, first.Cpu.App!.Value, 0.2);
    }

    [Fact]
    public void DG8_NoPerfEntriesWhenTheConfigSaysPerfIsOffOrDiagnosticsAreOffOrTheRunIsSampledOut()
    {
        foreach (var config in new[] { FakeServer.ConfigWithDiagnostics(perf: false), FakeServer.ConfigWithDiagnostics(enabled: false), FakeServer.ConfigWithDiagnostics(sample: 0), FakeServer.ConfigEnabled })
        {
            using var kit = DiagnosticsKit.Granted(config);
            var perf = new FakePerfSource();
            kit.Service.ConfigureDiagnostics(perf, null);
            kit.Store.StoreConfig(kit.Store.Credentials!.Id, TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes(config))!);
            kit.Service.Capture.Start();
            kit.Drain();
            for (var minute = 0; minute < 120; minute++)
            {
                kit.Time.Advance(TimeSpan.FromSeconds(60));
                kit.Service.Capture.SampleOnce();
            }

            Assert.Equal(0, perf.Calls);
            Assert.Equal(0, kit.Service.Perf.ReadyCount);
        }
    }

    [Fact]
    public void DG8_NoSamplesWithoutConsent()
    {
        using var kit = DiagnosticsKit.Granted(grant: false);
        var perf = new FakePerfSource();
        kit.Service.ConfigureDiagnostics(perf, null);
        for (var minute = 0; minute < 120; minute++)
        {
            kit.Time.Advance(TimeSpan.FromSeconds(60));
            kit.Service.Capture.SampleOnce();
        }

        Assert.Equal(0, perf.Calls);
        Assert.Equal(0, kit.Service.Perf.Samples);
    }

    [Fact]
    public void PageMemoryReadOnceInASpanRidesInTheEntryAndIsSorted()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.ConfigureDiagnostics(new FakePerfSource(), null);
        kit.Store.StoreConfig(kit.Store.Credentials!.Id, TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes(FakeServer.ConfigWithDiagnostics()))!);
        var requests = 0;
        kit.Service.Capture.RequestPageMemory = () =>
        {
            requests++;
            kit.Service.Perf.SetPageMemory([166, 118], [210, 150], [512, 256]);
        };
        kit.Service.Capture.Start();
        kit.Drain();

        PerfEntry? entry = null;
        for (var minute = 0; minute < 31 && entry is null; minute++)
        {
            kit.Time.Advance(TimeSpan.FromSeconds(60));
            kit.Service.Capture.SampleOnce();
            entry = kit.Service.Perf.TakeReady().FirstOrDefault();
        }

        Assert.Equal(1, requests);
        Assert.NotNull(entry);
        var body = JsonNode.Parse(DiagnosticJson.Batch(new DiagnosticBatch { AppVersion = "1.0.0", Run = "3e5c0b1a9d7f2c64", Perf = [entry!] }, kit.Terms, kit.Time.GetUtcNow()).Body)!;
        Assert.Equal([118, 166], body["perf"]![0]!["js_heap_mb"]!["used_each"]!.AsArray().Select(n => n!.GetValue<int>()).ToArray());
        Assert.Equal([256, 512], body["perf"]![0]!["wasm_mb"]!["each"]!.AsArray().Select(n => n!.GetValue<int>()).ToArray());
    }

    [Fact]
    public void TheDiagnosticsBlockOfTheConfigIsClampedAndAMissingOrBadBlockIsDisabled()
    {
        static DiagnosticsConfig Parse(string block) =>
            TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes($$"""{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":false},"client_ok":true{{block}}}"""))!.Diagnostics;

        Assert.Equal(new DiagnosticsConfig(true, true, 600, 1800, 100), Parse(""","diagnostics":{"enabled":true,"perf":true,"interval_s":10,"perf_interval_s":100,"sample_pct":500}"""));
        Assert.Equal(new DiagnosticsConfig(true, false, 86400, 86400, 0), Parse(""","diagnostics":{"enabled":true,"perf":false,"interval_s":999999,"perf_interval_s":999999,"sample_pct":-3}"""));
        Assert.Equal(DiagnosticsConfig.Disabled, Parse(""));
        Assert.Equal(DiagnosticsConfig.Disabled, Parse(""","diagnostics":"on" """));
        Assert.Equal(DiagnosticsConfig.Disabled, Parse(""","diagnostics":{"enabled":"yes","perf":true,"interval_s":600,"perf_interval_s":1800,"sample_pct":100}"""));
        Assert.Equal(DiagnosticsConfig.Disabled, Parse(""","diagnostics":{"enabled":true}"""));
        Assert.False(Parse(""","diagnostics":null""").Enabled);
    }
}
