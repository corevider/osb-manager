using System.Globalization;
using System.Text.Json;

namespace OsbManager.Core.Telemetry.Diagnostics;

internal static class DiagnosticJsonReader
{
    private static readonly Dictionary<string, DiagnosticKind> Kinds = Enum.GetValues<DiagnosticKind>().ToDictionary(DiagnosticFormats.WireName, k => k, StringComparer.Ordinal);

    public static DiagnosticEvent? Event(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object || !Kinds.TryGetValue(Text(e, "kind"), out var kind))
        {
            return null;
        }
        var at = DateTimeOffset.Parse(Text(e, "at"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
        var result = new DiagnosticEvent
        {
            Kind = kind,
            Source = Text(e, "source") == "osb" ? DiagnosticSource.Osb : DiagnosticSource.Manager,
            Fingerprint = Text(e, "fp"),
            At = at,
            Count = e.GetProperty("count").GetInt32(),
            Context = e.TryGetProperty("context", out var context) ? Context(context) : null,
            Trail = e.TryGetProperty("trail", out var trail) ? trail.EnumerateArray().Select(Trail).ToList() : null,
        };
        return kind switch
        {
            DiagnosticKind.JsError or DiagnosticKind.DotnetException => result with { Error = Error(e.GetProperty("error")) },
            DiagnosticKind.ProcessFailed => result with { Process = Process(e.GetProperty("process")) },
            DiagnosticKind.Unresponsive => result with { Hang = new HangDetail(Text(e.GetProperty("hang"), "outcome"), e.GetProperty("hang").GetProperty("waited_s").GetInt32()) },
            DiagnosticKind.GpuFailed => result with { Gpu = new GpuDetail(Text(e.GetProperty("gpu"), "code"), e.GetProperty("gpu").GetProperty("retries").GetInt32()) },
            DiagnosticKind.BotStop => result with { Stop = new StopDetail(Text(e.GetProperty("stop"), "code"), Text(e.GetProperty("stop"), "source")) },
            DiagnosticKind.Warn => result with { Warn = Warn(e.GetProperty("warn")) },
            DiagnosticKind.RunEnd => result with { RunEnd = RunEnd(e.GetProperty("run_end")) },
            _ => null,
        };
    }

    private static ErrorDetail Error(JsonElement e) => new(
        Text(e, "type"),
        Text(e, "origin"),
        e.GetProperty("handled").GetBoolean(),
        e.GetProperty("frames").EnumerateArray().Select(f => f.GetString()!).ToList(),
        e.TryGetProperty("inner", out var inner) ? inner.EnumerateArray().Select(i => i.GetString()!).ToList() : [],
        Optional(e, "hresult"),
        Optional(e, "template"),
        Optional(e, "module"));

    private static ProcessDetail Process(JsonElement e) => new(Text(e, "kind"), Text(e, "reason"), Text(e, "exit_code"), Optional(e, "description"));

    private static WarnDetail Warn(JsonElement e)
    {
        RefusalDetail? refusal = e.TryGetProperty("refusal", out var r)
            ? new RefusalDetail(Text(r, "source"), Text(r, "reason"), r.GetProperty("native").GetInt32())
            : null;
        return new WarnDetail(Text(e, "category"), Text(e, "code"), Optional(e, "error_class"), refusal);
    }

    private static RunEndDetail RunEnd(JsonElement e) => new(Text(e, "outcome"), e.GetProperty("uptime_s").GetInt32(), Text(e, "previous_version"));

    private static DiagnosticContext Context(JsonElement e) => new()
    {
        Phase = Optional(e, "phase"),
        Mode = Optional(e, "mode"),
        TownPhase = Optional(e, "town_phase"),
        Dead = OptionalBool(e, "dead"),
        LoginStage = Optional(e, "login_stage"),
        Window = OptionalInt(e, "window"),
        Windows = OptionalInt(e, "windows"),
        Light = OptionalBool(e, "light"),
        Hidden = OptionalBool(e, "hidden"),
        UptimeSeconds = OptionalInt(e, "uptime_s"),
    };

    private static TrailItem Trail(JsonElement e)
    {
        Dictionary<string, double>? numbers = null;
        Dictionary<string, bool>? flags = null;
        if (e.TryGetProperty("d", out var details))
        {
            foreach (var property in details.EnumerateObject())
            {
                if (property.Value.ValueKind == JsonValueKind.Number)
                {
                    (numbers ??= new(StringComparer.Ordinal))[property.Name] = property.Value.GetDouble();
                }
                else if (property.Value.ValueKind is JsonValueKind.True or JsonValueKind.False)
                {
                    (flags ??= new(StringComparer.Ordinal))[property.Name] = property.Value.GetBoolean();
                }
            }
        }
        return new TrailItem(
            e.GetProperty("s").GetInt32(),
            Text(e, "l"),
            Text(e, "c"),
            Text(e, "k"),
            OptionalInt(e, "n") ?? 1,
            OptionalInt(e, "w"),
            Optional(e, "o"),
            Optional(e, "e"),
            numbers,
            flags);
    }

    private static string Text(JsonElement e, string name) => e.GetProperty(name).GetString() ?? throw new FormatException(name);

    private static string? Optional(JsonElement e, string name) =>
        e.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int? OptionalInt(JsonElement e, string name) =>
        e.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : null;

    private static bool? OptionalBool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : null;
}
