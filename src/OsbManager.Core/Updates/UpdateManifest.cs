using System.Text.Json;
using System.Text.RegularExpressions;

namespace OsbManager.Core.Updates;

/// <summary>The signed description of one platform's release zip.</summary>
public sealed partial record UpdateManifest(UpdateVersion Version, string Platform, string Asset, long Size, string Sha256)
{
    public const int Format = 1;
    public const string Product = "osb-manager";
    public const int MaxBytes = 4096;
    public const long MaxAssetBytes = 512L * 1024 * 1024;

    private static readonly HashSet<string> Fields = ["format", "product", "platform", "version", "asset", "size", "sha256"];

    /// <summary>Reads a manifest whose signature has already been verified, and checks it is for this platform.</summary>
    public static UpdateManifest Parse(ReadOnlySpan<byte> json, UpdatePlatform platform)
    {
        if (json.Length > MaxBytes)
        {
            throw new UpdateException("The update manifest is too large.");
        }
        try
        {
            using var document = JsonDocument.Parse(json.ToArray(), new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new UpdateException("The update manifest is not an object.");
            }
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in root.EnumerateObject())
            {
                if (!Fields.Contains(property.Name) || !seen.Add(property.Name))
                {
                    throw new UpdateException($"The update manifest has an unexpected field {property.Name}.");
                }
            }
            if (seen.Count != Fields.Count)
            {
                throw new UpdateException("The update manifest is missing a field.");
            }
            if (root.GetProperty("format").ValueKind != JsonValueKind.Number || !root.GetProperty("format").TryGetInt32(out var format) || format != Format)
            {
                throw new UpdateException("The update manifest has an unknown format.");
            }
            if (Text(root, "product") != Product)
            {
                throw new UpdateException("The update manifest is for another product.");
            }
            if (Text(root, "platform") != platform.Name)
            {
                throw new UpdateException("The update manifest is for another platform.");
            }
            if (!UpdateVersion.TryParse(Text(root, "version"), out var version))
            {
                throw new UpdateException("The update manifest has a malformed version.");
            }
            if (Text(root, "asset") != platform.ZipName)
            {
                throw new UpdateException("The update manifest names another file.");
            }
            var sizeElement = root.GetProperty("size");
            if (sizeElement.ValueKind != JsonValueKind.Number || !sizeElement.TryGetInt64(out var size) || size <= 0 || size > MaxAssetBytes)
            {
                throw new UpdateException("The update manifest has a size out of range.");
            }
            var sha256 = Text(root, "sha256");
            if (!HexPattern().IsMatch(sha256))
            {
                throw new UpdateException("The update manifest has a malformed SHA-256.");
            }
            return new UpdateManifest(version, platform.Name, platform.ZipName, size, sha256);
        }
        catch (JsonException e)
        {
            throw new UpdateException("The update manifest is not valid JSON.", e);
        }
    }

    private static string Text(JsonElement root, string name)
    {
        var element = root.GetProperty(name);
        return element.ValueKind == JsonValueKind.String ? element.GetString() ?? "" : throw new UpdateException($"The update manifest field {name} is not text.");
    }

    [GeneratedRegex(@"\A[0-9a-f]{64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex HexPattern();
}
