using OsbManager.Core.Status;

namespace OsbManager.Core.Telemetry;

/// <summary>Maps what the page reports to the state names of the platform; the table is in docs/telemetry.md.</summary>
public static class AccountStates
{
    public const string Offline = "offline";
    public const string Login = "login";
    public const string Loading = "loading";
    public const string Idle = "idle";
    public const string Hunting = "hunting";
    public const string Town = "town";
    public const string Dead = "dead";
    public const string Stopped = "stopped";
    public const string Unknown = "unknown";

    public static string Map(BotStatus status)
    {
        if (status.InWorld)
        {
            if (status.Dead)
            {
                return Dead;
            }
            if (status.BotVersion is null)
            {
                return Idle;
            }
            if (status.TownTrip)
            {
                return Town;
            }
            return status.Hunting ? Hunting : Stopped;
        }
        if (status.LoginStage is "title" or "server" or "credentials" or "connecting" or "retry" or "character" or "entering" or "choose" or "failed")
        {
            return Login;
        }
        return status.Phase switch
        {
            null or "world" => Loading,
            "signed-out" or "character-select" => Login,
            _ => Unknown,
        };
    }
}
