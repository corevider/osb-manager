using System.Text.RegularExpressions;

namespace OsbManager.Core.Updates;

/// <summary>Where releases are published. Asset addresses are built from the tag, never taken from the API answer.</summary>
public static partial class UpdateSource
{
    public const string Repository = "corevider/osb-manager";

    public static readonly Uri LatestReleaseApi = new($"https://api.github.com/repos/{Repository}/releases/latest");

    public static readonly Uri LatestReleasePage = new($"https://github.com/{Repository}/releases/latest");

    public static bool IsValidTag(string? tag) => tag is not null && TagPattern().IsMatch(tag);

    public static Uri AssetUrl(string tag, string assetName) =>
        IsValidTag(tag) ? new Uri($"https://github.com/{Repository}/releases/download/{tag}/{assetName}") : throw new ArgumentException("The release tag is not valid.", nameof(tag));

    public static Uri ReleasePage(string tag) =>
        IsValidTag(tag) ? new Uri($"https://github.com/{Repository}/releases/tag/{tag}") : LatestReleasePage;

    [GeneratedRegex(@"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z", RegexOptions.CultureInvariant)]
    private static partial Regex TagPattern();
}
