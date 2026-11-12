using System.Text.Json.Nodes;
using OsbManager.Core.Telemetry;
using OsbManager.Core.Telemetry.Diagnostics;

namespace OsbManager.Tests.Telemetry;

public class WireTimeTests
{
    private static TelemetryKit RunningAhead(out FakeTimeProvider wire)
    {
        wire = new FakeTimeProvider();
        var scaled = new FakeTimeProvider(wire.GetUtcNow().AddHours(10));
        var kit = DiagnosticsKit.Granted(time: scaled, wireTime: wire);
        kit.Store.StoreConfig(kit.Store.State.InstallId!, TelemetryConfig.TryParse(System.Text.Encoding.UTF8.GetBytes(FakeServer.ConfigWithDiagnostics()))!);
        return kit;
    }

    [Fact]
    public void T13_EventTimesAndTheBatchWindowFollowTheWireClockWhileTheSchedulerClockRunsAhead()
    {
        using var kit = RunningAhead(out var wire);
        kit.Service.Capture.ProcessFailed("RenderProcessExited", "Crashed", 1, null, DiagnosticsKit.Window());
        kit.Drain();

        var body = JsonNode.Parse(kit.Service.PreviewNextDiagnostics()!)!;

        var at = Assert.Single(body["events"]!.AsArray())!["at"]!.GetValue<string>();
        Assert.Equal(DiagnosticFormats.MinuteText(wire.GetUtcNow()), at);
    }

    [Fact]
    public void T13_ThePerfRotationPresenceWindowFollowsTheWireClock()
    {
        using var kit = RunningAhead(out var wire);
        kit.Service.PageBatches.Rotation.Present(1, wire.GetUtcNow());

        kit.Service.TickOsbPerf();

        Assert.NotEqual(0, kit.Service.PageBatches.Rotation.Wanted(1, wire.GetUtcNow()));
    }

    [Fact]
    public void T13_TheRunMarkerStampsTheWireClock()
    {
        using var kit = RunningAhead(out var wire);
        kit.Service.Capture.Start();
        kit.Drain();

        var marker = JsonNode.Parse(File.ReadAllText(kit.Marker()))!;

        Assert.Equal(DiagnosticFormats.MinuteText(wire.GetUtcNow()), marker["alive"]!.GetValue<string>());
    }
}
