using System.ComponentModel;
using System.Text.RegularExpressions;

namespace OsbManager.Core.Telemetry.Diagnostics;

public static partial class DiagnosticScrubber
{
    public const string PrivateMark = "<x>";
    public const string PathMark = "<path>";
    public const string Other = "other";
    public const string FallbackType = "Exception";

    private static readonly Dictionary<string, string> ProcessDescriptions = new(StringComparer.Ordinal)
    {
        ["Audio Service"] = "audio-service",
        ["Network Service"] = "network-service",
        ["Storage Service"] = "storage-service",
        ["Data Decoder Service"] = "data-decoder-service",
        ["Video Capture"] = "video-capture",
        ["GPU Process"] = "gpu-process",
        ["Utility Process"] = "utility-process",
        ["Unzipper"] = "unzipper",
        ["Printing Service"] = "printing-service",
        ["Speech Recognition Service"] = "speech-recognition-service",
    };

    private static readonly HashSet<string> EngineErrorTypes = new(StringComparer.Ordinal)
    {
        "TypeError", "RangeError", "ReferenceError", "SyntaxError", "URIError", "EvalError", "AggregateError", "DOMException",
    };

    [GeneratedRegex(@"[A-Za-z]:\\|\\\\|/Users/|/home/|%[A-Z]+%|Users[\\/]", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex PathPattern();

    [GeneratedRegex("'[^']*'|\"[^\"]*\"|`[^`]*`|«[^»]*»", RegexOptions.CultureInvariant)]
    private static partial Regex QuotedPattern();

    [GeneratedRegex(@"\b[a-z][a-z0-9+.-]*://\S+", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex UrlPattern();

    [GeneratedRegex(@"\b0x[0-9a-fA-F]+\b|\d{2,}", RegexOptions.CultureInvariant)]
    private static partial Regex NumberPattern();

    [GeneratedRegex(@"[\p{L}\p{N}_]{3,}", RegexOptions.CultureInvariant)]
    private static partial Regex WordPattern();

    [GeneratedRegex("[^A-Za-z0-9 .,:;()<>'_/-]", RegexOptions.CultureInvariant)]
    private static partial Regex OutsideTemplatePattern();

    [GeneratedRegex(" {2,}", RegexOptions.CultureInvariant)]
    private static partial Regex SpacesPattern();

    public static bool LooksLikePath(string? text) => text is not null && PathPattern().IsMatch(text);

    public static bool IsClean(string? text, PrivateTerms terms) => text is null || (!LooksLikePath(text) && !terms.Hits(text));

    public static ErrorDetail Exception(Exception exception, string origin, bool handled)
    {
        var inner = new List<string>();
        for (var current = exception.InnerException; current is not null && inner.Count < DiagnosticFormats.MaxInner; current = current.InnerException)
        {
            inner.Add(TypeName(current.GetType()));
        }
        return new ErrorDetail(
            TypeName(exception.GetType()),
            DiagnosticFormats.Origins.Contains(origin) ? origin : "caught",
            handled,
            FrameReducer.FromException(exception),
            inner,
            DiagnosticFormats.Hex(NativeCode(exception)));
    }

    public static string TypeName(Type type)
    {
        var name = FrameReducer.TypeName(type);
        return FrameReducer.IsOwnNamespace(name) && DiagnosticFormats.IsTypeName(name) ? name! : FallbackType;
    }

    public static int NativeCode(Exception exception)
    {
        if (exception is Win32Exception win32)
        {
            var code = win32.NativeErrorCode;
            return code <= 0 ? code : unchecked((int)(0x80070000u | ((uint)code & 0xFFFF)));
        }
        return exception.HResult;
    }

    public static string? ProcessDescription(string? description) =>
        description is not null && ProcessDescriptions.TryGetValue(description.Trim(), out var code) ? code : null;

    public static string ProcessKind(string enumName) => Allowed(DiagnosticFormats.SnakeCase(enumName), DiagnosticFormats.ProcessKinds, "unknown_process_exited");

    public static string ProcessReason(string enumName) => Allowed(DiagnosticFormats.SnakeCase(enumName), DiagnosticFormats.ProcessReasons, "unexpected");

    public static string? GpuFailure(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }
        if (Contains(text, "adapter") || Contains(text, "null"))
        {
            return "adapter-null";
        }
        if (Contains(text, "lost") || Contains(text, "destroyed"))
        {
            return "device-lost";
        }
        if (Contains(text, "memory"))
        {
            return "out-of-memory";
        }
        if (Contains(text, "support") || Contains(text, "webgpu is not") || Contains(text, "navigator.gpu"))
        {
            return "unsupported";
        }
        return Other;
    }

    public static string? Phase(string? value) => value is null ? null : Allowed(value, DiagnosticFormats.Phases, Other);

    public static string? LoginStage(string? value) => value is null ? null : Allowed(value, DiagnosticFormats.LoginStages, Other);

    public static string? Mode(string? value) => value is null ? null : Allowed(value, DiagnosticFormats.Modes, Other);

    public static string? Template(string? type, string? message, PrivateTerms terms)
    {
        if (type is null || message is null || !EngineErrorTypes.Contains(type))
        {
            return null;
        }
        var text = message.Length > 300 ? message[..300] : message;
        text = QuotedPattern().Replace(text, "<q>");
        text = UrlPattern().Replace(text, "<url>");
        text = NumberPattern().Replace(text, "<n>");
        text = WordPattern().Replace(text, m => terms.Hits(m.Value) ? PrivateMark : m.Value);
        text = OsbVocabulary.Current.Words(text);
        text = OutsideTemplatePattern().Replace(text, "");
        text = OsbVocabulary.Current.Words(SpacesPattern().Replace(text, " ").Trim());
        if (text.Length > DiagnosticFormats.MaxTemplateLength)
        {
            text = text[..DiagnosticFormats.MaxTemplateLength];
        }
        return Guard(text, terms);
    }

    public static DiagnosticEvent? Scrub(DiagnosticEvent e, PrivateTerms terms)
    {
        if (!DiagnosticFormats.IsHex16(e.Fingerprint) || e.Fingerprint == DiagnosticFormats.ReservedFingerprint)
        {
            return null;
        }
        var scrubbed = e with
        {
            Count = Math.Clamp(e.Count, 1, DiagnosticFormats.MaxCount),
            Error = null,
            Process = null,
            Hang = null,
            Gpu = null,
            Stop = null,
            Warn = null,
            RunEnd = null,
            Context = Context(e.Context, terms),
            Trail = Trail(e.Trail, e.Source, terms),
        };
        return e.Kind switch
        {
            DiagnosticKind.JsError or DiagnosticKind.DotnetException => Error(e.Error, terms) is { } error ? scrubbed with { Error = error } : null,
            DiagnosticKind.ProcessFailed => Process(e.Process, terms) is { } process ? scrubbed with { Process = process } : null,
            DiagnosticKind.Unresponsive => e.Hang is { } hang && DiagnosticFormats.HangOutcomes.Contains(hang.Outcome)
                ? scrubbed with { Hang = hang with { WaitedSeconds = Math.Clamp(hang.WaitedSeconds, 0, 86400) } }
                : null,
            DiagnosticKind.GpuFailed => e.Gpu is { } gpu && Code(gpu.Code, terms) is { } gpuCode
                ? scrubbed with { Gpu = new GpuDetail(gpuCode, Math.Clamp(gpu.Retries, 0, 100)) }
                : null,
            DiagnosticKind.BotStop => e.Stop is { } stop && Code(stop.Code, terms) is { } stopCode && DiagnosticFormats.StopSources.Contains(stop.Source)
                ? scrubbed with { Stop = new StopDetail(stopCode, stop.Source) }
                : null,
            DiagnosticKind.Warn => Warn(e.Warn, terms) is { } warn ? scrubbed with { Warn = warn } : null,
            DiagnosticKind.RunEnd => e.RunEnd is { } end && DiagnosticFormats.RunOutcomes.Contains(end.Outcome) && Version(end.PreviousVersion, terms) is { } previous
                ? scrubbed with { RunEnd = new RunEndDetail(end.Outcome, DiagnosticFormats.RoundUptime(end.UptimeSeconds), previous), Trail = null, Context = null }
                : null,
            _ => null,
        };
    }

    public static string? Code(string? value, PrivateTerms terms) => DiagnosticFormats.IsCode(value) && IsClean(value, terms) ? value : null;

    public static string? Version(string? value, PrivateTerms terms) => DiagnosticFormats.IsVersion(value) && IsClean(value, terms) ? value : null;

    public static string Frame(string value, PrivateTerms terms)
    {
        if (!DiagnosticFormats.IsFrame(value))
        {
            return FrameReducer.External;
        }
        if (LooksLikePath(value))
        {
            return PathMark;
        }
        return terms.Hits(value) ? PrivateMark : value;
    }

    private static string? Guard(string text, PrivateTerms terms)
    {
        if (LooksLikePath(text))
        {
            return PathMark;
        }
        if (terms.Hits(text))
        {
            return PrivateMark;
        }
        return DiagnosticFormats.IsTemplate(text) ? text : null;
    }

    private static ErrorDetail? Error(ErrorDetail? error, PrivateTerms terms)
    {
        if (error is null || !DiagnosticFormats.Origins.Contains(error.Origin))
        {
            return null;
        }
        var type = DiagnosticFormats.IsTypeName(error.Type) && IsClean(error.Type, terms) ? error.Type : null;
        if (type is null)
        {
            return null;
        }
        var frames = error.Frames.Take(DiagnosticFormats.MaxFrames).Select(f => Frame(f, terms)).ToList();
        var inner = (error.Inner ?? []).Take(DiagnosticFormats.MaxInner)
            .Select(t => DiagnosticFormats.IsTypeName(t) && IsClean(t, terms) ? t : FallbackType)
            .ToList();
        return error with
        {
            Type = type,
            Frames = frames,
            Inner = inner,
            HResult = DiagnosticFormats.IsHResult(error.HResult) ? error.HResult : null,
            Template = error.Template is null ? null : Guard(error.Template, terms),
            Module = Code(error.Module, terms),
        };
    }

    private static ProcessDetail? Process(ProcessDetail? process, PrivateTerms terms)
    {
        if (process is null
            || !DiagnosticFormats.ProcessKinds.Contains(process.Kind)
            || !DiagnosticFormats.ProcessReasons.Contains(process.Reason)
            || !DiagnosticFormats.IsExitCode(process.ExitCode))
        {
            return null;
        }
        return process with { Description = Code(process.Description, terms) };
    }

    private static WarnDetail? Warn(WarnDetail? warn, PrivateTerms terms)
    {
        if (warn is null || Code(warn.Category, terms) is not { } category || Code(warn.Code, terms) is not { } code)
        {
            return null;
        }
        RefusalDetail? refusal = null;
        if (warn.Refusal is { } r && Code(r.Source, terms) is { } source && Code(r.Reason, terms) is { } reason)
        {
            refusal = new RefusalDetail(source, reason, Math.Clamp(r.Native, 0, 65535));
        }
        return new WarnDetail(category, code, Code(warn.ErrorClass, terms), refusal);
    }

    private static DiagnosticContext? Context(DiagnosticContext? context, PrivateTerms terms)
    {
        if (context is null)
        {
            return null;
        }
        return new DiagnosticContext
        {
            Phase = Phase(context.Phase),
            Mode = Mode(context.Mode),
            TownPhase = Code(context.TownPhase, terms),
            Dead = context.Dead,
            LoginStage = LoginStage(context.LoginStage),
            Window = context.Window is >= 1 and <= 64 ? context.Window : null,
            Windows = context.Windows is >= 0 and <= 64 ? context.Windows : null,
            Light = context.Light,
            Hidden = context.Hidden,
            UptimeSeconds = context.UptimeSeconds is { } uptime ? DiagnosticFormats.RoundUptime(uptime) : null,
        };
    }

    private static IReadOnlyList<TrailItem>? Trail(IReadOnlyList<TrailItem>? trail, DiagnosticSource source, PrivateTerms terms)
    {
        if (trail is null)
        {
            return null;
        }
        var limit = source == DiagnosticSource.Osb ? DiagnosticFormats.MaxOsbTrail : DiagnosticFormats.MaxManagerTrail;
        var result = new List<TrailItem>();
        foreach (var item in trail.Skip(Math.Max(0, trail.Count - limit)))
        {
            if (!DiagnosticFormats.TrailLevels.Contains(item.Level) || Code(item.Category, terms) is not { } category || Code(item.Code, terms) is not { } code)
            {
                continue;
            }
            result.Add(new TrailItem(
                Math.Clamp(item.SecondsBefore, -86400, 0),
                item.Level,
                category,
                code,
                Math.Clamp(item.Count, 1, DiagnosticFormats.MaxCount),
                item.Window is >= 1 and <= 64 ? item.Window : null,
                Code(item.Outcome, terms),
                Code(item.ErrorClass, terms),
                Numbers(item.Numbers),
                Flags(item.Flags)));
        }
        return result;
    }

    private static IReadOnlyDictionary<string, double>? Numbers(IReadOnlyDictionary<string, double>? numbers)
    {
        var kept = numbers?
            .Where(p => DiagnosticFormats.DetailNumbers.Contains(p.Key) && double.IsFinite(p.Value) && Math.Abs(p.Value) <= DiagnosticFormats.MaxDetailMagnitude)
            .ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal);
        return kept is { Count: > 0 } ? kept : null;
    }

    private static IReadOnlyDictionary<string, bool>? Flags(IReadOnlyDictionary<string, bool>? flags)
    {
        var kept = flags?.Where(p => DiagnosticFormats.DetailFlags.Contains(p.Key)).ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal);
        return kept is { Count: > 0 } ? kept : null;
    }

    private static string Allowed(string value, IReadOnlySet<string> allowed, string fallback) => allowed.Contains(value) ? value : fallback;

    private static bool Contains(string text, string part) => text.Contains(part, StringComparison.OrdinalIgnoreCase);
}
