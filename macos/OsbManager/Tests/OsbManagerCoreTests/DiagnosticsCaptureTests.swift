import CrashSignals
import Foundation
import Testing
@testable import OsbManagerCore

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var date: Date { lock.withLock { current } }

    var now: @Sendable () -> Date { { [self] in date } }

    func set(_ date: Date) {
        lock.withLock { current = date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

enum CaptureSamples {
    static let env = DiagnosticEnv(osBuild: "26.5.0", webview2: "156.0.8078.80", ramGb: 16, cores: 8, gpuVendor: "apple")
    static let on = DiagnosticsConfig(enabled: true, perf: true)

    static func at(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    static func terms() -> PrivateTerms {
        let terms = PrivateTerms.forMachine(.canary, dataFolder: "/Users/canaryuserkt/Library/Application Support/OSB Manager")
        terms.add(accounts: [Account(id: "a1", name: "CanaryAccountXv", loginId: "canary.login.mq", server: "CanaryServerWs", character: "CanaryCharJp")])
        terms.add("CanaryPlayerZq")
        return terms
    }

    static func hub(_ folder: URL, _ clock: TestClock, run: String = DiagnosticFormats.newRunKey(), terms: PrivateTerms = terms(), consent: Bool = true, allow: Bool = true) -> DiagnosticsHub {
        let hub = DiagnosticsHub(folder: folder, terms: terms, now: clock.now, sampleDraw: 0, run: run, consentOn: { consent })
        if allow { hub.applyServer(on) }
        return hub
    }

    static func capture(_ hub: DiagnosticsHub, version: String, vocabulary: OsbVocabulary? = nil, sampleWindows: (@Sendable ([PerfWindowInfo], Date) -> PerfSample)? = nil) -> DiagnosticsCapture {
        let capture = DiagnosticsCapture(hub: hub, appVersion: version, useSignals: false, vocabulary: vocabulary, sampleWindows: sampleWindows ?? { _, at in PerfSample(at: at, app: nil, helpers: [], windows: PerfWindows(open: 0, light: 0, hidden: 0, inWorld: 0)) })
        capture.start(sampling: false)
        capture.drain()
        return capture
    }

    static func fakeProcesses(start: Date) -> @Sendable ([PerfWindowInfo], Date) -> PerfSample {
        { _, at in
            let t = at.timeIntervalSince(start)
            let megabyte = 1024.0 * 1024.0
            return PerfSample(
                at: at,
                app: ProcessReading(pid: 100, role: .app, footprintBytes: 210 * megabyte, cpuSeconds: t * 0.031),
                helpers: [
                    ProcessReading(pid: 201, role: .renderer, footprintBytes: 655 * megabyte, cpuSeconds: t * 0.302),
                    ProcessReading(pid: 202, role: .renderer, footprintBytes: 380 * megabyte, cpuSeconds: t * 0.115),
                    ProcessReading(pid: 203, role: .renderer, footprintBytes: 410 * megabyte, cpuSeconds: t * 0.14),
                    ProcessReading(pid: 300, role: .gpu, footprintBytes: 290 * megabyte, cpuSeconds: t * 0.098),
                    ProcessReading(pid: 400, role: .utility, footprintBytes: 140 * megabyte, cpuSeconds: t * 0.01),
                ],
                windows: PerfWindows(open: 3, light: 1, hidden: 0, inWorld: 3)
            )
        }
    }

    static func endToEndBody() throws -> String {
        let directory = TemporaryDirectory()
        let folder = directory.file("diagnostics")
        let clock = TestClock(at("2026-11-12T11:00:00Z"))
        let terms = terms()

        let previousHub = hub(folder, clock, run: "aaaaaaaaaaaaaaaa", terms: terms)
        let previous = capture(previousHub, version: "1.0.9")
        clock.set(at("2026-11-12T14:00:00Z"))
        previous.marker.touch()
        previous.crash(exceptionName: "NSInvalidArgumentException", frames: [
            "OsbManagerApp.GameWindowController.gameBrowser", "OsbManagerCef.CefGameBrowser.cefBrowser.<closure>", "ext",
        ])
        try Data([UInt8(SIGABRT)]).write(to: previous.marker.signalFile)

        clock.set(at("2026-11-12T14:05:00Z"))
        let current = hub(folder, clock, run: "5d1c0e7a9b3f2c48", terms: terms)
        let capture = capture(current, version: "1.1.0", vocabulary: try OsbSamples.vocabulary(), sampleWindows: fakeProcesses(start: at("2026-11-12T14:06:00Z")))
        capture.configure { CaptureSamples.on }
        capture.requestPageMemory = { [perf = capture.perf] in perf.setPageMemory(used: [131, 118, 166], total: [160, 150, 210]) }
        clock.set(at("2026-11-12T14:06:00Z"))
        for _ in 0..<31 {
            capture.sampleOnce()
            clock.advance(60)
        }

        clock.set(at("2026-11-12T14:38:00Z"))
        capture.trail("info", TrailCodes.windowStart, window: 2)
        clock.set(at("2026-11-12T14:39:25Z"))
        capture.trail("warn", TrailCodes.gpuRetry, window: 2)
        capture.trail("warn", TrailCodes.gpuRetry, window: 2)
        clock.set(at("2026-11-12T14:41:00Z"))
        capture.processFailed(status: 2, errorCode: 11, context: DiagnosticContext(phase: "world", loginStage: "done", window: 2, windows: 3, light: false, hidden: false))
        capture.trail("error", TrailCodes.windowRendererExited, window: 2)
        capture.drain()
        clock.set(at("2026-11-12T14:42:00Z"))
        capture.unresponsive(outcome: "reloaded", waitedSeconds: 75, context: DiagnosticContext(phase: "world", window: 1, windows: 3))
        capture.drain()
        clock.set(at("2026-11-12T14:43:00Z"))
        capture.gpuFailed("GPUDevice was lost", retries: 3, context: nil)
        capture.gpuFailed("GPUDevice was lost", retries: 3, context: nil)
        capture.drain()
        clock.set(at("2026-11-12T14:44:00Z"))
        for _ in 0..<3 {
            capture.caught(ScriptFormatError("CanaryAccountXv /Users/canaryuserkt/x.json"), frames: ["OsbManagerCore.ScriptStore.install", "ext"], context: nil)
        }
        capture.drain()
        clock.set(at("2026-11-12T14:45:00Z"))
        capture.pageBatches.offer(OsbSamples.message([OsbSamples.errorEvent(clock.date)]), window: 2)
        capture.pageBatches.rotation.present(2, at: clock.date)
        capture.tickOsbPerf()
        capture.pageBatches.offerPerf(OsbSamples.perfAnswer(at("2026-11-12T14:15:00Z")), window: 2, osbVersion: OsbSamples.osbVersion)
        capture.pageBatches.drain()

        clock.set(at("2026-11-12T14:50:00Z"))
        let uploader = DiagnosticsUploader(hub: current, perf: capture.perf, appVersion: "1.1.0", env: { CaptureSamples.env })
        let prepared = try #require(uploader.prepare(on))
        return String(decoding: prepared.body, as: UTF8.self) + "\n"
    }
}

@Suite(.serialized)
struct DiagnosticsCaptureTests {
    @Test func goldenManagerMacBatchIsBuiltEndToEndFromCapturedEvents() throws {
        let text = try CaptureSamples.endToEndBody()
        if let target = ProcessInfo.processInfo.environment["OSB_WRITE_GOLDEN"] {
            try text.write(toFile: target, atomically: true, encoding: .utf8)
        }
        let fixture = try String(contentsOf: DiagnosticsSamples.goldenFile, encoding: .utf8)

        #expect(text == fixture)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let events = try #require(root["events"] as? [[String: Any]])
        #expect(events.map { $0["kind"] as? String } == ["dotnet_exception", "run_end", "process_failed", "unresponsive", "gpu_failed", "dotnet_exception", "js_error"])
        #expect(events.map { $0["source"] as? String } == ["manager", "manager", "manager", "manager", "manager", "manager", "osb"])
        #expect((events[6]["context"] as? [String: Any])?["window"] as? Int == 2)
        #expect((events[6]["error"] as? [String: Any])?["template"] as? String == OsbSamples.template)
        let osbPerf = try #require(root["osb_perf"] as? [[String: Any]])
        #expect(osbPerf.count == 1)
        #expect(osbPerf[0]["app_version"] as? String == OsbSamples.osbVersion)
        #expect((events[0]["error"] as? [String: Any])?["type"] as? String == "Foundation.NSInvalidArgumentException")
        #expect((events[1]["run_end"] as? [String: Any])?["signal"] as? String == "sigabrt")
        #expect((events[5]["error"] as? [String: Any])?["type"] as? String == "OsbManagerCore.ScriptFormatError")
        #expect(events[5]["count"] as? Int == 3)
        #expect(events[4]["count"] as? Int == 2)
        #expect(root["perf"] != nil)
        for canary in ["canary", "Canary", "/Users/"] {
            #expect(!text.contains(canary))
        }
    }

    @Test func anUncleanEndIsFoundByTheRunMarker() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let first = CaptureSamples.capture(CaptureSamples.hub(folder, clock), version: "1.0.9")
        clock.advance(3600)
        first.sampleOnce()

        clock.advance(600)
        let next = CaptureSamples.hub(folder, clock)
        _ = CaptureSamples.capture(next, version: "1.1.0")

        let runEnd = try #require(next.pendingEvents().compactMap { file -> RunEndDetail? in
            if case .runEnd(let detail) = file.event.detail { return detail }
            return nil
        }.first)
        #expect(runEnd == RunEndDetail(outcome: "unclean", uptimeSeconds: 3600, previousVersion: "1.0.9"))
    }

    @Test func aCleanQuitGivesClean() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let first = CaptureSamples.capture(CaptureSamples.hub(folder, clock), version: "1.0.9")
        clock.advance(120)
        first.finish()

        let next = CaptureSamples.hub(folder, clock)
        _ = CaptureSamples.capture(next, version: "1.1.0")

        let outcomes = next.pendingEvents().compactMap { file -> String? in
            if case .runEnd(let detail) = file.event.detail { return detail.outcome }
            return nil
        }
        #expect(outcomes == ["clean"])
    }

    @Test(arguments: [(SIGSEGV, "sigsegv"), (SIGTRAP, "sigtrap"), (SIGILL, "sigill"), (SIGBUS, "sigbus"), (SIGFPE, "sigfpe"), (SIGABRT, "sigabrt")])
    func aSignalByteIsReadAsACrashWithItsSignal(number: Int32, name: String) throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let first = CaptureSamples.capture(CaptureSamples.hub(folder, clock), version: "1.0.9")
        try Data([UInt8(number)]).write(to: first.marker.signalFile)

        let marker = RunMarker(folder: folder, now: clock.now, recording: { true })
        let previous = try #require(marker.readPrevious())

        #expect(previous.outcome == "crash")
        #expect(previous.detail.signal == name)
    }

    @Test func anUnknownSignalByteIsACrashWithoutASignal() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let first = CaptureSamples.capture(CaptureSamples.hub(folder, clock), version: "1.0.9")
        try Data("1".utf8).write(to: first.marker.signalFile)

        let previous = try #require(RunMarker(folder: folder, now: clock.now, recording: { true }).readPrevious())

        #expect(previous.outcome == "crash")
        #expect(previous.detail.signal == nil)
    }

    @Test func theRealSignalFileIsOpenedAndRemovedOnACleanQuit() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock)
        let marker = RunMarker(folder: folder, now: clock.now, recording: { hub.recording }, useSignals: true)

        #expect(marker.begin(version: "1.1.0"))
        #expect(FileManager.default.fileExists(atPath: marker.signalFile.path))
        #expect(crash_signals_descriptor() >= 0)

        marker.clean()

        #expect(crash_signals_descriptor() == -1)
        #expect(!FileManager.default.fileExists(atPath: marker.signalFile.path))
        crash_signals_uninstall()
    }

    @Test func aCrashIsWrittenAsAPendingFileAndSentAtTheNextStart() async throws {
        let first = try TelemetryKit(consent: false)
        first.allowDiagnostics()
        let capture = try #require(first.service.capture)
        capture.start(sampling: false)
        capture.drain()
        #expect(capture.marker.isWritten)
        CrashHandlers.install(capture)
        CrashHandlers.handle(NSException(name: .invalidArgumentException, reason: "CanaryAccountXv /Users/canaryuserkt/x", userInfo: ["k": "CanaryAccountXv"]))
        #expect(first.diagnostics.pending.count == 1)
        let marker = try String(contentsOf: capture.marker.file, encoding: .utf8)
        #expect(marker.contains("\"crashed\":true"))

        let next = try TelemetryKit(keyStore: first.keys, directory: first.directory)
        next.server.route("GET /v1/config") { _ in DiagnosticsSchedulerTests.config() }
        await next.run(for: .seconds(20 * 60))

        let bodies = next.server.to("POST /v1/diagnostics").map(\.bodyText)
        let all = bodies.joined()
        #expect(all.contains("\"type\":\"Foundation.NSInvalidArgumentException\""))
        #expect(all.contains("\"origin\":\"appdomain\""))
        #expect(all.contains("\"outcome\":\"crash\""))
        #expect(!all.contains("Canary") && !all.contains("canary"))
        #expect(next.diagnostics.pending.count == 0)
        await next.stop()
    }

    @Test func withConsentOffAtTheNextStartTheMarkerAndFilesAreDeletedUnread() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let first = CaptureSamples.capture(CaptureSamples.hub(folder, clock), version: "1.0.9")
        first.crash(exceptionName: "NSRangeException", frames: ["ext"])
        try Data([UInt8(SIGABRT)]).write(to: first.marker.signalFile)
        #expect(FileManager.default.fileExists(atPath: first.marker.file.path))

        _ = CaptureSamples.hub(folder, clock, consent: false)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func withoutTheServerFlagNoMarkerIsWrittenAndNothingIsCaptured() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock, allow: false)
        let capture = CaptureSamples.capture(hub, version: "1.1.0")

        capture.sampleOnce()
        capture.processFailed(status: 2, errorCode: 11, context: nil)
        capture.caught(ScriptFormatError("x"), context: nil)
        capture.crash(exceptionName: "NSRangeException", returnAddresses: Thread.callStackReturnAddresses)
        capture.trail("info", TrailCodes.windowStart)
        capture.drain()

        #expect(!hub.recording)
        #expect(hub.limiter.pendingCount == 0)
        #expect(hub.trail.count == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func theServerFlagGoingOffWipesBuffersMarkerAndFiles() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock)
        let capture = CaptureSamples.capture(hub, version: "1.1.0")
        capture.processFailed(status: 2, errorCode: 11, context: nil)
        capture.crash(exceptionName: "NSRangeException", frames: ["ext"])
        capture.drain()
        #expect(hub.limiter.pendingCount == 1)

        hub.applyServer(DiagnosticsConfig(enabled: false, perf: false))

        #expect(!hub.recording)
        #expect(hub.limiter.pendingCount == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aSampleDrawOutsideSamplePercentRecordsNothing() {
        let folder = TemporaryDirectory().file("diagnostics")
        let hub = DiagnosticsHub(folder: folder, terms: PrivateTerms(), sampleDraw: 50, consentOn: { true })

        hub.applyServer(DiagnosticsConfig(enabled: true, perf: true, samplePercent: 0))
        #expect(!hub.recording)
        hub.applyServer(DiagnosticsConfig(enabled: true, perf: true, samplePercent: 50))
        #expect(!hub.recording)
        hub.applyServer(DiagnosticsConfig(enabled: true, perf: true, samplePercent: 51))
        #expect(hub.recording)
    }

    @Test func caughtErrorsFromTheLogBecomeCaughtEvents() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock)
        let capture = CaptureSamples.capture(hub, version: "1.1.0")
        let log = AppLog(directory: TemporaryDirectory().url)
        log.onError = { capture.caught($0, context: nil) }

        log.error("Could not read /Users/canaryuserkt/x.json for CanaryAccountXv", ScriptFormatError("Could not read /Users/canaryuserkt/x.json for CanaryAccountXv"))
        capture.drain()

        let events = hub.limiter.take().events
        let event = try #require(events.first)
        guard case .error(let detail) = event.detail else {
            Issue.record("not an error event")
            return
        }
        #expect(detail.origin == "caught")
        #expect(detail.handled)
        #expect(detail.type == "OsbManagerCore.ScriptFormatError")
        #expect(!detail.frames.contains { $0.hasPrefix("OsbManagerCore.AppLog.") || $0.hasPrefix("OsbManagerCore.DiagnosticsCapture.") })
    }

    @Test func canary_anNSExceptionNameAndReasonHoldingAnAccountNameNeverLeave() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock)
        let capture = CaptureSamples.capture(hub, version: "1.1.0")
        CrashHandlers.install(capture)

        CrashHandlers.handle(NSException(name: NSExceptionName("CanaryAccountXvException"), reason: "CanaryAccountXv failed at /Users/canaryuserkt/x", userInfo: ["account": "CanaryAccountXv"]))

        let files = hub.pending.load()
        #expect(files.count == 1)
        let text = files.map { String(decoding: $0.content, as: UTF8.self) }.joined()
        #expect(text.contains("\"type\":\"Foundation.NSException\""))
        for needle in ["CanaryAccountXv", "canaryaccountxv", "canaryuserkt", "/Users/"] {
            #expect(!text.contains(needle))
        }
    }

    @Test func canary_aCaughtErrorWithAUserPathInItsDescriptionNeverLeaves() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock)
        let capture = CaptureSamples.capture(hub, version: "1.1.0")
        let error = NSError(domain: "/Users/canaryuserkt/Library", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not open /Users/canaryuserkt/accounts.json"])

        capture.caught(error)
        capture.drain()
        let uploader = DiagnosticsUploader(hub: hub, perf: capture.perf, appVersion: "1.1.0", env: { CaptureSamples.env })
        let body = String(decoding: try #require(uploader.prepare(CaptureSamples.on)).body, as: UTF8.self)

        #expect(body.contains("\"type\":\"Foundation.NSError\""))
        for needle in ["canaryuserkt", "/Users/", "accounts.json", "Library"] {
            #expect(!body.contains(needle))
        }
    }

    @Test func canary_aPageReportedPhaseHoldingAnAccountNameNeverLeaves() throws {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock)
        let capture = CaptureSamples.capture(hub, version: "1.1.0")

        capture.processFailed(status: 2, errorCode: 11, context: DiagnosticContext(phase: "CanaryAccountXv", loginStage: "canary.login.mq", window: 1, windows: 1))
        capture.drain()
        let uploader = DiagnosticsUploader(hub: hub, perf: capture.perf, appVersion: "1.1.0", env: { CaptureSamples.env })
        let body = String(decoding: try #require(uploader.prepare(CaptureSamples.on)).body, as: UTF8.self)

        #expect(body.contains("\"phase\":\"other\""))
        for needle in ["CanaryAccountXv", "canary.login.mq"] {
            #expect(!body.contains(needle))
        }
    }

    @Test func canary_theCefErrorStringIsNeverRead() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CefBridge/SroCefBrowser.mm")
        let text = try String(contentsOf: source, encoding: .utf8)
        let uses = text.components(separatedBy: "error_string").count - 1

        #expect(uses == 2)
        #expect(!text.contains("ToNSString(error_string)"))
        #expect(!text.contains("error_string."))
        #expect(text.contains("handleTerminatedStatus:static_cast<int>(status) code:error_code"))
    }

    @Test func ownFramesResolveToTheirDemangledNames() {
        let frames = NativeStack.selfCheck()

        #expect(frames.contains("OsbManagerCore.NativeStack.selfCheck"))
        #expect(frames.allSatisfy { !$0.contains("0x") && !$0.contains("/") && !$0.contains("$s") })
    }

    @Test func machineryFramesAreLeftOut() {
        #expect(NativeStack.withoutMachinery(["ext", "OsbManagerCore.AppLog.error", "OsbManagerCore.DiagnosticsCapture.caught", "OsbManagerApp.GameWindowController.fail", "ext"]) == ["OsbManagerApp.GameWindowController.fail", "ext"])
        #expect(NativeStack.withoutMachinery(["ext"]) == ["ext"])
    }

    @Test func swiftAndCxxSymbolsAreDemangled() {
        #expect(NativeStack.demangle("$sSi") == "Swift.Int")
        #expect(NativeStack.demangle("_ZN9SroClient25OnRenderProcessTerminatedEv") == "SroClient::OnRenderProcessTerminated()")
        #expect(NativeStack.demangle("-[SroCefBrowser handleTerminated:]") == "-[SroCefBrowser handleTerminated:]")
    }

    @Test func pageHealthReportsHowLongAPageHung() {
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let health = PageHealth(clock: { clock.date })
        health.pageStarted()
        #expect(health.markResponsive() == nil)

        #expect(health.markUnresponsive())
        clock.advance(17)
        #expect(health.unresponsiveSeconds == 17)
        #expect(health.markResponsive() == 17)
        #expect(!health.unresponsive)

        clock.advance(40)
        #expect(health.silentSeconds == 40)
    }

    @Test func threeHoursGiveAtMostSixPerfEntries() {
        let perf = PerfCollector()
        let start = CaptureSamples.at("2026-11-12T10:00:00Z")
        let source = CaptureSamples.fakeProcesses(start: start)
        var entries: [PerfEntry] = []
        for minute in 0..<180 {
            perf.add(source([], start.addingTimeInterval(Double(minute) * 60)))
            perf.tryComplete(interval: 1800)
            entries += perf.takeReady()
        }

        #expect(entries.count == 6)
        let first = entries[0]
        #expect(first.memory?.rendererEach == [655, 380, 410])
        #expect(abs((first.cpu?.app ?? 0) - 3.1) < 0.01)
        #expect(abs((first.cpu?.gpu ?? 0) - 9.8) < 0.01)
    }

    @Test func perfIsNotCollectedWhilePerfIsOffOrConsentIsOff() {
        let folder = TemporaryDirectory().file("diagnostics")
        let clock = TestClock(CaptureSamples.at("2026-11-12T10:00:00Z"))
        let hub = CaptureSamples.hub(folder, clock)
        let capture = CaptureSamples.capture(hub, version: "1.1.0", sampleWindows: CaptureSamples.fakeProcesses(start: clock.date))
        capture.configure { DiagnosticsConfig(enabled: true, perf: false) }
        for _ in 0..<40 {
            capture.sampleOnce()
            clock.advance(60)
        }
        #expect(capture.perf.sampleCount == 0)
        #expect(capture.perf.readyCount == 0)

        let offFolder = TemporaryDirectory().file("diagnostics")
        let offHub = CaptureSamples.hub(offFolder, clock, consent: false)
        let off = CaptureSamples.capture(offHub, version: "1.1.0", sampleWindows: CaptureSamples.fakeProcesses(start: clock.date))
        off.configure { CaptureSamples.on }
        for _ in 0..<40 {
            off.sampleOnce()
            clock.advance(60)
        }
        #expect(off.perf.sampleCount == 0)
        #expect(!FileManager.default.fileExists(atPath: offFolder.path))
    }

    @Test func helperProcessesAreClassifiedByTheirNameSuffix() {
        #expect(ProcessSampler.role(helperName: "OSB Manager Helper (GPU)") == .gpu)
        #expect(ProcessSampler.role(helperName: "OSB Manager Helper (Renderer)") == .renderer)
        #expect(ProcessSampler.role(helperName: "OSB Manager Helper (Plugin)") == .utility)
        #expect(ProcessSampler.role(helperName: "OSB Manager Helper") == .utility)
    }

    @Test func theAppItselfIsMeasuredWithoutTaskForPid() throws {
        let reading = try #require(ProcessSampler.appReading())
        let sample = ProcessSampler.sample(windows: [PerfWindowInfo(rendererPid: nil, light: true, hidden: false, inWorld: true)], at: Date())

        #expect(reading.footprintBytes > 1024 * 1024)
        #expect(reading.cpuSeconds > 0)
        #expect(sample.windows == PerfWindows(open: 1, light: 1, hidden: 0, inWorld: 1))
        #expect(sample.app != nil)
    }

    @Test func theDiagnosticsBlockIsClampedAndAMissingOrBrokenBlockIsOff() throws {
        func parse(_ block: String) -> DiagnosticsConfig? {
            let text = #"{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true},"client_ok":true"# + block + "}"
            return TelemetryConfig.parse(Data(text.utf8))?.diagnostics
        }

        let clamped = try #require(parse(#","diagnostics":{"enabled":true,"perf":true,"interval_s":10,"perf_interval_s":5,"sample_pct":150}"#))
        #expect(clamped == DiagnosticsConfig(enabled: true, perf: true, intervalSeconds: 600, perfIntervalSeconds: 1800, samplePercent: 100))
        let high = try #require(parse(#","diagnostics":{"enabled":true,"perf":false,"interval_s":999999,"perf_interval_s":999999,"sample_pct":-4}"#))
        #expect(high == DiagnosticsConfig(enabled: true, perf: false, intervalSeconds: 86_400, perfIntervalSeconds: 86_400, samplePercent: 0))
        #expect(parse("") == nil)
        #expect(parse(#","diagnostics":{"enabled":"yes","perf":true,"interval_s":600,"perf_interval_s":1800,"sample_pct":100}"#) == nil)
        #expect(parse(#","diagnostics":{"enabled":true,"perf":true,"interval_s":600,"perf_interval_s":1800}"#) == nil)
        #expect(parse(#","diagnostics":[]"#) == nil)
        let missing = try #require(TelemetryConfig.parse(Data(#"{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true},"client_ok":true}"#.utf8)))
        #expect(missing.diagnosticsSettings == .disabled)
        var notOk = missing
        notOk.clientOk = false
        notOk.diagnostics = CaptureSamples.on
        #expect(notOk.diagnosticsSettings == .disabled)
    }
}
