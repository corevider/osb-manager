#if DEBUG
using System.Drawing.Imaging;
using System.Globalization;
using OsbManager.Core.Status;
using OsbManager.Core.Telemetry;

namespace OsbManager.UI;

internal static class DialogShots
{
    public static void Run(AppServices services, string directory)
    {
        Directory.CreateDirectory(directory);
        var texts = PrivacyTexts.English;
        Capture(new MainForm(services, StartupOptions.Parse([])), Path.Combine(directory, "first-run.png"));

        services.Telemetry.WithdrawAsync().GetAwaiter().GetResult();
        Capture(new PrivacyForm(services.Telemetry, texts), Path.Combine(directory, "privacy-off.png"));

        services.Telemetry.Accept(characters: true);
        services.Telemetry.Statuses.Publish("sample-a", "ExampleServer", Sample("ExampleHero"), services.Time.GetUtcNow());
        services.Telemetry.Statuses.Publish("sample-b", "ExampleServer", Sample("ExampleMage") with { Hunting = false, TownTrip = true, Level = 64 }, services.Time.GetUtcNow());
        var privacy = new PrivacyForm(services.Telemetry, texts);
        privacy.ExpandPreview();
        Capture(privacy, Path.Combine(directory, "privacy-on.png"));
        services.Telemetry.WithdrawAsync().GetAwaiter().GetResult();

        var diagnostics = ReportDiagnostics.Build(
            AppServices.AppVersion, Environment.OSVersion.Version.ToString(), System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
            [WindowDiagnostics.From(Sample("x"), false), WindowDiagnostics.From(new BotStatus { Phase = "signed-out", LoginStage = "server", LoginMessage = "waiting for the server list" }, true)],
            [new ScriptDiagnostics("OSB", "2.0.4")]);
        var report = new ReportForm(services.Telemetry, texts, AppServices.AppVersion, CultureInfo.CurrentUICulture.TwoLetterISOLanguageName, diagnostics, []);
        report.SetDescription("The bot stops after the town trip.");
        report.SetScreenshotForPreview(SamplePicture());
        Capture(report, Path.Combine(directory, "report.png"));
    }

    private static BotStatus Sample(string character) => new()
    {
        BotVersion = "2.0.4", Phase = "world", Character = character, InWorld = true, Level = 87, Gold = 123456789,
        HpPercent = 92, MpPercent = 70, Hunting = true, ReturnScrolls = 12, ReverseScrolls = 3,
        Session = new SessionStats(5_400_000, 812, 1, 48211933, 2210450, 0),
    };

    private static byte[] SamplePicture()
    {
        using var bitmap = new Bitmap(1280, 720);
        using (var graphics = Graphics.FromImage(bitmap))
        using (var brush = new System.Drawing.Drawing2D.LinearGradientBrush(new Rectangle(0, 0, 1280, 720), Color.FromArgb(30, 40, 70), Color.FromArgb(160, 110, 50), 45f))
        {
            graphics.FillRectangle(brush, 0, 0, 1280, 720);
            using var font = new Font("Segoe UI", 40);
            graphics.DrawString("sample game window", font, Brushes.White, 380, 320);
        }
        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);

    private static void Capture(Form form, string path)
    {
        form.StartPosition = FormStartPosition.Manual;
        form.Location = new Point(80, 40);
        form.ShowInTaskbar = false;
        form.Show();
        for (var i = 0; i < 20; i++)
        {
            Application.DoEvents();
            Thread.Sleep(40);
        }
        using var bitmap = new Bitmap(form.Width, form.Height);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            var context = graphics.GetHdc();
            try
            {
                PrintWindow(form.Handle, context, 2);
            }
            finally
            {
                graphics.ReleaseHdc(context);
            }
        }
        bitmap.Save(path, ImageFormat.Png);
        form.Close();
        form.Dispose();
    }
}
#endif
