using System.Globalization;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace OsbManager.Core.Telemetry.Diagnostics;

public static partial class DiagnosticFormats
{
    public const string ReservedFingerprint = "0000000000000000";
    public const int MaxEvents = 50;
    public const int MaxPerf = 2;
    public const int MaxFrames = 16;
    public const int MaxInner = 3;
    public const int MaxManagerTrail = 50;
    public const int MaxOsbTrail = 20;
    public const int MaxEach = 64;
    public const int MaxCount = 100_000;
    public const int MaxEventBytes = 4 * 1024;
    public const int MaxPerfBytes = 8 * 1024;
    public const int SoftBodyBytes = 60 * 1024;
    public const int MaxBodyBytes = 64 * 1024;
    public const int MaxUptimeSeconds = 2_592_000;
    public const int MaxTemplateLength = 160;
    public const double MaxMegabytes = 262_144;
    public const double MaxCorePercent = 25_600;
    public const double MaxMilliseconds = 600_000;
    public const double MaxDetailMagnitude = 1e9;
    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(7);
    public static readonly TimeSpan MaxAhead = TimeSpan.FromMinutes(10);

    public static readonly IReadOnlySet<string> Origins = new HashSet<string>(StringComparer.Ordinal)
    {
        "guard", "tick", "data", "panel", "window", "rejection", "appdomain", "ui_thread", "task", "caught",
    };

    public static readonly IReadOnlySet<string> ProcessKinds = new HashSet<string>(StringComparer.Ordinal)
    {
        "browser_process_exited", "render_process_exited", "render_process_unresponsive", "frame_render_process_exited",
        "utility_process_exited", "sandbox_helper_process_exited", "gpu_process_exited", "ppapi_plugin_process_exited",
        "ppapi_broker_process_exited", "unknown_process_exited",
    };

    public static readonly IReadOnlySet<string> ProcessReasons = new HashSet<string>(StringComparer.Ordinal)
    {
        "unexpected", "unresponsive", "terminated", "crashed", "launch_failed", "out_of_memory", "profile_deleted",
    };

    public static readonly IReadOnlySet<string> HangOutcomes = new HashSet<string>(StringComparer.Ordinal) { "responded", "reloaded", "restarted", "gave_up" };

    public static readonly IReadOnlySet<string> StopSources = new HashSet<string>(StringComparer.Ordinal) { "stop", "town", "stop_all" };

    public static readonly IReadOnlySet<string> RunOutcomes = new HashSet<string>(StringComparer.Ordinal) { "clean", "unclean", "crash" };

    public static readonly IReadOnlySet<string> TrailLevels = new HashSet<string>(StringComparer.Ordinal) { "info", "warn", "error", "cmd" };

    public static readonly IReadOnlySet<string> GpuVendors = new HashSet<string>(StringComparer.Ordinal)
    {
        "nvidia", "amd", "intel", "apple", "qualcomm", "other", "unknown",
    };

    public static readonly IReadOnlySet<string> Phases = new HashSet<string>(StringComparer.Ordinal)
    {
        "signed-out", "listing-servers", "loading-roster", "authenticating", "connecting", "entering-world", "world",
        "reconnecting", "disconnected", "character-select", "other",
    };

    public static readonly IReadOnlySet<string> LoginStages = new HashSet<string>(StringComparer.Ordinal)
    {
        "off", "waiting", "title", "server", "credentials", "connecting", "retry", "character", "entering", "choose",
        "failed", "done", "other",
    };

    public static readonly IReadOnlySet<string> Modes = new HashSet<string>(StringComparer.Ordinal)
    {
        "idle", "hunting", "fight", "loot", "resting", "town", "returning", "travelling", "quest", "resurrect",
        "party-support", "recording", "shopping", "error", "other",
    };

    public static readonly IReadOnlySet<string> DetailNumbers = new HashSet<string>(StringComparer.Ordinal)
    {
        "durationMs", "distance", "attempt", "quantity", "hpPct", "mpPct", "delayMs", "kills", "deaths", "potions",
        "items", "revision", "visited", "progressAgeMs", "skillId", "leg", "legs",
    };

    public static readonly IReadOnlySet<string> DetailFlags = new HashSet<string>(StringComparer.Ordinal) { "attackingPlayer", "choice" };

    public static readonly int[] RamBuckets = [2, 4, 8, 16, 32, 64];
    public static readonly int[] CoreBuckets = [1, 2, 4, 8, 16, 32];

    [GeneratedRegex("^[a-z0-9][a-z0-9_.:-]{0,63}$", RegexOptions.CultureInvariant)]
    private static partial Regex CodePattern();

    [GeneratedRegex("^[0-9A-Za-z.+-]{1,32}$", RegexOptions.CultureInvariant)]
    private static partial Regex VersionPattern();

    [GeneratedRegex("^[0-9a-f]{16}$", RegexOptions.CultureInvariant)]
    private static partial Regex Hex16Pattern();

    [GeneratedRegex(@"^[A-Za-z_$<?][A-Za-z0-9_$<>.+-]{0,95}(@[0-9]{1,7}:[0-9]{1,5}|\+IL_[0-9A-F]{4,6})?$", RegexOptions.CultureInvariant)]
    private static partial Regex FramePattern();

    [GeneratedRegex("^[A-Za-z0-9 .,:;()<>'_/-]*$", RegexOptions.CultureInvariant)]
    private static partial Regex TemplatePattern();

    [GeneratedRegex("^[A-Za-z_][A-Za-z0-9_.]{0,127}$", RegexOptions.CultureInvariant)]
    private static partial Regex TypePattern();

    [GeneratedRegex("^0x[0-9A-F]{8}$", RegexOptions.CultureInvariant)]
    private static partial Regex HResultPattern();

    [GeneratedRegex("^-?0x[0-9A-F]{1,8}$", RegexOptions.CultureInvariant)]
    private static partial Regex ExitCodePattern();

    [GeneratedRegex(@"^[0-9]{1,5}(\.[0-9]{1,6}){1,3}$", RegexOptions.CultureInvariant)]
    private static partial Regex OsBuildPattern();

    public static bool IsCode(string? value) => value is not null && CodePattern().IsMatch(value);

    public static bool IsVersion(string? value) => value is not null && VersionPattern().IsMatch(value);

    public static bool IsHex16(string? value) => value is not null && Hex16Pattern().IsMatch(value);

    public static bool IsFrame(string? value) => value is not null && (value == "ext" || FramePattern().IsMatch(value));

    public static bool IsTemplate(string? value) =>
        value is not null && value.EnumerateRunes().Count() <= MaxTemplateLength && TemplatePattern().IsMatch(value);

    public static bool IsTypeName(string? value) => value is not null && TypePattern().IsMatch(value);

    public static bool IsHResult(string? value) => value is not null && HResultPattern().IsMatch(value);

    public static bool IsExitCode(string? value) => value is not null && ExitCodePattern().IsMatch(value);

    public static bool IsOsBuild(string? value) => value is not null && OsBuildPattern().IsMatch(value);

    public static string WireName(DiagnosticKind kind) => kind switch
    {
        DiagnosticKind.JsError => "js_error",
        DiagnosticKind.DotnetException => "dotnet_exception",
        DiagnosticKind.ProcessFailed => "process_failed",
        DiagnosticKind.Unresponsive => "unresponsive",
        DiagnosticKind.GpuFailed => "gpu_failed",
        DiagnosticKind.BotStop => "bot_stop",
        DiagnosticKind.Warn => "warn",
        DiagnosticKind.RunEnd => "run_end",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public static string WireName(DiagnosticSource source) => source == DiagnosticSource.Osb ? "osb" : "manager";

    public static string Hex(int value) => "0x" + value.ToString("X8", CultureInfo.InvariantCulture);

    public static string ExitCode(int value) => "0x" + unchecked((uint)value).ToString("X", CultureInfo.InvariantCulture);

    public static string SnakeCase(string name)
    {
        var builder = new System.Text.StringBuilder(name.Length + 8);
        for (var i = 0; i < name.Length; i++)
        {
            var c = name[i];
            if (char.IsUpper(c))
            {
                if (i > 0)
                {
                    builder.Append('_');
                }
                builder.Append(char.ToLowerInvariant(c));
            }
            else
            {
                builder.Append(c);
            }
        }
        return builder.ToString();
    }

    public static DateTimeOffset Minute(DateTimeOffset value)
    {
        var utc = value.ToUniversalTime();
        return new DateTimeOffset(utc.Year, utc.Month, utc.Day, utc.Hour, utc.Minute, 0, TimeSpan.Zero);
    }

    public static string MinuteText(DateTimeOffset value) => Minute(value).ToString("yyyy-MM-dd'T'HH:mm':00Z'", CultureInfo.InvariantCulture);

    public static int RoundUptime(double seconds) => (int)Math.Clamp(Math.Round(seconds / 60) * 60, 0, MaxUptimeSeconds);

    public static int? RamBucket(long bytes)
    {
        var gigabytes = bytes / (1024.0 * 1024 * 1024);
        return Bucket(gigabytes + 1, RamBuckets);
    }

    public static int? CoreBucket(int cores) => Bucket(cores, CoreBuckets);

    public static string NewRunKey() => Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();

    private static int? Bucket(double value, int[] buckets)
    {
        int? result = null;
        foreach (var bucket in buckets)
        {
            if (value >= bucket)
            {
                result = bucket;
            }
        }
        return result;
    }
}
