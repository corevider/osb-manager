namespace OsbManager.Core.Accounts;

/// <summary>
/// Limits how often a game page may receive the saved login details, so a looping or hostile page cannot
/// keep retrying a password and lock the account.
/// </summary>
public sealed class CredentialGate
{
    private readonly int maxPerWindow;
    private readonly TimeSpan window;
    private readonly TimeSpan minimumGap;
    private readonly Func<DateTime> clock;
    private readonly Queue<DateTime> given = new();

    public CredentialGate(int maxPerWindow = 3, TimeSpan? window = null, TimeSpan? minimumGap = null, Func<DateTime>? clock = null)
    {
        this.maxPerWindow = maxPerWindow;
        this.window = window ?? TimeSpan.FromMinutes(10);
        this.minimumGap = minimumGap ?? TimeSpan.FromSeconds(15);
        this.clock = clock ?? (() => DateTime.UtcNow);
    }

    public bool TryTake()
    {
        var now = clock();
        while (given.Count > 0 && now - given.Peek() >= window)
        {
            given.Dequeue();
        }
        if (given.Count >= maxPerWindow || given.Count > 0 && now - given.Last() < minimumGap)
        {
            return false;
        }
        given.Enqueue(now);
        return true;
    }
}
