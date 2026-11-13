import Foundation
import Testing
@testable import OsbManagerCore

@Suite(.serialized)
struct DiagnosticsSchedulerTests {
    static func config(enabled: Bool = true, perf: Bool = true, sample: Int = 100, interval: Int = 600) -> Reply {
        .json(200, #"{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true,"screenshots":true},"client_ok":true,"message":null,"diagnostics":{"enabled":\#(enabled),"perf":\#(perf),"interval_s":\#(interval),"perf_interval_s":1800,"sample_pct":\#(sample)}}"#)
    }

    private static func pendingCrash(_ kit: TelemetryKit, name: String = "pending-1800000000-0a0b0c0d.json") throws {
        let event = DiagnosticEvent.make(
            .error(ErrorDetail(type: "Foundation.NSRangeException", origin: "appdomain", handled: false, frames: ["OsbManagerApp.GameManager.launch", "ext"])),
            at: Date(timeIntervalSince1970: TelemetryKit.origin)
        )
        let data = try #require(DiagnosticJson.event(event, terms: PrivateTerms()))
        let folder = kit.directory.file("diagnostics")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }

    private static func gpuEvent() -> DiagnosticEvent {
        DiagnosticEvent.make(.gpu(GpuDetail(code: "device-lost", retries: 1)), at: Date(timeIntervalSince1970: TelemetryKit.origin))
    }

    private func kit(_ reply: Reply = DiagnosticsSchedulerTests.config(), sampleDraw: Int = 0) throws -> TelemetryKit {
        let kit = try TelemetryKit(consent: false, sampleDraw: sampleDraw)
        kit.server.route("GET /v1/config") { _ in reply }
        kit.publish("account-a", hunting())
        return kit
    }

    @Test func usageGoesFirstAndOnlyOneRequestIsInFlight() async throws {
        let kit = try kit()
        try Self.pendingCrash(kit)

        await kit.run(for: .seconds(5 * 60))

        let endpoints = kit.server.requests.map(\.endpoint)
        #expect(Array(endpoints.prefix(4)) == ["GET /v1/config", "POST /v1/installs", "POST /v1/telemetry", "POST /v1/diagnostics"])
        #expect(kit.server.peakInFlight == 1)
        #expect(kit.diagnostics.pending.count == 0)
        let body = try #require(kit.server.to("POST /v1/diagnostics").first?.json)
        #expect(body["app"] as? String == "manager-mac")
        #expect(kit.server.to("POST /v1/diagnostics").first?.authorization.hasPrefix("Bearer ") == true)
        await kit.stop()
    }

    @Test func aTelemetryRequestInFlightMakesDiagnosticsWait() async throws {
        let kit = try kit()
        try Self.pendingCrash(kit)
        kit.server.hang("POST /v1/telemetry")

        await kit.run(for: .seconds(5 * 60))

        let telemetry = try #require(kit.server.to("POST /v1/telemetry").first)
        let diagnostics = try #require(kit.server.to("POST /v1/diagnostics").first)
        #expect(diagnostics.at - telemetry.at >= TelemetryLimits.requestTimeout)
        #expect(kit.server.peakInFlight == 1)
        await kit.stop()
    }

    @Test func diagnosticsFailuresBackOffWithoutMovingTheTelemetrySchedule() async throws {
        let quiet = try kit()
        await quiet.run(for: .seconds(3 * 3600))
        let expected = quiet.server.to("POST /v1/telemetry").count
        await quiet.stop()

        let failing = try kit()
        failing.server.route("POST /v1/diagnostics") { _ in Reply.problem(500, "server_error") }
        try Self.pendingCrash(failing)
        await failing.run(for: .seconds(3 * 3600))

        let attempts = failing.server.to("POST /v1/diagnostics").map(\.at)
        #expect(failing.server.to("POST /v1/telemetry").count == expected)
        #expect(attempts.count >= 3 && attempts.count <= 8)
        let gaps = zip(attempts.dropFirst(), attempts).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= .seconds(60) })
        #expect(gaps == gaps.sorted())
        #expect(failing.diagnostics.pending.count == 1)
        await failing.stop()
    }

    @Test func retryAfterIsHonoured() async throws {
        let kit = try kit()
        kit.server.routeSequence("POST /v1/diagnostics", [Reply.problem(429, "rate_limited", retryAfter: 900)])
        try Self.pendingCrash(kit)

        await kit.run(for: .seconds(30 * 60))

        let attempts = kit.server.to("POST /v1/diagnostics").map(\.at)
        #expect(attempts.count == 2)
        if attempts.count == 2 {
            #expect(attempts[1] - attempts[0] >= .seconds(900))
        }
        #expect(kit.diagnostics.pending.count == 0)
        await kit.stop()
    }

    @Test func withTheServerFlagOffNothingIsRecordedOrSent() async throws {
        let kit = try kit(Self.config(enabled: false))
        try Self.pendingCrash(kit)

        await kit.run(for: .seconds(3 * 3600))

        #expect(!kit.diagnostics.recording)
        #expect(kit.diagnostics.record(Self.gpuEvent()) == nil)
        #expect(kit.server.to("POST /v1/diagnostics").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: kit.directory.file("diagnostics").path))
        #expect(!kit.server.to("POST /v1/telemetry").isEmpty)
        await kit.stop()
    }

    @Test func aMissingDiagnosticsBlockCountsAsOff() async throws {
        let kit = try TelemetryKit(consent: false)
        kit.publish("account-a", hunting())

        await kit.run(for: .seconds(3600))

        #expect(!kit.diagnostics.recording)
        #expect(kit.server.to("POST /v1/diagnostics").isEmpty)
        await kit.stop()
    }

    @Test func aSamplePercentOfZeroRecordsNothing() async throws {
        let kit = try kit(Self.config(sample: 0), sampleDraw: 0)

        await kit.run(for: .seconds(3600))

        #expect(!kit.diagnostics.recording)
        #expect(kit.diagnostics.record(Self.gpuEvent()) == nil)
        #expect(kit.server.to("POST /v1/diagnostics").isEmpty)
        await kit.stop()
    }

    @Test func theFlagGoingOffAtAConfigReadWipesTheBuffers() async throws {
        let kit = try TelemetryKit(consent: false)
        kit.publish("account-a", hunting())
        let enabled = Flag(true)
        kit.server.route("GET /v1/config") { _ in Self.config(enabled: enabled.value) }
        kit.server.hang("POST /v1/diagnostics")
        await kit.run(for: .seconds(5 * 60))
        #expect(kit.diagnostics.recording)
        #expect(kit.diagnostics.record(Self.gpuEvent()) == .added)
        enabled.value = false

        await kit.advance(.seconds(7 * 3600))

        #expect(!kit.diagnostics.recording)
        #expect(kit.diagnostics.limiter.pendingCount == 0)
        #expect(kit.server.to("GET /v1/config").count >= 2)
        await kit.stop()
    }

    @Test func perfIsSentOnlyWhilePerfIsOn() async throws {
        for perfOn in [true, false] {
            let kit = try TelemetryKit(consent: false, sampleWindows: CaptureSamples.fakeProcesses(start: Date(timeIntervalSince1970: TelemetryKit.origin)))
            kit.allowDiagnostics(DiagnosticsConfig(enabled: true, perf: perfOn))
            let capture = try #require(kit.service.capture)
            capture.configure { DiagnosticsConfig(enabled: true, perf: perfOn) }
            capture.start(sampling: false)
            capture.drain()
            let uploader = try #require(kit.service.uploader)
            for _ in 0..<31 {
                capture.sampleOnce()
                await kit.clock.advance(by: .seconds(60)) {}
            }
            _ = kit.diagnostics.record(Self.gpuEvent())

            let body = try #require(uploader.prepare(DiagnosticsConfig(enabled: true, perf: perfOn)))
            let root = try #require(try JSONSerialization.jsonObject(with: body.body) as? [String: Any])
            #expect((root["perf"] != nil) == perfOn)
        }
    }

    @Test func aSecondConsentRequiredStopsDiagnosticsAfterOneConsentUpdate() async throws {
        let kit = try kit()
        kit.server.route("POST /v1/diagnostics") { _ in Reply.problem(403, "consent_required") }
        try Self.pendingCrash(kit)

        await kit.run(for: .seconds(6 * 3600))

        let endpoints = kit.server.requests.map(\.endpoint).filter { $0 == "POST /v1/diagnostics" || $0 == "PUT /v1/installs/me/consent" }
        #expect(endpoints == ["POST /v1/diagnostics", "PUT /v1/installs/me/consent", "POST /v1/diagnostics"])
        #expect(await kit.service.diagnosticsHaveStopped)
        #expect(kit.server.to("POST /v1/telemetry").count > 10)
        await kit.stop()
    }

    @Test func a503DisabledStopsDiagnosticsUntilTheNextConfigRead() async throws {
        let kit = try kit()
        kit.server.route("POST /v1/diagnostics") { _ in Reply.problem(503, "disabled") }
        try Self.pendingCrash(kit)

        await kit.run(for: .seconds(5 * 3600))

        #expect(kit.server.to("POST /v1/diagnostics").count == 1)
        await kit.advance(.seconds(2 * 3600))
        #expect(kit.server.to("POST /v1/diagnostics").count >= 2)
        await kit.stop()
    }

    @Test func switchingOffDuringARequestAbortsItAndDropsItsResult() async throws {
        let kit = try kit()
        kit.server.hang("POST /v1/diagnostics")
        try Self.pendingCrash(kit)
        await kit.run(for: .seconds(125))
        try #require(kit.server.to("POST /v1/diagnostics").count == 1)
        #expect(kit.server.inFlight == 1)
        let before = kit.server.requests.count

        #expect(await kit.service.withdraw() == .deleted)
        await kit.advance(.seconds(6 * 3600))

        #expect(kit.server.inFlight == 0)
        #expect(kit.server.requests.dropFirst(before).map(\.endpoint) == ["DELETE /v1/installs/me"])
        #expect(kit.diagnostics.limiter.pendingCount == 0)
        #expect(!FileManager.default.fileExists(atPath: kit.directory.file("diagnostics").path))
        await kit.stop()
    }

    @Test func threeFaultsSwitchDiagnosticsOffAndUsageKeepsRunning() async throws {
        let kit = try kit()
        await kit.service.injectDiagnosticsFault { throw TelemetryTestError.injected }
        try Self.pendingCrash(kit)

        await kit.run(for: .seconds(6 * 3600))

        #expect(kit.diagnostics.faulted)
        #expect(!kit.diagnostics.recording)
        #expect(kit.server.to("POST /v1/diagnostics").isEmpty)
        #expect(kit.diagnostics.limiter.pendingCount == 0)
        #expect(kit.server.to("POST /v1/telemetry").count > 10)
        #expect(kit.logs.lines.contains { $0.contains("Error reports are switched off") })
        await kit.stop()
    }

    @Test func showWhatIsSentPreviewsTheNextBatchAndSendsNothing() async throws {
        let kit = try kit()
        await kit.run(for: .seconds(5 * 60))
        #expect(kit.diagnostics.record(Self.gpuEvent()) == .added)
        let before = kit.server.requests.count

        let preview = try #require(kit.service.previewNextDiagnostics())
        let prepared = try #require(kit.service.uploader?.prepare(kit.service.currentDiagnostics()))

        #expect(kit.server.requests.count == before)
        let shown = try #require(try JSONSerialization.jsonObject(with: Data(preview.utf8)) as? NSDictionary)
        let sent = try #require(try JSONSerialization.jsonObject(with: prepared.body) as? NSDictionary)
        #expect(shown == sent)
        #expect(preview.contains("\"gpu_failed\""))
        let text = try #require(PreviewText.compose(usage: "{}", diagnostics: preview, texts: .english))
        #expect(text.hasPrefix("Usage statistics, next batch\n{}\n\nError reports and performance data, next batch\n"))
        _ = await kit.service.withdraw()
        #expect(kit.service.previewNextDiagnostics() == nil)
        await kit.stop()
    }
}
