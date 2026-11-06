using System.Globalization;

namespace OsbManager.Core.Status;

public static class Format
{
    public const string Missing = "—";

    public static string Compact(long? value, CultureInfo? culture = null)
    {
        if (value is not { } number)
        {
            return Missing;
        }
        culture ??= CultureInfo.CurrentCulture;
        var magnitude = Math.Abs((double)number);
        return magnitude switch
        {
            >= 1e9 => (number / 1e9).ToString("0.##", culture) + "B",
            >= 1e6 => (number / 1e6).ToString("0.##", culture) + "M",
            >= 1e5 => (number / 1e3).ToString("0.#", culture) + "K",
            _ => number.ToString("N0", culture),
        };
    }

    public static string Duration(long milliseconds)
    {
        var time = TimeSpan.FromMilliseconds(Math.Max(0, milliseconds));
        var hours = (long)time.TotalHours;
        return hours > 0 ? $"{hours}h {time.Minutes:00}m" : $"{time.Minutes}m";
    }

    /// <summary>A per-hour rate, shown only after 30 seconds so the first kills do not read as huge rates.</summary>
    public static string PerHour(long? value, long milliseconds, CultureInfo? culture = null)
    {
        if (value is null || milliseconds < 30_000)
        {
            return Missing;
        }
        return Compact((long)Math.Round(value.Value * 3_600_000.0 / milliseconds), culture);
    }

    public static string PerHour(double? rate, CultureInfo? culture = null) =>
        rate is { } value ? Compact((long)Math.Round(value), culture) : Missing;

    public static string Bytes(long bytes, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        return bytes switch
        {
            >= 1L << 30 => (bytes / (double)(1L << 30)).ToString("0.0", culture) + " GB",
            >= 1L << 20 => (bytes / (double)(1L << 20)).ToString("0", culture) + " MB",
            >= 1L << 10 => (bytes / (double)(1L << 10)).ToString("0", culture) + " KB",
            _ => bytes.ToString(culture) + " B",
        };
    }

    public static string Percent(double? value) => value is { } number ? $"{Math.Round(number):0}%" : Missing;
}
