using System.Text.RegularExpressions;

namespace OsbManager.Core.Scripts;

/// <summary>The ==UserScript== header of a Tampermonkey-style script.</summary>
public sealed partial class UserScriptMeta
{
    public static readonly IReadOnlySet<string> SupportedGrants = new HashSet<string>(StringComparer.Ordinal)
    {
        "none", "unsafeWindow", "GM_info", "GM_addStyle", "GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues",
        "GM.info", "GM.addStyle", "GM.getValue", "GM.setValue", "GM.deleteValue", "GM.listValues",
    };

    public string Name { get; private init; } = "";
    public string Namespace { get; private init; } = "";
    public string Version { get; private init; } = "";
    public string RunAt { get; private init; } = "document-idle";
    public bool NoFrames { get; private init; }
    public IReadOnlyList<string> Matches { get; private init; } = [];
    public IReadOnlyList<string> Includes { get; private init; } = [];
    public IReadOnlyList<string> Excludes { get; private init; } = [];
    public IReadOnlyList<string> Grants { get; private init; } = [];
    public IReadOnlyList<string> Requires { get; private init; } = [];
    public string? UpdateUrl { get; private init; }
    public string? DownloadUrl { get; private init; }

    public IEnumerable<string> UnsupportedGrants => Grants.Where(g => !SupportedGrants.Contains(g));

    public static UserScriptMeta Parse(string source)
    {
        var lines = source.Split('\n');
        var start = Array.FindIndex(lines, l => l.Trim() == "// ==UserScript==");
        var end = start < 0 ? -1 : Array.FindIndex(lines, start + 1, l => l.Trim() == "// ==/UserScript==");
        if (start < 0 || end < 0)
        {
            throw new FormatException("This file has no ==UserScript== header.");
        }
        var values = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var line in lines[(start + 1)..end])
        {
            var match = MetaLine().Match(line);
            if (match.Success)
            {
                var key = match.Groups[1].Value;
                if (!values.TryGetValue(key, out var list))
                {
                    values[key] = list = [];
                }
                list.Add(match.Groups[2].Value.Trim());
            }
        }
        string? First(string key) => values.TryGetValue(key, out var list) && list.Count > 0 ? list[0] : null;
        IReadOnlyList<string> All(string key) => values.TryGetValue(key, out var list) ? list.Where(v => v.Length > 0).ToList() : [];

        var meta = new UserScriptMeta
        {
            Name = First("name") ?? "",
            Namespace = First("namespace") ?? "",
            Version = First("version") ?? "",
            RunAt = First("run-at") is { Length: > 0 } runAt ? runAt : "document-idle",
            NoFrames = values.ContainsKey("noframes"),
            Matches = All("match"),
            Includes = All("include"),
            Excludes = All("exclude"),
            Grants = All("grant"),
            Requires = All("require"),
            UpdateUrl = First("updateURL"),
            DownloadUrl = First("downloadURL"),
        };
        if (meta.Name.Length == 0)
        {
            throw new FormatException("The script header has no @name.");
        }
        if (meta.Matches.Count == 0 && meta.Includes.Count == 0)
        {
            throw new FormatException("The script header has no @match or @include.");
        }
        return meta;
    }

    [GeneratedRegex(@"^\s*//\s*@([\w.-]+)(?:\s+(.*?))?\s*$")]
    private static partial Regex MetaLine();
}
