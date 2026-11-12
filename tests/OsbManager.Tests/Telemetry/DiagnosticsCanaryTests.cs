using System.Text;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class DiagnosticsCanaryTests
{
    private static readonly string[] Canaries =
    [
        "CanaryAccountXv", "CanaryPlayerZq", "canary.login.Wb", "CanaryServerQx", "CanaryWinUser", "CANARY-PC", "CANARY-DOMAIN",
        @"C:\Users", @"\Users\", "/Users/", "/home/", "AppData",
    ];

    private static Exception Thrown(string message)
    {
        try
        {
            throw new InvalidOperationException(message, new FileNotFoundException(message + " inner"));
        }
        catch (InvalidOperationException e)
        {
            return e;
        }
    }

    [Fact]
    public async Task DG10_To_DG12_NamesPathsAndIdentityNeverLeaveOnAnyCapturedPath()
    {
        using var dir = new TempDirectory();
        var time = new FakeTimeProvider();
        var names = new[] { "CanaryAccountXv", "canary.login.Wb", "CanaryServerQx" };
        string installKey;
        using (var first = DiagnosticsKit.Granted(root: dir.Path, time: time))
        {
            first.Service.ConfigureDiagnostics(null, () => names);
            first.Service.Capture.Start();
            first.Service.Capture.Learn("CanaryPlayerZq");
            first.Drain();
            first.Service.Capture.Crash(Thrown(@"crash for CanaryAccountXv at C:\Users\CanaryWinUser\AppData\Local\OSB Manager\accounts.json"), "appdomain");
            Assert.NotEmpty(Directory.EnumerateFiles(first.Paths.Diagnostics, "pending-*.json"));
        }
        time.Advance(TimeSpan.FromMinutes(3));

        using var kit = DiagnosticsKit.Granted(root: dir.Path, time: time, grant: false);
        installKey = kit.Store.Credentials!.Key;
        kit.Service.ConfigureDiagnostics(null, () => names);
        kit.Store.StoreConfig(kit.Store.Credentials!.Id, TelemetryConfig.TryParse(Encoding.UTF8.GetBytes(FakeServer.ConfigWithDiagnostics()))!);
        kit.Service.Capture.Start();
        kit.Service.Capture.Learn("CanaryPlayerZq");
        var capture = kit.Service.Capture;
        var context = new DiagnosticContext { Phase = "CanaryAccountXv logged in", LoginStage = "CanaryPlayerZq", Window = 1, Windows = 1 };
        capture.Trail("info", TrailCodes.WindowStart, 1);
        capture.Trail("warn", TrailCodes.LoginFailed("CanaryPlayerZq typed canary.login.Wb"), 1);
        capture.Trail("warn", "resurrection.from.canaryplayerzq", 1);
        capture.Trail("info", @"C:\Users\CanaryWinUser", 1);
        capture.ProcessFailed("RenderProcessExited", "OutOfMemory", 3, @"C:\Users\CanaryWinUser\AppData\Local\OSB Manager\WebView2 CanaryAccountXv", context);
        capture.ProcessFailed("UtilityProcessExited", "CanaryPlayerZq", 4, "CanaryServerQx Service", context);
        capture.Exception(Thrown(@"Cannot read C:\Users\CanaryWinUser\AppData\x.json of CanaryAccountXv (canary.login.Wb) on CANARY-PC for CanaryPlayerZq"), "caught", true, context);
        capture.Exception(Thrown("/home/CanaryWinUser/.config and /Users/CanaryWinUser"), "ui_thread", false, context);
        capture.Unresponsive("gave_up", 90, context);
        capture.GpuFailed("device lost for CanaryPlayerZq on CANARY-PC", 2, context);
        kit.Drain();
        kit.Service.Capture.Exception(new Exception(Thrown("x").Message), "caught", true);
        kit.Drain();

        var preview = kit.Service.PreviewNextDiagnostics();
        await kit.RunFor(TimeSpan.FromMinutes(14), startService: true);

        var everything = new StringBuilder();
        everything.AppendLine(preview);
        foreach (var request in kit.Server.To("POST /v1/diagnostics"))
        {
            everything.AppendLine(request.BodyText);
        }
        everything.AppendLine(kit.EverythingOnDisk());
        everything.AppendLine(string.Join("\n", kit.LogLines));
        var text = everything.ToString();

        Assert.NotNull(preview);
        Assert.NotEmpty(kit.Server.To("POST /v1/diagnostics"));
        foreach (var canary in Canaries.Append(installKey))
        {
            Assert.DoesNotContain(canary, text, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void AProcessDescriptionHoldingAnAccountNameOrAPathIsDroppedAndOnlyKnownDescriptionsAreKept()
    {
        using var kit = DiagnosticsKit.Granted();
        kit.Service.ConfigureDiagnostics(null, () => ["CanaryAccountXv"]);
        kit.Service.Capture.Start();
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 1, "Network Service CanaryAccountXv", DiagnosticsKit.Window());
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 2, @"C:\Users\CanaryWinUser", DiagnosticsKit.Window());
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 3, "Network Service", DiagnosticsKit.Window());
        kit.Drain();

        var events = kit.Service.Diagnostics.Limiter.Peek().Events;

        Assert.Equal(2, events.Count);
        Assert.Null(events[0].Process!.Description);
        Assert.Equal(2, events[0].Count);
        Assert.Equal("network-service", events[1].Process!.Description);
    }
}
