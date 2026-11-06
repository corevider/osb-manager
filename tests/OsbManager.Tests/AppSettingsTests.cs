using OsbManager.Core;

namespace OsbManager.Tests;

public class AppSettingsTests
{
    [Fact]
    public void DefaultsToSixtyFramesASecond()
    {
        using var temp = new TempDirectory();

        Assert.Equal(60, AppSettings.Load(temp.File("settings.json")).FrameLimit);
    }

    [Fact]
    public void KeepsTheChosenFrameLimit()
    {
        using var temp = new TempDirectory();
        var settings = AppSettings.Load(temp.File("settings.json"));
        settings.FrameLimit = 0;
        settings.Save();

        Assert.Equal(0, AppSettings.Load(temp.File("settings.json")).FrameLimit);
    }

    [Fact]
    public void KeepsTheHideStarChoiceAndLoadsOldFilesWithItOff()
    {
        using var temp = new TempDirectory();
        File.WriteAllText(temp.File("settings.json"), """{"frameLimit":60,"lowMemoryWhenHidden":false}""");
        var settings = AppSettings.Load(temp.File("settings.json"));
        Assert.False(settings.HideStarSox);

        settings.HideStarSox = true;
        settings.Save();

        Assert.True(AppSettings.Load(temp.File("settings.json")).HideStarSox);
        Assert.Contains("\"hideStarSox\": true", File.ReadAllText(temp.File("settings.json")));
        Assert.False(AppSettings.Load(temp.File("missing.json")).HideStarSox);
    }

    [Theory]
    [InlineData("""{"frameLimit":7}""")]
    [InlineData("""{"frameLimit":-1}""")]
    [InlineData("not json")]
    public void FallsBackToTheDefaultForUnknownValues(string json)
    {
        using var temp = new TempDirectory();
        File.WriteAllText(temp.File("settings.json"), json);

        Assert.Equal(AppSettings.DefaultFrameLimit, AppSettings.Load(temp.File("settings.json")).FrameLimit);
    }

    [Fact]
    public void MemorySettingsAreOffUntilSwitchedOn()
    {
        using var temp = new TempDirectory();
        var settings = AppSettings.Load(temp.File("settings.json"));

        Assert.False(settings.LowMemoryWhenHidden);
    }

    [Fact]
    public void KeepsTheMemorySettings()
    {
        using var temp = new TempDirectory();
        var settings = AppSettings.Load(temp.File("settings.json"));
        settings.LowMemoryWhenHidden = true;
        settings.Save();

        var loaded = AppSettings.Load(temp.File("settings.json"));
        Assert.True(loaded.LowMemoryWhenHidden);
    }
}
