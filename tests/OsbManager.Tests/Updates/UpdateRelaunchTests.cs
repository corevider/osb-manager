namespace OsbManager.Tests.Updates;

public class UpdateRelaunchTests
{
    [Fact]
    public void ReadsTheProcessIdOfThePreviousVersion()
    {
        var options = StartupOptions.Parse(["--data", "C:\\data", "--updated-from", "4242"]);

        Assert.Equal(4242, options.UpdatedFrom);
        Assert.Equal("C:\\data", options.DataRoot);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-5")]
    [InlineData("abc")]
    [InlineData(" 12")]
    public void RefusesABadProcessId(string value)
    {
        Assert.Throws<ArgumentException>(() => StartupOptions.Parse(["--updated-from", value]));
    }

    [Fact]
    public void RestartsWithTheSameArgumentsWithoutAnOldUpdateMarker()
    {
        var arguments = UpdateRelaunch.ArgumentsForRestart(["--data", "C:\\My Data", "--updated-from", "12", "--start", "a,b", "--light"]);

        Assert.Equal(["--data", "C:\\My Data", "--start", "a,b", "--light"], arguments);
    }

    [Fact]
    public void TheMarkerIsNotInTheUsageText()
    {
        Assert.DoesNotContain(UpdateRelaunch.Option, StartupOptions.Usage);
    }
}
