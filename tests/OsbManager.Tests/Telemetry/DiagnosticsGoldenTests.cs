using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class DiagnosticsGoldenTests
{
    private const string GoldenPath = "DIAGNOSTICS.md 9.2";

    private static JsonNode Golden() => JsonNode.Parse(GoldenText)!;

    private const string GoldenText = """
        {
          "schema": 1,
          "app": "manager-win",
          "app_version": "1.4.2",
          "run": "3e5c0b1a9d7f2c64",
          "env": { "os_build": "10.0.26100", "webview2": "131.0.2903.70", "dotnet": "10.0.1", "ram_gb": 16, "cores": 8, "gpu_vendor": "nvidia" },
          "events": [
            {
              "kind": "process_failed", "source": "manager", "fp": "5b0e2a9c41d7f308", "at": "2026-11-12T14:20:00Z", "count": 1,
              "process": { "kind": "render_process_exited", "reason": "out_of_memory", "exit_code": "0xE0000008" },
              "context": { "phase": "world", "login_stage": "done", "window": 3, "windows": 4, "light": false, "hidden": true, "uptime_s": 7260 },
              "trail": [
                { "s": -600, "l": "info", "c": "window", "k": "window.start", "w": 3 },
                { "s": -95, "l": "warn", "c": "gpu", "k": "gpu.retry", "w": 3, "n": 2 },
                { "s": 0, "l": "error", "c": "window", "k": "window.renderer-exited", "w": 3 }
              ]
            },
            {
              "kind": "dotnet_exception", "source": "manager", "fp": "a41c09e7b23d5f16", "at": "2026-11-12T14:22:00Z", "count": 3,
              "error": {
                "type": "System.InvalidOperationException", "hresult": "0x80131509", "inner": [], "handled": true, "origin": "caught",
                "frames": [ "OsbManager.Browser.GameWindow.OnWebMessage+IL_01A3", "System.Text.Json.JsonDocument.Parse+IL_0042", "ext" ]
              },
              "context": { "phase": "world", "window": 1, "windows": 4, "light": true, "hidden": false, "uptime_s": 7380 }
            },
            {
              "kind": "run_end", "source": "manager", "fp": "0c8d1e2f3a4b5c6d", "at": "2026-11-12T12:00:00Z", "count": 1,
              "run_end": { "outcome": "unclean", "uptime_s": 10800, "previous_version": "1.4.1" }
            }
          ],
          "perf": [
            {
              "at": "2026-11-12T14:00:00Z", "span_s": 1800, "samples": 30,
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

    private static JsonNode Shape(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => KeyValuePair.Create(p.Key, (JsonNode?)Shape(p.Value)))),
        JsonArray a => a.Count == 0 ? new JsonArray() : new JsonArray(Merge(a.Select(Shape).ToList())),
        JsonValue v => JsonValue.Create(v.GetValueKind() switch
        {
            System.Text.Json.JsonValueKind.String => "string",
            System.Text.Json.JsonValueKind.Number => "number",
            _ => "boolean",
        })!,
        _ => JsonValue.Create("null")!,
    };

    private static JsonNode Merge(List<JsonNode> shapes)
    {
        if (shapes[0] is not JsonObject)
        {
            return shapes[0].DeepClone();
        }
        var keys = shapes.SelectMany(s => s.AsObject().Select(p => p.Key)).Distinct().Order(StringComparer.Ordinal);
        return new JsonObject(keys.Select(key => KeyValuePair.Create(key, (JsonNode?)Merge(shapes.Select(s => s.AsObject()[key]).Where(n => n is not null).Select(n => n!).ToList()))));
    }

    [Fact]
    public void TheGoldenBatchPassesTheServerParserRules()
    {
        Assert.Empty(DiagnosticsServerRules.Check(Golden()));
    }

    [Fact]
    public void TheRulesCheckerCatchesWhatTheServerRejects()
    {
        var bad = Golden();
        bad["events"]![0]!["fp"] = "0000000000000000";
        bad["events"]![1]!["context"]!["uptime_s"] = 7381;
        bad["events"]![1]!["error"]!["template"] = null;
        bad["events"]![0]!["extra"] = 1;
        bad["perf"]![0]!["mem_mb"]!["renderer"]!["each"] = new JsonArray(690, 380);
        bad["perf"]![0]!["cpu_pct"]!["gpu"] = 18.45;

        var problems = DiagnosticsServerRules.Check(bad);

        Assert.Contains(problems, p => p.Contains("fp"));
        Assert.Contains(problems, p => p.Contains("multiple of 60"));
        Assert.Contains(problems, p => p.Contains("is null"));
        Assert.Contains(problems, p => p.Contains("unknown field extra"));
        Assert.Contains(problems, p => p.Contains("sorted"));
        Assert.Contains(problems, p => p.Contains("one decimal"));
    }

    [Fact]
    public async Task DG22_TheGoldenManagerBatchIsBuiltEndToEndFromCapturedEvents()
    {
        using var dir = new TempDirectory();
        var time = new FakeTimeProvider();
        using (var killed = DiagnosticsKit.Granted(root: dir.Path, time: time))
        {
            killed.Service.Capture.Start();
            killed.Drain();
            time.Advance(TimeSpan.FromMinutes(180));
            killed.Service.Capture.SampleOnce();
        }
        time.Advance(TimeSpan.FromMinutes(2));

        using var kit = DiagnosticsKit.Granted(root: dir.Path, time: time, grant: false);
        kit.Store.StoreConfig(kit.Store.Credentials!.Id, TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes(FakeServer.ConfigWithDiagnostics()))!);
        kit.Service.ConfigureDiagnostics(new FakePerfSource(), null);
        kit.Service.Capture.RequestPageMemory = () => kit.Service.Perf.SetPageMemory([166, 118, 131, 140], [210, 150, 160, 170], [512, 256, 256, 256]);
        kit.Service.Capture.Start();
        kit.Drain();
        for (var minute = 0; minute < 30; minute++)
        {
            time.Advance(TimeSpan.FromSeconds(60));
            kit.Service.Capture.SampleOnce();
        }
        Assert.Equal(1, kit.Service.Perf.ReadyCount);

        var capture = kit.Service.Capture;
        capture.Trail("info", TrailCodes.WindowStart, 3);
        capture.Trail("warn", TrailCodes.GpuRetry, 3);
        capture.Trail("warn", TrailCodes.GpuRetry, 3);
        capture.Trail("error", TrailCodes.WindowRendererExited, 3);
        capture.ProcessFailed(
            "RenderProcessExited",
            "OutOfMemory",
            unchecked((int)0xE0000008),
            "Renderer",
            new DiagnosticContext { Phase = "world", LoginStage = "done", Window = 3, Windows = 4, Light = false, Hidden = true });
        try
        {
            throw new InvalidOperationException("never sent");
        }
        catch (InvalidOperationException e)
        {
            capture.Exception(e, "caught", true, new DiagnosticContext { Phase = "world", Window = 1, Windows = 4, Light = true, Hidden = false });
        }
        kit.Drain();
        var rotation = kit.Service.PageBatches.Rotation;
        rotation.Present(1, time.GetUtcNow());
        kit.Service.TickOsbPerf();
        Assert.NotEqual(0, rotation.Wanted(1, time.GetUtcNow()));
        var entry = Golden()["osb_perf"]![0]!.DeepClone().AsObject();
        entry.Remove("app_version");
        entry["at"] = DiagnosticFormats.MinuteText(time.GetUtcNow().AddMinutes(-30));
        var answer = new JsonObject { ["type"] = OsbPageBatch.PerfType, ["perf"] = entry };
        Assert.True(kit.Service.PageBatches.OfferPerf(answer.ToJsonString(), 1, "2.0.14"));
        Assert.True(kit.Service.PageBatches.Drain(TimeSpan.FromSeconds(10)));

        await kit.RunFor(TimeSpan.FromMinutes(14), startService: true);

        var body = kit.DiagnosticBodies().First();
        var actual = Shape(body);
        var expected = Shape(Golden());
        Assert.True(JsonNode.DeepEquals(expected, actual), $"Shape differs from {GoldenPath}.\nExpected {expected.ToJsonString()}\nActual   {actual.ToJsonString()}");
        Assert.Empty(DiagnosticsServerRules.Check(body));
        Assert.Equal("manager-win", body["app"]!.GetValue<string>());
        Assert.Equal(1, body["schema"]!.GetValue<int>());
        var kinds = body["events"]!.AsArray().Select(e => e!["kind"]!.GetValue<string>()).Order().ToArray();
        Assert.Equal(["dotnet_exception", "process_failed", "run_end"], kinds);
        var failed = body["events"]!.AsArray().Single(e => e!["kind"]!.GetValue<string>() == "process_failed")!;
        Assert.Equal("0xE0000008", failed["process"]!["exit_code"]!.GetValue<string>());
        Assert.Equal(3, failed["trail"]!.AsArray().Count);
        Assert.Equal(2, failed["trail"]![1]!["n"]!.GetValue<int>());
        Assert.Equal(180 * 60, body["events"]!.AsArray().Single(e => e!["kind"]!.GetValue<string>() == "run_end")!["run_end"]!["uptime_s"]!.GetValue<int>());
        var osbPerf = Assert.Single(body["osb_perf"]!.AsArray())!;
        Assert.Equal("2.0.14", osbPerf["app_version"]!.GetValue<string>());
        Assert.Equal(912.0, osbPerf["gap_ms"]!["max"]!.GetValue<double>());
    }

    [Fact]
    public void EveryKindOfBatchMeetsTheServerRulesIncludingTheMemoryAndCpuNumbers()
    {
        var now = new DateTimeOffset(2026, 11, 12, 14, 30, 0, TimeSpan.Zero);
        var terms = PrivateTerms.ForMachine("CanaryWinUser", "CANARY-PC", "CANARY-DOMAIN", @"C:\x\y");
        DiagnosticEvent Event(DiagnosticKind kind, string fp) => new() { Kind = kind, Fingerprint = fp, At = now.AddSeconds(-37), Count = 7, Context = new DiagnosticContext { Phase = "world", Window = 2, Windows = 3, UptimeSeconds = 7255 } };
        var batch = new DiagnosticBatch
        {
            AppVersion = "1.4.2",
            Run = "3e5c0b1a9d7f2c64",
            Env = new DiagnosticEnv("10.0.26100", "131.0.2903.70", "10.0.1", 16, 8, "unknown"),
            Events =
            [
                Event(DiagnosticKind.ProcessFailed, "5b0e2a9c41d7f308") with { Process = new ProcessDetail("gpu_process_exited", "crashed", "0x5", "gpu-process") },
                Event(DiagnosticKind.Unresponsive, "1b0e2a9c41d7f308") with { Hang = new HangDetail("gave_up", 90) },
                Event(DiagnosticKind.GpuFailed, "2b0e2a9c41d7f308") with { Gpu = new GpuDetail("device-lost", 3) },
                Event(DiagnosticKind.DotnetException, "3b0e2a9c41d7f308") with { Error = new ErrorDetail("System.IO.IOException", "ui_thread", false, ["OsbManager.UI.MainForm.RefreshMemory+IL_0010", "ext"], ["System.Exception"], "0x80070005") },
                Event(DiagnosticKind.RunEnd, "4b0e2a9c41d7f308") with { RunEnd = new RunEndDetail("crash", 7255, "1.4.1") },
            ],
            Perf =
            [
                new PerfEntry
                {
                    At = now.AddMinutes(-31),
                    SpanSeconds = 1800,
                    Samples = 30,
                    Windows = new PerfWindows(4, 2, 1, 4),
                    Memory = new PerfMemory { Renderer = new RoleMemory(412.4, 690.6), RendererEach = [690.2, 380.7], Gpu = new RoleMemory(300, 344), BrowserTotal = new RoleMemory(2150.5, 2480), App = new RoleMemory(95, 101) },
                    JsHeapUsedEach = [166.4, 118.2],
                    JsHeapTotalEach = [210, 150],
                    WasmEach = [512, 256],
                    Cpu = new PerfCpu { RendererEach = [31.234, 12.049], Gpu = 18.449, BrowserTotal = 92.35, App = 1.04 },
                },
            ],
            Dropped = new DroppedCounts(3, 0, 0),
        };

        var body = JsonNode.Parse(DiagnosticJson.Batch(batch, terms, now).Body)!;

        Assert.Empty(DiagnosticsServerRules.Check(body));
        Assert.Equal(5, body["events"]!.AsArray().Count);
        Assert.Single(body["perf"]!.AsArray());
    }
}
