using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OsbManager.Core.Scripts;

/// <summary>Wraps a userscript so it runs only on its URLs, at its run-at time, with a small GM_* surface.</summary>
public static partial class ScriptInjection
{
    public static string Build(UserScriptMeta meta, string source)
    {
        var settings = JsonSerializer.Serialize(new
        {
            name = meta.Name,
            @namespace = meta.Namespace,
            version = meta.Version,
            runAt = meta.RunAt,
            noFrames = meta.NoFrames,
            include = meta.Matches.Select(UrlPattern.FromMatch).Concat(meta.Includes.Select(UrlPattern.FromGlob)).ToArray(),
            exclude = meta.Excludes.Select(UrlPattern.FromGlob).ToArray(),
        });
        var script = new StringBuilder(source.Length + 2048);
        script.Append("(() => {\n");
        script.Append("//# sourceURL=osb-manager-script/").Append(SourceName(meta.Name)).Append(".user.js\n");
        script.Append("const meta = ").Append(settings).Append(";\n");
        script.Append(Prelude);
        script.Append("const run = () => {\n").Append(source).Append("\n};\n");
        script.Append(Launcher);
        script.Append("})();\n");
        return script.ToString();
    }

    private static string SourceName(string? name)
    {
        var safe = UnsafeSourceCharacters().Replace((name ?? "").Trim(), "-");
        return safe.Length == 0 ? "script" : safe.Length > 64 ? safe[..64] : safe;
    }

    [GeneratedRegex("[^A-Za-z0-9._-]", RegexOptions.CultureInvariant)]
    private static partial Regex UnsafeSourceCharacters();

    private const string Prelude = """
        if (meta.noFrames && window.top !== window) return;
        const matches = list => list.some(pattern => new RegExp(pattern).test(location.href));
        if (!matches(meta.include) || matches(meta.exclude)) return;
        const unsafeWindow = window;
        const GM_info = Object.freeze({ scriptHandler: 'OSB Manager', version: '1.0', script: Object.freeze({ name: meta.name, namespace: meta.namespace, version: meta.version }) });
        const storeKey = key => 'sroMultiAcc.gm:' + meta.namespace + ':' + meta.name + ':' + key;
        const GM_addStyle = css => { const style = document.createElement('style'); style.textContent = String(css); (document.head || document.documentElement).appendChild(style); return style; };
        const GM_getValue = (key, fallback) => { try { const value = localStorage.getItem(storeKey(key)); return value === null ? fallback : JSON.parse(value); } catch { return fallback; } };
        const GM_setValue = (key, value) => { try { localStorage.setItem(storeKey(key), JSON.stringify(value)); } catch {} };
        const GM_deleteValue = key => { try { localStorage.removeItem(storeKey(key)); } catch {} };
        const GM_listValues = () => { const prefix = storeKey(''); const keys = []; for (let i = 0; i < localStorage.length; i++) { const key = localStorage.key(i); if (key && key.startsWith(prefix)) keys.push(key.slice(prefix.length)); } return keys; };
        const GM = Object.freeze({ info: GM_info, addStyle: async css => GM_addStyle(css), getValue: async (key, fallback) => GM_getValue(key, fallback), setValue: async (key, value) => GM_setValue(key, value), deleteValue: async key => GM_deleteValue(key), listValues: async () => GM_listValues() });

        """;

    private const string Launcher = """
        const start = () => { try { run(); } catch (error) { console.error('[' + meta.name + ']', error); } };
        if (meta.runAt === 'document-start') start();
        else if (meta.runAt === 'document-end' || meta.runAt === 'document-body') {
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true }); else start();
        } else if (document.readyState === 'complete') setTimeout(start, 0);
        else window.addEventListener('load', start, { once: true });

        """;
}
