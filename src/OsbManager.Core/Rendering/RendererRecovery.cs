using OsbManager.Core.Status;

namespace OsbManager.Core.Rendering;

public enum RendererStep
{
    None,
    Reload,
    Restart,
    GiveUp,
}

/// <summary>
/// One account's way back when the game's renderer cannot start even after the page's own retries: reload the page
/// once, then restart the window once (when the setting allows it), then stop and ask the player. Reaching the game
/// world again proves the renderer works and starts the ladder over.
/// </summary>
public sealed class RendererRecovery
{
    public bool Reloaded { get; private set; }
    public bool Restarted { get; private set; }
    public bool GaveUp { get; private set; }

    /// <summary>What to do after a new report from the page; acts once, when the renderer failure first shows.</summary>
    public RendererStep Observe(BotStatus? previous, BotStatus report, bool restartAllowed)
    {
        if (report.InWorld)
        {
            Reloaded = Restarted = GaveUp = false;
            return RendererStep.None;
        }
        if (report.GpuFailed is null || previous?.GpuFailed is not null)
        {
            return RendererStep.None;
        }
        if (!Reloaded)
        {
            Reloaded = true;
            return RendererStep.Reload;
        }
        if (!Restarted && restartAllowed)
        {
            Restarted = true;
            return RendererStep.Restart;
        }
        GaveUp = true;
        return RendererStep.GiveUp;
    }

    /// <summary>The Status tab text while the renderer is being recovered, or null to show the normal state.</summary>
    public string? StateText(BotStatus? status, bool waitingForSlot, string normal)
    {
        if (status is { GpuFailed: not null })
        {
            return GaveUp ? RendererTexts.GaveUpState : RendererTexts.RecoveringState;
        }
        if (status is { GpuRetryIn: > 0 })
        {
            return RendererTexts.RetryingState(status.GpuRetryIn);
        }
        if (waitingForSlot)
        {
            return RendererTexts.WaitingState;
        }
        if (status?.InWorld == true)
        {
            return null;
        }
        if (Restarted)
        {
            return $"{RendererTexts.RestartedState} ({normal})";
        }
        return Reloaded ? $"{RendererTexts.ReloadedState} ({normal})" : null;
    }
}

/// <summary>The renderer recovery's texts for the Status tab and the log.</summary>
public static class RendererTexts
{
    public const string RecoveringState = "Renderer failed, recovering";
    public const string GaveUpState = "Renderer failed, use Reload";
    public const string WaitingState = "Waiting for another window's renderer";
    public const string RestartedState = "Restarted after renderer failure";
    public const string ReloadedState = "Reloaded after renderer failure";

    public static string RetryingState(int seconds) => $"Renderer failed, retrying in {seconds} s";

    public static string Retrying(string account, int retries, int limit, int seconds) =>
        $"{account}: the graphics card was full when the game started its renderer; trying again in {seconds} s ({retries} of {(limit > 0 ? limit : retries)}).";

    public static string Failed(string account, string reason) => $"{account}: the game's renderer could not start ({reason}).";

    public static string Step(string account, RendererStep step, bool restarted) => step switch
    {
        RendererStep.Reload => $"{account}: reloading the game page to start the renderer again.",
        RendererStep.Restart => $"{account}: restarting the game window with the same profile and saved login to start the renderer again.",
        RendererStep.GiveUp => $"{account}: the renderer still could not start after a reload{(restarted ? " and a window restart" : "; automatic window restart is off")}. Close a game window or wait until the others have loaded, then use Reload.",
        _ => "",
    };
}
