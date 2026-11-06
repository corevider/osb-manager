namespace OsbManager.Core.Updates;

/// <summary>A release build and the names of its assets on the GitHub release.</summary>
public sealed record UpdatePlatform(string Name)
{
    public static readonly UpdatePlatform WindowsX64 = new("windows-x64");
    public static readonly UpdatePlatform MacosArm64 = new("macos-arm64");

    public string ZipName => $"OSB-Manager-{Name}.zip";

    public string ManifestName => $"OSB-Manager-{Name}.update.json";

    public string SignatureName => ManifestName + ".sig";
}
