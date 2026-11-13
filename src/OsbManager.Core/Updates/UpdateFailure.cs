namespace OsbManager.Core.Updates;

public enum UpdateStep
{
    Download,
    Stage,
    CloseWindows,
    Prepare,
    Swap,
    Start,
}

public static class UpdateFailure
{
    public static string StepText(UpdateStep step) => step switch
    {
        UpdateStep.Download => "while downloading and checking it",
        UpdateStep.Stage => "while unpacking it",
        UpdateStep.CloseWindows => "while closing the game windows",
        UpdateStep.Prepare => "while preparing the restart",
        UpdateStep.Swap => "while replacing the exe",
        UpdateStep.Start => "while starting the new version",
        _ => throw new ArgumentOutOfRangeException(nameof(step)),
    };

    public static string Reason(Exception exception) =>
        string.IsNullOrWhiteSpace(exception.Message) ? $"{exception.GetType().Name} without a message" : exception.Message;

    public static string ForLog(UpdateVersion version, UpdateStep step) => $"The update to {version} failed {StepText(step)}";

    public static string ForUser(UpdateVersion version, UpdateStep step, Exception exception) => $"{ForLog(version, step)}: {Reason(exception)}";
}
