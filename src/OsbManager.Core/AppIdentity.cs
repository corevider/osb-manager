namespace OsbManager.Core;

/// <summary>Names the app goes by on this PC.</summary>
public static class AppIdentity
{
    public const string Name = "OSB Manager";
    public const string DataFolderName = "OSB Manager";
    public const string InstallFolderName = "OSB Manager";

    public static string UserAgent(string version) => $"OSBManager/{version} (Windows)";
}
