using System.Globalization;

namespace OsbManager.Core.Status;

/// <summary>The columns, rows and summary of the SoX list. Hiding Star items only changes what is shown, never what is kept.</summary>
public static class SoxTable
{
    public static readonly IReadOnlyList<(string Title, int Width)> Columns =
    [
        ("Time", 130), ("Character", 110), ("Item", 220), ("Seal", 60), ("From", 160), ("Seen by", 100), ("Went to", 100),
    ];

    public static string[] Cells(SoxDrop drop, CultureInfo? culture = null) =>
    [
        drop.At.ToString("g", culture ?? CultureInfo.CurrentCulture), drop.Character, drop.Item, drop.Seal, drop.Monster, drop.SeenBy, drop.ReceivedBy ?? "",
    ];

    /// <summary>The drops the list shows, newest first.</summary>
    public static List<SoxDrop> Visible(IEnumerable<SoxDrop> drops, bool onlyMine, bool hideStar) =>
        drops.Where(d => (!onlyMine || d.Ours) && !(hideStar && d.Seal == "Star")).Reverse().ToList();

    public static string Summary(IReadOnlyCollection<SoxDrop> visible, bool onlyMine, bool hideStar)
    {
        var seals = hideStar ? new[] { "Moon", "Sun" } : ["Star", "Moon", "Sun"];
        var counts = string.Join(" · ", seals.Select(seal => $"{seal} {visible.Count(d => d.Seal == seal)}"));
        return counts + (onlyMine ? " by your characters" : " announced") + ". The game announces SoX drops to the whole server.";
    }
}
