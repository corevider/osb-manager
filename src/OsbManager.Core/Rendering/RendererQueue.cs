namespace OsbManager.Core.Rendering;

/// <summary>
/// Lets one game window at a time start the game's renderer (create its WebGPU device), with a short gap between
/// starts, so several windows never ask the graphics card for a device at the same moment. A slot that is not handed
/// back within the lease is taken back, so a page that crashes or reloads while it holds the slot cannot block the others.
/// </summary>
public sealed class RendererQueue
{
    public static readonly TimeSpan DefaultGap = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan DefaultLease = TimeSpan.FromSeconds(20);

    private readonly TimeSpan gap;
    private readonly TimeSpan lease;
    private readonly Func<DateTime> clock;
    private readonly List<Pending> waiting = [];
    private Pending? holder;
    private DateTime holderSince;
    private DateTime freeAt = DateTime.MinValue;

    public RendererQueue(TimeSpan? gap = null, TimeSpan? lease = null, Func<DateTime>? clock = null)
    {
        this.gap = gap ?? DefaultGap;
        this.lease = lease ?? DefaultLease;
        this.clock = clock ?? (() => DateTime.UtcNow);
    }

    /// <summary>The window that holds the slot, or null.</summary>
    public string? Holder => holder?.Window;

    public bool IsWaiting(string window) => waiting.Any(r => r.Window == window);

    /// <summary>
    /// Queues a window's request; <paramref name="grant"/> runs when its turn comes. A window has at most one request:
    /// a newer one replaces the older, because the page behind the older one is gone or has given up on it.
    /// </summary>
    public void Request(string window, string id, Action grant)
    {
        waiting.RemoveAll(r => r.Window == window);
        if (holder?.Window == window)
        {
            Free();
        }
        waiting.Add(new Pending(window, id, grant));
        Pump();
    }

    /// <summary>The page says its renderer start is over. Answers for an older request of the window are ignored.</summary>
    public void Release(string window, string id)
    {
        waiting.RemoveAll(r => r.Window == window && r.Id == id);
        if (holder is { } current && current.Window == window && current.Id == id)
        {
            Free();
        }
        Pump();
    }

    /// <summary>Drops everything of a window that closed, crashed or navigated away; its slot is free at once.</summary>
    public void Forget(string window)
    {
        waiting.RemoveAll(r => r.Window == window);
        if (holder?.Window == window)
        {
            Free();
        }
        Pump();
    }

    /// <summary>Takes back an expired slot and grants the next request once the gap has passed.</summary>
    public void Pump()
    {
        var now = clock();
        if (holder is not null && now - holderSince >= lease)
        {
            Free();
        }
        if (holder is not null || waiting.Count == 0 || now < freeAt)
        {
            return;
        }
        var next = waiting[0];
        waiting.RemoveAt(0);
        holder = next;
        holderSince = now;
        next.Grant();
    }

    private void Free()
    {
        holder = null;
        freeAt = clock() + gap;
    }

    private sealed record Pending(string Window, string Id, Action Grant);
}
