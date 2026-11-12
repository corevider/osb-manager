using System.Text.Json;
using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class OsbVocabularyTests
{
    private const string Canary = "cnry";

    private static string MinuteOf(DateTimeOffset now) => DiagnosticFormats.MinuteText(now);

    private static JsonObject Forged(string fp, string kind, string detailName, JsonObject detail, DateTimeOffset now) => new()
    {
        ["kind"] = kind,
        ["source"] = "osb",
        ["fp"] = fp,
        ["at"] = MinuteOf(now),
        ["count"] = 1,
        [detailName] = detail,
        ["context"] = new JsonObject { ["phase"] = "cnryforgedphasezq", ["mode"] = "hunting", ["town_phase"] = "cnryforgedtownzq", ["dead"] = false, ["uptime_s"] = 60 },
        ["trail"] = new JsonArray(
            new JsonObject { ["s"] = -1, ["l"] = "info", ["c"] = "cnryforgedcategoryzq", ["k"] = "cnryforgedtrailzq", ["o"] = "cnryforgedoutcomezq", ["e"] = "cnryforgedclasszq" },
            new JsonObject { ["s"] = 0, ["l"] = "warn", ["c"] = "party", ["k"] = "cnryherozq" }),
    };

    private static string ForgedBatch(DateTimeOffset now) => new JsonObject
    {
        ["type"] = OsbPageBatch.BatchType,
        ["events"] = new JsonArray(
            Forged("aaaaaaaaaaaa0001", "js_error", "error", new JsonObject
            {
                ["type"] = "CnryForgedTypeError",
                ["template"] = "cnryForgedTemplateZq is not a function",
                ["module"] = "cnryacctzq",
                ["handled"] = true,
                ["origin"] = "guard",
                ["frames"] = new JsonArray("cnryForgedFrameZq@1:1", "CnryHeroZq@2:2", "Quest.cnryForgedZq@3:3"),
            }, now),
            Forged("aaaaaaaaaaaa0002", "warn", "warn", new JsonObject
            {
                ["category"] = "cnryforgedcategoryzq",
                ["code"] = "cnryforgedwarnzq",
                ["error_class"] = "cnryforgedclasszq",
                ["refusal"] = new JsonObject { ["source"] = "cnryforgedsourcezq", ["reason"] = "cnryforgedreasonzq", ["native"] = 1 },
            }, now),
            Forged("aaaaaaaaaaaa0003", "bot_stop", "stop", new JsonObject { ["code"] = "cnryforgedstopzq", ["source"] = "stop" }, now)),
    }.ToJsonString();

    private static JsonObject RealError(DateTimeOffset now) => new()
    {
        ["kind"] = "js_error",
        ["source"] = "osb",
        ["fp"] = "77e1a0b9c2d4f531",
        ["at"] = MinuteOf(now),
        ["count"] = 12,
        ["error"] = new JsonObject
        {
            ["type"] = "TypeError",
            ["template"] = "Cannot read properties of <q> (reading <q>)",
            ["module"] = "quest",
            ["handled"] = true,
            ["origin"] = "guard",
            ["frames"] = new JsonArray("Quest.observe@14210:31", "Controller.guard@12018:20", "Controller.tick@12110:12", "Object.<anonymous>@1:2", "?@4:20", "ext"),
        },
        ["context"] = new JsonObject { ["phase"] = "world", ["mode"] = "hunting", ["town_phase"] = "walk-vendor", ["dead"] = false, ["uptime_s"] = 5400 },
        ["trail"] = new JsonArray(
            new JsonObject { ["s"] = -42, ["l"] = "info", ["c"] = "town", ["k"] = "operation-end", ["o"] = "confirmed", ["d"] = new JsonObject { ["durationMs"] = 61200 } },
            new JsonObject { ["s"] = -30, ["l"] = "info", ["c"] = "party", ["k"] = "legacy", ["e"] = "unclassified-error" },
            new JsonObject { ["s"] = -12, ["l"] = "warn", ["c"] = "movement", ["k"] = "approach-abandoned", ["o"] = "unconfirmed", ["d"] = new JsonObject { ["revision"] = 4, ["durationMs"] = 8000 } }),
    };

    private static JsonObject RealStop(DateTimeOffset now) => new()
    {
        ["kind"] = "bot_stop",
        ["source"] = "osb",
        ["fp"] = "3d2c1b0a99887766",
        ["at"] = MinuteOf(now),
        ["count"] = 1,
        ["stop"] = new JsonObject { ["code"] = "stuck-no-progress", ["source"] = "stop" },
        ["context"] = new JsonObject { ["phase"] = "world", ["mode"] = "hunting", ["dead"] = false, ["uptime_s"] = 6060 },
    };

    private static JsonObject RealWarn(DateTimeOffset now) => new()
    {
        ["kind"] = "warn",
        ["source"] = "osb",
        ["fp"] = "e0f1a2b3c4d5e6f7",
        ["at"] = MinuteOf(now),
        ["count"] = 40,
        ["warn"] = new JsonObject
        {
            ["category"] = "combat",
            ["code"] = "game-refusal",
            ["refusal"] = new JsonObject { ["source"] = "cast", ["reason"] = "unmapped-error", ["native"] = 12305 },
        },
        ["context"] = new JsonObject { ["phase"] = "world", ["mode"] = "fight", ["dead"] = false, ["uptime_s"] = 6180 },
    };

    [Fact]
    public void TheEmbeddedVocabularyLoadsWithItsOsbVersionAndOsbsOwnValues()
    {
        var vocabulary = OsbVocabulary.Current;
        using var document = JsonDocument.Parse(OsbVocabulary.EmbeddedText());

        Assert.Matches(@"^[0-9]+\.[0-9]+\.[0-9]+$", vocabulary.Version);
        Assert.Equal(
            ["version", "modules", "stop_codes", "activity_categories", "activity_codes", "error_codes", "error_types", "phases", "modes",
                "town_phases", "outcomes", "refusal_sources", "refusal_reasons", "engine_words", "identifiers"],
            document.RootElement.EnumerateObject().Select(p => p.Name));
        Assert.Contains("quest", vocabulary.Modules);
        Assert.Contains("stuck-no-progress", vocabulary.StopCodes);
        Assert.Contains(OsbVocabulary.Other, vocabulary.StopCodes);
        Assert.Contains("approach-abandoned", vocabulary.ActivityCodes);
        Assert.Contains("unclassified-error", vocabulary.ErrorCodes);
        Assert.Contains("TypeError", vocabulary.ErrorTypes);
        Assert.Contains("walk-vendor", vocabulary.TownPhases);
        Assert.Contains("Controller", vocabulary.Identifiers);
        Assert.Contains("cannot", vocabulary.EngineWords);
        Assert.DoesNotContain(vocabulary.Identifiers, word => word.Contains(Canary, StringComparison.OrdinalIgnoreCase));
        Assert.All(vocabulary.Modules.Concat(vocabulary.StopCodes).Concat(vocabulary.ActivityCodes).Concat(vocabulary.TownPhases), code => Assert.True(DiagnosticFormats.IsCode(code), code));
    }

    [Fact]
    public void RealOsbEventsPassTheVocabularyUnchanged()
    {
        var now = DateTimeOffset.Parse("2026-11-12T14:33:30Z");
        var message = new JsonObject { ["type"] = OsbPageBatch.BatchType, ["events"] = new JsonArray(RealError(now), RealStop(now), RealWarn(now)) }.ToJsonString();

        var events = OsbPageBatch.Parse(message, now, out var mapped);

        Assert.NotNull(events);
        Assert.Equal(0, mapped);
        var error = events[0].Error!;
        Assert.Equal("TypeError", error.Type);
        Assert.Equal("Cannot read properties of <q> (reading <q>)", error.Template);
        Assert.Equal("quest", error.Module);
        Assert.Equal(["Quest.observe@14210:31", "Controller.guard@12018:20", "Controller.tick@12110:12", "Object.<anonymous>@1:2", "?@4:20", "ext"], error.Frames);
        Assert.Equal("walk-vendor", events[0].Context!.TownPhase);
        Assert.Equal(["operation-end", "legacy", "approach-abandoned"], events[0].Trail!.Select(t => t.Code));
        Assert.Equal("unclassified-error", events[0].Trail![1].ErrorClass);
        Assert.Equal("stuck-no-progress", events[1].Stop!.Code);
        Assert.Equal(new WarnDetail("combat", "game-refusal", null, new RefusalDetail("cast", "unmapped-error", 12305)), events[2].Warn);
    }

    [Fact]
    public async Task AForgedPageBatchKeepsNoCanaryAfterTheManager()
    {
        var now = DateTimeOffset.Parse("2026-11-12T15:00:30Z");
        Assert.Contains(Canary, ForgedBatch(now), StringComparison.OrdinalIgnoreCase);

        var events = OsbPageBatch.Parse(ForgedBatch(now), now, out var mapped);

        Assert.NotNull(events);
        Assert.Equal(3, events.Count);
        var error = events[0].Error!;
        Assert.Equal(OsbVocabulary.FallbackType, error.Type);
        Assert.Equal("<x> is not a function", error.Template);
        Assert.Null(error.Module);
        Assert.Equal(["?@1:1", "?@2:2", "?@3:3"], error.Frames);
        Assert.All(events, e =>
        {
            Assert.Equal(OsbVocabulary.Other, e.Context!.Phase);
            Assert.Null(e.Context.TownPhase);
            Assert.Equal([OsbVocabulary.Other, "party"], e.Trail!.Select(t => t.Category));
            Assert.All(e.Trail!, t => Assert.Equal(OsbVocabulary.Other, t.Code));
            Assert.All(e.Trail!, t => Assert.Null(t.Outcome));
            Assert.All(e.Trail!, t => Assert.Null(t.ErrorClass));
        });
        Assert.Equal(new WarnDetail(OsbVocabulary.Other, OsbVocabulary.Other, null, new RefusalDetail(OsbVocabulary.Other, OsbVocabulary.Other, 1)), events[1].Warn);
        Assert.Equal(OsbVocabulary.Other, events[2].Stop!.Code);
        Assert.True(mapped >= 25, mapped.ToString(System.Globalization.CultureInfo.InvariantCulture));

        using var kit = DiagnosticsKit.Granted();
        kit.Service.Capture.Start();
        var forged = ForgedBatch(kit.Time.GetUtcNow());
        Assert.True(kit.Service.PageBatches.Offer(forged, 1));
        Assert.True(kit.Service.PageBatches.Drain(TimeSpan.FromSeconds(10)));
        await kit.RunFor(TimeSpan.FromMinutes(14));

        var body = Assert.Single(kit.DiagnosticBodies());
        var text = body.ToJsonString();
        Assert.Equal(3, body["events"]!.AsArray().Count(e => e!["source"]!.GetValue<string>() == "osb"));
        Assert.DoesNotContain(Canary, text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Forged", text, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(DiagnosticsServerRules.Check(body));
        Assert.True(kit.Service.PageBatches.Counts.Mapped >= 25);
    }

    [Theory]
    [InlineData("cnryLowerZq is not a function")]
    [InlineData("ÇnryUmlautZq is not a function")]
    [InlineData("CnryUpperZq is not a function")]
    public void AnUnknownNameInATemplateBecomesXWhateverItsShape(string message)
    {
        var template = DiagnosticScrubber.Template("TypeError", message, new PrivateTerms());

        Assert.Equal("<x> is not a function", template);
        Assert.Equal("<x> is not a function", OsbVocabulary.Current.Words(message));
    }

    [Fact]
    public void TwoKnownWordsJoinedByADroppedCharacterAreCheckedAgain()
    {
        Assert.Equal("<x> is not a function", DiagnosticScrubber.Template("TypeError", "Controller[guard] is not a function", new PrivateTerms()));
    }

    [Fact]
    public void TemplateWordsKeepEngineWordsIdentifiersAndNumbersOnly()
    {
        var vocabulary = OsbVocabulary.Current;

        Assert.Equal("Controller.guard is not a function", vocabulary.Words("Controller.guard is not a function"));
        Assert.Equal("<x>.members is not iterable", vocabulary.Words("cnryLowerZq.members is not iterable"));
        Assert.Equal("Invalid array length 7", vocabulary.Words("Invalid array length 7"));
        Assert.Equal("Cannot read properties of <q> (reading <q>)", vocabulary.Words("Cannot read properties of <q> (reading <q>)"));
        Assert.Equal("<x> <x>", vocabulary.Words("akrBeyQz x$y"));
        Assert.Equal("?@3:4", vocabulary.Frame("cnryForgedFrameZq@3:4"));
        Assert.Equal("Object.<anonymous>@1:1", vocabulary.Frame("Object.<anonymous>@1:1"));
        Assert.Equal("ext", vocabulary.Frame("ext"));
    }

    [Fact]
    public void F9_AJunkMessageDoesNotBlockTheNextRealBatchOfTheSameWindow()
    {
        using var kit = DiagnosticsKit.Granted();
        var receiver = kit.Service.PageBatches;
        var now = kit.Time.GetUtcNow();
        var real = new JsonObject { ["type"] = OsbPageBatch.BatchType, ["events"] = new JsonArray(RealStop(now)) }.ToJsonString();

        Assert.True(receiver.Offer("""{"type":"osb-diagnostics-batch","events":[{"kind":"junk"}]}""", 1));
        Assert.True(receiver.Drain(TimeSpan.FromSeconds(10)));
        kit.Time.Advance(TimeSpan.FromSeconds(1));
        Assert.True(receiver.Offer(real, 1));
        Assert.True(receiver.Drain(TimeSpan.FromSeconds(10)));
        kit.Time.Advance(TimeSpan.FromSeconds(1));
        Assert.True(receiver.Offer(real, 1));
        Assert.True(receiver.Drain(TimeSpan.FromSeconds(10)));

        Assert.Equal(new PageBatchCounts(1, 1, 0, 1, 0), receiver.Counts);
        Assert.Contains(kit.Service.Diagnostics.Limiter.Peek().Events, e => e.Kind == DiagnosticKind.BotStop && e.Source == DiagnosticSource.Osb);
    }
}
