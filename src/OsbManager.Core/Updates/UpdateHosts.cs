namespace OsbManager.Core.Updates;

/// <summary>
/// The only hosts the updater talks to, for the first request and for every redirect. Only HTTPS on the default port,
/// without user information, is allowed.
/// </summary>
public sealed class UpdateHosts
{
    public static readonly UpdateHosts GitHub = new(
    [
        "api.github.com",
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
    ]);

    private readonly HashSet<string> hosts;

    public UpdateHosts(IEnumerable<string> hosts)
    {
        this.hosts = new HashSet<string>(hosts, StringComparer.OrdinalIgnoreCase);
    }

    public IReadOnlyCollection<string> Names => hosts;

    public bool Allows(Uri url) =>
        url.IsAbsoluteUri
        && url.Scheme == Uri.UriSchemeHttps
        && url.IsDefaultPort
        && url.UserInfo.Length == 0
        && hosts.Contains(url.IdnHost);
}
