using System.ComponentModel;
using System.Text;
using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class DiagnosticsCoreTests
{
    private const string GoldenManagerBatch = """
        {
          "schema": 1,
          "app": "manager-win",
          "app_version": "1.4.2",
          "run": "3e5c0b1a9d7f2c64",
          "env": { "os_build": "10.0.26100", "webview2": "131.0.2903.70", "dotnet": "10.0.1", "ram_gb": 16, "cores": 8, "gpu_vendor": "nvidia" },
          "events": [
            {
              "kind": "process_failed",
              "source": "manager",
              "fp": "5b0e2a9c41d7f308",
              "at": "2026-11-12T14:20:00Z",
              "count": 1,
              "process": { "kind": "render_process_exited", "reason": "out_of_memory", "exit_code": "0xE0000008" },
              "context": { "phase": "world", "login_stage": "done", "window": 3, "windows": 4, "light": false, "hidden": true, "uptime_s": 7260 },
              "trail": [
                { "s": -600, "l": "info", "c": "window", "k": "window.start", "w": 3 },
                { "s": -95, "l": "warn", "c": "gpu", "k": "gpu.retry", "w": 3, "n": 2 },
                { "s": 0, "l": "error", "c": "window", "k": "window.renderer-exited", "w": 3 }
              ]
            },
            {
              "kind": "dotnet_exception",
              "source": "manager",
              "fp": "a41c09e7b23d5f16",
              "at": "2026-11-12T14:22:00Z",
              "count": 3,
              "error": {
                "type": "System.InvalidOperationException",
                "hresult": "0x80131509",
                "inner": [],
                "handled": true,
                "origin": "caught",
                "frames": [ "OsbManager.Browser.GameWindow.OnWebMessage+IL_01A3", "System.Text.Json.JsonDocument.Parse+IL_0042", "ext" ]
              },
              "context": { "phase": "world", "window": 1, "windows": 4, "light": true, "hidden": false, "uptime_s": 7380 }
            },
            {
              "kind": "run_end",
              "source": "manager",
              "fp": "0c8d1e2f3a4b5c6d",
              "at": "2026-11-12T12:00:00Z",
              "count": 1,
              "run_end": { "outcome": "unclean", "uptime_s": 10800, "previous_version": "1.4.1" }
            }
          ],
          "perf": [
            {
              "at": "2026-11-12T14:00:00Z",
              "span_s": 1800,
              "samples": 30,
              "windows": { "open": 4, "light": 2, "hidden": 1, "in_world": 4 },
              "mem_mb": {
                "renderer": { "p50": 412, "max": 690, "each": [380, 402, 455, 690] },
                "gpu": { "p50": 300, "max": 344 },
                "browser_total": { "p50": 2150, "max": 2480 },
                "utility": { "p50": 120, "max": 131 },
                "app": { "p50": 95, "max": 101 }
              },
              "js_heap_mb": { "used_each": [118, 131, 140, 166], "total_each": [150, 160, 170, 210] },
              "wasm_mb": { "each": [256, 256, 256, 512] },
              "cpu_pct": { "renderer_each": [12.0, 14.5, 15.1, 31.2], "gpu": 18.4, "browser_total": 92.3, "app": 1.1 }
            }
          ],
          "osb_perf": [
            {
              "app_version": "2.0.14",
              "at": "2026-11-12T14:00:00Z",
              "span_s": 1800,
              "samples": 30,
              "js_heap_mb": { "used": 131, "total": 160 },
              "tick_ms": { "p50": 1.2, "p95": 3.0, "p99": 8.4, "max": 41.0, "late_pct": 0.3 },
              "gap_ms": { "p50": 100.1, "p95": 104.0, "p99": 180.0, "max": 912.0, "late_pct": 0.3 },
              "long_tasks": { "count": 3, "total_ms": 412.0 }
            }
          ],
          "dropped": { "rate_limited": 0, "oversize": 0, "sampled_out": 0 }
        }
        """;

    private static readonly DateTimeOffset Now = new(2026, 11, 12, 14, 30, 0, TimeSpan.Zero);

    private const string CanaryPlayer = "CanaryPlayerZq";
    private const string CanaryAccount = "CanaryAccountXv";
    private const string CanaryLogin = "canary.login.Wb";
    private const string CanaryUser = "CanaryUserKt";
    private const string CanaryMachine = "CANARY-PC-7Q";
    private const string CanaryChat = "canary chat line about loot Hn";

    private static PrivateTerms CanaryTerms()
    {
        var terms = PrivateTerms.ForMachine(CanaryUser, CanaryMachine, "CANARY-DOMAIN-3", $@"C:\Users\{CanaryUser}\AppData\Local\OSB Manager");
        terms.AddRange([CanaryAccount, CanaryLogin, CanaryPlayer]);
        return terms;
    }

    private static DiagnosticBatch GoldenBatch() => new()
    {
        AppVersion = "1.4.2",
        Run = "3e5c0b1a9d7f2c64",
        Env = new DiagnosticEnv("10.0.26100", "131.0.2903.70", "10.0.1", 16, 8, "nvidia"),
        Events =
        [
            new DiagnosticEvent
            {
                Kind = DiagnosticKind.ProcessFailed,
                Fingerprint = "5b0e2a9c41d7f308",
                At = new DateTimeOffset(2026, 11, 12, 14, 20, 37, TimeSpan.Zero),
                Process = new ProcessDetail(DiagnosticScrubber.ProcessKind("RenderProcessExited"), DiagnosticScrubber.ProcessReason("OutOfMemory"), DiagnosticFormats.ExitCode(unchecked((int)0xE0000008))),
                Context = new DiagnosticContext { Phase = "world", LoginStage = "done", Window = 3, Windows = 4, Light = false, Hidden = true, UptimeSeconds = 7255 },
                Trail =
                [
                    new TrailItem(-600, "info", "window", TrailCodes.WindowStart, Window: 3),
                    new TrailItem(-95, "warn", "gpu", TrailCodes.GpuRetry, Count: 2, Window: 3),
                    new TrailItem(0, "error", "window", TrailCodes.WindowRendererExited, Window: 3),
                ],
            },
            new DiagnosticEvent
            {
                Kind = DiagnosticKind.DotnetException,
                Fingerprint = "a41c09e7b23d5f16",
                At = new DateTimeOffset(2026, 11, 12, 14, 22, 0, TimeSpan.Zero),
                Count = 3,
                Error = new ErrorDetail(
                    "System.InvalidOperationException", "caught", true,
                    FrameReducer.Reduce([
                        new FrameInfo("OsbManager.Browser.GameWindow", "OnWebMessage", 0x1A3),
                        new FrameInfo("System.Text.Json.JsonDocument", "Parse", 0x42),
                        new FrameInfo("Microsoft.Web.WebView2.Core.CoreWebView2", "OnWebMessageReceived", 0x10) with { DeclaringType = "Vendor.Hidden" },
                        new FrameInfo("ThirdParty.Thing", "Run", 2),
                    ]),
                    [], DiagnosticFormats.Hex(unchecked((int)0x80131509))),
                Context = new DiagnosticContext { Phase = "world", Window = 1, Windows = 4, Light = true, Hidden = false, UptimeSeconds = 7380 },
            },
            new DiagnosticEvent
            {
                Kind = DiagnosticKind.RunEnd,
                Fingerprint = "0c8d1e2f3a4b5c6d",
                At = new DateTimeOffset(2026, 11, 12, 12, 0, 0, TimeSpan.Zero),
                RunEnd = new RunEndDetail("unclean", 10790, "1.4.1"),
            },
        ],
        Perf =
        [
            new PerfEntry
            {
                At = new DateTimeOffset(2026, 11, 12, 14, 0, 0, TimeSpan.Zero),
                SpanSeconds = 1800,
                Samples = 30,
                Windows = new PerfWindows(4, 2, 1, 4),
                Memory = new PerfMemory
                {
                    Renderer = new RoleMemory(412, 690),
                    RendererEach = [690, 380, 455.2, 402],
                    Gpu = new RoleMemory(300, 344),
                    BrowserTotal = new RoleMemory(2150, 2480),
                    Utility = new RoleMemory(120, 131),
                    App = new RoleMemory(95, 101),
                },
                JsHeapUsedEach = [166, 118, 140, 131],
                JsHeapTotalEach = [210, 150, 160, 170],
                WasmEach = [512, 256, 256, 256],
                Cpu = new PerfCpu { RendererEach = [31.24, 12, 14.5, 15.1], Gpu = 18.4, BrowserTotal = 92.3, App = 1.1 },
            },
        ],
        OsbPerf =
        [
            new OsbPerfEntry(
                new PerfEntry
                {
                    At = new DateTimeOffset(2026, 11, 12, 14, 0, 0, TimeSpan.Zero),
                    SpanSeconds = 1800,
                    Samples = 30,
                    JsHeapUsed = 131,
                    JsHeapTotal = 160,
                    Tick = new PerfTiming(1.2, 3.0, 8.4, 41.0, 0.3),
                    Gap = new PerfTiming(100.1, 104.0, 180.0, 912.0, 0.3),
                    LongTasks = new PerfLongTasks(3, 412.0),
                },
                "2.0.14"),
        ],
    };

    private static string BodyText(DiagnosticBatch batch, PrivateTerms terms) => Encoding.UTF8.GetString(DiagnosticJson.Batch(batch, terms, Now).Body);

    [Fact]
    public void DG22_TheManagerBatchMatchesTheGoldenPayloadOfAppendixNineTwo()
    {
        var body = JsonNode.Parse(DiagnosticJson.Batch(GoldenBatch(), new PrivateTerms(), Now).Body)!;

        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(GoldenManagerBatch), body), body.ToJsonString());
    }

    [Fact]
    public void DG23_EveryTimeIsMinuteAligned()
    {
        var text = BodyText(GoldenBatch(), new PrivateTerms());

        var times = System.Text.RegularExpressions.Regex.Matches(text, "\"at\":\"([^\"]*)\"").Select(m => m.Groups[1].Value).ToList();

        Assert.Equal(5, times.Count);
        Assert.All(times, t => Assert.Matches("^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:00Z$", t));
        Assert.Contains("2026-11-12T14:20:00Z", times);
    }

    [Fact]
    public void Canary_ALogLineWithAPlayerNameNeverLeaves()
    {
        var hub = new DiagnosticTrail(new FakeTimeProvider());
        var log = new List<string> { $"SoX drop: {CanaryPlayer} got Canary Blade of Hn", $"item notice {CanaryPlayer}" };
        foreach (var _ in log)
        {
            hub.Info(TrailCodes.WindowStart, 1);
        }
        var batch = GoldenBatch() with
        {
            Events = [GoldenBatch().Events[0] with { Trail = hub.Snapshot(new FakeTimeProvider().GetUtcNow()) }],
        };

        var withScrubber = BodyText(batch, CanaryTerms());
        var playerInCode = batch with { Events = [batch.Events[0] with { Trail = [new TrailItem(-1, "info", "window", "window.start", Outcome: CanaryPlayer.ToLowerInvariant())] }] };

        Assert.DoesNotContain(CanaryPlayer, withScrubber, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Blade", withScrubber);
        Assert.DoesNotContain(CanaryPlayer, BodyText(playerInCode, CanaryTerms()), StringComparison.OrdinalIgnoreCase);
        Assert.Contains(CanaryPlayer, BodyText(playerInCode, new PrivateTerms()), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Canary_APathWithAUserNameNeverLeaves()
    {
        var exception = Thrown(() => throw new FileNotFoundException($@"Could not find file 'C:\Users\{CanaryUser}\x.json'", $@"C:\Users\{CanaryUser}\x.json"));
        var error = DiagnosticScrubber.Exception(exception, "caught", handled: true);
        var leaky = error with { Template = $@"Could not find C:\Users\{CanaryUser}\x.json" };
        var batch = Single(DiagnosticKind.DotnetException, e => e with { Error = leaky });

        var text = BodyText(batch, CanaryTerms());

        Assert.Equal("System.IO.FileNotFoundException", error.Type);
        Assert.DoesNotContain(CanaryUser, text);
        Assert.DoesNotContain(@":\", text);
        Assert.DoesNotContain(@"\Users\", text);
        Assert.DoesNotContain(@"\\Users\\", text);
        Assert.DoesNotContain(".cs", text);
        Assert.All(error.Frames, f => Assert.True(f == "ext" || f.Contains("+IL_", StringComparison.Ordinal), f));
        Assert.Contains($@"C:\\Users\\{CanaryUser}", NoScrubberJson(batch));
    }

    [Fact]
    public void Canary_TheMachineNameNeverLeaves()
    {
        var batch = Single(DiagnosticKind.Warn, e => e with { Warn = new WarnDetail("window", "probe-" + CanaryMachine.ToLowerInvariant()) });
        var asCode = Single(DiagnosticKind.GpuFailed, e => e with { Gpu = new GpuDetail(CanaryMachine.ToLowerInvariant(), 1) });

        Assert.DoesNotContain(CanaryMachine, BodyText(batch, CanaryTerms()), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(CanaryMachine, BodyText(asCode, CanaryTerms()), StringComparison.OrdinalIgnoreCase);
        Assert.Contains(CanaryMachine, BodyText(asCode, new PrivateTerms()), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Canary_AChatLineNeverLeaves()
    {
        var template = DiagnosticScrubber.Template("TypeError", $"Cannot create property 'x' on string '{CanaryChat}'", CanaryTerms());
        var unquoted = DiagnosticScrubber.Template("RangeError", $"Invalid length for {CanaryPlayer} message", CanaryTerms());
        var own = DiagnosticScrubber.Template("Error", CanaryChat, CanaryTerms());
        var batch = Single(DiagnosticKind.JsError, e => e with
        {
            Source = DiagnosticSource.Osb,
            Error = new ErrorDetail("TypeError", "guard", true, ["Quest.observe@14210:31", "ext"], Template: template),
        });

        Assert.Equal("Cannot create property <q> on string <q>", template);
        Assert.Equal("Invalid length for <x> message", unquoted);
        Assert.Null(own);
        Assert.DoesNotContain("chat", BodyText(batch, CanaryTerms()));
        var raw = Single(DiagnosticKind.JsError, e => e with { Error = new ErrorDetail("TypeError", "guard", true, ["ext"], Template: CanaryChat) });
        Assert.Contains("chat", NoScrubberJson(raw));
    }

    [Fact]
    public void Canary_AnExceptionMessageHoldingAnAccountNameNeverLeaves()
    {
        var exception = Thrown(() => throw new InvalidOperationException($"Login failed for {CanaryAccount} ({CanaryLogin})", new Win32Exception(5, CanaryAccount)));
        var error = DiagnosticScrubber.Exception(exception, "caught", handled: true);
        var batch = Single(DiagnosticKind.DotnetException, e => e with { Error = error });
        var pending = DiagnosticJson.Event(batch.Events[0], CanaryTerms())!;
        var careless = Single(DiagnosticKind.DotnetException, e => e with { Error = error with { Template = exception.Message.Replace("(", "").Replace(")", "") } });

        var text = BodyText(batch, CanaryTerms()) + BodyText(careless, CanaryTerms());

        Assert.DoesNotContain(CanaryAccount, text);
        Assert.DoesNotContain(CanaryLogin, text);
        Assert.DoesNotContain("Login failed", text);
        Assert.DoesNotContain(CanaryAccount, Encoding.UTF8.GetString(pending));
        Assert.Equal(["System.ComponentModel.Win32Exception"], error.Inner);
        Assert.Contains(CanaryAccount, exception.ToString());
    }

    [Fact]
    public void AFrameOrTypeThatHoldsAPrivateTermIsReplacedOrDropsTheEvent()
    {
        var terms = new PrivateTerms();
        terms.Add("GameWindow");
        var frames = Single(DiagnosticKind.DotnetException, e => e with
        {
            Error = new ErrorDetail("System.Exception", "caught", true, ["OsbManager.Browser.GameWindow.Fail+IL_0001", "OsbManager.UI.MainForm.Load+IL_0002"]),
        });
        var type = Single(DiagnosticKind.DotnetException, e => e with { Error = new ErrorDetail("OsbManager.GameWindowException", "caught", true, []) });

        var body = JsonNode.Parse(DiagnosticJson.Batch(frames, terms, Now).Body)!;

        Assert.Equal("<x>", (string)body["events"]![0]!["error"]!["frames"]![0]!);
        Assert.Equal("OsbManager.UI.MainForm.Load+IL_0002", (string)body["events"]![0]!["error"]!["frames"]![1]!);
        Assert.Empty(DiagnosticJson.Batch(type, terms, Now).Events);
    }

    [Fact]
    public void ExceptionTypesOutsideTheAllowlistAndMessagesAreNeverSent()
    {
        var foreign = DiagnosticScrubber.Exception(Thrown(() => throw new CanaryLeakException("secret " + CanaryAccount)), "task", handled: false);

        Assert.Equal("Exception", foreign.Type);
        Assert.Null(foreign.Template);
        Assert.Equal("0x80131500", foreign.HResult);
        Assert.Equal("0x80070005", DiagnosticScrubber.Exception(new Win32Exception(5), "caught", true).HResult);
    }

    [Fact]
    public void FramesKeepOurNamespacesDropGenericsAndCollapseTheRest()
    {
        var frames = FrameReducer.Reduce([
            new FrameInfo("OsbManager.Core.Thing`1", "Run", 0x12),
            new FrameInfo("OsbManager.UI.MainForm+<>c__DisplayClass12_0", "<OnLoad>b__0", 0x1F),
            new FrameInfo("Vendor.A", "X", 1),
            new FrameInfo("Vendor.B", "Y", 2),
            new FrameInfo("System.Threading.Tasks.Task", "Run", -1),
            new FrameInfo(null, null, 0),
        ]);

        Assert.Equal(["OsbManager.Core.Thing.Run+IL_0012", "OsbManager.UI.MainForm+<>c__DisplayClass12_0.<OnLoad>b__0+IL_001F", "ext", "System.Threading.Tasks.Task.Run", "ext"], frames);
        Assert.True(FrameReducer.Reduce(Enumerable.Range(0, 40).Select(i => new FrameInfo("OsbManager.X", "M" + i, i))).Count == 16);
    }

    [Fact]
    public void ARealStackHasNoFileInformation()
    {
        var frames = FrameReducer.FromException(Thrown(() => Deep(3)));

        Assert.Contains(frames, f => f.StartsWith("OsbManager.Tests.Telemetry.DiagnosticsCoreTests.Deep+IL_", StringComparison.Ordinal));
        Assert.All(frames, f => Assert.DoesNotContain(".cs", f));
        Assert.All(frames, f => Assert.True(DiagnosticFormats.IsFrame(f), f));
    }

    [Fact]
    public void FingerprintsAreSixteenHexStableAndIgnoreOffsetsAndForeignFrames()
    {
        var a = DiagnosticFingerprint.ForException(DiagnosticKind.DotnetException, "System.Exception", "caught", ["OsbManager.A.B+IL_0001", "ext", "OsbManager.C.D+IL_0002"]);
        var b = DiagnosticFingerprint.ForException(DiagnosticKind.DotnetException, "System.Exception", "caught", ["OsbManager.A.B+IL_00FF", "OsbManager.C.D+IL_0003"]);
        var c = DiagnosticFingerprint.ForException(DiagnosticKind.DotnetException, "System.Exception", "task", ["OsbManager.A.B+IL_0001", "OsbManager.C.D+IL_0002"]);

        Assert.Matches("^[0-9a-f]{16}$", a);
        Assert.Equal(a, b);
        Assert.NotEqual(a, c);
        Assert.Equal(DiagnosticFingerprint.Of("dotnet_exception", "System.Exception", "caught", "OsbManager.A.B,OsbManager.C.D"), a);
        Assert.NotEqual(DiagnosticFingerprint.ForHang("reloaded"), DiagnosticFingerprint.ForHang("gave_up"));
        Assert.Equal(DiagnosticFingerprint.ForRunEnd("unclean"), DiagnosticFingerprint.ForRunEnd("unclean"));
    }

    [Fact]
    public void TheTrailKeepsTheLastFiftyCodesAndCountsRepeats()
    {
        var time = new FakeTimeProvider();
        var trail = new DiagnosticTrail(time);
        for (var i = 0; i < 60; i++)
        {
            trail.Info("window.start", i % 64 + 1);
            time.Advance(TimeSpan.FromSeconds(1));
        }
        trail.Warning(TrailCodes.GpuRetry, 3);
        trail.Warning(TrailCodes.GpuRetry, 3);
        trail.Info("Not A Code");

        var items = trail.Snapshot(time.GetUtcNow());

        Assert.Equal(50, items.Count);
        Assert.Equal(12, items[0].Window);
        Assert.Equal(2, items[^1].Count);
        Assert.Equal("gpu", items[^1].Category);
        Assert.Equal(0, items[^1].SecondsBefore);
        Assert.Equal(-49, items[0].SecondsBefore);
        Assert.Equal("login.failed:credentials", TrailCodes.LoginFailed("credentials"));
        Assert.Equal("login.failed:other", TrailCodes.LoginFailed("Canary text"));
        Assert.Equal("gpu.failed:adapter-null", TrailCodes.GpuFailed("requestAdapter returned null"));
        trail.Clear();
        Assert.Empty(trail.Snapshot(time.GetUtcNow()));
    }

    [Fact]
    public void DG6_ThousandIdenticalErrorsBecomeOneEventWithOneTrail()
    {
        var time = new FakeTimeProvider();
        var limiter = new DiagnosticLimiter(time);
        for (var i = 0; i < 1000; i++)
        {
            limiter.Record(Event(time.GetUtcNow(), "aaaaaaaaaaaaaaaa") with { Trail = [new TrailItem(0, "info", "window", "window.start")] });
            time.Advance(TimeSpan.FromMilliseconds(600));
        }

        var (events, dropped) = limiter.Take();

        Assert.Single(events);
        Assert.Equal(1000, events[0].Count);
        Assert.NotNull(events[0].Trail);
        Assert.Equal(0, dropped.RateLimited);
        limiter.Record(Event(time.GetUtcNow(), "aaaaaaaaaaaaaaaa") with { Trail = [new TrailItem(0, "info", "window", "window.start")] });
        time.Advance(TimeSpan.FromHours(2));
        Assert.Null(limiter.Take().Events.Single().Trail);
    }

    [Fact]
    public void DG7_AtMostThirtyNewEventsAnHourAndTwoHundredADay()
    {
        var time = new FakeTimeProvider();
        var limiter = new DiagnosticLimiter(time);
        for (var i = 0; i < 100; i++)
        {
            limiter.Record(Event(time.GetUtcNow(), i.ToString("x16")));
            time.Advance(TimeSpan.FromSeconds(30));
        }
        limiter.Record(Event(time.GetUtcNow(), "ffffffffffffffff") with { Kind = DiagnosticKind.RunEnd, RunEnd = new RunEndDetail("clean", 60, "1.0.0") });

        var (events, dropped) = limiter.Take();

        Assert.Equal(31, events.Count);
        Assert.Equal(70, dropped.RateLimited);
        Assert.Equal(0, limiter.Take().Dropped.RateLimited);

        var day = new DiagnosticLimiter(time);
        var added = 0;
        for (var i = 0; i < 400; i++)
        {
            if (day.Record(Event(time.GetUtcNow(), (1000 + i).ToString("x16"))) == RecordOutcome.Added)
            {
                added++;
            }
            _ = day.Take();
            time.Advance(TimeSpan.FromMinutes(3));
        }
        Assert.Equal(200, added);
    }

    [Fact]
    public void TheSameFingerprintGoesOnTheWireAtMostOnceAnHour()
    {
        var time = new FakeTimeProvider();
        var limiter = new DiagnosticLimiter(time);
        limiter.Record(Event(time.GetUtcNow(), "bbbbbbbbbbbbbbbb"));
        Assert.Single(limiter.Take().Events);

        time.Advance(TimeSpan.FromMinutes(10));
        limiter.Record(Event(time.GetUtcNow(), "bbbbbbbbbbbbbbbb"));
        limiter.Record(Event(time.GetUtcNow(), "bbbbbbbbbbbbbbbb") with { Count = 4 });
        Assert.Empty(limiter.Take().Events);

        time.Advance(TimeSpan.FromMinutes(51));
        var later = limiter.Take().Events;
        Assert.Equal(5, later.Single().Count);
    }

    [Fact]
    public void AFailedRequestReturnsItsEventsWithoutLosingCounts()
    {
        var time = new FakeTimeProvider();
        var limiter = new DiagnosticLimiter(time);
        limiter.Record(Event(time.GetUtcNow(), "cccccccccccccccc"));
        var (events, dropped) = limiter.Take();
        limiter.Record(Event(time.GetUtcNow(), "cccccccccccccccc") with { Count = 2 });

        limiter.Return(events, dropped);

        Assert.Equal(3, limiter.Take().Events.Single().Count);
    }

    [Theory]
    [InlineData(0, 100, true)]
    [InlineData(99, 100, true)]
    [InlineData(49, 50, true)]
    [InlineData(50, 50, false)]
    [InlineData(0, 0, false)]
    public void SamplingKeepsADrawBelowThePercentage(int draw, int percent, bool kept)
    {
        Assert.Equal(kept, DiagnosticLimiter.SampledIn(draw, percent));
        var limiter = new DiagnosticLimiter(new FakeTimeProvider(), draw, percent);
        Assert.Equal(kept ? RecordOutcome.Added : RecordOutcome.SampledOut, limiter.Record(Event(Now, "dddddddddddddddd")));
        Assert.Equal(0, limiter.Take().Dropped.SampledOut);
    }

    [Fact]
    public void DG9_ABigBatchIsCutToSixtyKilobytesInTheOrderOfTheDesign()
    {
        var trail = Enumerable.Range(0, 20).Select(i => new TrailItem(-i, "info", "window", "window.start-" + new string('a', 40), Window: 1)).ToList();
        var events = Enumerable.Range(0, 50).Select(i => Event(Now, (i + 1).ToString("x16")) with { Trail = trail }).ToList();
        var batch = GoldenBatch() with { Events = events, Perf = [GoldenBatch().Perf[0], GoldenBatch().Perf[0]] };

        var body = DiagnosticJson.Batch(batch, new PrivateTerms(), Now);

        Assert.True(body.Body.Length <= DiagnosticFormats.SoftBodyBytes, body.Body.Length.ToString());
        Assert.Equal(50, body.Events.Count);
        Assert.Equal(2, body.PerfCount);
        Assert.True(body.Events[0].Trail is { Count: > 0 });
        Assert.Null(body.Events[^1].Trail);

        var many = Enumerable.Range(0, 80).Select(i => Event(Now, (i + 1).ToString("x16")) with { Error = new ErrorDetail("System.Exception", "caught", true, Enumerable.Range(0, 16).Select(f => "OsbManager.Very.Long.Namespace.Name.Type" + f + ".Method+IL_0001").ToList()) }).ToList();
        var cut = DiagnosticJson.Batch(batch with { Events = many }, new PrivateTerms(), Now);
        Assert.True(cut.Body.Length <= DiagnosticFormats.SoftBodyBytes);
        Assert.Equal(30 + 50 - cut.Events.Count, cut.Dropped.Oversize);
        Assert.Equal(many[49].Fingerprint, cut.Events[^1].Fingerprint);
    }

    [Fact]
    public void AnEventOverFourKilobytesLosesItsTrailAndPerSpanArraysAreCappedAndSorted()
    {
        var trail = Enumerable.Range(0, 50).Select(i => new TrailItem(-i, "info", "window", "window.start-" + new string('b', 50), Window: 2)).ToList();
        var fat = Event(Now, "eeeeeeeeeeeeeeee") with { Trail = trail };
        var bytes = DiagnosticJson.Event(fat, new PrivateTerms())!;
        var perf = GoldenBatch().Perf[0] with { WasmEach = Enumerable.Range(0, 100).Select(i => (double)(100 - i)).ToList() };

        var body = JsonNode.Parse(DiagnosticJson.Batch(GoldenBatch() with { Events = [], Perf = [perf] }, new PrivateTerms(), Now).Body)!;

        Assert.True(bytes.Length <= DiagnosticFormats.MaxEventBytes);
        Assert.Null(JsonNode.Parse(bytes)!["trail"]);
        var each = body["perf"]![0]!["wasm_mb"]!["each"]!.AsArray().Select(n => (double)n!).ToList();
        Assert.Equal(64, each.Count);
        Assert.Equal(each.Order(), each);
    }

    [Fact]
    public void InvalidValuesAreDroppedAndOldEventsAreNotSent()
    {
        var events = new[]
        {
            Event(Now, "NOT-HEX"),
            Event(Now - TimeSpan.FromDays(8), "1111111111111111"),
            Event(Now, "2222222222222222") with { Kind = DiagnosticKind.ProcessFailed, Error = null, Process = new ProcessDetail("render_process_exited", "Out Of Memory", "0x1") },
            Event(Now, "3333333333333333") with { Context = new DiagnosticContext { Phase = "Canary phase text", Window = 99, LoginStage = "credentials" } },
        };

        var body = DiagnosticJson.Batch(GoldenBatch() with { Events = events, Perf = [] }, new PrivateTerms(), Now);

        var single = Assert.Single(body.Events);
        Assert.Equal("other", single.Context!.Phase);
        Assert.Null(single.Context.Window);
        Assert.Equal("credentials", single.Context.LoginStage);
    }

    [Fact]
    public void APendingEventRoundTripsAndIsScrubbedAgainOnTheWay()
    {
        var golden = GoldenBatch();
        foreach (var e in golden.Events)
        {
            var bytes = DiagnosticJson.Event(e, new PrivateTerms())!;
            var parsed = DiagnosticJson.ParseEvent(bytes)!;
            Assert.Equal(Encoding.UTF8.GetString(bytes), Encoding.UTF8.GetString(DiagnosticJson.Event(parsed, new PrivateTerms())!));
        }
        Assert.Null(DiagnosticJson.ParseEvent("{\"kind\":\"nope\"}"u8));
        Assert.Null(DiagnosticJson.ParseEvent("not json"u8));
    }

    [Fact]
    public void PendingFilesAreCappedExpireAndAreNeverWrittenWithoutConsent()
    {
        using var directory = new TempDirectory();
        var time = new FakeTimeProvider();
        var consent = true;
        var pending = new PendingDiagnostics(Path.Combine(directory.Path, "diagnostics"), time, () => consent);

        for (var i = 0; i < 14; i++)
        {
            Assert.True(pending.Write(Encoding.UTF8.GetBytes("{\"n\":" + i + "}")));
            time.Advance(TimeSpan.FromMinutes(1));
        }
        Assert.False(pending.Write(new byte[PendingDiagnostics.MaxFileBytes + 1]));
        Assert.Equal(10, pending.Count());
        var loaded = pending.Load();
        Assert.Equal("{\"n\":4}", Encoding.UTF8.GetString(loaded[0].Content));

        pending.Delete(loaded[0].Id);
        pending.Delete(@"..\privacy.json");
        Assert.Equal(9, pending.Count());

        time.Advance(TimeSpan.FromDays(7));
        Assert.Empty(pending.Load());
        Assert.Equal(0, pending.Count());

        consent = false;
        Assert.False(pending.Write("{}"u8.ToArray()));
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(directory.Path, "diagnostics")));
    }

    [Fact]
    public void ThePrivateTermsSetIgnoresShortTermsEvictsTheOldestAndKeepsTheMachineTerms()
    {
        var terms = PrivateTerms.ForMachine(CanaryUser, CanaryMachine, null, @"D:\Data\Osb");
        terms.Add("ab");
        terms.Add("   ");
        for (var i = 0; i < PrivateTerms.Capacity + 5; i++)
        {
            terms.Add("Term" + i.ToString("D5"));
        }

        Assert.False(terms.Hits("xxabxx"));
        Assert.False(terms.Hits("Term00000"));
        Assert.True(terms.Hits("Term02004"));
        Assert.True(terms.Hits("hello " + CanaryUser.ToUpperInvariant()));
        Assert.True(terms.Hits(@"d:\data\osb\x"));
        Assert.True(terms.Hits(CanaryMachine.ToLowerInvariant()));
    }

    [Fact]
    public void PageStringsAndProcessDescriptionsMapToFixedCodes()
    {
        Assert.Equal("render_process_exited", DiagnosticScrubber.ProcessKind("RenderProcessExited"));
        Assert.Equal("unknown_process_exited", DiagnosticScrubber.ProcessKind("SomethingNew"));
        Assert.Equal("out_of_memory", DiagnosticScrubber.ProcessReason("OutOfMemory"));
        Assert.Equal("network-service", DiagnosticScrubber.ProcessDescription("Network Service"));
        Assert.Null(DiagnosticScrubber.ProcessDescription(@"C:\Users\" + CanaryUser + @"\plugin.dll"));
        Assert.Equal("device-lost", DiagnosticScrubber.GpuFailure("GPU device was lost"));
        Assert.Equal("other", DiagnosticScrubber.GpuFailure("Canary text " + CanaryPlayer));
        Assert.Equal("other", DiagnosticScrubber.Phase("Canary"));
        Assert.Equal("world", DiagnosticScrubber.Phase("world"));
        Assert.Equal("0xFFFFFFFB", DiagnosticFormats.ExitCode(-5));
        Assert.Equal("0xE0000008", DiagnosticFormats.ExitCode(unchecked((int)0xE0000008)));
        Assert.Equal(16, DiagnosticFormats.RamBucket(17_000_000_000L));
        Assert.Equal(8, DiagnosticFormats.CoreBucket(12));
        Assert.Matches("^[0-9a-f]{16}$", DiagnosticFormats.NewRunKey());
    }

    private static DiagnosticEvent Event(DateTimeOffset at, string fingerprint) => new()
    {
        Kind = DiagnosticKind.DotnetException,
        Fingerprint = fingerprint,
        At = at,
        Error = new ErrorDetail("System.Exception", "caught", true, ["OsbManager.X.Y+IL_0001"]),
    };

    private static DiagnosticBatch Single(DiagnosticKind kind, Func<DiagnosticEvent, DiagnosticEvent> shape) =>
        GoldenBatch() with { Events = [shape(Event(Now, "abcdefabcdefabcd") with { Kind = kind, Error = null })], Perf = [] };

    private static string NoScrubberJson(DiagnosticBatch batch) => System.Text.Json.JsonSerializer.Serialize(batch.Events);

    private static Exception Thrown(Action action)
    {
        try
        {
            action();
        }
        catch (Exception e)
        {
            return e;
        }
        throw new InvalidOperationException("Nothing was thrown.");
    }

    private static void Deep(int depth)
    {
        if (depth == 0)
        {
            throw new InvalidOperationException("deep");
        }
        Deep(depth - 1);
    }

    private sealed class CanaryLeakException(string message) : Exception(message);
}
