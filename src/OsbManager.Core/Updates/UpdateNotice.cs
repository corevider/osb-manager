namespace OsbManager.Core.Updates;

/// <summary>
/// Decides when the update notice is shown. Later hides a version for the rest of this run; a newer version or a
/// check the user asked for shows it again. Nothing is installed without Install and restart.
/// </summary>
public sealed class UpdateNotice
{
    private readonly HashSet<UpdateVersion> postponed = [];

    public UpdateOffer? Current { get; private set; }

    public bool Installing { get; private set; }

    public bool Offer(UpdateOffer offer, bool requestedByUser)
    {
        if (Installing || (!requestedByUser && postponed.Contains(offer.Version)))
        {
            return false;
        }
        if (Current is not null && Current.Version > offer.Version)
        {
            return false;
        }
        Current = offer;
        return true;
    }

    public void Later()
    {
        if (Current is not null && !Installing)
        {
            postponed.Add(Current.Version);
            Current = null;
        }
    }

    public UpdateOffer? BeginInstall()
    {
        if (Current is null || Installing)
        {
            return null;
        }
        Installing = true;
        return Current;
    }

    public void InstallFailed()
    {
        Installing = false;
    }
}
