using OsbManager.UI;

namespace OsbManager.Tests;

public class AboutBoxTests
{
    [Fact]
    public void ListsVersionMakerRuntimeAndDataFolder()
    {
        var details = AboutBox.Details("1.0.0", "131.0.2903.70", @"C:\data");

        Assert.Equal(["Version 1.0.0", "Corevider", "WebView2 Runtime 131.0.2903.70", @"Data folder: C:\data"], details);
    }

    [Fact]
    public void SaysWhenTheRuntimeIsMissing()
    {
        var details = AboutBox.Details("1.0.0", null, @"C:\data");

        Assert.Contains("WebView2 Runtime not installed", details);
    }
}
