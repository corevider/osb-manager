using System.Globalization;
using System.Text;
using System.Text.Json;

namespace OsbManager.Core.Telemetry.Diagnostics;

public static class OsbPageBatch
{
    public const string BatchType = "osb-diagnostics-batch";
    public const string SwitchType = "osb-diagnostics";
    public const string PerfType = "osb-diagnostics-perf";
    public const int MaxPerfBytes = 2 * 1024;
    public const int MaxBytes = 12 * 1024;
    public const int MaxEvents = 10;
    public const int MaxDepth = 8;

    private const string Head = "{\"type\":\"" + BatchType + "\"";
    private const string Tail = ",\"type\":\"" + BatchType + "\"}";
    private const string PerfHead = "{\"type\":\"" + PerfType + "\"";
    private const string PerfTail = ",\"type\":\"" + PerfType + "\"}";

    private static readonly IReadOnlySet<string> Kinds = new HashSet<string>(StringComparer.Ordinal) { "js_error", "bot_stop", "warn" };

    private static readonly IReadOnlySet<string> PageOrigins = new HashSet<string>(StringComparer.Ordinal)
    {
        "guard", "tick", "data", "panel", "window", "rejection",
    };

    public static bool IsBatch(string? json) =>
        json is not null && (json.StartsWith(Head, StringComparison.Ordinal) || json.EndsWith(Tail, StringComparison.Ordinal));

    public static bool IsPerf(string? json) =>
        json is not null && (json.StartsWith(PerfHead, StringComparison.Ordinal) || json.EndsWith(PerfTail, StringComparison.Ordinal));

    public static string Switch(bool on, bool perf = false) => !on
        ? "{\"type\":\"" + SwitchType + "\",\"on\":false}"
        : "{\"type\":\"" + SwitchType + "\",\"on\":true,\"perf\":" + (perf ? "true" : "false") + "}";

    public static PerfEntry? ParsePerf(string json, DateTimeOffset now)
    {
        if (json.Length > MaxPerfBytes || Encoding.UTF8.GetByteCount(json) > MaxPerfBytes)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = MaxDepth });
            var reader = new Reader(now);
            var entry = reader.PerfMessage(document.RootElement);
            return reader.Failed ? null : entry;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }

    public static IReadOnlyList<DiagnosticEvent>? Parse(string json, DateTimeOffset now) => Parse(json, now, out _);

    public static IReadOnlyList<DiagnosticEvent>? Parse(string json, DateTimeOffset now, out int mapped)
    {
        mapped = 0;
        if (json.Length > MaxBytes || Encoding.UTF8.GetByteCount(json) > MaxBytes)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = MaxDepth });
            var reader = new Reader(now);
            var events = reader.Batch(document.RootElement);
            if (reader.Failed)
            {
                return null;
            }
            var vocabulary = OsbVocabulary.Current;
            var result = new List<DiagnosticEvent>(events.Count);
            foreach (var e in events)
            {
                result.Add(vocabulary.Map(e, ref mapped));
            }
            return result;
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or ArgumentException)
        {
            return null;
        }
    }

    private sealed class Reader(DateTimeOffset now)
    {
        public bool Failed { get; private set; }

        public IReadOnlyList<DiagnosticEvent> Batch(JsonElement root)
        {
            if (!Keys(root, ["type", "events"], ["type", "events"]) || Text(root, "type") != BatchType)
            {
                return Fail<IReadOnlyList<DiagnosticEvent>>([]);
            }
            var items = Array(root, "events", MaxEvents);
            if (items is not { Count: > 0 })
            {
                return Fail<IReadOnlyList<DiagnosticEvent>>([]);
            }
            var events = new List<DiagnosticEvent>();
            foreach (var item in items)
            {
                if (Event(item) is { } parsed)
                {
                    events.Add(parsed);
                }
            }
            return events;
        }

        public PerfEntry? PerfMessage(JsonElement root)
        {
            if (!Keys(root, ["type", "perf"], ["type", "perf"]) || Text(root, "type") != PerfType)
            {
                return null;
            }
            var p = root.GetProperty("perf");
            if (!Keys(p, ["at", "span_s", "samples", "js_heap_mb", "tick_ms", "gap_ms", "long_tasks"], ["at", "span_s", "samples"]))
            {
                return null;
            }
            var at = Minute(p, "at");
            var span = Int(p, "span_s", 60, 86400);
            var samples = Int(p, "samples", 1, 1440);
            double? used = null, total = null;
            if (p.TryGetProperty("js_heap_mb", out var heap))
            {
                if (!Keys(heap, ["used", "total"], ["used", "total"]))
                {
                    return null;
                }
                used = Int(heap, "used", 0, (int)DiagnosticFormats.MaxMegabytes);
                total = Int(heap, "total", 0, (int)DiagnosticFormats.MaxMegabytes);
            }
            PerfLongTasks? tasks = null;
            if (p.TryGetProperty("long_tasks", out var longTasks))
            {
                if (!Keys(longTasks, ["count", "total_ms"], ["count", "total_ms"]))
                {
                    return null;
                }
                var count = Int(longTasks, "count", 0, DiagnosticFormats.MaxCount);
                var totalMs = OneDecimal(longTasks.GetProperty("total_ms"), 86_400_000);
                tasks = count is { } c && totalMs is { } ms && ms >= 0 ? new PerfLongTasks(c, ms) : Fail<PerfLongTasks?>(null);
            }
            var tick = p.TryGetProperty("tick_ms", out var tickElement) ? Timing(tickElement) : null;
            var gap = p.TryGetProperty("gap_ms", out var gapElement) ? Timing(gapElement) : null;
            if (at is null || span is null || samples is null || Failed)
            {
                return null;
            }
            return new PerfEntry
            {
                At = at.Value,
                SpanSeconds = span.Value,
                Samples = samples.Value,
                JsHeapUsed = used,
                JsHeapTotal = total,
                Tick = tick,
                Gap = gap,
                LongTasks = tasks,
            };
        }

        private PerfTiming? Timing(JsonElement e)
        {
            if (!Keys(e, ["p50", "p95", "p99", "max", "late_pct"], ["p50", "p95", "p99", "max", "late_pct"]))
            {
                return null;
            }
            var values = new[] { "p50", "p95", "p99", "max" }.Select(name => OneDecimal(e.GetProperty(name), DiagnosticFormats.MaxMilliseconds)).ToList();
            var late = OneDecimal(e.GetProperty("late_pct"), 100);
            if (values.Any(v => v is not >= 0) || late is not >= 0)
            {
                return Fail<PerfTiming?>(null);
            }
            return new PerfTiming(values[0]!.Value, values[1]!.Value, values[2]!.Value, values[3]!.Value, late.Value);
        }

        private DiagnosticEvent? Event(JsonElement e)
        {
            var kind = e.ValueKind == JsonValueKind.Object && e.TryGetProperty("kind", out var k) && k.ValueKind == JsonValueKind.String ? k.GetString() : null;
            if (kind is null || !Kinds.Contains(kind))
            {
                return Fail<DiagnosticEvent?>(null);
            }
            var detail = kind switch { "js_error" => "error", "bot_stop" => "stop", _ => "warn" };
            if (!Keys(e, ["kind", "source", "fp", "at", "count", detail, "context", "trail"], ["kind", "source", "fp", "at", "count", detail])
                || Encoding.UTF8.GetByteCount(e.GetRawText()) > DiagnosticFormats.MaxEventBytes
                || Text(e, "source") != "osb")
            {
                return Fail<DiagnosticEvent?>(null);
            }
            var fingerprint = Text(e, "fp");
            if (!DiagnosticFormats.IsHex16(fingerprint) || fingerprint == DiagnosticFormats.ReservedFingerprint)
            {
                return Fail<DiagnosticEvent?>(null);
            }
            var at = Minute(e, "at");
            var count = Int(e, "count", 1, DiagnosticFormats.MaxCount);
            if (at is null || count is null)
            {
                return Fail<DiagnosticEvent?>(null);
            }
            var result = new DiagnosticEvent
            {
                Kind = kind switch { "js_error" => DiagnosticKind.JsError, "bot_stop" => DiagnosticKind.BotStop, _ => DiagnosticKind.Warn },
                Source = DiagnosticSource.Osb,
                Fingerprint = fingerprint!,
                At = at.Value,
                Count = count.Value,
                Context = e.TryGetProperty("context", out var context) ? Context(context) : null,
                Trail = e.TryGetProperty("trail", out var trail) ? Trail(trail) : null,
            };
            var body = e.GetProperty(detail);
            return kind switch
            {
                "js_error" => Error(body) is { } error ? result with { Error = error } : Fail<DiagnosticEvent?>(null),
                "bot_stop" => Stop(body) is { } stop ? result with { Stop = stop } : Fail<DiagnosticEvent?>(null),
                _ => Warn(body) is { } warn ? result with { Warn = warn } : Fail<DiagnosticEvent?>(null),
            };
        }

        private ErrorDetail? Error(JsonElement e)
        {
            if (!Keys(e, ["type", "template", "inner", "module", "handled", "origin", "frames"], ["type", "handled", "origin"]))
            {
                return null;
            }
            var type = Text(e, "type");
            var origin = Text(e, "origin");
            var handled = Bool(e, "handled");
            if (!DiagnosticFormats.IsTypeName(type) || origin is null || !PageOrigins.Contains(origin) || handled is null)
            {
                return Fail<ErrorDetail?>(null);
            }
            var template = Optional(e, "template", DiagnosticFormats.IsTemplate);
            var module = Optional(e, "module", DiagnosticFormats.IsCode);
            var inner = e.TryGetProperty("inner", out _) ? Strings(e, "inner", DiagnosticFormats.MaxInner, DiagnosticFormats.IsTypeName) : [];
            var frames = e.TryGetProperty("frames", out _) ? Strings(e, "frames", DiagnosticFormats.MaxFrames, DiagnosticFormats.IsFrame) : [];
            return Failed ? null : new ErrorDetail(type!, origin, handled.Value, frames ?? [], inner ?? [], null, template, module);
        }

        private StopDetail? Stop(JsonElement e)
        {
            if (!Keys(e, ["code", "source"], ["code", "source"]))
            {
                return null;
            }
            var code = Text(e, "code");
            var source = Text(e, "source");
            return DiagnosticFormats.IsCode(code) && source is not null && DiagnosticFormats.StopSources.Contains(source)
                ? new StopDetail(code!, source)
                : Fail<StopDetail?>(null);
        }

        private WarnDetail? Warn(JsonElement e)
        {
            if (!Keys(e, ["category", "code", "error_class", "refusal"], ["category", "code"]))
            {
                return null;
            }
            var category = Text(e, "category");
            var code = Text(e, "code");
            var errorClass = Optional(e, "error_class", DiagnosticFormats.IsCode);
            RefusalDetail? refusal = null;
            if (e.TryGetProperty("refusal", out var r))
            {
                if (!Keys(r, ["source", "reason", "native"], ["source", "reason", "native"]))
                {
                    return null;
                }
                var source = Text(r, "source");
                var reason = Text(r, "reason");
                var native = Int(r, "native", 0, 65535);
                if (!DiagnosticFormats.IsCode(source) || !DiagnosticFormats.IsCode(reason) || native is null)
                {
                    return Fail<WarnDetail?>(null);
                }
                refusal = new RefusalDetail(source!, reason!, native.Value);
            }
            return DiagnosticFormats.IsCode(category) && DiagnosticFormats.IsCode(code) && !Failed
                ? new WarnDetail(category!, code!, errorClass, refusal)
                : Fail<WarnDetail?>(null);
        }

        private DiagnosticContext? Context(JsonElement e)
        {
            if (!Keys(e, ["phase", "mode", "town_phase", "dead", "uptime_s"], []))
            {
                return null;
            }
            var mode = Optional(e, "mode", value => value is not null && DiagnosticFormats.Modes.Contains(value));
            int? uptime = null;
            if (e.TryGetProperty("uptime_s", out _))
            {
                uptime = Int(e, "uptime_s", 0, DiagnosticFormats.MaxUptimeSeconds);
                if (uptime is not { } seconds || seconds % 60 != 0)
                {
                    return Fail<DiagnosticContext?>(null);
                }
            }
            bool? dead = null;
            if (e.TryGetProperty("dead", out _) && (dead = Bool(e, "dead")) is null)
            {
                return Fail<DiagnosticContext?>(null);
            }
            return new DiagnosticContext
            {
                Phase = Optional(e, "phase", DiagnosticFormats.IsCode),
                Mode = mode,
                TownPhase = Optional(e, "town_phase", DiagnosticFormats.IsCode),
                Dead = dead,
                UptimeSeconds = uptime,
            };
        }

        private IReadOnlyList<TrailItem>? Trail(JsonElement e)
        {
            if (e.ValueKind != JsonValueKind.Array || e.GetArrayLength() > DiagnosticFormats.MaxOsbTrail)
            {
                return Fail<IReadOnlyList<TrailItem>?>(null);
            }
            var items = new List<TrailItem>();
            foreach (var entry in e.EnumerateArray())
            {
                if (!Keys(entry, ["s", "l", "c", "k", "o", "n", "e", "d"], ["s", "l", "c", "k"]))
                {
                    return null;
                }
                var seconds = Int(entry, "s", -86400, 0);
                var level = Text(entry, "l");
                var category = Text(entry, "c");
                var code = Text(entry, "k");
                var outcome = Optional(entry, "o", DiagnosticFormats.IsCode);
                var errorClass = Optional(entry, "e", DiagnosticFormats.IsCode);
                int? repeat = 1;
                if (entry.TryGetProperty("n", out _))
                {
                    repeat = Int(entry, "n", 1, DiagnosticFormats.MaxCount);
                }
                var (numbers, flags) = entry.TryGetProperty("d", out var details) ? Details(details) : (null, null);
                if (seconds is null || level is null || !DiagnosticFormats.TrailLevels.Contains(level) || !DiagnosticFormats.IsCode(category)
                    || !DiagnosticFormats.IsCode(code) || repeat is null || Failed)
                {
                    return Fail<IReadOnlyList<TrailItem>?>(null);
                }
                items.Add(new TrailItem(seconds.Value, level, category!, code!, repeat.Value, null, outcome, errorClass, numbers, flags));
            }
            return items;
        }

        private (IReadOnlyDictionary<string, double>?, IReadOnlyDictionary<string, bool>?) Details(JsonElement e)
        {
            if (!Keys(e, [.. DiagnosticFormats.DetailNumbers, .. DiagnosticFormats.DetailFlags], []))
            {
                return (null, null);
            }
            Dictionary<string, double>? numbers = null;
            Dictionary<string, bool>? flags = null;
            foreach (var property in e.EnumerateObject())
            {
                if (DiagnosticFormats.DetailFlags.Contains(property.Name))
                {
                    if (property.Value.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                    {
                        return Fail<(IReadOnlyDictionary<string, double>?, IReadOnlyDictionary<string, bool>?)>((null, null));
                    }
                    (flags ??= new(StringComparer.Ordinal))[property.Name] = property.Value.GetBoolean();
                    continue;
                }
                if (OneDecimal(property.Value, DiagnosticFormats.MaxDetailMagnitude) is not { } number)
                {
                    return Fail<(IReadOnlyDictionary<string, double>?, IReadOnlyDictionary<string, bool>?)>((null, null));
                }
                (numbers ??= new(StringComparer.Ordinal))[property.Name] = number;
            }
            return (numbers, flags);
        }

        private bool Keys(JsonElement e, IReadOnlyCollection<string> allowed, IReadOnlyCollection<string> required)
        {
            if (e.ValueKind != JsonValueKind.Object)
            {
                return Fail(false);
            }
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in e.EnumerateObject())
            {
                if (!seen.Add(property.Name) || !allowed.Contains(property.Name) || property.Value.ValueKind == JsonValueKind.Null)
                {
                    return Fail(false);
                }
            }
            foreach (var name in required)
            {
                if (!seen.Contains(name))
                {
                    return Fail(false);
                }
            }
            return true;
        }

        private string? Text(JsonElement e, string name)
        {
            if (!e.TryGetProperty(name, out var value))
            {
                return null;
            }
            if (value.ValueKind != JsonValueKind.String)
            {
                return Fail<string?>(null);
            }
            var text = value.GetString()!;
            foreach (var c in text)
            {
                if (char.IsControl(c) || char.IsSurrogate(c))
                {
                    return Fail<string?>(null);
                }
            }
            return text;
        }

        private string? Optional(JsonElement e, string name, Func<string?, bool> valid)
        {
            if (!e.TryGetProperty(name, out _))
            {
                return null;
            }
            var text = Text(e, name);
            return valid(text) ? text : Fail<string?>(null);
        }

        private IReadOnlyList<string>? Strings(JsonElement e, string name, int max, Func<string?, bool> valid)
        {
            var items = Array(e, name, max);
            if (items is null)
            {
                return null;
            }
            var result = new List<string>();
            foreach (var item in items)
            {
                var text = item.ValueKind == JsonValueKind.String ? item.GetString() : null;
                if (text is null || text.Any(c => char.IsControl(c) || char.IsSurrogate(c)) || !valid(text))
                {
                    return Fail<IReadOnlyList<string>?>(null);
                }
                result.Add(text);
            }
            return result;
        }

        private List<JsonElement>? Array(JsonElement e, string name, int max)
        {
            if (!e.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > max)
            {
                return Fail<List<JsonElement>?>(null);
            }
            return [.. value.EnumerateArray()];
        }

        private bool? Bool(JsonElement e, string name) =>
            e.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? value.GetBoolean()
                : Fail<bool?>(null);

        private int? Int(JsonElement e, string name, int min, int max) =>
            e.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)
                && IsWhole(value) && number >= min && number <= max
                ? number
                : Fail<int?>(null);

        private DateTimeOffset? Minute(JsonElement e, string name)
        {
            var text = Text(e, name);
            if (text is null || text.Length != 20 || !text.EndsWith(":00Z", StringComparison.Ordinal)
                || !DateTimeOffset.TryParseExact(text, "yyyy-MM-dd'T'HH:mm':00Z'", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at))
            {
                return Fail<DateTimeOffset?>(null);
            }
            return at >= now - DiagnosticFormats.MaxAge && at <= now + DiagnosticFormats.MaxAhead ? at : Fail<DateTimeOffset?>(null);
        }

        private double? OneDecimal(JsonElement value, double magnitude)
        {
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out var number) || !double.IsFinite(number)
                || Math.Abs(number) > magnitude || Math.Round(number, 1) != number)
            {
                return Fail<double?>(null);
            }
            return number;
        }

        private static bool IsWhole(JsonElement value)
        {
            var raw = value.GetRawText();
            return !raw.Contains('.') && !raw.Contains('e') && !raw.Contains('E');
        }

        private T Fail<T>(T value)
        {
            Failed = true;
            return value;
        }
    }
}
