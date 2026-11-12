using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace OsbManager.Tests.Telemetry;

internal static partial class DiagnosticsServerRules
{
    private static readonly Dictionary<string, string[]> Allowed = new()
    {
        ["batch"] = ["schema", "app", "app_version", "run", "env", "events", "perf", "osb_perf", "dropped"],
        ["osb_perf"] = ["app_version", "at", "span_s", "samples", "js_heap_mb", "tick_ms", "gap_ms", "long_tasks"],
        ["osb_js_heap_mb"] = ["used", "total"],
        ["timing"] = ["p50", "p95", "p99", "max", "late_pct"],
        ["long_tasks"] = ["count", "total_ms"],
        ["env"] = ["os_build", "webview2", "dotnet", "ram_gb", "cores", "gpu_vendor"],
        ["event"] = ["kind", "source", "fp", "at", "count", "error", "process", "hang", "gpu", "stop", "warn", "run_end", "context", "trail"],
        ["error"] = ["type", "template", "hresult", "inner", "module", "handled", "origin", "frames"],
        ["process"] = ["kind", "reason", "exit_code", "description"],
        ["hang"] = ["outcome", "waited_s"],
        ["gpu"] = ["code", "retries"],
        ["run_end"] = ["outcome", "uptime_s", "previous_version"],
        ["context"] = ["phase", "mode", "town_phase", "dead", "login_stage", "window", "windows", "light", "hidden", "uptime_s"],
        ["trail"] = ["s", "l", "c", "k", "o", "n", "w", "d", "e"],
        ["perf"] = ["at", "span_s", "samples", "windows", "mem_mb", "js_heap_mb", "wasm_mb", "cpu_pct"],
        ["windows"] = ["open", "light", "hidden", "in_world"],
        ["mem_mb"] = ["renderer", "gpu", "browser_total", "utility", "app"],
        ["renderer"] = ["p50", "max", "each"],
        ["role"] = ["p50", "max"],
        ["js_heap_mb"] = ["used_each", "total_each"],
        ["wasm_mb"] = ["each"],
        ["cpu_pct"] = ["renderer_each", "gpu", "browser_total", "app"],
        ["dropped"] = ["rate_limited", "oversize", "sampled_out"],
    };

    [GeneratedRegex("^[0-9a-f]{16}$")]
    private static partial Regex Hex16();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$")]
    private static partial Regex Minute();

    public static IReadOnlyList<string> Check(JsonNode body)
    {
        var problems = new List<string>();
        var root = body.AsObject();
        Keys(root, "batch", "$", problems);
        if (root["env"] is JsonObject env)
        {
            Keys(env, "env", "$.env", problems);
        }
        foreach (var (e, i) in Items(root["events"]))
        {
            Event(e, $"$.events[{i}]", problems);
        }
        foreach (var (p, i) in Items(root["perf"]))
        {
            Perf(p, $"$.perf[{i}]", problems);
        }
        if (root["osb_perf"] is JsonArray osbPerf && osbPerf.Count > 1)
        {
            problems.Add("$.osb_perf has more than one entry");
        }
        foreach (var (p, i) in Items(root["osb_perf"]))
        {
            OsbPerf(p, $"$.osb_perf[{i}]", problems);
        }
        if (root["dropped"] is JsonObject dropped)
        {
            Keys(dropped, "dropped", "$.dropped", problems);
            foreach (var (name, value) in dropped)
            {
                Integer(value, $"$.dropped.{name}", problems);
            }
        }
        NoNulls(body, "$", problems);
        return problems;
    }

    private static void Event(JsonObject e, string path, List<string> problems)
    {
        Keys(e, "event", path, problems);
        if (e["fp"] is not JsonValue fp || !Hex16().IsMatch(fp.GetValue<string>()) || fp.GetValue<string>() == "0000000000000000")
        {
            problems.Add($"{path}.fp is not a valid fingerprint");
        }
        if (e["at"] is not JsonValue at || !Minute().IsMatch(at.GetValue<string>()))
        {
            problems.Add($"{path}.at is not minute aligned");
        }
        foreach (var name in new[] { "error", "process", "hang", "gpu", "run_end", "context" })
        {
            if (e[name] is JsonObject detail)
            {
                Keys(detail, name, $"{path}.{name}", problems);
            }
        }
        Sources(e, path, problems);
        if (e["run_end"]?["uptime_s"] is JsonNode runUptime)
        {
            Multiple(runUptime, $"{path}.run_end.uptime_s", problems);
        }
        if (e["context"]?["uptime_s"] is JsonNode uptime)
        {
            Multiple(uptime, $"{path}.context.uptime_s", problems);
        }
        foreach (var (entry, i) in Items(e["trail"]))
        {
            Keys(entry, "trail", $"{path}.trail[{i}]", problems);
        }
    }

    private static void OsbPerf(JsonObject p, string path, List<string> problems)
    {
        Keys(p, "osb_perf", path, problems);
        if (p["app_version"] is not JsonValue version || !Regex.IsMatch(version.GetValue<string>(), "^[0-9A-Za-z.+-]{1,32}$"))
        {
            problems.Add($"{path}.app_version is not a version");
        }
        if (p["at"] is not JsonValue at || !Minute().IsMatch(at.GetValue<string>()))
        {
            problems.Add($"{path}.at is not minute aligned");
        }
        Integer(p["span_s"], $"{path}.span_s", problems);
        Integer(p["samples"], $"{path}.samples", problems);
        if (p["js_heap_mb"] is JsonObject heap)
        {
            Keys(heap, "osb_js_heap_mb", $"{path}.js_heap_mb", problems);
            foreach (var (name, value) in heap)
            {
                Integer(value, $"{path}.js_heap_mb.{name}", problems);
            }
        }
        foreach (var name in new[] { "tick_ms", "gap_ms" })
        {
            if (p[name] is JsonObject timing)
            {
                Keys(timing, "timing", $"{path}.{name}", problems);
                foreach (var (inner, value) in timing)
                {
                    OneDecimal(value, $"{path}.{name}.{inner}", problems);
                }
            }
        }
        if (p["long_tasks"] is JsonObject tasks)
        {
            Keys(tasks, "long_tasks", $"{path}.long_tasks", problems);
            Integer(tasks["count"], $"{path}.long_tasks.count", problems);
            OneDecimal(tasks["total_ms"], $"{path}.long_tasks.total_ms", problems);
        }
        if (System.Text.Encoding.UTF8.GetByteCount(p.ToJsonString()) > 2048)
        {
            problems.Add($"{path} is over 2 KB");
        }
    }

    private static void Sources(JsonObject e, string path, List<string> problems)
    {
        var source = e["source"]?.GetValue<string>();
        var kind = e["kind"]?.GetValue<string>();
        if (source is not ("osb" or "manager"))
        {
            problems.Add($"{path}.source is not osb or manager");
            return;
        }
        if (kind == "js_error" && source != "osb" || kind == "dotnet_exception" && source != "manager")
        {
            problems.Add($"{path}.source does not match {kind}");
        }
        if (e["error"] is JsonObject error)
        {
            if (error["template"] is not null && source != "osb")
            {
                problems.Add($"{path}.error.template is only accepted from osb");
            }
            if (error["hresult"] is not null && source != "manager")
            {
                problems.Add($"{path}.error.hresult is only accepted from manager");
            }
            var origins = source == "osb"
                ? new[] { "guard", "tick", "data", "panel", "window", "rejection" }
                : ["appdomain", "ui_thread", "task", "caught"];
            if (!origins.Contains(error["origin"]?.GetValue<string>()))
            {
                problems.Add($"{path}.error.origin is not an {source} origin");
            }
        }
    }

    private static void Perf(JsonObject p, string path, List<string> problems)
    {
        Keys(p, "perf", path, problems);
        if (p["windows"] is JsonObject windows)
        {
            Keys(windows, "windows", $"{path}.windows", problems);
        }
        if (p["mem_mb"] is JsonObject mem)
        {
            Keys(mem, "mem_mb", $"{path}.mem_mb", problems);
            foreach (var (name, value) in mem)
            {
                var role = value!.AsObject();
                Keys(role, name == "renderer" ? "renderer" : "role", $"{path}.mem_mb.{name}", problems);
                foreach (var (inner, number) in role)
                {
                    if (number is JsonArray each)
                    {
                        Sorted(each, $"{path}.mem_mb.{name}.{inner}", problems, integers: true);
                    }
                    else
                    {
                        Integer(number, $"{path}.mem_mb.{name}.{inner}", problems);
                    }
                }
            }
        }
        foreach (var name in new[] { "js_heap_mb", "wasm_mb" })
        {
            if (p[name] is JsonObject heap)
            {
                Keys(heap, name, $"{path}.{name}", problems);
                foreach (var (inner, array) in heap)
                {
                    Sorted(array!.AsArray(), $"{path}.{name}.{inner}", problems, integers: true);
                }
            }
        }
        if (p["cpu_pct"] is JsonObject cpu)
        {
            Keys(cpu, "cpu_pct", $"{path}.cpu_pct", problems);
            foreach (var (inner, value) in cpu)
            {
                if (value is JsonArray array)
                {
                    Sorted(array, $"{path}.cpu_pct.{inner}", problems, integers: false);
                }
                else
                {
                    OneDecimal(value, $"{path}.cpu_pct.{inner}", problems);
                }
            }
        }
    }

    private static IEnumerable<(JsonObject Item, int Index)> Items(JsonNode? array) =>
        array is JsonArray items ? items.Select((node, i) => (node!.AsObject(), i)) : [];

    private static void Keys(JsonObject node, string kind, string path, List<string> problems)
    {
        foreach (var (name, _) in node)
        {
            if (!Allowed[kind].Contains(name) && !(kind == "event" && name == "stop") && !(kind == "trail" && name == "d"))
            {
                problems.Add($"{path} has the unknown field {name}");
            }
        }
    }

    private static void NoNulls(JsonNode? node, string path, List<string> problems)
    {
        switch (node)
        {
            case null:
                problems.Add($"{path} is null");
                break;
            case JsonObject o:
                foreach (var (name, value) in o)
                {
                    NoNulls(value, $"{path}.{name}", problems);
                }
                break;
            case JsonArray a:
                for (var i = 0; i < a.Count; i++)
                {
                    NoNulls(a[i], $"{path}[{i}]", problems);
                }
                break;
        }
    }

    private static bool TryNumber(JsonNode? node, out double number)
    {
        number = 0;
        return node is JsonValue { } value
            && value.GetValueKind() == System.Text.Json.JsonValueKind.Number
            && double.TryParse(value.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture, out number);
    }

    private static void Integer(JsonNode? node, string path, List<string> problems)
    {
        if (!TryNumber(node, out var number) || number != Math.Floor(number))
        {
            problems.Add($"{path} is not an integer");
        }
    }

    private static void OneDecimal(JsonNode? node, string path, List<string> problems)
    {
        if (!TryNumber(node, out var number) || Math.Round(number, 1) != number)
        {
            problems.Add($"{path} has more than one decimal");
        }
    }

    private static void Multiple(JsonNode node, string path, List<string> problems)
    {
        if (!TryNumber(node, out var number) || number % 60 != 0)
        {
            problems.Add($"{path} is not a multiple of 60");
        }
    }

    private static void Sorted(JsonArray array, string path, List<string> problems, bool integers)
    {
        var numbers = array.Select(n => TryNumber(n, out var number) ? number : double.NaN).ToList();
        if (!numbers.SequenceEqual(numbers.Order()))
        {
            problems.Add($"{path} is not sorted ascending");
        }
        for (var i = 0; i < array.Count; i++)
        {
            if (integers)
            {
                Integer(array[i], $"{path}[{i}]", problems);
            }
            else
            {
                OneDecimal(array[i], $"{path}[{i}]", problems);
            }
        }
    }
}
