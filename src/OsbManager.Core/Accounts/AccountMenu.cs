namespace OsbManager.Core.Accounts;

public enum AccountMenuState
{
    Closed,
    Queued,
    Open,
}

public enum AccountMenuAction
{
    Add,
    StartAll,
    StartAllLight,
    CloseAll,
    Start,
    StartLight,
    CancelStart,
    ShowWindow,
    ReloadWindow,
    Close,
    ToggleLight,
    MoveUp,
    MoveDown,
    Remove,
}

public sealed record AccountMenuItem(AccountMenuAction Action, string Text, Account? Target, bool Enabled = true, bool SeparatorBefore = false);

public static class AccountMenu
{
    public const string Add = "Add…";
    public const string Remove = "Remove…";
    public const string MoveUp = "Move up";
    public const string MoveDown = "Move down";
    public const string Start = "Start";
    public const string StartLight = "Start light";
    public const string StartAll = "Start all";
    public const string StartAllLight = "Start all light";
    public const string ToggleLight = "Toggle light mode";
    public const string Close = "Close";
    public const string CloseAll = "Close all";
    public const string ShowWindow = "Show window";
    public const string ReloadWindow = "Reload window";
    public const string CancelStart = "Cancel start";

    public static IReadOnlyList<AccountMenuItem> ForRoot() =>
    [
        new(AccountMenuAction.Add, Add, null),
        new(AccountMenuAction.StartAll, StartAll, null, SeparatorBefore: true),
        new(AccountMenuAction.StartAllLight, StartAllLight, null),
        new(AccountMenuAction.CloseAll, CloseAll, null, SeparatorBefore: true),
    ];

    public static IReadOnlyList<AccountMenuItem> ForAccount(Account account, AccountMenuState state)
    {
        IReadOnlyList<AccountMenuItem> lead = state switch
        {
            AccountMenuState.Open =>
            [
                new AccountMenuItem(AccountMenuAction.ShowWindow, ShowWindow, account),
                new AccountMenuItem(AccountMenuAction.ReloadWindow, ReloadWindow, account),
                new AccountMenuItem(AccountMenuAction.Close, Close, account),
            ],
            AccountMenuState.Queued =>
            [
                new AccountMenuItem(AccountMenuAction.CancelStart, CancelStart, account),
                new AccountMenuItem(AccountMenuAction.Start, Start, account),
                new AccountMenuItem(AccountMenuAction.StartLight, StartLight, account),
            ],
            _ =>
            [
                new AccountMenuItem(AccountMenuAction.Start, Start, account),
                new AccountMenuItem(AccountMenuAction.StartLight, StartLight, account),
            ],
        };
        return
        [
            .. lead,
            new AccountMenuItem(AccountMenuAction.ToggleLight, ToggleLight, account, SeparatorBefore: true),
            new AccountMenuItem(AccountMenuAction.MoveUp, MoveUp, account, SeparatorBefore: true),
            new AccountMenuItem(AccountMenuAction.MoveDown, MoveDown, account),
            new AccountMenuItem(AccountMenuAction.Remove, Remove, account, Enabled: state != AccountMenuState.Open, SeparatorBefore: true),
        ];
    }
}
