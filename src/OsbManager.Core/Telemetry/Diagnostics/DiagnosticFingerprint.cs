using System.Security.Cryptography;
using System.Text;

namespace OsbManager.Core.Telemetry.Diagnostics;

public static class DiagnosticFingerprint
{
    public const int FrameCount = 5;

    public static string ForException(DiagnosticKind kind, string type, string origin, IEnumerable<string> frames)
    {
        var own = frames.Where(f => f != FrameReducer.External && f != DiagnosticScrubber.PrivateMark && f != DiagnosticScrubber.PathMark)
            .Take(FrameCount)
            .Select(FrameReducer.WithoutOffset);
        return Of(DiagnosticFormats.WireName(kind), type, origin, string.Join(",", own));
    }

    public static string ForException(ErrorDetail error) => ForException(DiagnosticKind.DotnetException, error.Type, error.Origin, error.Frames);

    public static string ForProcess(ProcessDetail process) =>
        Of(DiagnosticFormats.WireName(DiagnosticKind.ProcessFailed), process.Kind, process.Reason, process.Description ?? "");

    public static string ForHang(string outcome) => Of(DiagnosticFormats.WireName(DiagnosticKind.Unresponsive), outcome);

    public static string ForGpu(string code) => Of(DiagnosticFormats.WireName(DiagnosticKind.GpuFailed), code);

    public static string ForRunEnd(string outcome) => Of(DiagnosticFormats.WireName(DiagnosticKind.RunEnd), outcome);

    public static string ForWarn(string category, string code) => Of(DiagnosticFormats.WireName(DiagnosticKind.Warn), category, code);

    public static string Of(params string[] parts)
    {
        var text = "manager|" + string.Join("|", parts);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(hash, 0, 8).ToLowerInvariant();
    }
}
