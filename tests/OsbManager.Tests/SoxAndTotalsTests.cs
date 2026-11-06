using System.Globalization;
using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class SoxLogTests
{
    [Theory]
    [InlineData("hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser", "hunter", "Demon Polearm", "Star", "Wing Tribe Chaser")]
    [InlineData("(Notice):healer has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser", "healer", "Blaze Diadem", "Moon", "Wing Tribe Chaser")]
    [InlineData("SEAL OF SUN: sorcerer has dropped Lynx Valor Phantom (Seal Of Sun) from Tiger Woman.", "sorcerer", "Lynx Valor Phantom", "Sun", "Tiger Woman")]
    [InlineData("bard has dropped Sapphire Ring (Seal Of Star)", "bard", "Sapphire Ring", "Star", "")]
    [InlineData("SEAL OF SUN: bard has dropped Lynx Blade from Tiger Woman.", "bard", "Lynx Blade", "Sun", "Tiger Woman")]
    [InlineData("SEAL OF SUN: bard has dropped Lynx Blade", "bard", "Lynx Blade", "Sun", "")]
    [InlineData("minstrel has dropped Moon Blade (seal of moon) from Mob", "minstrel", "Moon Blade", "Moon", "Mob")]
    public void ReadsDropAnnouncements(string text, string who, string item, string seal, string from)
    {
        Assert.Equal((who, item, seal, from), SoxLog.Parse(text));
    }

    [Theory]
    [InlineData("")]
    [InlineData("hunter has dropped Demon Polearm from Wing Tribe Chaser")]
    [InlineData("The server will restart in 5 minutes.")]
    public void IgnoresOtherNotices(string text)
    {
        Assert.Null(SoxLog.Parse(text));
    }

    [Fact]
    public void KeepsOneCopyOfAnAnnouncementSeveralWindowsSaw()
    {
        using var temp = new TempDirectory();
        var time = new DateTime(2026, 10, 30, 12, 0, 0);
        var log = new SoxLog(temp.File("sox.json"), () => time);
        const string text = "hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser";

        Assert.NotNull(log.Add(text, "hunter", ["hunter"]));
        Assert.Null(log.Add(text, "bot", ["hunter"]));
        time = time.AddMinutes(3);
        Assert.NotNull(log.Add(text, "bot", ["hunter"]));
        Assert.Equal(2, log.Drops.Count);
    }

    [Fact]
    public void KeepsOneCopyOfASunDropSeenAsBannerAndAsChat()
    {
        using var temp = new TempDirectory();
        var log = new SoxLog(temp.File("sox.json"));

        Assert.NotNull(log.Add("SEAL OF SUN: hunter has dropped Lynx Blade from Tiger Woman", "hunter", []));
        Assert.Null(log.Add("hunter has dropped Lynx Blade (Seal Of Sun) from Tiger Woman", "bot", []));
        Assert.Equal("Sun", Assert.Single(log.Drops).Seal);
    }

    [Fact]
    public void MarksOurCharactersAndKeepsTheListForTheNextStart()
    {
        using var temp = new TempDirectory();
        var log = new SoxLog(temp.File("sox.json"));
        var added = new List<SoxDrop>();
        log.Added += added.Add;

        log.Add("Hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser", "hunter", ["hunter", "bard"]);
        log.Add("stranger has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser", "hunter", ["hunter", "bard"]);
        log.Add("not a drop", "hunter", ["hunter"]);

        Assert.Equal([true, false], added.Select(d => d.Ours));
        var reloaded = new SoxLog(temp.File("sox.json"));
        Assert.Equal(2, reloaded.Drops.Count);
        Assert.Equal("Demon Polearm", reloaded.Drops[0].Item);
        reloaded.Clear();
        Assert.Empty(new SoxLog(temp.File("sox.json")).Drops);
    }

    [Fact]
    public void KeepsOnlyTheNewestDrops()
    {
        using var temp = new TempDirectory();
        var time = DateTime.Now;
        var log = new SoxLog(temp.File("sox.json"), () => time = time.AddSeconds(1));

        for (var i = 0; i < SoxLog.Capacity + 5; i++)
        {
            log.Add($"p{i} has dropped Item {i} (Seal Of Star) from Mob", "a", []);
        }

        Assert.Equal(SoxLog.Capacity, log.Drops.Count);
        Assert.Equal("Item 5", log.Drops[0].Item);
    }
}

public class SoxReceiptTests
{
    private const string Announcement = "Hunter has dropped Star Blade (Seal Of Star) from Wing Tribe Chaser";

    private static SoxReceipt Party(string item, string member, bool inParty = true) =>
        new("UIIT_MSG_PARTYGET_ITEM_EXPENDABLE", item, member, inParty, 1);

    private static SoxReceipt Own(string item) => new("UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", item, "", false, 1);

    private static (SoxLog Log, Action<TimeSpan> Wait) Create(TempDirectory temp)
    {
        var time = new DateTime(2026, 11, 6, 12, 0, 0);
        var log = new SoxLog(temp.File("sox.json"), () => time);
        return (log, span => time += span);
    }

    [Theory]
    [InlineData("UIIT_MSG_PARTYGET_ITEM_EXPENDABLE", true)]
    [InlineData("UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", true)]
    [InlineData("UIIT_MSG_PARTYGET_ITEM", true)]
    [InlineData("UIIT_MSG_STATE_GET_ITEM_EQUIP", true)]
    [InlineData("UIIT_MSG_PARTYGET_GOLD", false)]
    [InlineData("UIIT_MSG_STATE_GAIN_GOLD", false)]
    [InlineData("uiit_msg_partyget_item", false)]
    public void KnowsTheItemPickupKeys(string key, bool wanted)
    {
        Assert.Equal(wanted, SoxReceipt.IsReceiveKey(key));
    }

    [Fact]
    public void TellsTheReceiverOnlyWhenSure()
    {
        Assert.Equal("Bard", Party("Star Blade", "Bard").Receiver("Hunter"));
        Assert.Null(Party("Star Blade", "Bard", inParty: false).Receiver("Hunter"));
        Assert.Null(Party("Star Blade", "").Receiver("Hunter"));
        Assert.Equal("Hunter", Own("Star Blade").Receiver("Hunter"));
        Assert.Null(Own("Star Blade").Receiver(null));
    }

    [Fact]
    public void ReadsPickupNoticesFromTheStatus()
    {
        var status = BotStatus.TryParse("""
            {"type":"status","received":[
              {"key":"UIIT_MSG_PARTYGET_ITEM_EXPENDABLE","item":"Star Blade","count":1,"member":"Bard","inParty":true},
              {"key":"UIIT_MSG_STATE_GET_ITEM_EXPENDABLE","item":"HP Potion","count":5,"member":"","inParty":false},
              {"key":"UIIT_MSG_PARTYGET_GOLD","item":"100","member":"Bard","inParty":true},
              {"key":"UIIT_MSG_PARTYGET_ITEM","item":"","member":"Bard"},
              "text"
            ]}
            """);

        Assert.Equal(
            [new SoxReceipt("UIIT_MSG_PARTYGET_ITEM_EXPENDABLE", "Star Blade", "Bard", true, 1), new SoxReceipt("UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", "HP Potion", "", false, 5)],
            status!.Received);
        Assert.Empty(BotStatus.TryParse("""{"type":"status"}""")!.Received);
    }

    [Fact]
    public void MatchesAPickupAfterTheAnnouncement()
    {
        using var temp = new TempDirectory();
        var (log, wait) = Create(temp);
        var updated = new List<SoxDrop>();
        log.Updated += updated.Add;

        log.Add(Announcement, "alpha", ["Hunter"]);
        wait(TimeSpan.FromSeconds(20));
        var result = log.Receive(Party("star blade", "Bard"), "Hunter");

        Assert.Equal(SoxReceiptOutcome.Matched, result.Outcome);
        Assert.Equal("Bard", Assert.Single(log.Drops).ReceivedBy);
        Assert.Equal("Bard", Assert.Single(updated).ReceivedBy);
        Assert.False(result.Log);
    }

    [Fact]
    public void MatchesAPickupThatCameBeforeTheAnnouncement()
    {
        using var temp = new TempDirectory();
        var (log, wait) = Create(temp);

        Assert.Equal(SoxReceiptOutcome.Waiting, log.Receive(Party("Star Blade", "Bard"), "Hunter").Outcome);
        wait(TimeSpan.FromSeconds(90));
        var drop = log.Add(Announcement, "alpha", ["Hunter"]);

        Assert.Equal("Bard", drop!.ReceivedBy);
    }

    [Fact]
    public void LeavesTheCellEmptyWhenNothingMatches()
    {
        using var temp = new TempDirectory();
        var (log, wait) = Create(temp);

        log.Receive(Party("Star Blade", "Bard"), "Hunter");
        wait(TimeSpan.FromMinutes(3));
        log.Add(Announcement, "alpha", ["Hunter"]);
        log.Receive(Party("Moon Shield", "Bard"), "Hunter");
        log.Receive(Party("Star Blade", "Stranger", inParty: false), "Hunter");

        Assert.Equal("", Assert.Single(log.Drops).ReceivedBy);
    }

    [Fact]
    public void IgnoresAPickupMoreThanTenMinutesLate()
    {
        using var temp = new TempDirectory();
        var (log, wait) = Create(temp);

        log.Add(Announcement, "alpha", ["Hunter"]);
        wait(TimeSpan.FromMinutes(10) + TimeSpan.FromSeconds(1));
        var result = log.Receive(Party("Star Blade", "Bard"), "Hunter");

        Assert.Equal(SoxReceiptOutcome.Waiting, result.Outcome);
        Assert.True(result.Log, "a pickup of a SoX item that finds no entry is logged");
        Assert.Equal("", Assert.Single(log.Drops).ReceivedBy);
    }

    [Fact]
    public void GivesTwoDropsOfTheSameItemOnePickupEach()
    {
        using var temp = new TempDirectory();
        var (log, wait) = Create(temp);

        log.Add(Announcement, "alpha", ["Hunter"]);
        wait(TimeSpan.FromMinutes(3));
        log.Add("Bard has dropped Star Blade (Seal Of Star) from Wing Tribe Chaser", "alpha", ["Hunter"]);
        wait(TimeSpan.FromSeconds(5));
        log.Receive(Party("Star Blade", "Bard"), "Hunter");
        wait(TimeSpan.FromSeconds(30));
        log.Receive(Own("Star Blade"), "Hunter");

        Assert.Equal(["Hunter", "Bard"], log.Drops.Select(d => d.ReceivedBy));
    }

    [Fact]
    public void CountsAPickupSeveralWindowsSawOnce()
    {
        using var temp = new TempDirectory();
        var (log, wait) = Create(temp);

        log.Receive(Party("Star Blade", "Bard"), "Hunter");
        wait(TimeSpan.FromSeconds(1));
        Assert.Equal(SoxReceiptOutcome.Repeated, log.Receive(Own("Star Blade"), "Bard").Outcome);
        log.Add(Announcement, "alpha", ["Hunter"]);
        wait(TimeSpan.FromMinutes(1));
        log.Add("Other has dropped Star Blade (Seal Of Star) from Wing Tribe Chaser", "alpha", ["Hunter"]);

        Assert.Equal(["Bard", ""], log.Drops.Select(d => d.ReceivedBy));
    }

    [Fact]
    public void FillsTheReceiverFromTheFirstWindowThatCanTell()
    {
        using var temp = new TempDirectory();
        var (log, wait) = Create(temp);

        log.Add(Announcement, "alpha", ["Hunter"]);
        Assert.Equal(SoxReceiptOutcome.Unknown, log.Receive(Party("Star Blade", "Bard", inParty: false), "Hunter").Outcome);
        wait(TimeSpan.FromSeconds(1));
        Assert.Equal(SoxReceiptOutcome.Matched, log.Receive(Party("Star Blade", "Bard"), "Cleric").Outcome);

        Assert.Equal("Bard", Assert.Single(log.Drops).ReceivedBy);
    }

    [Fact]
    public void LogsANewUnknownKeyOnceAndNeverThePotions()
    {
        using var temp = new TempDirectory();
        var (log, _) = Create(temp);
        var potion = Own("HP Potion");
        var equip = new SoxReceipt("UIIT_MSG_PARTYGET_ITEM_EQUIP", "Plain Blade", "Bard", true, 1);

        Assert.False(log.Receive(potion, "Hunter").Log);
        Assert.False(log.Receive(potion with { Count = 4 }, "Hunter").Log);
        Assert.True(log.Receive(equip, "Hunter").Log);
        Assert.False(log.Receive(equip with { Item = "Plain Shield" }, "Hunter").Log);
    }

    [Fact]
    public void KeepsTheReceiverForTheNextStartAndLoadsOldListsWithoutIt()
    {
        using var temp = new TempDirectory();
        var (log, _) = Create(temp);
        log.Add(Announcement, "alpha", ["Hunter"]);
        log.Receive(Party("Star Blade", "Bard"), "Hunter");

        Assert.Equal("Bard", Assert.Single(new SoxLog(temp.File("sox.json")).Drops).ReceivedBy);
        Assert.Contains("\"receivedBy\": \"Bard\"", File.ReadAllText(temp.File("sox.json")));

        File.WriteAllText(temp.File("old.json"), """
            [{"at":"2026-10-30T12:00:00","character":"Hunter","item":"Star Blade","seal":"Star","monster":"Mob","text":"t","ours":true,"seenBy":"alpha"}]
            """);
        var old = Assert.Single(new SoxLog(temp.File("old.json")).Drops);
        Assert.Equal("alpha", old.SeenBy);
        Assert.Equal("", old.ReceivedBy);
    }

    [Fact]
    public void ShowsWentToRightAfterSeenBy()
    {
        var titles = SoxTable.Columns.Select(c => c.Title).ToList();
        Assert.Equal(titles.IndexOf("Seen by") + 1, titles.IndexOf("Went to"));
        var drop = new SoxDrop(new DateTime(2026, 11, 6, 12, 0, 0), "Hunter", "Star Blade", "Star", "Mob", "t", true, "alpha", "Bard");
        Assert.Equal(["Hunter", "Star Blade", "Star", "Mob", "alpha", "Bard"], SoxTable.Cells(drop, CultureInfo.InvariantCulture).Skip(1));
        Assert.Equal("", SoxTable.Cells(drop with { ReceivedBy = "" }, CultureInfo.InvariantCulture)[^1]);
        Assert.Equal(titles.Count, SoxTable.Cells(drop).Length);
    }
}

public class SoxHideStarTests
{
    private static SoxDrop Drop(string character, string seal, bool ours, int minute) =>
        new(new DateTime(2026, 11, 6, 12, minute, 0), character, "Item " + character, seal, "Mob", "t", ours, "alpha");

    private static readonly SoxDrop[] Drops =
    [
        Drop("hunter", "Star", true, 0), Drop("stranger", "Moon", false, 1), Drop("bard", "Sun", true, 2), Drop("cleric", "Star", false, 3),
    ];

    [Fact]
    public void ShowsEverythingNewestFirstWhenOff()
    {
        Assert.Equal(["cleric", "bard", "stranger", "hunter"], SoxTable.Visible(Drops, onlyMine: false, hideStar: false).Select(d => d.Character));
        Assert.Equal(["bard", "hunter"], SoxTable.Visible(Drops, onlyMine: true, hideStar: false).Select(d => d.Character));
    }

    [Fact]
    public void HidesStarEntriesAndKeepsMoonAndSun()
    {
        Assert.Equal(["bard", "stranger"], SoxTable.Visible(Drops, onlyMine: false, hideStar: true).Select(d => d.Character));
        Assert.Equal(["bard"], SoxTable.Visible(Drops, onlyMine: true, hideStar: true).Select(d => d.Character));
    }

    [Fact]
    public void LeavesStarOutOfTheCountsWhenHidden()
    {
        Assert.Equal("Star 2 · Moon 1 · Sun 1 announced. The game announces SoX drops to the whole server.",
            SoxTable.Summary(SoxTable.Visible(Drops, false, false), onlyMine: false, hideStar: false));
        Assert.Equal("Moon 1 · Sun 1 announced. The game announces SoX drops to the whole server.",
            SoxTable.Summary(SoxTable.Visible(Drops, false, true), onlyMine: false, hideStar: true));
        Assert.Equal("Moon 0 · Sun 1 by your characters. The game announces SoX drops to the whole server.",
            SoxTable.Summary(SoxTable.Visible(Drops, true, true), onlyMine: true, hideStar: true));
    }

    [Fact]
    public void KeepsRecordingStarDropsWhileHidden()
    {
        using var temp = new TempDirectory();
        var log = new SoxLog(temp.File("sox.json"));
        log.Add("hunter has dropped Star Blade (Seal Of Star) from Mob", "alpha", ["hunter"]);
        log.Add("hunter has dropped Moon Blade (Seal Of Moon) from Mob", "alpha", ["hunter"]);

        Assert.Single(SoxTable.Visible(log.Drops, onlyMine: true, hideStar: true));
        Assert.Equal(["Star", "Moon"], log.Drops.Select(d => d.Seal));
        Assert.Equal(["Star", "Moon"], new SoxLog(temp.File("sox.json")).Drops.Select(d => d.Seal));
        Assert.Equal(2, SoxTable.Visible(log.Drops, onlyMine: true, hideStar: false).Count);
    }
}

public class StatsTotalsTests
{
    [Fact]
    public void AddsTheAccountsRatesAndShowsTheLongestSession()
    {
        var total = StatsTotals.Sum([
            new StatsLine(4_080_000, 288, 0, 175_590_000, 0, 1),
            new StatsLine(4_140_000, 273, 2_780_000, 197_330_000, 3, 2),
        ]);

        Assert.Equal(4_140_000, total.Milliseconds);
        Assert.Equal(561, total.Kills);
        Assert.Equal(254.1 + 237.4, total.KillsPerHour!.Value, 1);
        Assert.Equal(2_780_000, total.Experience);
        Assert.Equal(3, total.Deaths);
        Assert.Equal(3, total.Sox);
    }

    [Fact]
    public void LeavesOutRatesOfSessionsShorterThanThirtySeconds()
    {
        var total = StatsTotals.Sum([new StatsLine(3_600_000, 100, null, null, 0, 0), new StatsLine(10_000, 5, null, null, 0, 0)]);

        Assert.Equal(100, total.KillsPerHour);
        Assert.Null(total.ExperiencePerHour);
        Assert.Equal("100", Format.PerHour(total.KillsPerHour, CultureInfo.InvariantCulture));
        Assert.Equal("—", Format.PerHour(total.ExperiencePerHour, CultureInfo.InvariantCulture));
    }
}

public class SoxStatusTests
{
    [Fact]
    public void ReadsTheSoxCountAndNewDrops()
    {
        var status = BotStatus.TryParse("""{"type":"status","session":{"ms":1,"kills":1,"deaths":0,"sox":4},"drops":["a has dropped B (Seal Of Star) from C",5,""]}""");

        Assert.Equal(4, status!.Session!.Sox);
        Assert.Equal(["a has dropped B (Seal Of Star) from C"], status.Drops);
    }

    [Fact]
    public void ReadsTheScrollCountsAndBoundsThem()
    {
        var status = BotStatus.TryParse("""{"type":"status","scrolls":{"ret":12,"reverse":3}}""");
        Assert.Equal(12, status!.ReturnScrolls);
        Assert.Equal(3, status.ReverseScrolls);

        var bad = BotStatus.TryParse("""{"type":"status","scrolls":{"ret":-1,"reverse":"many"}}""");
        Assert.Null(bad!.ReturnScrolls);
        Assert.Null(bad.ReverseScrolls);
        Assert.Null(BotStatus.TryParse("""{"type":"status"}""")!.ReturnScrolls);
    }
}
