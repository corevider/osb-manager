using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace OsbManager.Core.Telemetry;

public enum ReportKind
{
    Bug,
    Feature,
}

/// <summary>The JSON part of POST /v1/reports. The preview shows these exact bytes.</summary>
public static class ReportPayload
{
    public const int MaxDescription = 2000;
    public const int MaxScreenshotBytes = 768 * 1024;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string CleanDescription(string text)
    {
        var builder = new StringBuilder();
        var count = 0;
        foreach (var rune in text.Replace("\r\n", "\n").Replace('\r', '\n').Trim().EnumerateRunes())
        {
            if (Rune.IsControl(rune) && rune.Value is not ('\n' or '\t'))
            {
                continue;
            }
            if (count++ == MaxDescription)
            {
                break;
            }
            builder.Append(rune.ToString());
        }
        return builder.ToString();
    }

    public static byte[] Build(ReportKind kind, string description, JsonObject diagnostics, string appVersion, string locale)
    {
        var body = new JsonObject
        {
            ["schema"] = 1,
            ["kind"] = kind == ReportKind.Bug ? "bug" : "feature",
            ["app"] = TelemetryLimits.AppName,
            ["app_version"] = appVersion,
            ["os"] = TelemetryLimits.OsName,
            ["locale"] = locale,
            ["description"] = CleanDescription(description),
            ["diagnostics"] = diagnostics.DeepClone(),
        };
        return Encoding.UTF8.GetBytes(body.ToJsonString(Options));
    }

    public static string Preview(byte[] reportJson) => Encoding.UTF8.GetString(reportJson);
}
