using System.Text;
using System.Text.Json.Nodes;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class OsbPageBatchTests
{
    private const string Hero = "CanaryHeroQd";

    private static string MinuteOf(DateTimeOffset now) => DiagnosticFormats.MinuteText(now);

    private static JsonObject ErrorEvent(DateTimeOffset now, string fp = "3a91c2d4e5f60718", string template = "Cannot read properties of <q> (reading <q>)") => new()
    {
        ["kind"] = "js_error",
        ["source"] = "osb",
        ["fp"] = fp,
        ["at"] = MinuteOf(now),
        ["count"] = 3,
        ["error"] = new JsonObject
        {
            ["type"] = "TypeError",
            ["template"] = template,
            ["module"] = "quest",
            ["handled"] = true,
            ["origin"] = "guard",
            ["frames"] = new JsonArray("Quest.observe@14210:31", "Controller.guard@12018:20", "ext"),
        },
        ["context"] = new JsonObject { ["phase"] = "world", ["mode"] = "town", ["town_phase"] = "walk-vendor", ["dead"] = false, ["uptime_s"] = 3600 },
        ["trail"] = new JsonArray(
            new JsonObject { ["s"] = -42, ["l"] = "info", ["c"] = "town", ["k"] = "operation-start" },
            new JsonObject { ["s"] = -3, ["l"] = "warn", ["c"] = "movement", ["k"] = "legacy", ["e"] = "travel-error", ["n"] = 2, ["d"] = new JsonObject { ["distance"] = 12.5, ["attempt"] = 2, ["choice"] = true } }),
    };

    private static JsonObject StopEvent(DateTimeOffset now) => new()
    {
        ["kind"] = "bot_stop",
        ["source"] = "osb",
        ["fp"] = "5b7d9f1a2c3e4d60",
        ["at"] = MinuteOf(now),
        ["count"] = 1,
        ["stop"] = new JsonObject { ["code"] = "stuck-no-progress", ["source"] = "stop" },
        ["context"] = new JsonObject { ["phase"] = "world", ["mode"] = "hunting", ["dead"] = false, ["uptime_s"] = 3600 },
    };

    private static JsonObject WarnEvent(DateTimeOffset now) => new()
    {
        ["kind"] = "warn",
        ["source"] = "osb",
        ["fp"] = "6c8e0a2b4d6f8091",
        ["at"] = MinuteOf(now),
        ["count"] = 7,
        ["warn"] = new JsonObject
        {
            ["category"] = "combat",
            ["code"] = "legacy",
            ["error_class"] = "timeout",
            ["refusal"] = new JsonObject { ["source"] = "cast", ["reason"] = "cooldown-or-action-recovery", ["native"] = 12293 },
        },
    };

    private static JsonObject Message(params JsonObject[] events) => new() { ["type"] = OsbPageBatch.BatchType, ["events"] = new JsonArray(events) };

    private static JsonObject Valid(DateTimeOffset now) => Message(ErrorEvent(now), StopEvent(now), WarnEvent(now));

    private static string Text(JsonNode node) => node.ToJsonString();

    [Fact]
    public void AWellFormedOsbBatchParsesIntoOsbEvents()
    {
        var now = DateTimeOffset.Parse("2026-11-12T15:00:30Z");
        var events = OsbPageBatch.Parse(Text(Valid(now)), now);

        Assert.NotNull(events);
        Assert.Equal([DiagnosticKind.JsError, DiagnosticKind.BotStop, DiagnosticKind.Warn], events.Select(e => e.Kind));
        Assert.All(events, e => Assert.Equal(DiagnosticSource.Osb, e.Source));
        Assert.Equal("Cannot read properties of <q> (reading <q>)", events[0].Error!.Template);
        Assert.Equal(2, events[0].Trail!.Count);
        Assert.Equal(12.5, events[0].Trail![1].Numbers!["distance"]);
        Assert.Equal(12293, events[2].Warn!.Refusal!.Native);
        Assert.Null(events[0].Context!.Window);
    }

    [Fact]
    public void TheTypeIsRecognisedInEitherKeyOrderWithoutParsing()
    {
        Assert.True(OsbPageBatch.IsBatch("""{"type":"osb-diagnostics-batch","events":[]}"""));
        Assert.True(OsbPageBatch.IsBatch("""{"events":[],"type":"osb-diagnostics-batch"}"""));
        Assert.False(OsbPageBatch.IsBatch("""{"type":"status","bot":"osb-diagnostics-batch"}"""));
        Assert.False(OsbPageBatch.IsBatch("""{"type":"osb-diagnostics","on":true}"""));
        Assert.False(OsbPageBatch.IsBatch(null));
        Assert.Equal("""{"type":"osb-diagnostics","on":true,"perf":false}""", OsbPageBatch.Switch(true));
        Assert.Equal("""{"type":"osb-diagnostics","on":true,"perf":true}""", OsbPageBatch.Switch(true, perf: true));
        Assert.Equal("""{"type":"osb-diagnostics","on":false}""", OsbPageBatch.Switch(false, perf: true));
        Assert.True(OsbPageBatch.IsPerf("""{"type":"osb-diagnostics-perf","perf":{}}"""));
        Assert.True(OsbPageBatch.IsPerf("""{"perf":{},"type":"osb-diagnostics-perf"}"""));
        Assert.False(OsbPageBatch.IsPerf("""{"type":"osb-diagnostics-batch","events":[]}"""));
        Assert.False(OsbPageBatch.IsBatch("""{"type":"osb-diagnostics-perf","perf":{}}"""));
        Assert.Equal("""{"type":"osb-diagnostics","on":false}""", OsbPageBatch.Switch(false));
    }

    public static TheoryData<string> Broken() =>
    [
        "wrong source",
        "manager source on a js_error",
        "unknown top-level field",
        "perf field",
        "dropped field",
        "unknown event field",
        "unknown error field",
        "hresult from the page",
        "manager origin",
        "unknown context field",
        "window in context",
        "unknown trail field",
        "window in trail",
        "goldChange in details",
        "null event field",
        "null optional field",
        "null event",
        "duplicate property",
        "eleven events",
        "no events",
        "reserved fingerprint",
        "uppercase fingerprint",
        "seconds in at",
        "at a week old",
        "decimal count",
        "zero count",
        "uptime not a multiple of 60",
        "two decimals in details",
        "control character",
        "lone surrogate",
        "process_failed kind",
        "stop object on an error",
        "bad mode",
        "bad stop source",
        "template with forbidden characters",
        "seventeen frames",
        "twenty-one trail entries",
        "wrong type",
        "comment",
        "trailing comma",
    ];

    [Theory]
    [MemberData(nameof(Broken))]
    public void TheStrictParserRejectsTheWholeMessage(string broken)
    {
        var now = DateTimeOffset.Parse("2026-11-12T15:00:30Z");
        var message = Valid(now);
        var first = message["events"]![0]!.AsObject();
        var error = first["error"]!.AsObject();
        var text = (string?)null;
        switch (broken)
        {
            case "wrong source": message["events"]![1]!["source"] = "server"; break;
            case "manager source on a js_error": first["source"] = "manager"; break;
            case "unknown top-level field": message["extra"] = 1; break;
            case "perf field": message["perf"] = new JsonObject { ["at"] = MinuteOf(now), ["span_s"] = 1800, ["samples"] = 30 }; break;
            case "dropped field": message["dropped"] = new JsonObject { ["rate_limited"] = 1 }; break;
            case "unknown event field": first["name"] = "x"; break;
            case "unknown error field": error["message"] = "x"; break;
            case "hresult from the page": error["hresult"] = "0x80004005"; break;
            case "manager origin": error["origin"] = "caught"; break;
            case "unknown context field": first["context"]!["character"] = "x"; break;
            case "window in context": first["context"]!["window"] = 3; break;
            case "unknown trail field": first["trail"]![0]!["text"] = "x"; break;
            case "window in trail": first["trail"]![0]!["w"] = 1; break;
            case "goldChange in details": first["trail"]![1]!["d"]!["goldChange"] = 10; break;
            case "null event field": first["count"] = null; break;
            case "null optional field": error["module"] = null; break;
            case "null event": message["events"]!.AsArray().Add(null); break;
            case "duplicate property": text = Text(message).Replace("\"count\":3,", "\"count\":3,\"count\":4,", StringComparison.Ordinal); break;
            case "eleven events": message = Message([.. Enumerable.Range(0, 11).Select(i => ErrorEvent(now, $"{i + 1:x16}"))]); break;
            case "no events": message = Message(); break;
            case "reserved fingerprint": first["fp"] = DiagnosticFormats.ReservedFingerprint; break;
            case "uppercase fingerprint": first["fp"] = "3A91C2D4E5F60718"; break;
            case "seconds in at": first["at"] = "2026-11-12T15:00:30Z"; break;
            case "at a week old": first["at"] = MinuteOf(now.AddDays(-8)); break;
            case "decimal count": text = Text(message).Replace("\"count\":3,", "\"count\":3.0,", StringComparison.Ordinal); break;
            case "zero count": first["count"] = 0; break;
            case "uptime not a multiple of 60": first["context"]!["uptime_s"] = 3601; break;
            case "two decimals in details": first["trail"]![1]!["d"]!["distance"] = 12.55; break;
            case "control character": error["module"] = "quest\u0007"; break;
            case "lone surrogate": text = Text(message).Replace("\"quest\"", "\"quest\\ud800\"", StringComparison.Ordinal); break;
            case "process_failed kind": first["kind"] = "process_failed"; break;
            case "stop object on an error": first["stop"] = new JsonObject { ["code"] = "other", ["source"] = "stop" }; break;
            case "bad mode": first["context"]!["mode"] = "sleeping"; break;
            case "bad stop source": message["events"]![1]!["stop"]!["source"] = "player"; break;
            case "template with forbidden characters": error["template"] = "Cannot read \"x\""; break;
            case "seventeen frames": error["frames"] = new JsonArray([.. Enumerable.Range(0, 17).Select(_ => (JsonNode)"ext")]); break;
            case "twenty-one trail entries":
                first["trail"] = new JsonArray([.. Enumerable.Range(0, 21).Select(_ => (JsonNode)new JsonObject { ["s"] = 0, ["l"] = "info", ["c"] = "town", ["k"] = "x" })]);
                break;
            case "wrong type": message["type"] = "status"; break;
            case "comment": text = Text(message).Replace("{\"type\"", "{/* x */\"type\"", StringComparison.Ordinal); break;
            case "trailing comma": text = Text(message)[..^1] + ",}"; break;
            default: throw new ArgumentException(broken);
        }
        Assert.Null(OsbPageBatch.Parse(text ?? Text(message), now));
    }

    [Fact]
    public void AMessageOver12KbIsRejectedEvenWhenEveryFieldIsValid()
    {
        var now = DateTimeOffset.Parse("2026-11-12T15:00:30Z");
        var message = Message([.. Enumerable.Range(0, 10).Select(i =>
        {
            var e = ErrorEvent(now, $"{i + 1:x16}");
            e["trail"] = new JsonArray([.. Enumerable.Range(0, 20).Select(_ => (JsonNode)new JsonObject { ["s"] = -1, ["l"] = "info", ["c"] = "movement", ["k"] = "approach-abandoned" })]);
            return e;
        })]);
        var text = Text(message);
        Assert.True(Encoding.UTF8.GetByteCount(text) > OsbPageBatch.MaxBytes);
        Assert.Null(OsbPageBatch.Parse(text, now));
    }

    [Fact]
    public async Task DG25_TheManagerReScrubsAPageBatchAndMergesItWithTheWindowOrdinal()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        kit.Service.Capture.Learn(Hero);
        kit.Service.Capture.Learn(DiagnosticsKit.CanaryAccount);
        kit.Drain();
        var now = kit.Time.GetUtcNow();
        var leaky = ErrorEvent(now, template: $"Cannot read properties of {Hero} (reading <q>)");
        leaky["error"]!["module"] = DiagnosticsKit.CanaryAccount.ToLowerInvariant();
        leaky["context"]!["town_phase"] = "walk-" + Hero.ToLowerInvariant();
        leaky["trail"]!.AsArray().Add(new JsonObject { ["s"] = -1, ["l"] = "info", ["c"] = "party", ["k"] = "resurrection.from." + Hero.ToLowerInvariant() });
        var message = Text(Message(leaky, StopEvent(now), WarnEvent(now)));
        Assert.Contains(Hero, message);

        Assert.True(kit.Service.PageBatches.Offer(message, 2));
        Assert.True(kit.Service.PageBatches.Drain(TimeSpan.FromSeconds(10)));
        await kit.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(kit.DiagnosticBodies());
        var forwarded = body["events"]!.AsArray().Select(e => e!.AsObject()).Where(e => e["source"]!.GetValue<string>() == "osb").ToList();
        Assert.Equal(3, forwarded.Count);
        Assert.All(forwarded, e => Assert.Equal(2, e["context"]!["window"]!.GetValue<int>()));
        var error = forwarded.Single(e => e["kind"]!.GetValue<string>() == "js_error");
        Assert.Equal("Cannot read properties of <x> (reading <q>)", error["error"]!["template"]!.GetValue<string>());
        Assert.Null(error["error"]!["module"]);
        Assert.Null(error["context"]!["town_phase"]);
        Assert.Equal(["operation-start", "legacy", OsbVocabulary.Other], error["trail"]!.AsArray().Select(t => t!["k"]!.GetValue<string>()));
        var text = body.ToJsonString();
        Assert.DoesNotContain(Hero, text, StringComparison.OrdinalIgnoreCase);
        DiagnosticsKit.AssertNoCanary(text);
        Assert.Empty(DiagnosticsServerRules.Check(body));
        Assert.Equal(1, kit.Service.PageBatches.Counts.Accepted);
        Assert.Equal(4, kit.Service.PageBatches.Counts.Mapped);
    }

    [Fact]
    public async Task DG25_AfterTheSwitchGoesOffPageBatchesAreDroppedAndNothingIsSent()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        var receiver = kit.Service.PageBatches;
        var now = kit.Time.GetUtcNow();
        var queuedBeforeOff = new OsbPageBatchReceiver.Item(Text(Valid(now)), 1, kit.Service.Diagnostics.Session, now);

        await kit.Service.WithdrawAsync();

        Assert.False(kit.Service.Diagnostics.Recording);
        Assert.False(receiver.Offer(Text(Valid(now)), 1));
        receiver.Process(queuedBeforeOff);
        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Equal(new PageBatchCounts(0, 0, 0, 0, 2), receiver.Counts);
        await kit.RunFor(TimeSpan.FromMinutes(30));
        Assert.Empty(kit.Server.To("POST /v1/diagnostics"));
    }

    [Fact]
    public void ABatchQueuedBeforeASwitchOffAndOnIsDroppedWithTheOldSession()
    {
        using var kit = DiagnosticsKit.Granted();
        var now = kit.Time.GetUtcNow();
        var stale = new OsbPageBatchReceiver.Item(Text(Valid(now)), 1, kit.Service.Diagnostics.Session, now);
        kit.Service.Diagnostics.Wipe();

        kit.Service.PageBatches.Process(stale);

        Assert.Equal(0, kit.Service.Diagnostics.Limiter.PendingCount);
        Assert.Equal(1, kit.Service.PageBatches.Counts.AfterOff);
    }

    [Fact]
    public void TooFrequentOversizeAndInvalidMessagesAreDroppedAndCounted()
    {
        using var kit = DiagnosticsKit.Granted();
        var receiver = kit.Service.PageBatches;
        var now = kit.Time.GetUtcNow();

        Assert.True(receiver.Offer(Text(Valid(now)), 1));
        Assert.True(receiver.Drain(TimeSpan.FromSeconds(10)));
        kit.Time.Advance(TimeSpan.FromSeconds(30));
        Assert.True(receiver.Offer(Text(Valid(now)), 1));
        Assert.True(receiver.Offer(Text(Valid(now)), 2));
        Assert.True(receiver.Drain(TimeSpan.FromSeconds(10)));
        kit.Time.Advance(TimeSpan.FromSeconds(30));
        Assert.True(receiver.Offer("""{"type":"osb-diagnostics-batch","events":[null]}""", 1));
        Assert.True(receiver.Drain(TimeSpan.FromSeconds(10)));
        Assert.False(receiver.Offer("{\"type\":\"osb-diagnostics-batch\",\"events\":[\"" + new string('a', OsbPageBatch.MaxBytes) + "\"]}", 3));

        Assert.Equal(new PageBatchCounts(2, 1, 1, 1, 0), receiver.Counts);
        var (_, dropped) = kit.Service.Diagnostics.Limiter.Peek();
        Assert.Equal(1, dropped.RateLimited);
        Assert.Equal(1, dropped.Oversize);
    }

    [Fact]
    public void AFloodOfMessagesFillsOnlyThePageQueueAndNeverTheManagersOwnInbox()
    {
        using var kit = DiagnosticsKit.Granted();
        var message = Text(Valid(kit.Time.GetUtcNow()));
        for (var i = 0; i < 200; i++)
        {
            kit.Service.PageBatches.Offer(message, 1);
        }
        Assert.True(kit.Service.PageBatches.Drain(TimeSpan.FromSeconds(10)));

        var counts = kit.Service.PageBatches.Counts;
        Assert.Equal(1, counts.Accepted);
        Assert.Equal(199, counts.TooFrequent);
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 1, null, DiagnosticsKit.Window());
        kit.Drain();
        Assert.Contains(kit.Service.Diagnostics.Limiter.Peek().Events, e => e.Kind == DiagnosticKind.ProcessFailed);
    }

    [Fact]
    public async Task TheGpuVendorAPageReportedBecomesEnvGpuVendor()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Env = kit.Env with { GpuVendor = null };
        var status = BotStatus.TryParse("""{"type":"status","gpu":{"retries":0,"limit":6,"failed":null,"retryIn":0,"vendor":"amd"}}""")!;
        Assert.Equal("amd", status.GpuVendor);
        kit.Service.Diagnostics.GpuVendor = status.GpuVendor;
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 1, null, DiagnosticsKit.Window());
        kit.Drain();

        await kit.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(kit.DiagnosticBodies());
        Assert.Equal("amd", body["env"]!["gpu_vendor"]!.GetValue<string>());
        Assert.Empty(DiagnosticsServerRules.Check(body));
    }

    [Theory]
    [InlineData("NVIDIA GeForce RTX 4090")]
    [InlineData("10de")]
    [InlineData("Nvidia")]
    [InlineData("")]
    public void OnlyTheVendorEnumIsAcceptedFromThePage(string vendor)
    {
        var status = BotStatus.TryParse("{\"type\":\"status\",\"gpu\":{\"vendor\":\"" + vendor + "\"}}")!;
        Assert.Null(status.GpuVendor);
    }

    [Fact]
    public void TheVendorIsNotKeptWhileTheSwitchIsOffAndIsForgottenWhenItGoesOff()
    {
        using var off = DiagnosticsKit.Granted(grant: false);
        off.Service.Diagnostics.GpuVendor = "nvidia";
        Assert.Null(off.Service.Diagnostics.GpuVendor);

        using var on = DiagnosticsKit.Granted();
        on.Service.Diagnostics.GpuVendor = "intel";
        Assert.Equal("intel", on.Service.Diagnostics.GpuVendor);
        on.Service.Diagnostics.GpuVendor = "Canary GPU";
        Assert.Equal("intel", on.Service.Diagnostics.GpuVendor);
        on.Service.Diagnostics.Wipe();
        Assert.Null(on.Service.Diagnostics.GpuVendor);
    }
}
