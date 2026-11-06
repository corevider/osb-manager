using System.Collections.Concurrent;
using OsbManager.Core.Status;

namespace OsbManager.Core.Telemetry;

public sealed record AccountSnapshot(string AccountId, string Server, BotStatus Status, DateTimeOffset ReceivedAt);

public interface IStatusSource
{
    IReadOnlyList<AccountSnapshot> Snapshot();
}

/// <summary>
/// The latest report of every open game window. The windows publish on their own thread; telemetry reads copies of
/// the immutable records, so it never touches a window or the UI thread.
/// </summary>
public sealed class StatusRegistry : IStatusSource
{
    private readonly ConcurrentDictionary<string, AccountSnapshot> entries = new();

    public void Publish(string accountId, string server, BotStatus status, DateTimeOffset receivedAt) =>
        entries[accountId] = new AccountSnapshot(accountId, server, status, receivedAt);

    public void Remove(string accountId) => entries.TryRemove(accountId, out _);

    public IReadOnlyList<AccountSnapshot> Snapshot() => [.. entries.Values];
}
