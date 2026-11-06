using System.Security.Cryptography;
using System.Text;
using OsbManager.Core;
using OsbManager.UI;

namespace OsbManager;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        StartupOptions options;
        try
        {
            options = StartupOptions.Parse(args);
        }
        catch (ArgumentException e)
        {
            MessageBox.Show(e.Message + Environment.NewLine + Environment.NewLine + StartupOptions.Usage, AppIdentity.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        if (options.UpdatedFrom is { } previous)
        {
            UpdateRelaunch.AnnounceAndWait(previous);
        }

        var paths = options.DataRoot is { } root ? new AppPaths(root) : AppPaths.Default();
        var lockName = "OsbManager." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(paths.Root.ToUpperInvariant())))[..16];
        using var instance = new Mutex(initiallyOwned: true, lockName, out var firstInstance);
        if (!firstInstance)
        {
            MessageBox.Show($"{AppIdentity.Name} is already running with this data folder.", AppIdentity.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        using var services = AppServices.Create(paths, options);
#if DEBUG
        if (TelemetryTestSwitches.DialogShots is { } shots)
        {
            DialogShots.Run(services, shots);
            return;
        }
#endif
        Application.Run(new MainForm(services, options));
    }
}
