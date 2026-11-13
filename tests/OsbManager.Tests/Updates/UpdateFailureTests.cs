using OsbManager.Core;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class UpdateFailureTests
{
    private static readonly UpdateVersion Version = new(1, 2, 0);

    [Fact]
    public void AnEmptyMessageStillNamesTheStepAndTheExceptionType()
    {
        var error = new FileNotFoundException("", "System.Diagnostics.Process, Version=10.0.0.0");

        var text = UpdateFailure.ForUser(Version, UpdateStep.Start, error);

        Assert.Equal("The update to 1.2.0 failed while starting the new version: FileNotFoundException without a message", text);
    }

    [Fact]
    public void AWhitespaceMessageCountsAsEmpty()
    {
        var text = UpdateFailure.ForUser(Version, UpdateStep.Swap, new IOException("  "));

        Assert.Equal("The update to 1.2.0 failed while replacing the exe: IOException without a message", text);
    }

    [Fact]
    public void TheFileNameOfTheExceptionIsNotShown()
    {
        var error = new FileNotFoundException("", @"D:\canary-made-up-folder\OSB Manager\x.dll");

        var text = UpdateFailure.ForUser(Version, UpdateStep.Prepare, error);

        Assert.DoesNotContain(@"D:\", text);
        Assert.DoesNotContain("canary-made-up-folder", text);
        Assert.Contains("while preparing the restart", text);
    }

    [Fact]
    public void AMessageIsShownWithTheStep()
    {
        var text = UpdateFailure.ForUser(Version, UpdateStep.Download, new UpdateException("The download does not match the signed manifest."));

        Assert.Equal("The update to 1.2.0 failed while downloading and checking it: The download does not match the signed manifest.", text);
    }

    [Fact]
    public void EveryStepHasItsOwnText()
    {
        var texts = Enum.GetValues<UpdateStep>().Select(UpdateFailure.StepText).ToList();

        Assert.All(texts, text => Assert.StartsWith("while ", text));
        Assert.Equal(texts.Count, texts.Distinct().Count());
    }

    [Fact]
    public void TheLogLineNamesTheStepAndTheExceptionType()
    {
        using var folder = new TempDirectory();
        var log = new AppLog(folder.Path);

        log.Error(UpdateFailure.ForLog(Version, UpdateStep.Start), new FileNotFoundException(""));

        var line = log.Recent[^1].Message;
        Assert.Contains("The update to 1.2.0 failed while starting the new version", line);
        Assert.Contains("FileNotFoundException", line);
    }
}
