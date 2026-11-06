using System.Text.RegularExpressions;

namespace OsbManager.Core.Status;

/// <summary>A Star, Moon or Sun item the game announced as dropped; ReceivedBy is the character whose bag it went to.</summary>
public sealed record SoxDrop(DateTime At, string Character, string Item, string Seal, string Monster, string Text, bool Ours, string SeenBy, string ReceivedBy = "");

/// <summary>
/// The game's server-wide SoX drop announcements ("X has dropped Y (Seal Of Star) from Z"), kept for every account in
/// one list. Several windows see the same announcement, so one seen again within two minutes is kept once. Item pickup
/// notices fill in who received a drop: a notice up to ten minutes after the announcement, or up to two minutes before it.
/// </summary>
public sealed partial class SoxLog
{
    public const int Capacity = 1000;
    private static readonly TimeSpan SameWindow = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan ReceivedAfter = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ReceivedBefore = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan SamePickup = TimeSpan.FromSeconds(10);
    private const int ReceiptCapacity = 500;

    private readonly string path;
    private readonly Func<DateTime> clock;
    private readonly List<SoxDrop> drops;
    private readonly List<PendingReceipt> receipts = [];
    private readonly HashSet<string> keysSeen = [];
    private readonly object sync = new();

    public SoxLog(string path, Func<DateTime>? clock = null)
    {
        this.path = path;
        this.clock = clock ?? (() => DateTime.Now);
        try
        {
            drops = JsonFile.Read<List<SoxDrop>>(path)?.Where(d => d is not null).Select(d => d.ReceivedBy is null ? d with { ReceivedBy = "" } : d)
                .TakeLast(Capacity).ToList() ?? [];
        }
        catch (System.Text.Json.JsonException)
        {
            drops = [];
        }
    }

    public event Action<SoxDrop>? Added;

    public event Action<SoxDrop>? Updated;

    public IReadOnlyList<SoxDrop> Drops
    {
        get { lock (sync) { return [.. drops]; } }
    }

    /// <summary>
    /// Reads an announcement; returns null when it is not a SoX drop. Sun drops come as the game's banner notice, which
    /// starts with "SEAL OF SUN: " and may leave out the "(Seal Of Sun)" after the item.
    /// </summary>
    public static (string Character, string Item, string Seal, string Monster)? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }
        var line = text.Trim();
        var sunBanner = line.StartsWith(SunBanner, StringComparison.OrdinalIgnoreCase);
        if (sunBanner)
        {
            line = line[SunBanner.Length..];
        }
        var match = Announcement().Match(line);
        if (!match.Success || !match.Groups["seal"].Success && !sunBanner)
        {
            return null;
        }
        var seal = match.Groups["seal"].Success ? Seals.First(s => s.Equals(match.Groups["seal"].Value, StringComparison.OrdinalIgnoreCase)) : "Sun";
        return (match.Groups["who"].Value.Trim(), match.Groups["item"].Value.Trim(), seal, match.Groups["from"].Value.Trim());
    }

    private const string SunBanner = "SEAL OF SUN: ";
    private static readonly string[] Seals = ["Star", "Moon", "Sun"];

    /// <summary>Adds an announcement seen by an account; ours lists the character names of this app's accounts.</summary>
    public SoxDrop? Add(string text, string seenBy, IReadOnlyCollection<string> ours)
    {
        if (Parse(text) is not { } parsed)
        {
            return null;
        }
        var now = clock();
        SoxDrop drop;
        lock (sync)
        {
            var same = (SoxDrop d) => d.Text == text || string.Equals(d.Character, parsed.Character, StringComparison.OrdinalIgnoreCase)
                && string.Equals(d.Item, parsed.Item, StringComparison.OrdinalIgnoreCase) && d.Seal == parsed.Seal;
            if (drops.Any(d => same(d) && now - d.At < SameWindow))
            {
                return null;
            }
            var mine = ours.Any(name => string.Equals(name, parsed.Character, StringComparison.OrdinalIgnoreCase));
            drop = new SoxDrop(now, parsed.Character, parsed.Item, parsed.Seal, parsed.Monster, text, mine, seenBy);
            Prune(now);
            var waiting = receipts.LastOrDefault(r => !r.Matched && SameItem(r.Item, drop.Item) && now - r.At <= ReceivedBefore);
            if (waiting is not null)
            {
                waiting.Matched = true;
                drop = drop with { ReceivedBy = waiting.Receiver };
            }
            drops.Add(drop);
            if (drops.Count > Capacity)
            {
                drops.RemoveRange(0, drops.Count - Capacity);
            }
            Save();
        }
        Added?.Invoke(drop);
        return drop;
    }

    /// <summary>
    /// Reads an item pickup notice a window saw; ownCharacter is that window's character. The newest drop of the same
    /// item without a receiver, announced up to ten minutes before, gets it; otherwise the notice waits two minutes for
    /// its announcement. The same pickup seen by several windows counts once.
    /// </summary>
    public SoxReceiptResult Receive(SoxReceipt receipt, string? ownCharacter)
    {
        var now = clock();
        SoxDrop updated;
        SoxReceiptResult result;
        lock (sync)
        {
            var newKey = !SoxReceipt.KnownKeys.Contains(receipt.Key) && keysSeen.Add(receipt.Key);
            var soxItem = drops.Any(d => SameItem(d.Item, receipt.Item));
            var receiver = receipt.Receiver(ownCharacter);
            Prune(now);
            if (receiver is null)
            {
                return new SoxReceiptResult(SoxReceiptOutcome.Unknown, null, null, newKey, soxItem);
            }
            if (receipts.Any(r => SameItem(r.Item, receipt.Item) && string.Equals(r.Receiver, receiver, StringComparison.OrdinalIgnoreCase) && now - r.At < SamePickup))
            {
                return new SoxReceiptResult(SoxReceiptOutcome.Repeated, receiver, null, newKey, soxItem);
            }
            var pending = new PendingReceipt(receipt.Item, receiver, now);
            receipts.Add(pending);
            if (receipts.Count > ReceiptCapacity)
            {
                receipts.RemoveRange(0, receipts.Count - ReceiptCapacity);
            }
            var index = drops.FindLastIndex(d => d.ReceivedBy.Length == 0 && SameItem(d.Item, receipt.Item) && now >= d.At && now - d.At <= ReceivedAfter);
            if (index < 0)
            {
                return new SoxReceiptResult(SoxReceiptOutcome.Waiting, receiver, null, newKey, soxItem);
            }
            pending.Matched = true;
            updated = drops[index] = drops[index] with { ReceivedBy = receiver };
            Save();
            result = new SoxReceiptResult(SoxReceiptOutcome.Matched, receiver, updated, newKey, soxItem);
        }
        Updated?.Invoke(updated);
        return result;
    }

    public void Clear()
    {
        lock (sync)
        {
            drops.Clear();
            receipts.Clear();
            JsonFile.Write(path, drops);
        }
    }

    private static bool SameItem(string a, string b) => string.Equals(a.Trim(), b.Trim(), StringComparison.OrdinalIgnoreCase);

    private void Prune(DateTime now) => receipts.RemoveAll(r => now - r.At > ReceivedAfter);

    private void Save()
    {
        try
        {
            JsonFile.Write(path, drops);
        }
        catch (IOException)
        {
        }
    }

    [GeneratedRegex(@"^(?:\(Notice\):\s*)?(?<who>.+?) has dropped (?<item>.+?)(?: \(Seal Of (?<seal>Star|Moon|Sun)\))?(?: from (?<from>.+?))?\.?$", RegexOptions.IgnoreCase)]
    private static partial Regex Announcement();

    private sealed class PendingReceipt(string item, string receiver, DateTime at)
    {
        public string Item { get; } = item;
        public string Receiver { get; } = receiver;
        public DateTime At { get; } = at;
        public bool Matched { get; set; }
    }
}

/// <summary>
/// An item pickup notice from the game's system log: the window's own pickup (UIIT_MSG_STATE_GET_ITEM...) or a party
/// member's (UIIT_MSG_PARTYGET_ITEM..., with the member's name). InParty is true when the page found the member in the
/// window's party list.
/// </summary>
public sealed partial record SoxReceipt(string Key, string Item, string Member, bool InParty, long? Count)
{
    public static readonly IReadOnlyList<string> KnownKeys = ["UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", "UIIT_MSG_PARTYGET_ITEM_EXPENDABLE"];

    public bool PartyGet => Key.StartsWith("UIIT_MSG_PARTYGET_ITEM", StringComparison.Ordinal);

    public static bool IsReceiveKey(string key) => ReceiveKey().IsMatch(key);

    /// <summary>Who received the item, or null when it cannot be told for sure.</summary>
    public string? Receiver(string? ownCharacter)
    {
        var name = PartyGet ? (InParty ? Member : null) : ownCharacter;
        return string.IsNullOrWhiteSpace(name) ? null : name.Trim();
    }

    [GeneratedRegex("^UIIT_MSG_(PARTYGET|STATE_GET)_ITEM[A-Z_]{0,40}$")]
    private static partial Regex ReceiveKey();
}

public enum SoxReceiptOutcome
{
    Unknown,
    Repeated,
    Matched,
    Waiting,
}

/// <summary>What became of a pickup notice; Log tells whether it is worth a line in the app log.</summary>
public sealed record SoxReceiptResult(SoxReceiptOutcome Outcome, string? Receiver, SoxDrop? Drop, bool NewKey, bool SoxItem)
{
    public bool Log => NewKey || SoxItem && Outcome is SoxReceiptOutcome.Unknown or SoxReceiptOutcome.Waiting;
}
