using System.Text;
using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class OsbPerfRotationTests
{
    private static readonly TimeSpan Span = TimeSpan.FromMinutes(30);
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-12T15:00:00Z");

    private static JsonObject PerfEntry(DateTimeOffset at) => new()
    {
        ["at"] = DiagnosticFormats.MinuteText(at),
        ["span_s"] = 1800,
        ["samples"] = 30,
        ["js_heap_mb"] = new JsonObject { ["used"] = 131, ["total"] = 160 },
        ["tick_ms"] = new JsonObject { ["p50"] = 1.2, ["p95"] = 3.0, ["p99"] = 8.4, ["max"] = 41.0, ["late_pct"] = 0.3 },
        ["gap_ms"] = new JsonObject { ["p50"] = 100.1, ["p95"] = 104.5, ["p99"] = 180.2, ["max"] = 950.0, ["late_pct"] = 0.4 },
        ["long_tasks"] = new JsonObject { ["count"] = 3, ["total_ms"] = 412.0 },
    };

    private static string Answer(DateTimeOffset at) => new JsonObject { ["type"] = OsbPageBatch.PerfType, ["perf"] = PerfEntry(at) }.ToJsonString();

    private static OsbPerfRotation Present(DateTimeOffset now, params int[] windows)
    {
        var rotation = new OsbPerfRotation();
        foreach (var window in windows)
        {
            rotation.Present(window, now);
        }
        return rotation;
    }

    private static int[] Asked(OsbPerfRotation rotation, DateTimeOffset now, params int[] windows) =>
        windows.Where(w => rotation.Wanted(w, now) != 0).ToArray();

    [Fact]
    public void OneWindowIsAskedPerSpanAndTheWindowsTakeTurns()
    {
        var now = Start;
        var rotation = Present(now, 1, 2, 3);
        var asked = new List<int>();
        for (var span = 0; span < 4; span++)
        {
            rotation.Tick(now, Span, enabled: true);
            var wanted = Asked(rotation, now, 1, 2, 3);
            var single = Assert.Single(wanted);
            asked.Add(single);
            Assert.True(rotation.Accept(single, now + TimeSpan.FromMinutes(29)));
            Assert.Empty(Asked(rotation, now + TimeSpan.FromMinutes(29), 1, 2, 3));
            rotation.Tick(now + TimeSpan.FromMinutes(10), Span, enabled: true);
            Assert.Empty(Asked(rotation, now + TimeSpan.FromMinutes(10), 1, 2, 3));
            now += Span;
            foreach (var window in new[] { 1, 2, 3 })
            {
                rotation.Present(window, now);
            }
        }
        Assert.Equal([1, 2, 3, 1], asked);
    }

    [Fact]
    public void AWindowThatNeverAnswersIsSkippedInTheNextSpanAndStopsAfterTheGrace()
    {
        var rotation = Present(Start, 1, 2);
        rotation.Tick(Start, Span, enabled: true);
        Assert.Equal([1], Asked(rotation, Start, 1, 2));

        var next = Start + Span;
        rotation.Present(1, next);
        rotation.Present(2, next);
        rotation.Tick(next, Span, enabled: true);

        Assert.NotEqual(0, rotation.Wanted(2, next));
        Assert.NotEqual(0, rotation.Wanted(1, next));
        var afterGrace = next + OsbPerfRotation.AnswerGrace;
        Assert.Equal([2], Asked(rotation, afterGrace, 1, 2));
        Assert.False(rotation.Accept(1, afterGrace), "a late answer after the grace is not taken");
    }

    [Fact]
    public void NothingIsAskedWhilePerfIsOffOrNoWindowHasOsb()
    {
        var rotation = Present(Start, 1, 2);
        rotation.Tick(Start, Span, enabled: false);
        Assert.Empty(Asked(rotation, Start, 1, 2));
        rotation.Tick(Start, Span, enabled: true);
        Assert.Single(Asked(rotation, Start, 1, 2));
        rotation.Tick(Start + TimeSpan.FromMinutes(1), Span, enabled: false);
        Assert.Empty(Asked(rotation, Start + TimeSpan.FromMinutes(1), 1, 2));

        var stale = Present(Start, 1);
        stale.Tick(Start + OsbPerfRotation.PresentFor, Span, enabled: true);
        Assert.Equal(0, stale.Wanted(1, Start + OsbPerfRotation.PresentFor));
        stale.Gone(1);
        Assert.Equal(0, stale.Wanted(null, Start));
    }

    [Fact]
    public void ASingleWindowIsAskedAgainEachSpanEvenWhenItAnswersLate()
    {
        var rotation = Present(Start, 1);
        rotation.Tick(Start, Span, enabled: true);
        var first = rotation.Wanted(1, Start);
        var next = Start + Span;
        rotation.Present(1, next);
        rotation.Tick(next, Span, enabled: true);
        var second = rotation.Wanted(1, next);
        Assert.NotEqual(first, second);

        Assert.True(rotation.Accept(1, next + TimeSpan.FromSeconds(50)), "the late answer for the first span");
        var renewed = rotation.Wanted(1, next + TimeSpan.FromSeconds(50));
        Assert.NotEqual(0, renewed);
        Assert.NotEqual(second, renewed);
        Assert.True(rotation.Accept(1, next + Span - TimeSpan.FromMinutes(1)));
        Assert.False(rotation.Accept(1, next + Span - TimeSpan.FromMinutes(1)), "one answer per ask");
    }

    [Fact]
    public void ThePerfAnswerParsesStrictlyInTheOsbShape()
    {
        var entry = OsbPageBatch.ParsePerf(Answer(Start), Start);
        Assert.NotNull(entry);
        Assert.Equal(131, entry.JsHeapUsed);
        Assert.Equal(1.2, entry.Tick!.P50);
        Assert.Equal(3, entry.LongTasks!.Count);

        string Broken(Action<JsonObject> change)
        {
            var perf = PerfEntry(Start);
            change(perf);
            return new JsonObject { ["type"] = OsbPageBatch.PerfType, ["perf"] = perf }.ToJsonString();
        }
        var broken = new[]
        {
            Broken(p => p["windows"] = new JsonObject { ["open"] = 1, ["light"] = 0, ["hidden"] = 0, ["in_world"] = 1 }),
            Broken(p => p["js_heap_mb"] = new JsonObject { ["used_each"] = new JsonArray(1, 2) }),
            Broken(p => p["mem_mb"] = new JsonObject()),
            Broken(p => p["tick_ms"]!["p50"] = 1.25),
            Broken(p => p["tick_ms"]!["late_pct"] = 101),
            Broken(p => p["js_heap_mb"]!["used"] = 131.5),
            Broken(p => p["samples"] = 0),
            Broken(p => p["span_s"] = 30),
            Broken(p => p["at"] = "2026-11-12T15:00:30Z"),
            Broken(p => p["long_tasks"]!["total_ms"] = null),
            Broken(p => p["extra"] = 1),
            Broken(p => p.Remove("samples")),
            Broken(p => p["tick_ms"]!.AsObject().Remove("max")),
            new JsonObject { ["type"] = OsbPageBatch.PerfType, ["perf"] = PerfEntry(Start), ["events"] = new JsonArray() }.ToJsonString(),
            new JsonObject { ["type"] = OsbPageBatch.PerfType }.ToJsonString(),
            new JsonObject { ["type"] = OsbPageBatch.BatchType, ["perf"] = PerfEntry(Start) }.ToJsonString(),
            Answer(Start)[..^1] + ",\"perf\":{}}",
            Answer(Start)[..^2] + ",\"pad\":\"" + new string('x', 2048) + "\"}}",
        };
        foreach (var text in broken)
        {
            Assert.Null(OsbPageBatch.ParsePerf(text, Start));
        }
    }

    [Fact]
    public async Task TheAskedWindowsAnswerRidesInTheNextBatchAsOsbPerfWithItsOsbVersion()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        await kit.RunFor(TimeSpan.FromMinutes(3));
        var now = kit.Time.GetUtcNow();
        var rotation = kit.Service.PageBatches.Rotation;
        rotation.Present(1, now);
        rotation.Present(2, now);
        kit.Service.TickOsbPerf();
        var asked = new[] { 1, 2 }.Single(w => rotation.Wanted(w, now) != 0);
        var other = asked == 1 ? 2 : 1;

        Assert.True(kit.Service.PageBatches.OfferPerf(Answer(now), other, "2.0.14"));
        Assert.True(kit.Service.PageBatches.OfferPerf(Answer(now), asked, "2.0.14"));
        Assert.True(kit.Service.PageBatches.OfferPerf(Answer(now), asked, "2.0.14"));
        Assert.True(kit.Service.PageBatches.Drain(TimeSpan.FromSeconds(10)));
        var counts = kit.Service.PageBatches.Counts;
        Assert.Equal(1, counts.PerfAccepted);
        Assert.Equal(2, counts.PerfNotAsked);

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(kit.DiagnosticBodies());
        var osbPerf = Assert.Single(body["osb_perf"]!.AsArray())!.AsObject();
        Assert.Equal("2.0.14", osbPerf["app_version"]!.GetValue<string>());
        Assert.Equal(41.0, osbPerf["tick_ms"]!["max"]!.GetValue<double>());
        Assert.Equal(131, osbPerf["js_heap_mb"]!["used"]!.GetValue<int>());
        Assert.False(body.AsObject().ContainsKey("perf"));
        Assert.Empty(DiagnosticsServerRules.Check(body));
        Assert.Null(kit.Service.Diagnostics.PeekOsbPerf());
    }

    [Fact]
    public async Task NoOsbPerfIsAskedForKeptOrSentWhileTheConfigPerfFlagIsOff()
    {
        using var kit = DiagnosticsKit.Granted(FakeServer.ConfigWithDiagnostics(perf: false));
        kit.Service.Capture.Start();
        await kit.RunFor(TimeSpan.FromMinutes(3));
        var now = kit.Time.GetUtcNow();
        var rotation = kit.Service.PageBatches.Rotation;
        rotation.Present(1, now);
        kit.Service.TickOsbPerf();
        Assert.Equal(0, rotation.Wanted(1, now));
        Assert.True(kit.Service.PageBatches.OfferPerf(Answer(now), 1, "2.0.14"));
        Assert.True(kit.Service.PageBatches.Drain(TimeSpan.FromSeconds(10)));
        Assert.Equal(1, kit.Service.PageBatches.Counts.PerfNotAsked);

        kit.Service.Diagnostics.KeepOsbPerf(new OsbPerfEntry(OsbPageBatch.ParsePerf(Answer(now), now)!, "2.0.14"));
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 1, null, DiagnosticsKit.Window());
        kit.Drain();
        await kit.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(kit.DiagnosticBodies());
        Assert.Null(body["osb_perf"]);
        Assert.Empty(DiagnosticsServerRules.Check(body));
    }

    [Fact]
    public async Task AnOsbVersionHoldingAPrivateTermOrNotAVersionIsRefused()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        kit.Service.Capture.Learn("CanaryHeroQd");
        kit.Drain();
        await kit.RunFor(TimeSpan.FromMinutes(3));
        var now = kit.Time.GetUtcNow();
        var rotation = kit.Service.PageBatches.Rotation;
        foreach (var (window, version) in new[] { (1, "CanaryHeroQd"), (2, "2.0 beta") })
        {
            rotation.Present(window, now);
            rotation.Tick(now, Span, enabled: false);
            rotation.Present(window, now);
            kit.Service.TickOsbPerf();
            Assert.NotEqual(0, rotation.Wanted(window, now));
            Assert.True(kit.Service.PageBatches.OfferPerf(Answer(now), window, version));
            Assert.True(kit.Service.PageBatches.Drain(TimeSpan.FromSeconds(10)));
            rotation.Gone(window);
        }
        Assert.Equal(2, kit.Service.PageBatches.Counts.Invalid);
        Assert.Null(kit.Service.Diagnostics.PeekOsbPerf());
    }

    [Fact]
    public void AnAnswerOver2KbIsDroppedBeforeItIsQueued()
    {
        using var kit = DiagnosticsKit.Granted();
        var text = Answer(kit.Time.GetUtcNow())[..^2] + ",\"pad\":\"" + new string('x', 2048) + "\"}}";
        Assert.True(Encoding.UTF8.GetByteCount(text) > OsbPageBatch.MaxPerfBytes);
        Assert.False(kit.Service.PageBatches.OfferPerf(text, 1, "2.0.14"));
        Assert.Equal(1, kit.Service.PageBatches.Counts.Oversize);
    }
}
