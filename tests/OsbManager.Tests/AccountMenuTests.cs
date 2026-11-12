using OsbManager.Core.Accounts;

namespace OsbManager.Tests;

public class AccountMenuTests
{
    private static Account Named(string name) => new() { Id = name.PadRight(12, '0')[..12], Name = name };

    private static string[] Texts(IEnumerable<AccountMenuItem> items) => items.Select(i => i.Text).ToArray();

    [Fact]
    public void AClosedAccountOffersStartAndEditing()
    {
        var items = AccountMenu.ForAccount(Named("alpha"), AccountMenuState.Closed);

        Assert.Equal(["Start", "Start light", "Toggle light mode", "Move up", "Move down", "Remove…"], Texts(items));
        Assert.All(items, item => Assert.True(item.Enabled));
    }

    [Fact]
    public void AQueuedAccountAddsAWayToCancelTheStart()
    {
        var items = AccountMenu.ForAccount(Named("alpha"), AccountMenuState.Queued);

        Assert.Equal(["Cancel start", "Start", "Start light", "Toggle light mode", "Move up", "Move down", "Remove…"], Texts(items));
        Assert.All(items, item => Assert.True(item.Enabled));
    }

    [Fact]
    public void AnOpenAccountOffersTheWindowActionsAndLocksRemove()
    {
        var items = AccountMenu.ForAccount(Named("alpha"), AccountMenuState.Open);

        Assert.Equal(["Show window", "Reload window", "Close", "Toggle light mode", "Move up", "Move down", "Remove…"], Texts(items));
        Assert.False(items.Single(i => i.Action == AccountMenuAction.Remove).Enabled);
        Assert.All(items.Where(i => i.Action != AccountMenuAction.Remove), item => Assert.True(item.Enabled));
    }

    [Fact]
    public void TheRootNodeOffersAddAndTheBulkActions()
    {
        var items = AccountMenu.ForRoot();

        Assert.Equal(["Add…", "Start all", "Start all light", "Close all"], Texts(items));
        Assert.All(items, item => Assert.Null(item.Target));
    }

    [Theory]
    [InlineData(AccountMenuState.Closed)]
    [InlineData(AccountMenuState.Queued)]
    [InlineData(AccountMenuState.Open)]
    public void EachItemNamesTheAccountItActsOn(AccountMenuState state)
    {
        var first = Named("alpha");
        var second = Named("beta");

        var items = AccountMenu.ForAccount(first, state);
        var others = AccountMenu.ForAccount(second, state);

        Assert.All(items, item => Assert.Same(first, item.Target));
        Assert.All(others, item => Assert.Same(second, item.Target));
        Assert.Equal(Texts(items), Texts(others));
    }

    [Fact]
    public void TheSameStateAlwaysGivesTheSameItemsSoTheTreeAndTheStatusTabAgree()
    {
        var account = Named("alpha");

        foreach (var state in Enum.GetValues<AccountMenuState>())
        {
            Assert.Equal(AccountMenu.ForAccount(account, state), AccountMenu.ForAccount(account, state));
        }
    }

    [Fact]
    public void SharedItemNamesMatchTheAccountsMenu()
    {
        var all = new[] { AccountMenu.Add, AccountMenu.Remove, AccountMenu.MoveUp, AccountMenu.MoveDown, AccountMenu.Start, AccountMenu.StartLight, AccountMenu.StartAll, AccountMenu.StartAllLight, AccountMenu.ToggleLight, AccountMenu.Close, AccountMenu.CloseAll };

        Assert.Equal(["Add…", "Remove…", "Move up", "Move down", "Start", "Start light", "Start all", "Start all light", "Toggle light mode", "Close", "Close all"], all);
    }
}
