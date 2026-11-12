using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager;

internal static class CrashHooks
{
    public static void Install(AppServices services)
    {
        var capture = services.Telemetry.Capture;
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception exception)
            {
                capture.Crash(exception, "appdomain");
            }
        };
        Application.ThreadException += (_, e) => OnThreadException(capture, e.Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => capture.Exception(e.Exception, "task", handled: false);
        Application.ApplicationExit += (_, _) => capture.Stop();
    }

    private static void OnThreadException(DiagnosticsCapture capture, Exception exception)
    {
        capture.Exception(exception, "ui_thread", handled: false);
        using var dialog = new ThreadExceptionDialog(exception);
        if (dialog.ShowDialog() == DialogResult.Abort)
        {
            capture.Crash(exception, "ui_thread");
            Application.Exit();
            Environment.Exit(0);
        }
    }
}
