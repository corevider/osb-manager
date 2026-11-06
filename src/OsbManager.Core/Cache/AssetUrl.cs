using System.Text.RegularExpressions;

namespace OsbManager.Core.Cache;

/// <summary>Recognises the game's content-hashed pack files, the only URLs the shared cache serves.</summary>
public static partial class AssetUrl
{
    public const string Host = "opensro.online";
    public const string PackFilter = "https://opensro.online/assets/packs/*";
    private const string PackPrefix = "/assets/packs/";

    public static bool TryGetPackName(string? url, out string name)
    {
        name = "";
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || !uri.IsDefaultPort
            || !string.Equals(uri.Host, Host, StringComparison.OrdinalIgnoreCase)
            || uri.Query.Length > 0
            || uri.Fragment.Length > 0
            || !uri.AbsolutePath.StartsWith(PackPrefix, StringComparison.Ordinal))
        {
            return false;
        }
        var candidate = uri.AbsolutePath[PackPrefix.Length..];
        if (!PackName().IsMatch(candidate))
        {
            return false;
        }
        name = candidate;
        return true;
    }

    /// <summary>The first 12 hex digits of the pack's SHA-256, which the game puts in the file name.</summary>
    public static string HashPrefix(string packName) => PackName().Match(packName).Groups[1].Value;

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,100}-([0-9a-f]{12})\\.bin$")]
    private static partial Regex PackName();
}
