namespace OsbManager.UI;

internal static class AppIcon
{
    public static Icon Instance { get; } = Load();

    private static Icon Load()
    {
        using var stream = typeof(AppIcon).Assembly.GetManifestResourceStream("OsbManager.app.ico")
            ?? throw new InvalidOperationException("The app icon is missing from the build.");
        return new Icon(stream);
    }
}
