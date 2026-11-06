using System.Globalization;
using System.Text;

namespace OsbManager.Core.Status;

public sealed record ProcessMemory(long PrivateBytes, long WorkingSetBytes)
{
    public static ProcessMemory Sum(IEnumerable<ProcessMemory> parts)
    {
        long privateBytes = 0, workingSet = 0;
        foreach (var part in parts)
        {
            privateBytes += part.PrivateBytes;
            workingSet += part.WorkingSetBytes;
        }
        return new ProcessMemory(privateBytes, workingSet);
    }
}

/// <summary>What one open account's game window costs. A null field means the value could not be read.</summary>
public sealed record AccountMemory(
    string Account,
    bool Light,
    bool Hidden,
    ProcessMemory? Renderer,
    long? JsHeapUsed,
    long? JsHeapTotal,
    long? WasmBytes,
    int WasmMemories);

/// <summary>A snapshot of the browser processes of one app run, for the Memory tab and its copied text.</summary>
public sealed record MemoryReport(
    DateTimeOffset At,
    IReadOnlyList<AccountMemory> Accounts,
    ProcessMemory? Gpu,
    ProcessMemory Browser,
    ProcessMemory App)
{
    private static readonly CultureInfo Culture = CultureInfo.InvariantCulture;

    public static string Megabytes(long? bytes) => bytes is { } value ? (value / 1048576.0).ToString("N1", Culture) : Format.Missing;

    public static string ModeText(bool light, bool hidden) => (light, hidden) switch
    {
        (true, true) => "light, hidden",
        (true, false) => "light",
        (false, true) => "hidden",
        _ => "normal",
    };

    public static string WasmText(long? bytes, int memories) =>
        bytes is { } value ? (memories == 0 ? "none" : Megabytes(value) + (memories > 1 ? $" ({memories})" : "")) : Format.Missing;

    public string ToText()
    {
        var rows = new List<string[]> { new[] { "Account", "State", "Renderer private MB", "Renderer working set MB", "JS heap used MB", "JS heap total MB", "WebAssembly MB" } };
        foreach (var account in Accounts)
        {
            rows.Add([
                account.Account,
                ModeText(account.Light, account.Hidden),
                Megabytes(account.Renderer?.PrivateBytes),
                Megabytes(account.Renderer?.WorkingSetBytes),
                Megabytes(account.JsHeapUsed),
                Megabytes(account.JsHeapTotal),
                WasmText(account.WasmBytes, account.WasmMemories),
            ]);
        }
        var widths = Enumerable.Range(0, rows[0].Length).Select(i => rows.Max(r => r[i].Length)).ToArray();
        var text = new StringBuilder();
        text.AppendLine("OSB Manager memory report " + At.ToString("yyyy-MM-dd HH:mm:ss zzz", Culture));
        foreach (var row in rows)
        {
            text.AppendLine(string.Join("  ", row.Select((cell, i) => i < 2 ? cell.PadRight(widths[i]) : cell.PadLeft(widths[i]))).TrimEnd());
        }
        var renderers = ProcessMemory.Sum(Accounts.Select(a => a.Renderer).OfType<ProcessMemory>());
        text.AppendLine();
        text.AppendLine($"Game renderers ({Accounts.Count(a => a.Renderer is not null)}): private {Megabytes(renderers.PrivateBytes)} MB, working set {Megabytes(renderers.WorkingSetBytes)} MB");
        text.AppendLine(Gpu is { } gpu
            ? $"GPU process: private {Megabytes(gpu.PrivateBytes)} MB, working set {Megabytes(gpu.WorkingSetBytes)} MB"
            : "GPU process: not running");
        var all = new ProcessMemory(Browser.PrivateBytes + App.PrivateBytes, Browser.WorkingSetBytes + App.WorkingSetBytes);
        text.AppendLine($"All browser processes: private {Megabytes(Browser.PrivateBytes)} MB, working set {Megabytes(Browser.WorkingSetBytes)} MB");
        text.AppendLine($"The app: private {Megabytes(App.PrivateBytes)} MB, working set {Megabytes(App.WorkingSetBytes)} MB");
        text.AppendLine($"Everything: private {Megabytes(all.PrivateBytes)} MB, working set {Megabytes(all.WorkingSetBytes)} MB");
        return text.ToString();
    }
}
