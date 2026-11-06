using OsbManager.Core;

namespace OsbManager.Tests;

public class StartupOptionsTests
{
    [Fact]
    public void DefaultsToNothingSet()
    {
        var options = StartupOptions.Parse([]);

        Assert.Null(options.DataRoot);
        Assert.Empty(options.Start);
        Assert.False(options.StartLight);
        Assert.Null(options.DebugPort);
        Assert.Null(options.OsbUrl);
    }

    [Fact]
    public void ReadsTheDocumentedSwitches()
    {
        var options = StartupOptions.Parse(["--data", "C:\\data", "--start", "a, b,,c", "--light", "--debug-port", "9333"]);

        Assert.Equal("C:\\data", options.DataRoot);
        Assert.Equal(["a", "b", "c"], options.Start);
        Assert.True(options.StartLight);
        Assert.Equal(9333, options.DebugPort);
    }

    [Fact]
    public void ReadsTheHiddenTestSwitches()
    {
        var options = StartupOptions.Parse(["--data", "C:\\new", "--osb-url", "http://127.0.0.1:9/osb.user.js"]);

        Assert.Equal("C:\\new", options.DataRoot);
        Assert.Equal("http://127.0.0.1:9/osb.user.js", options.OsbUrl);
    }

    [Theory]
    [InlineData("--unknown")]
    [InlineData("--data")]
    [InlineData("--debug-port", "80")]
    [InlineData("--debug-port", "text")]
    [InlineData("--migrate-from", "C:\\old", "--data", "C:\\new")]
    [InlineData("--legacy-process", "NoSuchApp")]
    public void RejectsBadInput(params string[] args)
    {
        Assert.Throws<ArgumentException>(() => StartupOptions.Parse(args));
    }

    [Fact]
    public void UsageNamesTheNewExecutableAndKeepsTestSwitchesHidden()
    {
        Assert.StartsWith("OsbManager.exe ", StartupOptions.Usage);
        Assert.DoesNotContain("osb-url", StartupOptions.Usage);
    }
}
