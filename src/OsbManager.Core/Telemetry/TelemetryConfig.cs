using System.Text.Json;

namespace OsbManager.Core.Telemetry;

public static class TelemetryLimits
{
    public const int ConsentVersion = 1;
    public const string ConsentTextId = "2026-11-04.1";
    public const int MinIntervalSeconds = 300;
    public const int MaxIntervalSeconds = 86400;
    public const int DefaultIntervalSeconds = 600;
    public const int MaxMessageLength = 200;
    public const int MaxAccounts = 20;
    public const int MaxBodyBytes = 64 * 1024;
    public const int SoftBodyBytes = 60_000;
    public const int MaxResponseBytes = 64 * 1024;
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan ConfigRefresh = TimeSpan.FromHours(6);
    public static readonly TimeSpan ConfigMaxAge = TimeSpan.FromHours(24);
    public static readonly TimeSpan StatusMaxAge = TimeSpan.FromMinutes(2);
    public static readonly TimeSpan UnchangedResend = TimeSpan.FromHours(1);
    public static readonly TimeSpan MinWait = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan MaxWait = TimeSpan.FromHours(24);
    public static readonly TimeSpan BackoffBase = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan BackoffCap = TimeSpan.FromHours(6);
    public static readonly TimeSpan StartDelayMin = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan StartDelayMax = TimeSpan.FromSeconds(180);
    public static readonly TimeSpan ForbiddenPause = TimeSpan.FromHours(24);
    public static readonly TimeSpan ReportExpiry = TimeSpan.FromHours(72);
    public const string AppName = "manager-win";
    public const string OsName = "windows";
}

/// <summary>What the server's GET /v1/config says. A missing or malformed answer is <see cref="Disabled"/>.</summary>
public sealed record TelemetryConfig(bool TelemetryEnabled, int IntervalSeconds, bool ReportsEnabled, bool ScreenshotsEnabled, bool ClientOk, string? Message)
{
    public static TelemetryConfig Disabled { get; } = new(false, TelemetryLimits.DefaultIntervalSeconds, false, false, true, null);

    public static TelemetryConfig? TryParse(ReadOnlySpan<byte> json)
    {
        try
        {
            using var document = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions { MaxDepth = 6 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("schema", out var schema) || !schema.TryGetInt32(out var schemaNumber) || schemaNumber != 1
                || !TryObject(root, "telemetry", out var telemetry)
                || !TryObject(root, "reports", out var reports)
                || !TryFlag(telemetry, "enabled", out var telemetryEnabled)
                || !TryFlag(reports, "enabled", out var reportsEnabled)
                || !TryFlag(root, "client_ok", out var clientOk)
                || !telemetry.TryGetProperty("interval_s", out var interval) || !interval.TryGetInt64(out var intervalSeconds))
            {
                return null;
            }
            var screenshots = TryFlag(reports, "screenshots", out var screenshotsEnabled) && screenshotsEnabled;
            var message = root.TryGetProperty("message", out var text) && text.ValueKind == JsonValueKind.String ? Clean(text.GetString()!) : null;
            return new TelemetryConfig(
                telemetryEnabled,
                (int)Math.Clamp(intervalSeconds, TelemetryLimits.MinIntervalSeconds, TelemetryLimits.MaxIntervalSeconds),
                reportsEnabled,
                screenshots,
                clientOk,
                message);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool TryObject(JsonElement parent, string name, out JsonElement value) =>
        parent.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.Object;

    private static bool TryFlag(JsonElement parent, string name, out bool value)
    {
        value = false;
        if (!parent.TryGetProperty(name, out var element) || element.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            return false;
        }
        value = element.GetBoolean();
        return true;
    }

    private static string? Clean(string text)
    {
        var cleaned = new string(text.Where(c => !char.IsControl(c)).Take(TelemetryLimits.MaxMessageLength).ToArray()).Trim();
        return cleaned.Length == 0 ? null : cleaned;
    }
}
