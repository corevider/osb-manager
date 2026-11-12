namespace OsbManager.Core.Accounts;

/// <summary>
/// The accounts whose game window was closed only to be opened again. A restart names exactly one account, so a
/// problem in one window never closes or restarts another. Closing all windows or quitting cancels every restart.
/// </summary>
public sealed class WindowRestarts
{
    private readonly HashSet<string> restarting = new(StringComparer.Ordinal);

    public bool IsRestarting(string accountId) => restarting.Contains(accountId);

    /// <summary>Marks an open window for a restart; returns false when it is already marked.</summary>
    public bool Request(string accountId) => restarting.Add(accountId);

    /// <summary>Called when a window has closed; true when it should be queued to start again.</summary>
    public bool TakeOnClose(string accountId, bool quitting) => restarting.Remove(accountId) && !quitting;

    public void Clear() => restarting.Clear();
}
