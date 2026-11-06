using System.Globalization;
using OsbManager.Core.Accounts;
using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class AccountStoreTests
{
    [Fact]
    public void AddsRenamesRemovesAndPersists()
    {
        using var temp = new TempDirectory();
        var path = temp.File("accounts.json");
        var store = AccountStore.Load(path);
        var first = store.Add("  hunter ");
        var second = store.Add("healer");
        store.Rename(second, "apocalypse");
        first.StartLight = true;
        store.Save();
        store.Remove(second);

        var reloaded = AccountStore.Load(path);

        var account = Assert.Single(reloaded.Accounts);
        Assert.Equal("hunter", account.Name);
        Assert.True(account.StartLight);
        Assert.Equal(first.Id, account.Id);
        Assert.Matches("^acc-[0-9a-f]{12}$", account.ProfileName);
    }

    [Fact]
    public void MovesAccountsUpAndDownAndKeepsTheOrder()
    {
        using var temp = new TempDirectory();
        var path = temp.File("accounts.json");
        var store = AccountStore.Load(path);
        Account a = store.Add("a"), b = store.Add("b"), c = store.Add("c");

        Assert.True(store.Move(c, -1));
        Assert.False(store.Move(a, -1));
        Assert.False(store.Move(b, 1));
        Assert.False(store.Move(new Account { Id = "000000000000", Name = "x" }, 1));
        Assert.True(store.Move(a, 5));

        Assert.Equal(["c", "b", "a"], AccountStore.Load(path).Accounts.Select(x => x.Name));
    }

    [Fact]
    public void GivesEveryAccountItsOwnProfile()
    {
        using var temp = new TempDirectory();
        var store = AccountStore.Load(temp.File("accounts.json"));

        var profiles = Enumerable.Range(0, 20).Select(i => store.Add("acc" + i).ProfileName).ToHashSet();

        Assert.Equal(20, profiles.Count);
    }

    [Theory]
    [InlineData("", "Enter a name.")]
    [InlineData("   ", "Enter a name.")]
    [InlineData("HUNTER", "Another account already uses this name.")]
    [InlineData("tab\there", "Remove control characters from the name.")]
    [InlineData("12345678901234567890123456789012345678901", "Use at most 40 characters.")]
    public void ExplainsInvalidNames(string name, string problem)
    {
        var existing = new[] { new Account { Id = "000000000000", Name = "hunter" } };

        Assert.Equal(problem, AccountStore.NameProblem(name, existing, null));
    }

    [Fact]
    public void AllowsKeepingTheSameNameWhenRenaming()
    {
        var self = new Account { Id = "000000000000", Name = "hunter" };

        Assert.Null(AccountStore.NameProblem("Hunter", [self], self));
    }

    [Fact]
    public void DropsInvalidAndDuplicateEntriesOnLoad()
    {
        using var temp = new TempDirectory();
        var path = temp.File("accounts.json");
        File.WriteAllText(path, """
            [
              {"id":"aaaaaaaaaaaa","name":"one"},
              {"id":"../x","name":"bad id"},
              {"id":"bbbbbbbbbbbb","name":"ONE"},
              {"id":"cccccccccccc","name":""},
              {"id":"dddddddddddd","name":"two"}
            ]
            """);

        var store = AccountStore.Load(path);

        Assert.Equal(["one", "two"], store.Accounts.Select(a => a.Name));
    }
}

public class BotStatusTests
{
    private const string Report = """
        {"type":"status","bot":"1.2.172","phase":"world","character":"hunter","inWorld":true,"dead":false,"level":90,
         "gold":"1685416273","hp":73.4,"mp":86,"region":23918,"hunting":true,"town":false,"light":true,
         "session":{"ms":4080000,"kills":288,"deaths":0,"xp":"0","gold":"-175590000"}}
        """;

    [Fact]
    public void ReadsAFullReport()
    {
        var status = BotStatus.TryParse(Report);

        Assert.NotNull(status);
        Assert.Equal("1.2.172", status.BotVersion);
        Assert.Equal("hunter", status.Character);
        Assert.True(status.InWorld);
        Assert.Equal(90, status.Level);
        Assert.Equal(1_685_416_273, status.Gold);
        Assert.Equal(73.4, status.HpPercent);
        Assert.Equal(23918, status.Region);
        Assert.True(status.Hunting);
        Assert.True(status.Light);
        Assert.Equal(new SessionStats(4_080_000, 288, 0, 0, -175_590_000), status.Session);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("{\"type\":\"other\"}")]
    [InlineData("{\"type\":\"status\",\"a\":{\"b\":{\"c\":{\"d\":{\"e\":1}}}}}")]
    public void IgnoresOtherMessages(string? json)
    {
        Assert.Null(BotStatus.TryParse(json));
    }

    [Fact]
    public void IgnoresOversizedMessages()
    {
        var json = "{\"type\":\"status\",\"character\":\"" + new string('x', BotStatus.MaxMessageLength) + "\"}";

        Assert.Null(BotStatus.TryParse(json));
    }

    [Fact]
    public void BoundsUntrustedValues()
    {
        var status = BotStatus.TryParse("""
            {"type":"status","character":"a\u0007b","phase":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
             "level":-5,"hp":250,"mp":"50","region":1.5e300,"gold":"12abc","inWorld":"yes"}
            """);

        Assert.NotNull(status);
        Assert.Equal("ab", status.Character);
        Assert.Equal(64, status.Phase!.Length);
        Assert.Null(status.Level);
        Assert.Equal(100, status.HpPercent);
        Assert.Null(status.MpPercent);
        Assert.Null(status.Region);
        Assert.Null(status.Gold);
        Assert.False(status.InWorld);
        Assert.Null(status.Session);
    }
}

public class FormatTests
{
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    [Theory]
    [InlineData(288L, "288")]
    [InlineData(54_321L, "54,321")]
    [InlineData(175_590_000L, "175.59M")]
    [InlineData(2_780_000L, "2.78M")]
    [InlineData(1_685_416_273L, "1.69B")]
    [InlineData(-2_500_000L, "-2.5M")]
    [InlineData(null, "—")]
    public void CompactsLargeNumbers(long? value, string expected)
    {
        Assert.Equal(expected, Format.Compact(value, Invariant));
    }

    [Theory]
    [InlineData(0L, "0m")]
    [InlineData(59_000L, "0m")]
    [InlineData(4_080_000L, "1h 08m")]
    [InlineData(8_220_000L, "2h 17m")]
    public void FormatsHuntingTime(long ms, string expected)
    {
        Assert.Equal(expected, Format.Duration(ms));
    }

    [Fact]
    public void ShowsRatesOnlyAfterThirtySeconds()
    {
        Assert.Equal("—", Format.PerHour(10, 29_999, Invariant));
        Assert.Equal("252", Format.PerHour(288, 4_114_286, Invariant));
        Assert.Equal("—", Format.PerHour(null, 60_000, Invariant));
    }

    [Theory]
    [InlineData(512L, "512 B")]
    [InlineData(54L << 20, "54 MB")]
    [InlineData(5L << 29, "2.5 GB")]
    public void FormatsSizes(long bytes, string expected)
    {
        Assert.Equal(expected, Format.Bytes(bytes, Invariant));
    }
}
