namespace OsbManager;

/// <summary>
/// Command line switches, mainly for a separate test data folder and unattended starts. --osb-url is for tests
/// only and --updated-from is passed by the updater to the new version; neither is in <see cref="Usage"/>.
/// </summary>
internal sealed record StartupOptions(
    string? DataRoot,
    IReadOnlyList<string> Start,
    bool StartLight,
    int? DebugPort,
    string? OsbUrl = null,
    int? UpdatedFrom = null)
{
    public const string Usage = "OsbManager.exe [--data <folder>] [--start <account>[,<account>...]] [--light] [--debug-port <port>]";

    public static StartupOptions Parse(IReadOnlyList<string> args)
    {
        string? dataRoot = null;
        var start = new List<string>();
        var light = false;
        int? debugPort = null;
        string? osbUrl = null;
        int? updatedFrom = null;
        for (var i = 0; i < args.Count; i++)
        {
            string Value() => i + 1 < args.Count ? args[++i] : throw new ArgumentException($"{args[i]} needs a value.");
            switch (args[i])
            {
                case "--data":
                    dataRoot = Value();
                    break;
                case "--start":
                    start.AddRange(Value().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                    break;
                case "--light":
                    light = true;
                    break;
                case "--debug-port":
                    debugPort = int.TryParse(Value(), out var port) && port is > 1024 and < 65536
                        ? port
                        : throw new ArgumentException("--debug-port needs a port between 1025 and 65535.");
                    break;
                case "--osb-url":
                    osbUrl = Value();
                    break;
                case UpdateRelaunch.Option:
                    updatedFrom = int.TryParse(Value(), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var pid) && pid > 0
                        ? pid
                        : throw new ArgumentException($"{UpdateRelaunch.Option} needs a process id.");
                    break;
                default:
                    throw new ArgumentException($"Unknown option {args[i]}.");
            }
        }
        return new StartupOptions(dataRoot, start, light, debugPort, osbUrl, updatedFrom);
    }
}
