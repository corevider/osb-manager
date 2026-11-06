using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;

namespace OsbManager.Tests.Telemetry;

public class PayloadBuilderTests
{
    private static readonly byte[] Key = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray();

    private static AccountSnapshot Snapshot(string id, BotStatus status, FakeTimeProvider time, string server = "Srv", int ageSeconds = 0) =>
        new(id, server, status, time.GetUtcNow().AddSeconds(-ageSeconds));

    [Fact]
    public void TheSlotIsTheFirstSixteenHexCharactersOfAnHmacOverSlotColonAccountId()
    {
        var expected = Convert.ToHexString(HMACSHA256.HashData(Key, Encoding.UTF8.GetBytes("slot:account-a")))[..16].ToLowerInvariant();

        Assert.Equal(expected, TelemetryPayloadBuilder.Slot(Key, "account-a"));
        Assert.NotEqual(TelemetryPayloadBuilder.Slot(Key, "account-a"), TelemetryPayloadBuilder.Slot(Key, "account-b"));
        Assert.NotEqual(TelemetryPayloadBuilder.Slot(Key, "account-a"), TelemetryPayloadBuilder.Slot(new byte[32], "account-a"));
    }

    [Fact]
    public void TheSlotNeverContainsTheAccountIdOrTheLoginDetails()
    {
        var time = new FakeTimeProvider();
        var status = TelemetryKit.Hunting("SecretCharacter");

        var body = new TelemetryPayloadBuilder("1.0.0", time).Build([Snapshot("account-guid-1234", status, time, "SecretServer")], Key, includeCharacters: false)!.Body;

        var text = Encoding.UTF8.GetString(body);
        Assert.DoesNotContain("account-guid", text);
        Assert.DoesNotContain("SecretCharacter", text);
        Assert.DoesNotContain("SecretServer", text);
    }

    [Fact]
    public void TheSessionKeyStaysWhileTheSessionGrowsAndChangesWhenItRestarts()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.0.0", time);
        string KeyOf(SessionStats stats, bool commit = false)
        {
            var batch = builder.Build([Snapshot("a", TelemetryKit.Hunting() with { Session = stats }, time)], Key, false)!;
            if (commit)
            {
                batch.Commit();
            }
            return (string)JsonNode.Parse(batch.Body)!["accounts"]![0]!["session"]!["key"]!;
        }

        var first = KeyOf(new SessionStats(1000, 1, 0, 5, 5));
        var grown = KeyOf(new SessionStats(60_000, 9, 0, 50, 50));
        var restarted = KeyOf(new SessionStats(500, 0, 0, 0, 0));

        Assert.Equal(first, grown);
        Assert.NotEqual(grown, restarted);
        Assert.Matches("^[0-9a-f]{16}$", restarted);
    }

    public static TheoryData<BotStatus, string> StateTable => new()
    {
        { new BotStatus { InWorld = true, Dead = true, BotVersion = "2.0.4", Hunting = true }, "dead" },
        { new BotStatus { InWorld = true, TownTrip = true, Hunting = true, BotVersion = "2.0.4" }, "town" },
        { new BotStatus { InWorld = true, Hunting = true, BotVersion = "2.0.4" }, "hunting" },
        { new BotStatus { InWorld = true, BotVersion = "2.0.4" }, "stopped" },
        { new BotStatus { InWorld = true }, "idle" },
        { new BotStatus { InWorld = true, Dead = true }, "dead" },
        { new BotStatus { Phase = "signed-out" }, "login" },
        { new BotStatus { Phase = "character-select" }, "login" },
        { new BotStatus { Phase = "signed-out", LoginStage = "connecting" }, "login" },
        { new BotStatus { Phase = "world", LoginStage = "entering" }, "login" },
        { new BotStatus { LoginStage = "failed" }, "login" },
        { new BotStatus { Phase = "world" }, "loading" },
        { new BotStatus(), "loading" },
        { new BotStatus { Phase = "something-new" }, "unknown" },
    };

    [Theory]
    [MemberData(nameof(StateTable))]
    public void TheStateMappingTableHolds(BotStatus status, string expected) => Assert.Equal(expected, AccountStates.Map(status));

    [Fact]
    public void AnAccountWhoseWindowClosedIsReportedOfflineOnceAndThenForgotten()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.0.0", time);
        var open = Snapshot("a", TelemetryKit.Hunting(), time);
        builder.Build([open], Key, false)!.Commit();

        var closed = builder.Build([], Key, false)!;
        var account = JsonNode.Parse(closed.Body)!["accounts"]![0]!;
        closed.Commit();

        Assert.Equal("offline", (string)account["state"]!);
        Assert.Equal(TelemetryPayloadBuilder.Slot(Key, "a"), (string)account["slot"]!);
        Assert.Null(builder.Build([], Key, false));
    }

    [Fact]
    public void AnUnchangedAccountWithoutASessionIsSentAtMostOncePerHour()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.0.0", time);
        var idle = new BotStatus { InWorld = true, Phase = "world", Level = 50, Gold = 10, HpPercent = 100, MpPercent = 100 };
        builder.Build([Snapshot("a", idle, time)], Key, false)!.Commit();

        time.Advance(TimeSpan.FromMinutes(10));
        Assert.Null(builder.Build([Snapshot("a", idle, time)], Key, false));

        time.Advance(TimeSpan.FromMinutes(55));
        Assert.NotNull(builder.Build([Snapshot("a", idle, time)], Key, false));
    }

    [Fact]
    public void AnAccountWithARunningSessionIsAlwaysSent()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.0.0", time);
        builder.Build([Snapshot("a", TelemetryKit.Hunting(), time)], Key, false)!.Commit();

        time.Advance(TimeSpan.FromMinutes(10));

        Assert.NotNull(builder.Build([Snapshot("a", TelemetryKit.Hunting(), time)], Key, false));
    }

    [Fact]
    public void StatusesOlderThanTwoMinutesAreLeftOut()
    {
        var time = new FakeTimeProvider();
        var builder = new TelemetryPayloadBuilder("1.0.0", time);

        Assert.Null(builder.Build([Snapshot("a", TelemetryKit.Hunting(), time, ageSeconds: 121)], Key, false));
        Assert.NotNull(builder.Build([Snapshot("b", TelemetryKit.Hunting(), time, ageSeconds: 119)], Key, false));
    }

    [Fact]
    public void AtMostTwentyAccountsAreSentAndTheOldestAreDropped()
    {
        var time = new FakeTimeProvider();
        var snapshots = Enumerable.Range(0, 25).Select(i => Snapshot($"a{i}", TelemetryKit.Hunting(), time, ageSeconds: i)).ToList();

        var batch = new TelemetryPayloadBuilder("1.0.0", time).Build(snapshots, Key, false)!;

        var slots = JsonNode.Parse(batch.Body)!["accounts"]!.AsArray().Select(a => (string)a!["slot"]!).ToHashSet();
        Assert.Equal(20, slots.Count);
        Assert.Contains(TelemetryPayloadBuilder.Slot(Key, "a0"), slots);
        Assert.DoesNotContain(TelemetryPayloadBuilder.Slot(Key, "a24"), slots);
    }

    [Fact]
    public void ValuesThePageMadeUpAreClampedOrDropped()
    {
        var time = new FakeTimeProvider();
        var status = new BotStatus
        {
            InWorld = true, Phase = "world", BotVersion = "not a version!", Level = 999, Gold = -5, HpPercent = 150, MpPercent = -3,
            ReturnScrolls = 5_000_000, ReverseScrolls = -1, Character = new string('é', 80),
            Session = new SessionStats(long.MaxValue, long.MaxValue, 0, -1, long.MaxValue, 5),
        };

        var account = JsonNode.Parse(new TelemetryPayloadBuilder("1.0.0", time).Build([Snapshot("a", status, time)], Key, true)!.Body)!["accounts"]![0]!;

        Assert.Null(account["bot_version"]);
        Assert.Null(account["level"]);
        Assert.Null(account["gold"]);
        Assert.Equal(100, (int)account["hp_pct"]!);
        Assert.Equal(0, (int)account["mp_pct"]!);
        Assert.Null(account["scrolls"]);
        Assert.Equal(32, ((string)account["character"]!["name"]!).Length);
        Assert.Equal(2_592_000_000, (long)account["session"]!["ms"]!);
        Assert.Equal(10_000_000, (long)account["session"]!["kills"]!);
        Assert.Null(account["session"]!["xp"]);
        Assert.Equal(long.MaxValue.ToString(), (string)account["session"]!["gold"]!);
    }

    [Fact]
    public void OutsideTheWorldNoGameNumbersAreSent()
    {
        var time = new FakeTimeProvider();
        var status = new BotStatus { Phase = "signed-out", Gold = 5, HpPercent = 50, ReturnScrolls = 3 };

        var account = JsonNode.Parse(new TelemetryPayloadBuilder("1.0.0", time).Build([Snapshot("a", status, time)], Key, false)!.Body)!["accounts"]![0]!;

        Assert.Equal("login", (string)account["state"]!);
        Assert.Null(account["gold"]);
        Assert.Null(account["hp_pct"]);
        Assert.Null(account["scrolls"]);
    }
}
