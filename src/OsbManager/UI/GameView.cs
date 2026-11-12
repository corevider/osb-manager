using OsbManager.Core.Accounts;
using OsbManager.Core.Cache;
using OsbManager.Core.Status;

namespace OsbManager.UI;

/// <summary>What the main window shows about one open account: its state line, the last bot report and its window mode.</summary>
internal interface IGameView
{
    Account Account { get; }

    bool Light { get; }

    bool Hidden { get; }

    bool InGame { get; }

    BotStatus? Status { get; }

    string StateText { get; }
}

/// <summary>
/// Fixed windows, cache counters and memory numbers that the main window shows instead of live game windows. Only the
/// screenshot tool creates one; with it the main window starts no telemetry, update check or game window.
/// </summary>
internal sealed record ShowcaseFeed(IReadOnlyList<IGameView> Windows, CacheCounters Cache, MemoryReport Memory, DateTime SessionStart);
