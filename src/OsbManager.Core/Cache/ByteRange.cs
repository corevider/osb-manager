using System.Globalization;

namespace OsbManager.Core.Cache;

/// <summary>An inclusive byte range, as written in an HTTP Range header.</summary>
public readonly record struct ByteRange(long Start, long End)
{
    public const long MaxLength = 64L << 20;

    public long Length => End - Start + 1;

    public long EndExclusive => End + 1;

    /// <summary>Accepts only a single closed range ("bytes=10-99"); anything else goes to the network untouched.</summary>
    public static bool TryParseHeader(string? header, out ByteRange range)
    {
        range = default;
        if (header is null || !header.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        var spec = header.AsSpan(6).Trim();
        var dash = spec.IndexOf('-');
        if (dash <= 0 || dash == spec.Length - 1 || spec.Contains(','))
        {
            return false;
        }
        if (!long.TryParse(spec[..dash], NumberStyles.None, CultureInfo.InvariantCulture, out var start)
            || !long.TryParse(spec[(dash + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var end))
        {
            return false;
        }
        if (end < start || end - start + 1 > MaxLength)
        {
            return false;
        }
        range = new ByteRange(start, end);
        return true;
    }
}
