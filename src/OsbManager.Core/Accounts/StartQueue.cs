namespace OsbManager.Core.Accounts;

/// <summary>
/// Starts game windows one at a time, a fixed gap apart, so several new windows do not ask the graphics card
/// for memory at the same moment.
/// </summary>
public sealed class StartQueue
{
    private readonly TimeSpan gap;
    private readonly Func<DateTime> clock;
    private readonly List<(Account Account, bool Light)> waiting = [];
    private DateTime lastStart = DateTime.MinValue;

    public StartQueue(TimeSpan gap, Func<DateTime>? clock = null)
    {
        this.gap = gap;
        this.clock = clock ?? (() => DateTime.UtcNow);
    }

    public int Count => waiting.Count;

    public bool Contains(Account account) => waiting.Any(w => w.Account == account);

    public void Add(Account account, bool light)
    {
        if (!Contains(account))
        {
            waiting.Add((account, light));
        }
    }

    public bool Remove(Account account) => waiting.RemoveAll(w => w.Account == account) > 0;

    public void Clear() => waiting.Clear();

    /// <summary>Puts the waiting windows in the order of this list. Accounts missing from it keep their place at the end.</summary>
    public void SortBy(IReadOnlyList<Account> order)
    {
        var positions = order.Select((account, index) => (account, index)).ToDictionary(p => p.account, p => p.index);
        var sorted = waiting.OrderBy(w => positions.GetValueOrDefault(w.Account, int.MaxValue)).ToList();
        waiting.Clear();
        waiting.AddRange(sorted);
    }

    /// <summary>The next window to open, once the gap since the last one has passed.</summary>
    public (Account Account, bool Light)? TakeDue()
    {
        var now = clock();
        if (waiting.Count == 0 || now - lastStart < gap)
        {
            return null;
        }
        var next = waiting[0];
        waiting.RemoveAt(0);
        lastStart = now;
        return next;
    }

    /// <summary>How long until this account's window opens, or null when it is not waiting.</summary>
    public TimeSpan? WaitFor(Account account)
    {
        var position = waiting.FindIndex(w => w.Account == account);
        if (position < 0)
        {
            return null;
        }
        var first = lastStart + gap - clock();
        return (first > TimeSpan.Zero ? first : TimeSpan.Zero) + gap * position;
    }
}
