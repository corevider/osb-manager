namespace OsbManager.Core.Scripts;

public enum FirstInstallOutcome
{
    NotDue,
    Skipped,
    Installed,
    Failed,
}

public sealed record FirstInstallResult(FirstInstallOutcome Outcome, InstalledScript? Script = null, Exception? Error = null);

public static class OsbFirstInstall
{
    public static async Task<FirstInstallResult> RunAsync(ScriptStore scripts, HttpClient http, AppSettings settings, string osbUrl, bool allowLoopbackHttp = false, CancellationToken cancellation = default)
    {
        if (settings.OsbFirstInstall != OsbFirstInstallState.Pending)
        {
            return new FirstInstallResult(FirstInstallOutcome.NotDue);
        }
        if (scripts.Scripts.Any(script => BotScripts.IsOsb(script) || BotScripts.IsNixxane(script)))
        {
            Finish(settings, OsbFirstInstallState.Skipped);
            return new FirstInstallResult(FirstInstallOutcome.Skipped);
        }
        try
        {
            var osb = await scripts.InstallFromUrlAsync(osbUrl, http, cancellation, allowLoopbackHttp);
            Finish(settings, OsbFirstInstallState.Done);
            return new FirstInstallResult(FirstInstallOutcome.Installed, osb);
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellation.IsCancellationRequested)
        {
            return new FirstInstallResult(FirstInstallOutcome.Failed, Error: error);
        }
    }

    private static void Finish(AppSettings settings, OsbFirstInstallState state)
    {
        settings.OsbFirstInstall = state;
        settings.Save();
    }
}
