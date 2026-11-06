using System.Text.Json.Nodes;
using OsbManager.Core.Status;

namespace OsbManager.Core.Telemetry;

public sealed record WindowDiagnostics(string? Phase, string? LoginStage, string? LoginMessage, string? BotVersion, bool Light, int GpuRetries, string? GpuFailed)
{
    public static WindowDiagnostics From(BotStatus? status, bool light) => status is null
        ? new WindowDiagnostics(null, null, null, null, light, 0, null)
        : new WindowDiagnostics(status.Phase, status.LoginStage, status.LoginMessage, status.BotVersion, status.Light || light, status.GpuRetries, status.GpuFailed);
}

public sealed record ScriptDiagnostics(string Name, string Version);

/// <summary>
/// What a report carries about the app. Only the listed fields: no logs, no account, login or character names, no
/// paths. Free text from the page or from scripts is cut short.
/// </summary>
public static class ReportDiagnostics
{
    private const int MaxItems = 50;

    public static JsonObject Build(string appVersion, string osVersion, string dotnetVersion, IReadOnlyList<WindowDiagnostics> windows, IReadOnlyList<ScriptDiagnostics> scripts)
    {
        var windowList = new JsonArray();
        foreach (var window in windows.Take(MaxItems))
        {
            var entry = new JsonObject
            {
                ["phase"] = Cut(window.Phase, 64),
                ["bot_version"] = Cut(window.BotVersion, 32),
                ["light"] = window.Light,
            };
            if (window.LoginStage is not null || window.LoginMessage is not null)
            {
                entry["login"] = new JsonObject { ["stage"] = Cut(window.LoginStage, 64), ["message"] = Cut(window.LoginMessage, 64) };
            }
            entry["gpu"] = new JsonObject { ["retries"] = window.GpuRetries, ["failed"] = Cut(window.GpuFailed, 200) };
            windowList.Add(entry);
        }
        var scriptList = new JsonArray();
        foreach (var script in scripts.Take(MaxItems))
        {
            scriptList.Add(new JsonObject { ["name"] = Cut(script.Name, 64), ["version"] = Cut(script.Version, 32) });
        }
        return new JsonObject
        {
            ["app"] = AppIdentity.Name,
            ["version"] = Cut(appVersion, 32),
            ["os"] = Cut(osVersion, 64),
            ["dotnet"] = Cut(dotnetVersion, 64),
            ["windows"] = windows.Count,
            ["game_windows"] = windowList,
            ["scripts"] = scriptList,
        };
    }

    private static string? Cut(string? text, int length)
    {
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }
        var clean = new string(text.Where(c => !char.IsControl(c)).ToArray());
        if (clean.Length <= length)
        {
            return clean;
        }
        var cut = clean[..length];
        return char.IsHighSurrogate(cut[^1]) ? cut[..^1] : cut;
    }
}
