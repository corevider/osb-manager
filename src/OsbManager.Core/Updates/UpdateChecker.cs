using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace OsbManager.Core.Updates;

public enum UpdateCheckStatus
{
    UpToDate,
    Available,
    NotSigned,
    Failed,
}

/// <summary>A newer release whose manifest signature verified.</summary>
public sealed record UpdateOffer(UpdateManifest Manifest, string Tag, string Title, Uri ZipUrl, Uri ReleasePage)
{
    public UpdateVersion Version => Manifest.Version;
}

public sealed record UpdateCheckResult(UpdateCheckStatus Status, string Message, UpdateOffer? Offer = null);

/// <summary>Finds the latest release, verifies its signed manifest and downloads and checks its zip.</summary>
public sealed class UpdateChecker
{
    public const long MaxReleaseJsonBytes = 1024 * 1024;
    public const int MaxTitleLength = 100;
    public static readonly TimeSpan MetadataTimeout = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan DownloadTimeout = TimeSpan.FromMinutes(30);

    private const string JsonType = "application/vnd.github+json";
    private const string BinaryType = "application/octet-stream";

    private readonly UpdateHttp http;
    private readonly UpdatePlatform platform;
    private readonly UpdateVersion current;
    private readonly UpdateSignature signature;

    public UpdateChecker(UpdateHttp http, UpdatePlatform platform, UpdateVersion current, UpdateSignature signature)
    {
        this.http = http;
        this.platform = platform;
        this.current = current;
        this.signature = signature;
    }

    public TimeSpan MetadataLimit { get; init; } = MetadataTimeout;

    public TimeSpan DownloadLimit { get; init; } = DownloadTimeout;

    public async Task<UpdateCheckResult> CheckAsync(CancellationToken cancellation)
    {
        try
        {
            var release = ParseRelease(await http.GetBytesAsync(UpdateSource.LatestReleaseApi, MaxReleaseJsonBytes, MetadataLimit, JsonType, cancellation).ConfigureAwait(false));
            if (!release.Assets.Contains(platform.ManifestName) || !release.Assets.Contains(platform.SignatureName))
            {
                return new UpdateCheckResult(UpdateCheckStatus.NotSigned, $"The latest release {release.Tag} has no signed update for {platform.Name}.");
            }
            var signatureFile = await http.GetBytesAsync(UpdateSource.AssetUrl(release.Tag, platform.SignatureName), UpdateSignature.MaxFileBytes, MetadataLimit, BinaryType, cancellation).ConfigureAwait(false);
            var manifestFile = await http.GetBytesAsync(UpdateSource.AssetUrl(release.Tag, platform.ManifestName), UpdateManifest.MaxBytes, MetadataLimit, BinaryType, cancellation).ConfigureAwait(false);
            if (!signature.Verify(manifestFile, signatureFile))
            {
                return new UpdateCheckResult(UpdateCheckStatus.Failed, $"The update manifest of {release.Tag} does not have a valid signature. Nothing was installed.");
            }
            var manifest = UpdateManifest.Parse(manifestFile, platform);
            if (manifest.Version <= current)
            {
                return new UpdateCheckResult(UpdateCheckStatus.UpToDate, $"OSB Manager {current} is up to date (latest signed release {manifest.Version}).");
            }
            var title = string.IsNullOrEmpty(release.Title) ? $"OSB Manager {manifest.Version}" : release.Title;
            var offer = new UpdateOffer(manifest, release.Tag, title, UpdateSource.AssetUrl(release.Tag, platform.ZipName), UpdateSource.ReleasePage(release.Tag));
            return new UpdateCheckResult(UpdateCheckStatus.Available, $"OSB Manager {manifest.Version} is available.", offer);
        }
        catch (UpdateException e)
        {
            return new UpdateCheckResult(UpdateCheckStatus.Failed, e.Message);
        }
    }

    /// <summary>Downloads the zip into the folder and returns its path once its size and SHA-256 match the signed manifest.</summary>
    public async Task<string> DownloadAsync(UpdateOffer offer, string folder, CancellationToken cancellation)
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, platform.ZipName);
        try
        {
            await using (var file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                await http.DownloadAsync(offer.ZipUrl, file, offer.Manifest.Size, DownloadLimit, BinaryType, cancellation).ConfigureAwait(false);
            }
            Verify(path, offer.Manifest);
            return path;
        }
        catch
        {
            File.Delete(path);
            throw;
        }
    }

    public static void Verify(string path, UpdateManifest manifest)
    {
        using var file = File.OpenRead(path);
        if (file.Length != manifest.Size)
        {
            throw new UpdateException($"The download has {file.Length} bytes, the signed manifest says {manifest.Size}.");
        }
        var hash = Convert.ToHexStringLower(SHA256.HashData(file));
        if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(hash), Encoding.ASCII.GetBytes(manifest.Sha256)))
        {
            throw new UpdateException("The download's SHA-256 does not match the signed manifest.");
        }
    }

    public static string CleanTitle(string? title)
    {
        if (string.IsNullOrWhiteSpace(title))
        {
            return "";
        }
        var builder = new StringBuilder();
        var space = false;
        foreach (var character in title.Trim())
        {
            if (char.IsWhiteSpace(character) || char.IsControl(character))
            {
                space = builder.Length > 0;
                continue;
            }
            if (char.GetUnicodeCategory(character) == UnicodeCategory.Format)
            {
                continue;
            }
            if (space)
            {
                builder.Append(' ');
                space = false;
            }
            builder.Append(character);
        }
        var text = builder.ToString();
        return text.Length <= MaxTitleLength ? text : text[..(MaxTitleLength - 1)].TrimEnd() + "…";
    }

    private static Release ParseRelease(byte[] json)
    {
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 16 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("tag_name", out var tagElement) || tagElement.ValueKind != JsonValueKind.String)
            {
                throw new UpdateException("The release information has no tag.");
            }
            var tag = tagElement.GetString();
            if (!UpdateSource.IsValidTag(tag))
            {
                throw new UpdateException("The release tag is not valid.");
            }
            var title = root.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String ? CleanTitle(name.GetString()) : "";
            var assets = new HashSet<string>(StringComparer.Ordinal);
            if (root.TryGetProperty("assets", out var list) && list.ValueKind == JsonValueKind.Array)
            {
                foreach (var asset in list.EnumerateArray())
                {
                    if (asset.ValueKind == JsonValueKind.Object && asset.TryGetProperty("name", out var assetName) && assetName.ValueKind == JsonValueKind.String)
                    {
                        assets.Add(assetName.GetString()!);
                    }
                }
            }
            return new Release(tag!, title, assets);
        }
        catch (JsonException e)
        {
            throw new UpdateException("The release information is not valid JSON.", e);
        }
    }

    private sealed record Release(string Tag, string Title, IReadOnlySet<string> Assets);
}
