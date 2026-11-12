namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed class PrivateTerms
{
    public const int MinLength = 3;
    public const int Capacity = 2000;

    private readonly object sync = new();
    private readonly LinkedList<string> order = new();
    private readonly Dictionary<string, LinkedListNode<string>> terms = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> pinned = new(StringComparer.OrdinalIgnoreCase);

    public int Count
    {
        get { lock (sync) { return terms.Count; } }
    }

    public static PrivateTerms ForMachine(string userName, string machineName, string? domainName, string dataFolder)
    {
        var set = new PrivateTerms();
        set.Pin(userName);
        set.Pin(machineName);
        set.Pin(domainName);
        set.Pin(dataFolder);
        set.Pin(dataFolder.TrimEnd('\\', '/'));
        return set;
    }

    public static PrivateTerms ForThisMachine(string dataFolder) =>
        ForMachine(Environment.UserName, Environment.MachineName, Environment.UserDomainName, dataFolder);

    public void Add(string? term)
    {
        var value = Normalise(term);
        if (value is null)
        {
            return;
        }
        lock (sync)
        {
            if (terms.TryGetValue(value, out var node))
            {
                if (!pinned.Contains(value))
                {
                    order.Remove(node);
                    order.AddLast(node);
                }
                return;
            }
            terms[value] = order.AddLast(value);
            while (terms.Count - pinned.Count > Capacity && FirstEvictable() is { } oldest)
            {
                order.Remove(oldest);
                terms.Remove(oldest.Value);
            }
        }
    }

    public void AddRange(IEnumerable<string?> values)
    {
        foreach (var value in values)
        {
            Add(value);
        }
    }

    public bool Hits(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }
        lock (sync)
        {
            foreach (var term in terms.Keys)
            {
                if (text.Contains(term, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }
        return false;
    }

    private void Pin(string? term)
    {
        var value = Normalise(term);
        if (value is null)
        {
            return;
        }
        lock (sync)
        {
            if (!terms.ContainsKey(value))
            {
                terms[value] = order.AddLast(value);
            }
            pinned.Add(value);
        }
    }

    private LinkedListNode<string>? FirstEvictable()
    {
        for (var node = order.First; node is not null; node = node.Next)
        {
            if (!pinned.Contains(node.Value))
            {
                return node;
            }
        }
        return null;
    }

    private static string? Normalise(string? term)
    {
        var value = term?.Trim();
        return value is null || value.Length < MinLength ? null : value;
    }
}
