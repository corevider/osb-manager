using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using OsbManager.Core.Accounts;

namespace OsbManager.Core.Telemetry;

public enum ConsentStatus
{
    Undecided,
    Declined,
    Granted,
    Withdrawn,
    Outdated,
}

public sealed record InstallCredentials(string Id, string Key)
{
    public string Bearer => $"osb1.{Id}.{Key}";

    public byte[] KeyBytes() => PrivacyStore.DecodeKey(Key) ?? [];
}

public sealed record PrivacyState(
    ConsentStatus Status,
    int UsageConsentVersion,
    string? UsageConsentTextId,
    DateTimeOffset? UsageConsentedAt,
    bool CharactersConsent,
    DateTimeOffset? CharactersConsentedAt,
    DateTimeOffset? DecidedAt,
    string? InstallId,
    bool Registered,
    bool ServerKnowsCharacters,
    TelemetryConfig? Config,
    DateTimeOffset? ConfigFetchedAt,
    DateTimeOffset? LastSentAt,
    string? LastResult)
{
    public bool Granted => Status == ConsentStatus.Granted;

    public bool NeedsAnswer => Status is ConsentStatus.Undecided or ConsentStatus.Outdated;

    public bool SharedBefore => Status == ConsentStatus.Outdated;
}

public sealed record WithdrawResult(InstallCredentials? Credentials, bool WasRegistered);

internal sealed class PrivacyFile
{
    public int UsageConsentVersion { get; set; }
    public string? UsageConsentTextId { get; set; }
    public DateTimeOffset? UsageConsentedAt { get; set; }
    public bool CharactersConsent { get; set; }
    public DateTimeOffset? CharactersConsentedAt { get; set; }

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ConsentStatus Decision { get; set; } = ConsentStatus.Undecided;

    public DateTimeOffset? DecidedAt { get; set; }
    public string? InstallId { get; set; }
    public string? ProtectedInstallKey { get; set; }
    public bool Registered { get; set; }
    public bool ServerKnowsCharacters { get; set; }
    public TelemetryConfig? LastConfig { get; set; }
    public DateTimeOffset? ConfigFetchedAt { get; set; }
    public DateTimeOffset? LastSentAt { get; set; }
    public string? LastResult { get; set; }
}

/// <summary>
/// The consent record and the install identity, kept in privacy.json. Consent is off unless the file holds an
/// accepted, current consent with a valid identity; anything else, including a corrupt file, is off. The install key
/// is stored only DPAPI-protected. Safe to use from any thread.
/// </summary>
public sealed class PrivacyStore
{
    private readonly object sync = new();
    private readonly string path;
    private readonly ICredentialProtector protector;
    private readonly TimeProvider time;
    private readonly Action<string> log;
    private PrivacyFile file;
    private string? installKey;
    private int epoch;

    private PrivacyStore(string path, ICredentialProtector protector, TimeProvider time, Action<string> log, PrivacyFile file, string? installKey)
    {
        this.path = path;
        this.protector = protector;
        this.time = time;
        this.log = log;
        this.file = file;
        this.installKey = installKey;
    }

    public event Action? Changed;

    public int Epoch
    {
        get { lock (sync) { return epoch; } }
    }

    public PrivacyState State
    {
        get { lock (sync) { return Snapshot(); } }
    }

    public InstallCredentials? Credentials
    {
        get { lock (sync) { return Snapshot().Granted && file.InstallId is { } id && installKey is { } key ? new InstallCredentials(id, key) : null; } }
    }

    public static PrivacyStore Load(string path, ICredentialProtector protector, TimeProvider? time = null, Action<string>? log = null)
    {
        var sink = log ?? (_ => { });
        PrivacyFile file;
        try
        {
            file = JsonFile.Read<PrivacyFile>(path) ?? new PrivacyFile();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or NotSupportedException)
        {
            sink("privacy.json could not be read; usage statistics stay off.");
            return new PrivacyStore(path, protector, time ?? TimeProvider.System, sink, new PrivacyFile(), null);
        }
        string? key = null;
        if (file.UsageConsentVersion > 0 || file.InstallId is not null || file.ProtectedInstallKey is not null)
        {
            key = file.ProtectedInstallKey is { } sealedKey ? protector.Unprotect(sealedKey) : null;
            if (!Guid.TryParseExact(file.InstallId, "D", out _) || DecodeKey(key) is null)
            {
                sink("privacy.json holds no valid install identity; usage statistics are off.");
                file = new PrivacyFile { Decision = ConsentStatus.Undecided };
                key = null;
            }
        }
        if (file.Decision is ConsentStatus.Granted or ConsentStatus.Outdated)
        {
            file.Decision = ConsentStatus.Undecided;
        }
        return new PrivacyStore(path, protector, time ?? TimeProvider.System, sink, file, key);
    }

    public static bool IsCurrentTextId(string? textId) =>
        textId is not null && string.CompareOrdinal(textId, TelemetryLimits.ConsentTextId) >= 0;

    public static byte[]? DecodeKey(string? key)
    {
        if (key is null || key.Length != 43)
        {
            return null;
        }
        try
        {
            var bytes = Convert.FromBase64String(key.Replace('-', '+').Replace('_', '/') + "=");
            return bytes.Length == 32 ? bytes : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    public static string NewInstallId()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x40);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        return new Guid(bytes, bigEndian: true).ToString("D");
    }

    public static string NewInstallKey() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public PrivacyState Grant(bool characters)
    {
        PrivacyState state;
        lock (sync)
        {
            var now = time.GetUtcNow();
            var wasGranted = Snapshot().Granted;
            if (!wasGranted)
            {
                if (file.InstallId is null || installKey is null)
                {
                    var newKey = NewInstallKey();
                    string sealedKey;
                    try
                    {
                        sealedKey = protector.Protect(newKey);
                    }
                    catch (CryptographicException)
                    {
                        log("The install key could not be protected for this Windows user; usage statistics stay off.");
                        return Snapshot();
                    }
                    file.InstallId = NewInstallId();
                    installKey = newKey;
                    file.ProtectedInstallKey = sealedKey;
                }
                file.Registered = false;
                file.ServerKnowsCharacters = false;
                file.UsageConsentVersion = TelemetryLimits.ConsentVersion;
                file.UsageConsentTextId = TelemetryLimits.ConsentTextId;
                file.UsageConsentedAt = now;
                file.Decision = ConsentStatus.Granted;
                file.DecidedAt = now;
                file.LastSentAt = null;
                file.LastResult = null;
            }
            ApplyCharacters(characters, now);
            epoch++;
            Save();
            state = Snapshot();
        }
        Changed?.Invoke();
        return state;
    }

    public bool SetCharacters(bool on)
    {
        bool changed;
        lock (sync)
        {
            if (!Snapshot().Granted)
            {
                return false;
            }
            changed = file.CharactersConsent != on;
            ApplyCharacters(on, time.GetUtcNow());
            if (changed)
            {
                Save();
            }
        }
        if (changed)
        {
            Changed?.Invoke();
        }
        return changed;
    }

    public void Decline()
    {
        lock (sync)
        {
            if (Snapshot().Granted)
            {
                return;
            }
            file.Decision = ConsentStatus.Declined;
            file.DecidedAt = time.GetUtcNow();
            epoch++;
            Save();
        }
        Changed?.Invoke();
    }

    public WithdrawResult Withdraw()
    {
        WithdrawResult result;
        lock (sync)
        {
            var credentials = file.InstallId is { } id && installKey is { } key ? new InstallCredentials(id, key) : null;
            result = new WithdrawResult(credentials, credentials is not null && file.Registered);
            file = new PrivacyFile { Decision = ConsentStatus.Withdrawn, DecidedAt = time.GetUtcNow() };
            installKey = null;
            epoch++;
            Save();
        }
        Changed?.Invoke();
        return result;
    }

    public void MarkRegistered(string installId, bool charactersSent)
    {
        Update(installId, f =>
        {
            f.Registered = true;
            f.ServerKnowsCharacters = charactersSent;
        });
    }

    public void MarkUnregistered(string installId) => Update(installId, f => f.Registered = false);

    public void MarkCharactersSynced(string installId, bool value) => Update(installId, f => f.ServerKnowsCharacters = value);

    public InstallCredentials? ReplaceIdentity(string installId)
    {
        InstallCredentials? replacement = null;
        lock (sync)
        {
            if (!Snapshot().Granted || file.InstallId != installId)
            {
                return null;
            }
            file.InstallId = NewInstallId();
            installKey = NewInstallKey();
            file.ProtectedInstallKey = protector.Protect(installKey);
            file.Registered = false;
            file.ServerKnowsCharacters = false;
            Save();
            replacement = new InstallCredentials(file.InstallId, installKey);
        }
        return replacement;
    }

    public void StoreConfig(string installId, TelemetryConfig config) => Update(installId, f =>
    {
        f.LastConfig = config;
        f.ConfigFetchedAt = time.GetUtcNow();
    });

    public void RecordSend(string installId, string result, bool sent) => Update(installId, f =>
    {
        f.LastResult = result;
        if (sent)
        {
            f.LastSentAt = time.GetUtcNow();
        }
    });

    private void Update(string installId, Action<PrivacyFile> change)
    {
        lock (sync)
        {
            if (!Snapshot().Granted || file.InstallId != installId)
            {
                return;
            }
            change(file);
            Save();
        }
    }

    private void ApplyCharacters(bool on, DateTimeOffset now)
    {
        if (file.CharactersConsent == on)
        {
            return;
        }
        file.CharactersConsent = on;
        file.CharactersConsentedAt = on ? now : null;
    }

    private PrivacyState Snapshot()
    {
        var current = file.UsageConsentVersion >= TelemetryLimits.ConsentVersion
            && IsCurrentTextId(file.UsageConsentTextId)
            && file.InstallId is not null
            && installKey is not null;
        var status = current
            ? ConsentStatus.Granted
            : file.UsageConsentVersion > 0 ? ConsentStatus.Outdated : file.Decision;
        if (status == ConsentStatus.Granted)
        {
            return Build(status, file.CharactersConsent);
        }
        return Build(status, false);
    }

    private PrivacyState Build(ConsentStatus status, bool characters) => new(
        status,
        file.UsageConsentVersion,
        file.UsageConsentTextId,
        file.UsageConsentedAt,
        characters,
        characters ? file.CharactersConsentedAt : null,
        file.DecidedAt,
        file.InstallId,
        file.Registered,
        file.ServerKnowsCharacters,
        file.LastConfig,
        file.ConfigFetchedAt,
        file.LastSentAt,
        file.LastResult);

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            JsonFile.Write(path, file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            log($"privacy.json could not be saved: {e.GetType().Name}.");
        }
    }
}
