using OsbManager.Core.Status;

namespace OsbManager.Tests;

public class MemoryReportTests
{
    private const long Mb = 1L << 20;

    private static MemoryReport Report(params AccountMemory[] accounts) => new(
        new DateTimeOffset(2026, 11, 2, 12, 0, 0, TimeSpan.Zero),
        accounts,
        new ProcessMemory(500 * Mb, 300 * Mb),
        new ProcessMemory(2000 * Mb, 1500 * Mb),
        new ProcessMemory(50 * Mb, 60 * Mb));

    [Fact]
    public void TheTextListsEveryAccountAndTheTotals()
    {
        var text = Report(
            new AccountMemory("alpha", false, false, new ProcessMemory(700 * Mb, 800 * Mb), 40 * Mb, 70 * Mb, 0, 0),
            new AccountMemory("beta", true, false, new ProcessMemory(600 * Mb, 500 * Mb), 30 * Mb, 50 * Mb, null, 0)).ToText();

        Assert.Contains("alpha", text);
        Assert.Contains("light", text);
        Assert.Contains("1,300.0", text);
        Assert.Contains("GPU process: private 500.0 MB, working set 300.0 MB", text);
        Assert.Contains("All browser processes: private 2,000.0 MB", text);
        Assert.Contains("Everything: private 2,050.0 MB, working set 1,560.0 MB", text);
    }

    [Fact]
    public void UnreadableValuesShowAsMissingAndNeverAsZero()
    {
        var text = Report(new AccountMemory("alpha", false, true, null, null, null, null, 0)).ToText();

        var line = text.Split(Environment.NewLine).First(l => l.StartsWith("alpha"));
        Assert.Contains("hidden", line);
        Assert.Equal(5, line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Count(part => part == Format.Missing));
    }

    [Theory]
    [InlineData(false, false, "normal")]
    [InlineData(true, false, "light")]
    [InlineData(false, true, "hidden")]
    [InlineData(true, true, "light, hidden")]
    public void TheStateNamesLightAndHidden(bool light, bool hidden, string expected)
    {
        Assert.Equal(expected, MemoryReport.ModeText(light, hidden));
    }

    [Fact]
    public void WebAssemblyShowsNoneWhenThePageHasNoMemory()
    {
        Assert.Equal("none", MemoryReport.WasmText(0, 0));
        Assert.Equal("64.0 (2)", MemoryReport.WasmText(64 * Mb, 2));
        Assert.Equal(Format.Missing, MemoryReport.WasmText(null, 0));
    }

    [Fact]
    public void AMissingGpuProcessIsSaid()
    {
        var report = Report() with { Gpu = null };

        Assert.Contains("GPU process: not running", report.ToText());
    }

    [Fact]
    public void SumAddsPrivateAndWorkingSet()
    {
        var sum = ProcessMemory.Sum([new ProcessMemory(1, 2), new ProcessMemory(10, 20)]);

        Assert.Equal(new ProcessMemory(11, 22), sum);
    }
}
