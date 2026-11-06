using System.Globalization;
using System.Text.Json;

namespace OsbManager.Core.Status;

public sealed record SessionStats(long Milliseconds, long Kills, long Deaths, long? Experience, long? Gold, long Sox = 0);

/// <summary>What the page bridge reports once a second. The page is untrusted, so every field is optional and bounded.</summary>
public sealed record BotStatus
{
    public const int MaxMessageLength = 16 * 1024;
    private const int MaxText = 64;

    public string? BotVersion { get; init; }
    public string? Phase { get; init; }
    public string? Character { get; init; }
    public bool InWorld { get; init; }
    public bool Dead { get; init; }
    public int? Level { get; init; }
    public long? Gold { get; init; }
    public double? HpPercent { get; init; }
    public double? MpPercent { get; init; }
    public int? Region { get; init; }
    public bool Hunting { get; init; }
    public bool TownTrip { get; init; }
    public bool Light { get; init; }

    /// <summary>Light mode is wanted but waits until the world has loaded.</summary>
    public bool LightWaiting { get; init; }

    /// <summary>How many times the game's WebGPU device had to be requested again because the graphics card was full.</summary>
    public int GpuRetries { get; init; }

    /// <summary>Why the game's renderer could not start after the retries, if it could not.</summary>
    public string? GpuFailed { get; init; }

    /// <summary>How many retries the page makes before it gives up; 0 when the page does not say.</summary>
    public int GpuRetryLimit { get; init; }

    /// <summary>Seconds until the page tries to start the renderer again; 0 when no retry is waiting.</summary>
    public int GpuRetryIn { get; init; }

    /// <summary>Return scrolls (any kind) in the character's bag.</summary>
    public int? ReturnScrolls { get; init; }

    /// <summary>Reverse return scrolls in the character's bag.</summary>
    public int? ReverseScrolls { get; init; }

    /// <summary>New SoX drop announcements the game showed since the last report, at most 20.</summary>
    public IReadOnlyList<string> Drops { get; init; } = [];

    /// <summary>New item pickup notices of the character or its party since the last report, at most 20.</summary>
    public IReadOnlyList<SoxReceipt> Received { get; init; } = [];

    /// <summary>The page bridge holds the game's simulation worker and can send it session commands.</summary>
    public bool Linked { get; init; }
    public SessionStats? Session { get; init; }

    /// <summary>Automatic login progress: off, waiting, title, server, credentials, connecting, retry, character, entering, choose, done or failed.</summary>
    public string? LoginStage { get; init; }
    public string? LoginMessage { get; init; }

    /// <summary>The "type" of a page message, or null when it is not a small JSON object with one.</summary>
    public static string? MessageType(string? json)
    {
        if (json is null || json.Length > MaxMessageLength)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
            return document.RootElement.ValueKind == JsonValueKind.Object ? Text(document.RootElement, "type") : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static BotStatus? TryParse(string? json)
    {
        if (json is null || json.Length > MaxMessageLength)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || Text(root, "type") != "status")
            {
                return null;
            }
            return new BotStatus
            {
                BotVersion = Text(root, "bot"),
                Phase = Text(root, "phase"),
                Character = Text(root, "character"),
                InWorld = Flag(root, "inWorld"),
                Dead = Flag(root, "dead"),
                Level = (int?)Whole(root, "level", 0, 1000),
                Gold = Integer(root, "gold"),
                HpPercent = Percent(root, "hp"),
                MpPercent = Percent(root, "mp"),
                Region = (int?)Whole(root, "region", 0, int.MaxValue),
                Hunting = Flag(root, "hunting"),
                TownTrip = Flag(root, "town"),
                Light = Flag(root, "light"),
                LightWaiting = Flag(root, "lightWaiting"),
                GpuRetries = root.TryGetProperty("gpu", out var gpu) && gpu.ValueKind == JsonValueKind.Object ? (int)(Whole(gpu, "retries", 0, 100) ?? 0) : 0,
                GpuFailed = gpu.ValueKind == JsonValueKind.Object ? Text(gpu, "failed", 200) : null,
                GpuRetryLimit = gpu.ValueKind == JsonValueKind.Object ? (int)(Whole(gpu, "limit", 0, 100) ?? 0) : 0,
                GpuRetryIn = gpu.ValueKind == JsonValueKind.Object ? (int)(Whole(gpu, "retryIn", 0, 3600) ?? 0) : 0,
                Linked = Flag(root, "linked"),
                Session = root.TryGetProperty("session", out var session) && session.ValueKind == JsonValueKind.Object
                    ? new SessionStats(
                        Whole(session, "ms", 0, long.MaxValue) ?? 0,
                        Whole(session, "kills", 0, long.MaxValue) ?? 0,
                        Whole(session, "deaths", 0, long.MaxValue) ?? 0,
                        Integer(session, "xp"),
                        Integer(session, "gold"),
                        Whole(session, "sox", 0, long.MaxValue) ?? 0)
                    : null,
                ReturnScrolls = root.TryGetProperty("scrolls", out var scrolls) && scrolls.ValueKind == JsonValueKind.Object ? (int?)Whole(scrolls, "ret", 0, 1_000_000) : null,
                ReverseScrolls = scrolls.ValueKind == JsonValueKind.Object ? (int?)Whole(scrolls, "reverse", 0, 1_000_000) : null,
                Drops = root.TryGetProperty("drops", out var drops) && drops.ValueKind == JsonValueKind.Array
                    ? drops.EnumerateArray().Where(d => d.ValueKind == JsonValueKind.String).Take(20)
                        .Select(d => new string(d.GetString()!.Where(c => !char.IsControl(c)).Take(300).ToArray())).Where(d => d.Length > 0).ToList()
                    : [],
                Received = root.TryGetProperty("received", out var received) && received.ValueKind == JsonValueKind.Array
                    ? received.EnumerateArray().Where(r => r.ValueKind == JsonValueKind.Object).Take(20).Select(Receipt).OfType<SoxReceipt>().ToList()
                    : [],
                LoginStage = root.TryGetProperty("login", out var login) && login.ValueKind == JsonValueKind.Object ? Text(login, "stage") : null,
                LoginMessage = login.ValueKind == JsonValueKind.Object ? Text(login, "message", 200) : null,
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static SoxReceipt? Receipt(JsonElement element)
    {
        var key = Text(element, "key");
        var item = Text(element, "item");
        if (key is null || item is null || !SoxReceipt.IsReceiveKey(key))
        {
            return null;
        }
        return new SoxReceipt(key, item, Text(element, "member") ?? "", Flag(element, "inParty"), Whole(element, "count", 0, int.MaxValue));
    }

    private static string? Text(JsonElement element, string name, int maxLength = MaxText)
    {
        if (!element.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }
        var text = new string(value.GetString()!.Where(c => !char.IsControl(c)).Take(maxLength).ToArray());
        return text.Length == 0 ? null : text;
    }

    private static bool Flag(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static long? Whole(JsonElement element, string name, long min, long max)
    {
        if (!element.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var number))
        {
            return null;
        }
        if (double.IsNaN(number) || number < min || number > max)
        {
            return null;
        }
        return (long)Math.Floor(number);
    }

    private static double? Percent(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var number))
        {
            return null;
        }
        return double.IsFinite(number) ? Math.Clamp(number, 0, 100) : null;
    }

    private static long? Integer(JsonElement element, string name)
    {
        var text = Text(element, name);
        return long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number) ? number : null;
    }
}
