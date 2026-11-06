using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using OsbManager.Core.Status;

namespace OsbManager.Core.Telemetry;

public sealed class ScrollsDto
{
    [JsonPropertyName("return")] public int? Return { get; init; }
    [JsonPropertyName("reverse")] public int? Reverse { get; init; }
}

public sealed class CharacterDto
{
    [JsonPropertyName("name")] public string? Name { get; init; }
    [JsonPropertyName("server")] public string? Server { get; init; }
}

public sealed class SessionDto
{
    [JsonPropertyName("key")] public required string Key { get; init; }
    [JsonPropertyName("ms")] public long Ms { get; init; }
    [JsonPropertyName("kills")] public long Kills { get; init; }
    [JsonPropertyName("deaths")] public long Deaths { get; init; }
    [JsonPropertyName("xp")] public string? Xp { get; init; }
    [JsonPropertyName("gold")] public string? Gold { get; init; }
    [JsonPropertyName("sox")] public long Sox { get; init; }
}

public sealed class AccountDto
{
    [JsonPropertyName("slot")] public required string Slot { get; init; }
    [JsonPropertyName("state")] public required string State { get; init; }
    [JsonPropertyName("level")] public int? Level { get; init; }
    [JsonPropertyName("gold")] public string? Gold { get; init; }
    [JsonPropertyName("hp_pct")] public int? HpPct { get; init; }
    [JsonPropertyName("mp_pct")] public int? MpPct { get; init; }
    [JsonPropertyName("scrolls")] public ScrollsDto? Scrolls { get; init; }
    [JsonPropertyName("bot_version")] public string? BotVersion { get; init; }
    [JsonPropertyName("character")] public CharacterDto? Character { get; init; }
    [JsonPropertyName("session")] public SessionDto? Session { get; init; }
}

public sealed class TelemetryDto
{
    [JsonPropertyName("schema")] public int Schema { get; init; } = 1;
    [JsonPropertyName("app_version")] public required string AppVersion { get; init; }
    [JsonPropertyName("accounts")] public required IReadOnlyList<AccountDto> Accounts { get; init; }
}

public sealed record TelemetryBatch(byte[] Body, int Accounts, Action Commit);

/// <summary>
/// Turns the open windows' latest reports into the body of POST /v1/telemetry. It keeps what the last accepted batch
/// held, so it must be used from one thread only (the scheduler's).
/// </summary>
public sealed partial class TelemetryPayloadBuilder
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private const long MaxSessionMilliseconds = 2_592_000_000;
    private const long MaxCounter = 10_000_000;
    private const int MaxNameLength = 32;

    private readonly string appVersion;
    private readonly TimeProvider time;
    private readonly int maxBytes;
    private readonly Dictionary<string, SessionTrack> sessions = new();
    private readonly Dictionary<string, Reported> reported = new();

    public TelemetryPayloadBuilder(string appVersion, TimeProvider time, int maxBytes = TelemetryLimits.SoftBodyBytes)
    {
        this.appVersion = appVersion;
        this.time = time;
        this.maxBytes = Math.Min(maxBytes, TelemetryLimits.MaxBodyBytes);
    }

    public static string Slot(byte[] installKey, string accountId)
    {
        var hash = HMACSHA256.HashData(installKey, Encoding.UTF8.GetBytes("slot:" + accountId));
        return Convert.ToHexStringLower(hash.AsSpan(0, 8));
    }

    public TelemetryBatch? Build(IReadOnlyList<AccountSnapshot> snapshots, byte[] installKey, bool includeCharacters)
    {
        var now = time.GetUtcNow();
        var fresh = snapshots
            .Where(s => now - s.ReceivedAt < TelemetryLimits.StatusMaxAge)
            .OrderByDescending(s => s.ReceivedAt)
            .Take(TelemetryLimits.MaxAccounts)
            .ToList();
        var entries = new List<(AccountDto Dto, string Id, string Fingerprint)>();
        foreach (var snapshot in fresh)
        {
            var dto = Describe(snapshot, installKey, includeCharacters);
            var fingerprint = JsonSerializer.Serialize(new AccountDto
            {
                Slot = dto.Slot, State = dto.State, Level = dto.Level, Gold = dto.Gold, HpPct = dto.HpPct, MpPct = dto.MpPct,
                Scrolls = dto.Scrolls, BotVersion = dto.BotVersion, Character = dto.Character,
            }, JsonOptions);
            var previous = reported.GetValueOrDefault(snapshot.AccountId);
            var unchanged = previous is not null && previous.Fingerprint == fingerprint && dto.Session is null
                && now - previous.SentAt < TelemetryLimits.UnchangedResend;
            if (!unchanged)
            {
                entries.Add((dto, snapshot.AccountId, fingerprint));
            }
        }
        var present = fresh.Select(s => s.AccountId).ToHashSet();
        var gone = reported.Where(r => !present.Contains(r.Key)).Select(r => r.Key).ToList();
        foreach (var id in gone)
        {
            if (entries.Count < TelemetryLimits.MaxAccounts)
            {
                entries.Add((new AccountDto { Slot = reported[id].Slot, State = AccountStates.Offline }, id, ""));
            }
        }
        if (entries.Count == 0)
        {
            return null;
        }
        var body = Serialize(entries.Select(e => e.Dto).ToList());
        while (body.Length > maxBytes && entries.Count > 1)
        {
            entries.RemoveAt(entries.Count - 1);
            body = Serialize(entries.Select(e => e.Dto).ToList());
        }
        if (body.Length > TelemetryLimits.MaxBodyBytes)
        {
            return null;
        }
        var sent = entries.ToList();
        var sentAt = now;
        return new TelemetryBatch(body, sent.Count, () =>
        {
            foreach (var entry in sent)
            {
                if (entry.Dto.State == AccountStates.Offline)
                {
                    reported.Remove(entry.Id);
                    sessions.Remove(entry.Id);
                }
                else
                {
                    reported[entry.Id] = new Reported(entry.Dto.Slot, entry.Fingerprint, sentAt);
                }
            }
        });
    }

    private byte[] Serialize(IReadOnlyList<AccountDto> accounts) =>
        JsonSerializer.SerializeToUtf8Bytes(new TelemetryDto { AppVersion = appVersion, Accounts = accounts }, JsonOptions);

    private AccountDto Describe(AccountSnapshot snapshot, byte[] installKey, bool includeCharacters)
    {
        var status = snapshot.Status;
        var world = status.InWorld;
        var scrolls = world && (Scroll(status.ReturnScrolls) is not null || Scroll(status.ReverseScrolls) is not null)
            ? new ScrollsDto { Return = Scroll(status.ReturnScrolls), Reverse = Scroll(status.ReverseScrolls) }
            : null;
        return new AccountDto
        {
            Slot = Slot(installKey, snapshot.AccountId),
            State = AccountStates.Map(status),
            Level = status.Level is >= 1 and <= 255 ? status.Level : null,
            Gold = world && status.Gold is >= 0 ? status.Gold.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : null,
            HpPct = world ? Percent(status.HpPercent) : null,
            MpPct = world ? Percent(status.MpPercent) : null,
            Scrolls = scrolls,
            BotVersion = BotVersionPattern().IsMatch(status.BotVersion ?? "") && status.BotVersion!.Length <= 32 ? status.BotVersion : null,
            Character = includeCharacters ? Character(status.Character, snapshot.Server) : null,
            Session = Session(snapshot.AccountId, status.Session),
        };
    }

    private SessionDto? Session(string accountId, SessionStats? stats)
    {
        if (stats is null)
        {
            sessions.Remove(accountId);
            return null;
        }
        var previous = sessions.GetValueOrDefault(accountId);
        var key = previous is null || stats.Milliseconds < previous.Milliseconds || stats.Kills < previous.Kills || stats.Deaths < previous.Deaths
            ? Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8))
            : previous.Key;
        sessions[accountId] = new SessionTrack(key, stats.Milliseconds, stats.Kills, stats.Deaths);
        return new SessionDto
        {
            Key = key,
            Ms = Math.Clamp(stats.Milliseconds, 0, MaxSessionMilliseconds),
            Kills = Math.Clamp(stats.Kills, 0, MaxCounter),
            Deaths = Math.Clamp(stats.Deaths, 0, MaxCounter),
            Xp = stats.Experience is >= 0 ? stats.Experience.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : null,
            Gold = stats.Gold is >= 0 ? stats.Gold.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : null,
            Sox = Math.Clamp(stats.Sox, 0, MaxCounter),
        };
    }

    private static CharacterDto? Character(string? name, string server)
    {
        var cleanName = Name(name);
        var cleanServer = Name(server);
        return cleanName is null && cleanServer is null ? null : new CharacterDto { Name = cleanName, Server = cleanServer };
    }

    private static string? Name(string? value)
    {
        var text = new string((value ?? "").Where(c => !char.IsControl(c)).ToArray()).Trim();
        if (text.Length == 0)
        {
            return null;
        }
        var builder = new StringBuilder();
        var count = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (count++ == MaxNameLength)
            {
                break;
            }
            builder.Append(rune.ToString());
        }
        return builder.ToString();
    }

    private static int? Percent(double? value) => value is null ? null : (int)Math.Clamp(Math.Round(value.Value), 0, 100);

    private static int? Scroll(int? value) => value is >= 0 and <= 100_000 ? value : null;

    [GeneratedRegex("^[0-9A-Za-z.+-]+$")]
    private static partial Regex BotVersionPattern();

    private sealed record SessionTrack(string Key, long Milliseconds, long Kills, long Deaths);

    private sealed record Reported(string Slot, string Fingerprint, DateTimeOffset SentAt);
}
