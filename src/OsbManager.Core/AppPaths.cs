namespace OsbManager.Core;

/// <summary>Folders and files the app keeps under one data root.</summary>
public sealed class AppPaths
{
    public AppPaths(string root)
    {
        Root = Path.GetFullPath(root);
        WebViewData = Path.Combine(Root, "WebView2");
        PackCache = Path.Combine(Root, "cache", "packs");
        Scripts = Path.Combine(Root, "scripts");
        Logs = Path.Combine(Root, "logs");
        AccountsFile = Path.Combine(Root, "accounts.json");
        SettingsFile = Path.Combine(Root, "settings.json");
        SoxFile = Path.Combine(Root, "sox.json");
        PrivacyFile = Path.Combine(Root, "privacy.json");
        Outbox = Path.Combine(Root, "outbox");
        OutboxFailed = Path.Combine(Outbox, "failed");
        Updates = Path.Combine(Root, "updates");
    }

    public string Root { get; }
    public string WebViewData { get; }
    public string PackCache { get; }
    public string Scripts { get; }
    public string Logs { get; }
    public string AccountsFile { get; }
    public string SettingsFile { get; }
    public string SoxFile { get; }
    public string PrivacyFile { get; }
    public string Outbox { get; }
    public string OutboxFailed { get; }
    public string Updates { get; }

    public static AppPaths Default() => new(Path.Combine(LocalAppData(), AppIdentity.DataFolderName));

    private static string LocalAppData() => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public void EnsureCreated()
    {
        foreach (var directory in new[] { Root, WebViewData, PackCache, Scripts, Logs })
        {
            Directory.CreateDirectory(directory);
        }
    }
}
