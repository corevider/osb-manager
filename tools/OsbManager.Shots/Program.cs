using System.Globalization;
using OsbManager.Core;
using OsbManager.UI;

namespace OsbManager.Shots;

/// <summary>
/// Renders the OSB Manager main window from a fixture file into PNG screenshots. It uses a new temporary data folder,
/// opens no game window and makes no network request.
/// </summary>
internal static class Program
{
    private const string Usage = "OsbManager.Shots --fixture <fixture.json> --out <folder>";

    [STAThread]
    private static int Main(string[] args)
    {
        if (!TryParse(args, out var fixturePath, out var outDirectory))
        {
            Console.Error.WriteLine(Usage);
            return 2;
        }
        var fixture = ShotFixture.Load(fixturePath);
        var culture = CultureInfo.GetCultureInfo("en-US");
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.CurrentCulture = CultureInfo.CurrentUICulture = culture;
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var scratch = Directory.CreateTempSubdirectory("osb-shots-");
        try
        {
            var paths = new AppPaths(scratch.FullName);
            fixture.WriteData(paths);
            using var services = AppServices.Create(paths, StartupOptions.Parse([]));
            services.Telemetry.Decline();
            foreach (var lines in fixture.Scripts)
            {
                services.Scripts.Install(string.Join('\n', lines) + '\n', null);
            }
            using var form = new MainForm(services, StartupOptions.Parse([]), fixture.Feed(services.Accounts));
            var camera = new ShotCamera(form, fixture);
            camera.Prepare();
            foreach (var path in camera.CaptureAll(outDirectory))
            {
                Console.WriteLine(path);
            }
            form.Hide();
            return 0;
        }
        finally
        {
            scratch.Delete(recursive: true);
        }
    }

    private static bool TryParse(string[] args, out string fixture, out string output)
    {
        fixture = output = "";
        for (var i = 0; i + 1 < args.Length; i += 2)
        {
            switch (args[i])
            {
                case "--fixture":
                    fixture = Path.GetFullPath(args[i + 1]);
                    break;
                case "--out":
                    output = Path.GetFullPath(args[i + 1]);
                    break;
                default:
                    return false;
            }
        }
        return args.Length % 2 == 0 && File.Exists(fixture) && output.Length > 0;
    }
}
