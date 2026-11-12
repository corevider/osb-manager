using System.Diagnostics;
using System.Globalization;
using System.Reflection;

namespace OsbManager.Core.Telemetry.Diagnostics;

public sealed record FrameInfo(string? DeclaringType, string? Method, int ILOffset);

public static class FrameReducer
{
    public const string External = "ext";

    private static readonly string[] OwnNamespaces = ["System", "Microsoft", "OsbManager", "Windows"];

    public static IReadOnlyList<string> FromException(Exception exception) => Reduce(Frames(exception));

    public static IReadOnlyList<FrameInfo> Frames(Exception exception)
    {
        var trace = new StackTrace(exception, fNeedFileInfo: false);
        var frames = new List<FrameInfo>();
        foreach (var frame in trace.GetFrames())
        {
            MethodBase? method;
            try
            {
                method = frame.GetMethod();
            }
            catch (Exception e) when (e is NotSupportedException or InvalidOperationException)
            {
                method = null;
            }
            frames.Add(new FrameInfo(TypeName(method?.DeclaringType), method?.Name, frame.GetILOffset()));
        }
        return frames;
    }

    public static IReadOnlyList<string> Reduce(IEnumerable<FrameInfo> frames)
    {
        var result = new List<string>();
        foreach (var frame in frames)
        {
            var text = Format(frame);
            if (text == External && result.Count > 0 && result[^1] == External)
            {
                continue;
            }
            result.Add(text);
            if (result.Count == DiagnosticFormats.MaxFrames)
            {
                break;
            }
        }
        return result;
    }

    public static bool IsOwnNamespace(string? typeName)
    {
        if (typeName is null)
        {
            return false;
        }
        foreach (var name in OwnNamespaces)
        {
            if (typeName.StartsWith(name + ".", StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    public static string WithoutOffset(string frame)
    {
        var at = frame.IndexOf("+IL_", StringComparison.Ordinal);
        return at < 0 ? frame : frame[..at];
    }

    public static string? TypeName(Type? type)
    {
        if (type is null)
        {
            return null;
        }
        if (type.IsGenericType && !type.IsGenericTypeDefinition)
        {
            type = type.GetGenericTypeDefinition();
        }
        return StripArity(type.FullName ?? type.Name);
    }

    private static string Format(FrameInfo frame)
    {
        if (!IsOwnNamespace(frame.DeclaringType) || string.IsNullOrEmpty(frame.Method))
        {
            return External;
        }
        var text = StripArity(frame.DeclaringType!) + "." + frame.Method;
        if (frame.ILOffset >= 0)
        {
            text += "+IL_" + frame.ILOffset.ToString("X4", CultureInfo.InvariantCulture);
        }
        return DiagnosticFormats.IsFrame(text) ? text : External;
    }

    private static string StripArity(string name)
    {
        var bracket = name.IndexOf('[', StringComparison.Ordinal);
        if (bracket >= 0)
        {
            name = name[..bracket];
        }
        var builder = new System.Text.StringBuilder(name.Length);
        for (var i = 0; i < name.Length; i++)
        {
            if (name[i] == '`')
            {
                while (i + 1 < name.Length && char.IsAsciiDigit(name[i + 1]))
                {
                    i++;
                }
                continue;
            }
            builder.Append(name[i]);
        }
        return builder.ToString();
    }
}
