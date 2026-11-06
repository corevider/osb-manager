using OsbManager.Core;

namespace OsbManager.Tests;

public class AppPathsTests
{
    private static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    [Fact]
    public void TheDefaultDataFolderIsOsbManager()
    {
        Assert.Equal(Path.Combine(LocalAppData, "OSB Manager"), AppPaths.Default().Root);
    }

    [Fact]
    public void KeepsTheFolderLayout()
    {
        var paths = new AppPaths(Path.Combine(LocalAppData, "x"));

        Assert.EndsWith(Path.Combine("x", "WebView2"), paths.WebViewData);
        Assert.EndsWith(Path.Combine("x", "cache", "packs"), paths.PackCache);
        Assert.EndsWith(Path.Combine("x", "scripts"), paths.Scripts);
        Assert.EndsWith(Path.Combine("x", "accounts.json"), paths.AccountsFile);
        Assert.EndsWith(Path.Combine("x", "settings.json"), paths.SettingsFile);
        Assert.EndsWith(Path.Combine("x", "sox.json"), paths.SoxFile);
    }
}
