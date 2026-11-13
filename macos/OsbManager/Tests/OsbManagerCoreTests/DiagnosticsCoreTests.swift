import Foundation
import Testing
@testable import OsbManagerCore

extension MachineIdentity {
    static let canary = MachineIdentity(
        userName: "canaryuserkt",
        fullName: "Kt Canaryuser",
        hostName: "canary-mbp-7q.local",
        computerName: "Kt Canaryuser's MacBook Pro",
        localHostName: "Canary-MBP-7Q",
        homeFolder: "/Users/canaryuserkt"
    )
}

final class ManualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var clock: @Sendable () -> Date { { [self] in now } }
}

enum DiagnosticsSamples {
    static let now = Date(timeIntervalSince1970: 1_794_495_600)
    static let goldenFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/manager-mac-batch.json")

    static func at(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text) ?? now
    }

    static func goldenBatch() -> DiagnosticBatch {
        let crash = DiagnosticEvent.make(
            .process(RendererTermination.detail(status: 2, errorCode: 11)),
            at: at("2026-11-12T14:20:00Z"),
            context: DiagnosticContext(phase: "world", loginStage: "done", window: 2, windows: 3, light: false, hidden: false, uptimeSeconds: 7260),
            trail: [
                TrailItem(secondsBefore: -600, level: "info", category: "window", code: TrailCodes.windowStart, window: 2),
                TrailItem(secondsBefore: -95, level: "warn", category: "gpu", code: TrailCodes.gpuRetry, count: 2, window: 2),
                TrailItem(secondsBefore: 0, level: "error", category: "window", code: TrailCodes.windowRendererExited, window: 2),
            ]
        )
        let hang = DiagnosticEvent.make(.hang(HangDetail(outcome: "reloaded", waitedSeconds: 75)), at: at("2026-11-12T14:21:00Z"), context: DiagnosticContext(phase: "world", window: 1, windows: 3))
        let gpu = DiagnosticEvent.make(.gpu(GpuDetail(code: "device-lost", retries: 3)), at: at("2026-11-12T14:22:00Z"), count: 2)
        let uncaught = DiagnosticEvent.make(
            .error(ErrorDetail(type: ErrorTypeNames.wire(ErrorTypeNames.exception(named: "NSInvalidArgumentException")), origin: "appdomain", handled: false, frames: [
                "OsbManagerApp.GameWindowController.gameBrowser", "OsbManagerCef.CefGameBrowser.cefBrowser.<closure>", "ext",
            ])),
            at: at("2026-11-12T14:23:00Z"),
            context: DiagnosticContext(window: 2, windows: 3, uptimeSeconds: 7440)
        )
        let caught = DiagnosticEvent.make(
            .error(ErrorDetail(type: ErrorTypeNames.wire("OsbManagerCore.ScriptFormatError"), origin: "caught", handled: true, frames: ["OsbManagerCore.ScriptStore.install", "ext"])),
            at: at("2026-11-12T14:24:00Z"),
            count: 3
        )
        let runEnd = DiagnosticEvent.make(.runEnd(RunEndDetail(outcome: "crash", uptimeSeconds: 10800, previousVersion: "1.0.9", signal: "sigsegv")), at: at("2026-11-12T12:00:00Z"))
        let perf = PerfEntry(
            at: at("2026-11-12T14:00:00Z"),
            spanSeconds: 1800,
            samples: 30,
            windows: PerfWindows(open: 3, light: 1, hidden: 0, inWorld: 3),
            memory: PerfMemory(
                renderer: RoleMemory(p50: 410, max: 655),
                rendererEach: [655, 380, 410],
                gpu: RoleMemory(p50: 290, max: 330),
                browserTotal: RoleMemory(p50: 1720, max: 1910),
                utility: RoleMemory(p50: 140, max: 150),
                app: RoleMemory(p50: 210, max: 236)
            ),
            jsHeapUsedEach: [131, 118, 166],
            jsHeapTotalEach: [160, 150, 210],
            cpu: PerfCpu(rendererEach: [14.0, 11.5, 30.2], gpu: 9.8, browserTotal: 61.3, app: 3.1)
        )
        return DiagnosticBatch(
            appVersion: "1.1.0",
            run: "5d1c0e7a9b3f2c48",
            env: DiagnosticEnv(osBuild: "26.5.0", webview2: "156.0.8078.80", ramGb: 16, cores: 8, gpuVendor: "apple"),
            events: [crash, hang, gpu, uncaught, caught, runEnd],
            perf: [perf]
        )
    }
}

@Suite(.serialized)
struct DiagnosticsCoreTests {
    private func terms() -> PrivateTerms {
        let terms = PrivateTerms.forMachine(.canary, dataFolder: "/Users/canaryuserkt/Library/Application Support/OSB Manager")
        terms.add(accounts: [Account(id: "a1", name: "CanaryAccountXv", loginId: "canary.login.mq", server: "CanaryServerWs", character: "CanaryCharJp")])
        terms.add("CanaryPlayerZq")
        return terms
    }

    private func body(_ events: [DiagnosticEvent], terms: PrivateTerms) throws -> String {
        let batch = DiagnosticBatch(appVersion: "1.1.0", run: "5d1c0e7a9b3f2c48", events: events)
        let body = try DiagnosticJson.batch(batch, terms: terms, now: DiagnosticsSamples.now)
        return String(decoding: body.body, as: UTF8.self)
    }

    private func pendingText(_ event: DiagnosticEvent, terms: PrivateTerms) -> String {
        DiagnosticJson.event(event, terms: terms).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func expectAbsent(_ needles: [String], in texts: [String]) {
        for text in texts {
            for needle in needles {
                #expect(!text.lowercased().contains(needle.lowercased()), "\(needle) leaked")
            }
        }
    }

    private func exception(frames: [String], type: String = "Exception", at: Date = DiagnosticsSamples.now) -> DiagnosticEvent {
        DiagnosticEvent.make(.error(ErrorDetail(type: type, origin: "caught", handled: true, frames: frames)), at: at)
    }

    @Test func canary_aLogLineWithAPlayerNameNeverLeaves() throws {
        let terms = terms()
        let careless = DiagnosticEvent.make(
            .warn(WarnDetail(category: "party", code: "party.accepted-from:canaryplayerzq")),
            at: DiagnosticsSamples.now,
            trail: [TrailItem(secondsBefore: -5, level: "info", category: "party", code: "party.resurrected-by:canaryplayerzq")]
        )
        let crash = DiagnosticEvent.make(
            .process(RendererTermination.detail(status: 2, errorCode: 11)),
            at: DiagnosticsSamples.now,
            trail: [TrailItem(secondsBefore: -3, level: "info", category: "party", code: "party.accept:canaryplayerzq")]
        )

        let text = try body([careless, crash], terms: terms)

        expectAbsent(["CanaryPlayerZq"], in: [text, pendingText(crash, terms: terms), pendingText(careless, terms: terms)])
        #expect(text.contains("render_process_exited"))
    }

    @Test func canary_aPathWithAUserNameNeverLeaves() throws {
        let terms = terms()
        let event = exception(frames: ["/Users/CanaryUserKt/Library/Application Support/OSB Manager/privacy.json", "OsbManagerCore.PrivacySettings.save", "Users/CanaryUserKt"])

        let text = try body([event], terms: terms)

        expectAbsent(["CanaryUserKt", "/Users/", "Library/"], in: [text, pendingText(event, terms: terms)])
        #expect(text.contains("OsbManagerCore.PrivacySettings.save"))
    }

    @Test func canary_theHostNameNeverLeaves() throws {
        let terms = terms()
        let warn = DiagnosticEvent.make(.warn(WarnDetail(category: "net", code: "net.host:canary-mbp-7q")), at: DiagnosticsSamples.now)
        let error = exception(frames: ["OsbManagerApp.Canary-MBP-7Q.start", "OsbManagerApp.Host.canary_mbp_7q", "OsbManagerApp.CanaryUserkts.run"])

        let text = try body([warn, error], terms: terms)

        expectAbsent(["canary-mbp-7q", "Canary-MBP-7Q", "canaryuserkts"], in: [text, pendingText(warn, terms: terms), pendingText(error, terms: terms)])
    }

    @Test func canary_aChatLineNeverLeaves() throws {
        let terms = terms()
        terms.add("CanaryChatterQw")
        let event = exception(frames: ["CanaryChatterQw: wts gold, pm me", "OsbManagerApp.ChatFrom.CanaryChatterQw", "OsbManagerCore.BotStatus.parse"])

        let text = try body([event], terms: terms)

        expectAbsent(["CanaryChatterQw", "wts gold"], in: [text, pendingText(event, terms: terms)])
        #expect(text.contains("OsbManagerCore.BotStatus.parse"))
    }

    @Test func canary_anExceptionReasonHoldingAnAccountNameNeverLeaves() throws {
        let terms = terms()
        let reason = "Account CanaryAccountXv (canary.login.mq) not found"
        let event = DiagnosticEvent.make(
            .error(ErrorDetail(type: "Foundation.NSInvalidArgumentException.CanaryAccountXv", origin: "appdomain", handled: false, frames: [reason, "OsbManagerApp.Login.CanaryAccountXv", "OsbManagerApp.AppDelegate.applicationDidFinishLaunching"], inner: ["OsbManagerCore.CanaryAccountXv"])),
            at: DiagnosticsSamples.now
        )

        let text = try body([event], terms: terms)

        expectAbsent(["CanaryAccountXv", "canary.login.mq", "not found"], in: [text, pendingText(event, terms: terms)])
        #expect(text.contains("\"events\":[]"))
        #expect(pendingText(event, terms: terms).isEmpty)
    }

    @Test func aHandBuiltManagerMacBatchHasTheExpectedShape() throws {
        let body = try DiagnosticJson.batch(DiagnosticsSamples.goldenBatch(), terms: terms(), now: DiagnosticsSamples.now)

        #expect(body.events.count == 6)
        #expect(body.perfCount == 1)
        let root = try #require(try JSONSerialization.jsonObject(with: body.body) as? [String: Any])
        #expect(root["app"] as? String == "manager-mac")
        #expect(root["schema"] as? Int == 1)
        #expect(root["osb_perf"] == nil)
        let perf = try #require((root["perf"] as? [[String: Any]])?.first)
        #expect(perf["wasm_mb"] == nil)
        #expect((perf["mem_mb"] as? [String: Any]).flatMap { ($0["renderer"] as? [String: Any])?["each"] as? [Int] } == [380, 410, 655])
    }

    @Test func everyTimeIsMinuteAligned() throws {
        let seconds = DiagnosticsSamples.now.addingTimeInterval(-37.25)
        let event = DiagnosticEvent.make(.gpu(GpuDetail(code: "device-lost", retries: 1)), at: seconds)
        let text = try body([event], terms: terms())

        #expect(text.contains("\"at\":\"2026-11-12T14:59:00Z\""))
        #expect(DiagnosticFormats.minuteText(seconds) == "2026-11-12T14:59:00Z")
    }

    @Test func fingerprintsFollowTheWindowsFormula() {
        #expect(DiagnosticFingerprint.of(.runEnd(RunEndDetail(outcome: "unclean", uptimeSeconds: 60, previousVersion: nil))) == "09025720440394cf")
        #expect(DiagnosticFingerprint.of(.process(RendererTermination.detail(status: 2, errorCode: 11))) == "d4b68ee37f5cf932")
        let frames = ["OsbManagerApp.GameWindowController.gameBrowser", "ext", "OsbManagerCef.CefGameBrowser.cefBrowser.<closure>", "<x>"]
        #expect(DiagnosticFingerprint.forException(type: "Exception", origin: "appdomain", frames: frames) == "8e1c6583d892d3af")
    }

    @Test(arguments: [
        ("OsbManagerCore.PrivacySettings.grant(characters: Swift.Bool) -> OsbManagerCore.PrivacyState", "OsbManagerCore.PrivacySettings.grant"),
        ("closure #1 (Swift.Bool) -> () in OsbManagerApp.GameWindowController.load() -> ()", "OsbManagerApp.GameWindowController.load.<closure>"),
        ("closure #2 in closure #1 in OsbManagerApp.AppDelegate.start()", "OsbManagerApp.AppDelegate.start.<closure>"),
        ("@objc OsbManagerApp.AppDelegate.applicationDidFinishLaunching(Foundation.Notification) -> ()", "OsbManagerApp.AppDelegate.applicationDidFinishLaunching"),
        ("OsbManagerCore.JsonFile.read<A where A: Swift.Decodable>(_: A.Type, from: Foundation.URL) throws -> A?", "OsbManagerCore.JsonFile.read"),
        ("OsbManagerCore.Store<A>.load(from: Foundation.URL) throws -> A", "OsbManagerCore.Store.load"),
        ("OsbManagerApp.GameWindowController.(handle in _6F3A92B1C4D5E6F7)(Swift.String) -> ()", "OsbManagerApp.GameWindowController.handle"),
        ("OsbManagerCore.PrivacySettings.state.getter : OsbManagerCore.PrivacyState", "OsbManagerCore.PrivacySettings.state.getter"),
        ("-[SroCefBrowser handleTerminated:]", "CefBridge.SroCefBrowser.handleTerminated"),
        ("+[SroCefBrowser(Private) shared]", "CefBridge.SroCefBrowser.shared"),
        ("(anonymous namespace)::SroClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser>, cef_termination_status_t, int, CefStringBase<CefStringTraitsUTF16> const&)", "CefBridge.SroClient.OnRenderProcessTerminated"),
    ])
    func ownSymbolsReduceToModuleTypeMethod(symbol: String, expected: String) {
        #expect(FrameReducer.name(of: symbol) == expected)
    }

    @Test func foreignAndUnreadableFramesCollapseToExt() {
        let frames = [
            NativeFrame(ownImage: false, symbol: "objc_exception_throw"),
            NativeFrame(ownImage: false, symbol: "-[NSApplication run]"),
            NativeFrame(ownImage: true, symbol: "$s14OsbManagerCore15PrivacySettingsC5grant"),
            NativeFrame(ownImage: true, symbol: "Swift.Array.subscript.getter : (Swift.Int) -> A"),
            NativeFrame(ownImage: true, symbol: nil),
            NativeFrame(ownImage: true, symbol: "OsbManagerCore.BotStatus.parse(Foundation.Data) -> OsbManagerCore.BotStatus?"),
            NativeFrame(ownImage: true, symbol: "main"),
            NativeFrame(ownImage: false, symbol: "start"),
        ]

        #expect(FrameReducer.reduce(frames) == ["ext", "OsbManagerCore.BotStatus.parse", "ext"])
    }

    @Test func framesAreCappedAtSixteenAndCarryNoAddressOrPath() {
        let frames = (0..<40).map { NativeFrame(ownImage: true, symbol: "OsbManagerCore.Deep.level\($0)() -> ()") }
        let reduced = FrameReducer.reduce(frames)

        #expect(reduced.count == 16)
        #expect(reduced.allSatisfy { !$0.contains("0x") && !$0.contains("/") && !$0.contains("+") && !$0.contains("@") })
        #expect(FrameReducer.name(of: "OsbManagerCore." + String(repeating: "A", count: 120)) == nil)
    }

    @Test func errorTypesUseTheMacNamespacesSinceS1() {
        #expect(ErrorTypeNames.exception(named: "NSRangeException") == "Foundation.NSRangeException")
        #expect(ErrorTypeNames.exception(named: "CanaryCustomException") == "Foundation.NSException")
        #expect(ErrorTypeNames.wire("Foundation.NSRangeException") == "Foundation.NSRangeException")
        #expect(ErrorTypeNames.wire("Foundation.NSRangeException", acceptsMacNamespaces: false) == "Exception")
        #expect(ErrorTypeNames.wire("Foundation.NSRangeException", acceptsMacNamespaces: true) == "Foundation.NSRangeException")
        #expect(ErrorTypeNames.wire("OsbManagerCore.ScriptFormatError", acceptsMacNamespaces: true) == "OsbManagerCore.ScriptFormatError")
        #expect(ErrorTypeNames.wire("Swift.DecodingError", acceptsMacNamespaces: true) == "Exception")
        #expect(ErrorTypeNames.swiftError(ScriptFormatError("x")).hasPrefix("OsbManagerCore."))
        #expect(ErrorTypeNames.serverAcceptsMacNamespaces)
    }

    @Test(arguments: [(Int32(0), "unexpected"), (1, "terminated"), (2, "crashed"), (3, "out_of_memory"), (4, "launch_failed"), (5, "unexpected"), (99, "unexpected")])
    func cefTerminationStatusesMapToProcessReasons(status: Int32, reason: String) {
        #expect(RendererTermination.reason(status: status) == reason)
    }

    @Test func exitCodesAreUnsignedUpperHex() {
        #expect(DiagnosticFormats.exitCode(11) == "0xB")
        #expect(DiagnosticFormats.exitCode(-1) == "0xFFFFFFFF")
        #expect(DiagnosticFormats.exitCode(0) == "0x0")
    }

    @Test func environmentValuesAreBucketsAndVersionsOnly() {
        #expect(DiagnosticFormats.osBuild(OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)) == "26.5.0")
        #expect(DiagnosticFormats.chromiumVersion(cefVersion: "156.0.15+gcf671c0+chromium-156.0.8078.80") == "156.0.8078.80")
        #expect(DiagnosticFormats.ramBucket(bytes: 16 * 1_073_741_824 - 300_000_000) == 16)
        #expect(DiagnosticFormats.ramBucket(bytes: 1_000_000_000) == nil)
        #expect(DiagnosticFormats.coreBucket(10) == 8)
        #expect(DiagnosticFormats.gpuVendor(deviceName: "Apple M2 Pro") == "apple")
        #expect(DiagnosticFormats.gpuVendor(deviceName: "AMD Radeon Pro 5500M") == "amd")
        #expect(DiagnosticFormats.gpuVendor(deviceName: "Intel(R) UHD Graphics 630") == "intel")
        #expect(DiagnosticFormats.gpuVendor(deviceName: nil) == "unknown")
        #expect(DiagnosticFormats.gpuVendor(deviceName: "Canary GPU") == "other")
    }

    @Test func theTrailKeepsFiftyCodesAndCountsRepeats() {
        let time = ManualTime(DiagnosticsSamples.now)
        let trail = DiagnosticTrail(now: time.clock)
        for index in 0..<60 {
            trail.info(index.isMultiple(of: 2) ? TrailCodes.windowStart : TrailCodes.windowClosed, window: index % 4 + 1)
            time.advance(1)
        }
        trail.warning(TrailCodes.gpuRetry, window: 2)
        trail.warning(TrailCodes.gpuRetry, window: 2)
        trail.info("Not A Code")

        let items = trail.snapshot(before: time.now)

        #expect(items.count == 50)
        #expect(items.last?.code == TrailCodes.gpuRetry)
        #expect(items.last?.count == 2)
        #expect(items.last?.category == "gpu")
        #expect(TrailCodes.loginFailed("CanaryStage") == "login.failed:other")
        #expect(TrailCodes.gpuFailed("GPUDevice lost") == "gpu.failed:device-lost")
    }

    @Test func aThousandIdenticalErrorsAreOneEventWithOneTrail() {
        let time = ManualTime(DiagnosticsSamples.now)
        let limiter = DiagnosticLimiter(now: time.clock)
        let trail = [TrailItem(secondsBefore: 0, level: "error", category: "window", code: TrailCodes.windowRendererExited)]
        var outcomes: [RecordOutcome] = []
        for _ in 0..<1000 {
            outcomes.append(limiter.record(DiagnosticEvent.make(.process(RendererTermination.detail(status: 2, errorCode: 11)), at: time.now, trail: trail)))
            time.advance(0.5)
        }

        let taken = limiter.take()

        #expect(outcomes.filter { $0 == .added }.count == 1)
        #expect(taken.events.count == 1)
        #expect(taken.events[0].count == 1000)
        #expect(taken.events[0].trail?.count == 1)
    }

    @Test func atMostThirtyDistinctEventsPerHourAndTwoHundredPerDay() {
        let time = ManualTime(DiagnosticsSamples.now)
        let limiter = DiagnosticLimiter(now: time.clock)
        for index in 0..<100 {
            _ = limiter.record(DiagnosticEvent.make(.warn(WarnDetail(category: "window", code: "window.code-\(index)")), at: time.now))
        }
        let first = limiter.take()
        #expect(first.events.count == 30)
        #expect(first.dropped.rateLimited == 70)

        var added = 30
        for hour in 1..<30 {
            time.advance(3600)
            for index in 0..<30 where limiter.record(DiagnosticEvent.make(.warn(WarnDetail(category: "window", code: "window.h\(hour)-\(index)")), at: time.now)) == .added {
                added += 1
            }
            _ = limiter.take()
            if hour == 20 { break }
        }
        #expect(added == 200)
        #expect(limiter.record(DiagnosticEvent.make(.runEnd(RunEndDetail(outcome: "clean", uptimeSeconds: 60, previousVersion: nil)), at: time.now)) == .added)
    }

    @Test func aFingerprintIsSentAtMostOncePerHourAndAFailedBatchComesBack() {
        let time = ManualTime(DiagnosticsSamples.now)
        let limiter = DiagnosticLimiter(now: time.clock)
        let event = DiagnosticEvent.make(.gpu(GpuDetail(code: "device-lost", retries: 1)), at: time.now)
        _ = limiter.record(event)
        let first = limiter.take()
        _ = limiter.record(event)
        #expect(limiter.take().events.isEmpty)
        time.advance(3600)
        #expect(limiter.take().events.count == 1)

        time.advance(3600)
        _ = limiter.record(event)
        let failed = limiter.take()
        #expect(failed.events.count == 1)
        limiter.giveBack(failed.events, dropped: DroppedCounts(rateLimited: 4))
        let retried = limiter.take()
        #expect(first.events.count == 1)
        #expect(retried.events.count == 1)
        #expect(retried.dropped.rateLimited == 4)
    }

    @Test func aRunThatDrawsOutsideTheSampleRecordsNothing() {
        let limiter = DiagnosticLimiter(now: { DiagnosticsSamples.now }, sampleDraw: 60, samplePercent: 50)
        #expect(limiter.record(DiagnosticEvent.make(.gpu(GpuDetail(code: "device-lost", retries: 1)), at: DiagnosticsSamples.now)) == .sampledOut)
        #expect(limiter.pendingCount == 0)
        #expect(DiagnosticRules.sampledIn(draw: 0, percent: 1))
        #expect(!DiagnosticRules.sampledIn(draw: 0, percent: 0))
        #expect(!DiagnosticRules.sampledIn(draw: 99, percent: 99))
    }

    @Test func aLargeBatchIsCutToSixtyKilobytes() throws {
        let trail = (0..<50).map { TrailItem(secondsBefore: -$0, level: "info", category: "window", code: "window.step-\($0)-with-a-longer-code", window: 1) }
        let events = (0..<50).map { index in
            DiagnosticEvent.make(.error(ErrorDetail(type: "Exception", origin: "caught", handled: true, frames: (0..<16).map { "OsbManagerCore.Module\(index).VeryLongTypeNameForSize.method\($0)" })), at: DiagnosticsSamples.now, trail: trail)
        }
        let body = try DiagnosticJson.batch(DiagnosticBatch(appVersion: "1.1.0", run: "5d1c0e7a9b3f2c48", events: events), terms: terms(), now: DiagnosticsSamples.now)

        #expect(body.body.count <= DiagnosticFormats.softBodyBytes)
        #expect(body.events.count + body.dropped.oversize == 50)
        #expect(!body.events.isEmpty)
    }

    @Test func oldAndInvalidEventsAreDropped() throws {
        let old = DiagnosticEvent.make(.gpu(GpuDetail(code: "device-lost", retries: 1)), at: DiagnosticsSamples.now.addingTimeInterval(-8 * 24 * 3600))
        var invalid = DiagnosticEvent.make(.hang(HangDetail(outcome: "canary", waitedSeconds: 1)), at: DiagnosticsSamples.now)
        invalid.fingerprint = DiagnosticFormats.reservedFingerprint
        let body = try DiagnosticJson.batch(DiagnosticBatch(appVersion: "1.1.0", run: "5d1c0e7a9b3f2c48", events: [old, invalid]), terms: terms(), now: DiagnosticsSamples.now)

        #expect(body.events.isEmpty)
        #expect(throws: DiagnosticBatchError.invalidVersionOrRun) {
            try DiagnosticJson.batch(DiagnosticBatch(appVersion: "1.1.0 beta", run: "5d1c"), terms: PrivateTerms(), now: DiagnosticsSamples.now)
        }
    }

    @Test func aPendingEventRoundTrips() throws {
        let batch = DiagnosticsSamples.goldenBatch()
        for event in batch.events {
            let data = try #require(DiagnosticJson.event(event, terms: terms()))
            let parsed = try #require(DiagnosticJsonReader.event(data))
            #expect(DiagnosticJson.eventText(parsed) == String(decoding: data, as: UTF8.self))
        }
        #expect(DiagnosticJsonReader.event(Data("{\"kind\":\"js_error\",\"source\":\"osb\"}".utf8)) == nil)
    }

    @Test func pendingFilesKeepTheCapsExpireAndNeedConsent() throws {
        let temp = TemporaryDirectory()
        let time = ManualTime(DiagnosticsSamples.now)
        let consent = Flag(true)
        let pending = PendingDiagnostics(folder: temp.file("diagnostics"), now: time.clock, consentOn: { consent.value })
        for _ in 0..<12 {
            #expect(pending.write(Data("{\"a\":1}".utf8)))
            time.advance(1)
        }
        #expect(pending.count == 10)
        #expect(!pending.write(Data(count: PendingDiagnostics.maxFileBytes + 1)))
        #expect(!pending.write(Data()))

        let loaded = pending.load()
        #expect(loaded.count == 10)
        pending.delete(id: loaded[0].id)
        pending.delete(id: "../privacy.json")
        #expect(pending.count == 9)

        time.advance(7 * 24 * 3600)
        #expect(pending.load().isEmpty)
        #expect(pending.count == 0)

        consent.value = false
        #expect(!pending.write(Data("{\"a\":1}".utf8)))
        #expect(pending.count == 0)
    }

    @Test func privateTermsEvictTheOldestButKeepTheMachineTerms() {
        let terms = PrivateTerms.forMachine(.canary, dataFolder: "/Users/canaryuserkt/osb-data/")
        for index in 0..<(PrivateTerms.capacity + 5) {
            terms.add("CanaryName\(index)")
        }

        #expect(!terms.hits("CanaryName0"))
        #expect(!terms.hits("CanaryName4"))
        #expect(terms.hits("CanaryName5"))
        #expect(terms.hits("CanaryName\(PrivateTerms.capacity + 4)"))
        #expect(terms.hits("CANARYUSERKT"))
        #expect(terms.hits("canary-mbp-7q"))
        #expect(terms.hits("/Users/canaryuserkt/osb-data"))
        #expect(!terms.hits("OsbManagerCore.ProcessDetail"))
        #expect(!terms.hits("MacBook"))
        terms.add("ab")
        #expect(!terms.hits("ab"))
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
