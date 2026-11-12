using System.Text.Json;
using System.Text.RegularExpressions;

namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed partial class OsbVocabulary
{
    public const string ResourceName = "OsbManager.Core.diagnostics-vocabulary.json";
    public const string Other = "other";
    public const string UnknownFrame = "?";
    public const string UnknownWord = "<x>";
    public const string FallbackType = "Error";
    public const string AnonymousFrame = "<anonymous>";

    private static readonly Lazy<OsbVocabulary> Embedded = new(LoadEmbedded);

    private OsbVocabulary(JsonElement root)
    {
        Version = root.GetProperty("version").GetString() ?? throw new InvalidDataException("vocabulary version");
        Modules = Set(root, "modules");
        StopCodes = Set(root, "stop_codes");
        ActivityCategories = Set(root, "activity_categories");
        ActivityCodes = Set(root, "activity_codes");
        ErrorCodes = Set(root, "error_codes");
        ErrorTypes = Set(root, "error_types");
        Phases = Set(root, "phases");
        Modes = Set(root, "modes");
        TownPhases = Set(root, "town_phases");
        Outcomes = Set(root, "outcomes");
        RefusalSources = Set(root, "refusal_sources");
        RefusalReasons = Set(root, "refusal_reasons");
        EngineWords = Set(root, "engine_words", StringComparer.OrdinalIgnoreCase);
        Identifiers = Set(root, "identifiers");
    }

    public static OsbVocabulary Current => Embedded.Value;

    public string Version { get; }
    public IReadOnlySet<string> Modules { get; }
    public IReadOnlySet<string> StopCodes { get; }
    public IReadOnlySet<string> ActivityCategories { get; }
    public IReadOnlySet<string> ActivityCodes { get; }
    public IReadOnlySet<string> ErrorCodes { get; }
    public IReadOnlySet<string> ErrorTypes { get; }
    public IReadOnlySet<string> Phases { get; }
    public IReadOnlySet<string> Modes { get; }
    public IReadOnlySet<string> TownPhases { get; }
    public IReadOnlySet<string> Outcomes { get; }
    public IReadOnlySet<string> RefusalSources { get; }
    public IReadOnlySet<string> RefusalReasons { get; }
    public IReadOnlySet<string> EngineWords { get; }
    public IReadOnlySet<string> Identifiers { get; }

    public static OsbVocabulary Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return new OsbVocabulary(document.RootElement);
    }

    public static string EmbeddedText()
    {
        using var stream = typeof(OsbVocabulary).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new InvalidDataException("missing resource " + ResourceName);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public string Frame(string frame)
    {
        if (frame == FrameReducer.External)
        {
            return frame;
        }
        var location = FrameLocation().Match(frame);
        var name = frame[..location.Index];
        return name.Split('.').All(part => part is AnonymousFrame or UnknownFrame || Identifiers.Contains(part))
            ? frame
            : UnknownFrame + location.Value;
    }

    public string Words(string text) =>
        TemplateWord().Replace(text, match => match.Value[0] == '<' || KnownWord(match.Value) ? match.Value : UnknownWord);

    public bool KnownWord(string word) =>
        DigitsOnly().IsMatch(word) || (CodeWord().IsMatch(word) && (EngineWords.Contains(word) || Identifiers.Contains(word)));

    public DiagnosticEvent Map(DiagnosticEvent e, ref int mapped)
    {
        var count = 0;
        List<TrailItem>? trail = null;
        if (e.Trail is { } items)
        {
            trail = new List<TrailItem>(items.Count);
            foreach (var item in items)
            {
                trail.Add(MapTrail(item, ref count));
            }
        }
        var result = e with
        {
            Error = e.Error is { } error ? MapError(error, ref count) : null,
            Stop = e.Stop is { } stop ? stop with { Code = Required(stop.Code, StopCodes, ref count) } : null,
            Warn = e.Warn is { } warn ? MapWarn(warn, ref count) : null,
            Context = e.Context is { } context ? MapContext(context, ref count) : null,
            Trail = trail,
        };
        mapped += count;
        return result;
    }

    private ErrorDetail MapError(ErrorDetail error, ref int count)
    {
        var type = ErrorTypes.Contains(error.Type) ? error.Type : Changed(FallbackType, ref count);
        string? template = null;
        if (error.Template is { } original)
        {
            template = Words(original);
            if (template != original)
            {
                count++;
            }
        }
        var frames = new List<string>(error.Frames.Count);
        foreach (var frame in error.Frames)
        {
            var kept = Frame(frame);
            if (kept != frame)
            {
                count++;
            }
            frames.Add(kept);
        }
        var inner = error.Inner?.Select(t => ErrorTypes.Contains(t) ? t : FallbackType).ToList();
        if (inner is not null && error.Inner is { } before && !inner.SequenceEqual(before))
        {
            count++;
        }
        return error with
        {
            Type = type,
            Template = template,
            Frames = frames,
            Inner = inner,
            Module = Optional(error.Module, Modules, ref count),
        };
    }

    private WarnDetail MapWarn(WarnDetail warn, ref int count)
    {
        RefusalDetail? refusal = null;
        if (warn.Refusal is { } r)
        {
            refusal = r with { Source = Required(r.Source, RefusalSources, ref count), Reason = Required(r.Reason, RefusalReasons, ref count) };
        }
        return new WarnDetail(
            Required(warn.Category, ActivityCategories, ref count),
            Required(warn.Code, ActivityCodes, ref count),
            Optional(warn.ErrorClass, ErrorCodes, ref count),
            refusal);
    }

    private DiagnosticContext MapContext(DiagnosticContext context, ref int count) => context with
    {
        Phase = context.Phase is null ? null : Required(context.Phase, Phases, ref count),
        Mode = context.Mode is null ? null : Required(context.Mode, Modes, ref count),
        TownPhase = Optional(context.TownPhase, TownPhases, ref count),
        LoginStage = context.LoginStage is null ? null : Changed<string?>(null, ref count),
    };

    private TrailItem MapTrail(TrailItem item, ref int count) => item with
    {
        Category = Required(item.Category, ActivityCategories, ref count),
        Code = Required(item.Code, ActivityCodes, ref count),
        Outcome = Optional(item.Outcome, Outcomes, ref count),
        ErrorClass = Optional(item.ErrorClass, ErrorCodes, ref count),
    };

    private static string Required(string value, IReadOnlySet<string> allowed, ref int count) =>
        allowed.Contains(value) ? value : Changed(Other, ref count);

    private static string? Optional(string? value, IReadOnlySet<string> allowed, ref int count) =>
        value is null || allowed.Contains(value) ? value : Changed<string?>(null, ref count);

    private static T Changed<T>(T value, ref int count)
    {
        count++;
        return value;
    }

    private static HashSet<string> Set(JsonElement root, string name, StringComparer? comparer = null)
    {
        var set = new HashSet<string>(comparer ?? StringComparer.Ordinal);
        foreach (var item in root.GetProperty(name).EnumerateArray())
        {
            set.Add(item.GetString() ?? throw new InvalidDataException("vocabulary " + name));
        }
        return set;
    }

    private static OsbVocabulary LoadEmbedded() => Parse(EmbeddedText());

    [GeneratedRegex(@"(@[0-9]{1,7}:[0-9]{1,5}|\+IL_[0-9A-F]{4,6})?$", RegexOptions.CultureInvariant)]
    private static partial Regex FrameLocation();

    [GeneratedRegex(@"<(?:q|n|url|x|path|redacted)>|(?:[A-Za-z0-9_$]|[^\x00-\x7f])+", RegexOptions.CultureInvariant)]
    private static partial Regex TemplateWord();

    [GeneratedRegex("^[0-9]+$", RegexOptions.CultureInvariant)]
    private static partial Regex DigitsOnly();

    [GeneratedRegex("^[A-Za-z0-9_]+$", RegexOptions.CultureInvariant)]
    private static partial Regex CodeWord();
}
