import Foundation
import Testing
@testable import OsbManagerCore

enum OsbSamples {
    static let testFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let macVocabulary = testFolder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/diagnostics-vocabulary.json")
    static let windowsVocabulary = testFolder
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("src/OsbManager.Core/Telemetry/Diagnostics/diagnostics-vocabulary.json")
    static let osbVersion = "2.0.14"
    static let template = "Cannot read properties of <q> (reading <q>)"

    static func vocabulary() throws -> OsbVocabulary {
        try OsbVocabulary.load(from: macVocabulary)
    }

    static func errorEvent(_ at: Date, fp: String = "3a91c2d4e5f60718", template: String = template, frames: [String] = ["Quest.observe@14210:31", "Controller.guard@12018:20", "ext"]) -> [String: Any] {
        [
            "kind": "js_error",
            "source": "osb",
            "fp": fp,
            "at": DiagnosticFormats.minuteText(at),
            "count": 3,
            "error": [
                "type": "TypeError",
                "template": template,
                "module": "quest",
                "handled": true,
                "origin": "guard",
                "frames": frames,
            ] as [String: Any],
            "context": ["phase": "world", "mode": "town", "town_phase": "walk-vendor", "dead": false, "uptime_s": 3600] as [String: Any],
            "trail": [
                ["s": -42, "l": "info", "c": "town", "k": "operation-start"] as [String: Any],
                ["s": -3, "l": "warn", "c": "movement", "k": "legacy", "e": "travel-error", "n": 2, "d": ["distance": 12.5, "attempt": 2, "choice": true] as [String: Any]] as [String: Any],
            ],
        ]
    }

    static func stopEvent(_ at: Date) -> [String: Any] {
        [
            "kind": "bot_stop",
            "source": "osb",
            "fp": "5b7d9f1a2c3e4d60",
            "at": DiagnosticFormats.minuteText(at),
            "count": 1,
            "stop": ["code": "stuck-no-progress", "source": "stop"],
            "context": ["phase": "world", "mode": "hunting", "dead": false, "uptime_s": 3600] as [String: Any],
        ]
    }

    static func warnEvent(_ at: Date) -> [String: Any] {
        [
            "kind": "warn",
            "source": "osb",
            "fp": "6c8e0a2b4d6f8091",
            "at": DiagnosticFormats.minuteText(at),
            "count": 7,
            "warn": [
                "category": "combat",
                "code": "legacy",
                "error_class": "timeout",
                "refusal": ["source": "cast", "reason": "cooldown-or-action-recovery", "native": 12293] as [String: Any],
            ] as [String: Any],
        ]
    }

    static func message(_ events: [[String: Any]]) -> String {
        text(["type": OsbPageBatch.batchType, "events": events])
    }

    static func valid(_ at: Date) -> String {
        message([errorEvent(at), stopEvent(at), warnEvent(at)])
    }

    static func perfAnswer(_ at: Date) -> String {
        "{\"type\":\"osb-diagnostics-perf\",\"perf\":{\"at\":\"\(DiagnosticFormats.minuteText(at))\",\"span_s\":1800,\"samples\":30,"
            + "\"js_heap_mb\":{\"used\":131,\"total\":160},"
            + "\"tick_ms\":{\"p50\":1.2,\"p95\":3.0,\"p99\":8.4,\"max\":41.0,\"late_pct\":0.3},"
            + "\"gap_ms\":{\"p50\":100.1,\"p95\":104.0,\"p99\":180.0,\"max\":912.0,\"late_pct\":0.3},"
            + "\"long_tasks\":{\"count\":3,\"total_ms\":412.0}}}"
    }

    static func text(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

final class PageKit {
    static let accountName = "Alchemy"
    static let loginId = "AntiStuck"
    static let macUser = "AutoMastery"
    static let character = "BuffGear"

    let folder = TemporaryDirectory()
    let clock = TestClock(CaptureSamples.at("2026-11-12T15:00:30Z"))
    let consent: Flag
    let terms: PrivateTerms
    let hub: DiagnosticsHub
    let capture: DiagnosticsCapture
    let uploader: DiagnosticsUploader

    init(consent: Bool = true, allow: Bool = true, vocabulary: OsbVocabulary?? = nil) throws {
        let consentFlag = Flag(consent)
        self.consent = consentFlag
        let identity = MachineIdentity(userName: Self.macUser, fullName: "Kt Canaryuser", hostName: "canary-mbp-7q.local", computerName: nil, localHostName: nil, homeFolder: "/Users/\(Self.macUser)")
        terms = PrivateTerms.forMachine(identity, dataFolder: "/Users/\(Self.macUser)/Library/Application Support/OSB Manager")
        terms.add(accounts: [Account(id: "a1", name: Self.accountName, loginId: Self.loginId, server: "CanaryServerWs")])
        hub = DiagnosticsHub(folder: folder.file("diagnostics"), terms: terms, now: clock.now, sampleDraw: 0, run: "5d1c0e7a9b3f2c48", consentOn: { consentFlag.value })
        if allow { hub.applyServer(CaptureSamples.on) }
        let words = try vocabulary ?? OsbSamples.vocabulary()
        capture = DiagnosticsCapture(hub: hub, appVersion: "1.1.0", useSignals: false, vocabulary: words) { _, at in
            PerfSample(at: at, app: nil, helpers: [], windows: PerfWindows(open: 0, light: 0, hidden: 0, inWorld: 0))
        }
        capture.configure { CaptureSamples.on }
        capture.start(sampling: false)
        capture.drain()
        uploader = DiagnosticsUploader(hub: hub, perf: capture.perf, appVersion: "1.1.0", env: { CaptureSamples.env })
    }

    var receiver: OsbPageBatchReceiver { capture.pageBatches }
    var now: Date { clock.date }

    func offer(_ json: String, window: Int?) -> Bool {
        let taken = receiver.offer(json, window: window)
        receiver.drain()
        return taken
    }

    func answer(_ json: String, window: Int?) -> Bool {
        let taken = receiver.offerPerf(json, window: window, osbVersion: OsbSamples.osbVersion)
        receiver.drain()
        return taken
    }

    func body(_ config: DiagnosticsConfig = CaptureSamples.on) -> (text: String, root: [String: Any])? {
        guard let prepared = uploader.prepare(config) else { return nil }
        return (String(decoding: prepared.body, as: UTF8.self), OsbSamples.object(prepared.body))
    }

    func osbEvents(_ root: [String: Any]) -> [[String: Any]] {
        ((root["events"] as? [[String: Any]]) ?? []).filter { $0["source"] as? String == "osb" }
    }
}

struct OsbVocabularyCopyTests {
    @Test func theMacCopyOfTheVocabularyIsTheWindowsFile() throws {
        let mac = try Data(contentsOf: OsbSamples.macVocabulary)
        let windows = try Data(contentsOf: OsbSamples.windowsVocabulary)

        #expect(!mac.isEmpty)
        #expect(mac == windows, "macos/OsbManager/Resources/diagnostics-vocabulary.json differs from the Windows copy")
        let vocabulary = try OsbSamples.vocabulary()
        #expect(!vocabulary.identifiers.isEmpty)
        #expect(vocabulary.stopCodes.contains("stuck-no-progress"))
    }

    @Test func aBrokenVocabularyIsRefused() {
        #expect(throws: OsbVocabularyError.self) { try OsbVocabulary(data: Data("{\"version\":\"1\"}".utf8)) }
        #expect(throws: (any Error).self) { try OsbVocabulary(data: Data("not json".utf8)) }
    }
}

struct ScriptSourceLineTests {
    @Test func everyInjectedScriptStartsWithItsSourceName() throws {
        let source = ScriptFixtures.botHeader
        let injection = try ScriptInjection.build(meta: try UserScriptMeta.parse(source), source: source)

        let lines = injection.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "(() => {")
        #expect(lines[1] == "//# sourceURL=osb-manager-script/nixxane-bot.user.js")
        #expect(injection.components(separatedBy: "//# sourceURL=").count == 2)
    }

    @Test(arguments: [
        ("OSB Bot / ü", "OSB-Bot----"),
        ("  osb.lean_v2-beta  ", "osb.lean_v2-beta"),
        ("", "script"),
        ("a\u{1F600}b", "a--b"),
        ("x */ alert(1) //", "x----alert-1----"),
        (String(repeating: "n", count: 80), String(repeating: "n", count: 64)),
    ])
    func theSourceNameKeepsOnlySafeCharacters(name: String, expected: String) {
        #expect(ScriptInjection.sourceName(name) == expected)
    }

    @Test func theAppsOwnPageScriptsGetNoSourceLine() throws {
        let shim = try String(contentsOf: OsbSamples.testFolder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/cef-shim.js"), encoding: .utf8)
        #expect(!shim.contains("sourceURL"))
    }
}

struct OsbPageMessageTests {
    @Test func theSwitchMessagesMatchWindows() {
        #expect(OsbSamples.text(PageMessages.osbDiagnostics(on: true, perf: false)) == "{\"on\":true,\"perf\":false,\"type\":\"osb-diagnostics\"}")
        #expect(OsbSamples.text(PageMessages.osbDiagnostics(on: true, perf: true)) == "{\"on\":true,\"perf\":true,\"type\":\"osb-diagnostics\"}")
        #expect(OsbSamples.text(PageMessages.osbDiagnostics(on: false, perf: true)) == "{\"on\":false,\"type\":\"osb-diagnostics\"}")
    }

    @Test func theInboxHandsPageBatchesOnWithoutParsingThem() {
        let batch = "{\"type\":\"osb-diagnostics-batch\",\"events\":[]}"
        let reversed = "{\"events\":[],\"type\":\"osb-diagnostics-batch\"}"
        let perf = "{\"perf\":{},\"type\":\"osb-diagnostics-perf\"}"
        func accept(_ body: Any, main: Bool = true, host: String = PageMessageInbox.gameHost) -> PageMessage? {
            PageMessageInbox.accept(body: body, isMainFrame: main, scheme: "https", host: host, port: 0)
        }

        #expect(accept(batch) == .osbBatch(batch))
        #expect(accept(reversed) == .osbBatch(reversed))
        #expect(accept(perf) == .osbPerf(perf))
        #expect(accept(batch, main: false) == nil)
        #expect(accept(batch, host: "evil.example") == nil)
        #expect(accept(["type": "osb-diagnostics-batch"]) == nil)
        #expect(!OsbPageBatch.isBatch("{\"type\":\"status\",\"bot\":\"osb-diagnostics-batch\"}"))
        #expect(!OsbPageBatch.isBatch("{\"type\":\"osb-diagnostics\",\"on\":true}"))
        #expect(!OsbPageBatch.isPerf(batch))
        #expect(!OsbPageBatch.isBatch(nil))
    }
}

struct OsbPageBatchParserTests {
    private static let now = CaptureSamples.at("2026-11-12T15:00:30Z")

    private func parse(_ json: String) throws -> [DiagnosticEvent]? {
        OsbPageBatch.parse(json, now: Self.now, vocabulary: try OsbSamples.vocabulary())?.events
    }

    @Test func aWellFormedOsbBatchParsesIntoOsbEvents() throws {
        let events = try #require(try parse(OsbSamples.valid(Self.now)))

        #expect(events.map(\.kind) == [.jsError, .botStop, .warn])
        #expect(events.allSatisfy { $0.source == .osb })
        guard case .error(let error) = events[0].detail else {
            Issue.record("not an error")
            return
        }
        #expect(error.template == OsbSamples.template)
        #expect(error.frames == ["Quest.observe@14210:31", "Controller.guard@12018:20", "ext"])
        #expect(events[0].trail?.count == 2)
        #expect(events[0].trail?[1].numbers?["distance"] == 12.5)
        #expect(events[0].trail?[1].flags?["choice"] == true)
        #expect(events[0].context?.window == nil)
        guard case .warn(let warn) = events[2].detail else {
            Issue.record("not a warning")
            return
        }
        #expect(warn.refusal?.native == 12293)
    }

    @Test(arguments: [
        "wrong source", "manager source on a js_error", "unknown top-level field", "perf field", "unknown event field",
        "unknown error field", "hresult from the page", "manager origin", "window in context", "window in trail",
        "goldChange in details", "null event field", "null optional field", "null event", "duplicate property",
        "eleven events", "no events", "reserved fingerprint", "uppercase fingerprint", "seconds in at", "at a week old",
        "decimal count", "zero count", "uptime not a multiple of 60", "two decimals in details", "control character",
        "lone surrogate", "process_failed kind", "stop object on an error", "bad mode", "bad stop source",
        "template with forbidden characters", "seventeen frames", "twenty-one trail entries", "wrong type", "comment",
        "trailing comma", "not an object",
    ])
    func theStrictParserRejectsTheWholeMessage(broken: String) throws {
        let now = Self.now
        let valid = OsbSamples.valid(now)
        func replace(_ old: String, _ new: String) -> String {
            guard let range = valid.range(of: old) else { return "" }
            return valid.replacingCharacters(in: range, with: new)
        }
        var error = OsbSamples.errorEvent(now)
        var errorBody = error["error"] as? [String: Any] ?? [:]
        let text: String
        switch broken {
        case "wrong source": text = OsbSamples.message([OsbSamples.errorEvent(now), OsbSamples.stopEvent(now).merging(["source": "server"]) { $1 }])
        case "manager source on a js_error": text = replace("\"source\":\"osb\"", "\"source\":\"manager\"")
        case "unknown top-level field": text = replace("{\"events\":", "{\"extra\":1,\"events\":")
        case "perf field": text = replace("{\"events\":", "{\"perf\":{\"at\":\"2026-11-12T15:00:00Z\",\"span_s\":1800,\"samples\":30},\"events\":")
        case "unknown event field": text = replace("\"count\":3,", "\"count\":3,\"name\":\"x\",")
        case "unknown error field": text = replace("\"handled\":true", "\"handled\":true,\"message\":\"x\"")
        case "hresult from the page": text = replace("\"handled\":true", "\"handled\":true,\"hresult\":\"0x80004005\"")
        case "manager origin": text = replace("\"origin\":\"guard\"", "\"origin\":\"caught\"")
        case "window in context": text = replace("\"phase\":\"world\"", "\"phase\":\"world\",\"window\":3")
        case "window in trail": text = replace("\"k\":\"operation-start\"", "\"k\":\"operation-start\",\"w\":1")
        case "goldChange in details": text = replace("\"distance\":12.5", "\"distance\":12.5,\"goldChange\":10")
        case "null event field": text = replace("\"count\":3,", "\"count\":null,")
        case "null optional field": text = replace("\"module\":\"quest\"", "\"module\":null")
        case "null event": text = replace("\"events\":[", "\"events\":[null,")
        case "duplicate property": text = replace("\"count\":3,", "\"count\":3,\"count\":4,")
        case "eleven events": text = OsbSamples.message((1...11).map { OsbSamples.errorEvent(now, fp: String(format: "%016x", $0)) })
        case "no events": text = OsbSamples.message([])
        case "reserved fingerprint": text = replace("3a91c2d4e5f60718", DiagnosticFormats.reservedFingerprint)
        case "uppercase fingerprint": text = replace("3a91c2d4e5f60718", "3A91C2D4E5F60718")
        case "seconds in at": text = replace("\"at\":\"2026-11-12T15:00:00Z\"", "\"at\":\"2026-11-12T15:00:30Z\"")
        case "at a week old": text = replace("\"at\":\"2026-11-12T15:00:00Z\"", "\"at\":\"2026-11-04T15:00:00Z\"")
        case "decimal count": text = replace("\"count\":3,", "\"count\":3.0,")
        case "zero count": text = replace("\"count\":3,", "\"count\":0,")
        case "uptime not a multiple of 60": text = replace("\"uptime_s\":3600", "\"uptime_s\":3601")
        case "two decimals in details": text = replace("\"distance\":12.5", "\"distance\":12.55")
        case "control character": text = replace("\"quest\"", "\"quest\\u0007\"")
        case "lone surrogate": text = replace("\"quest\"", "\"quest\\ud800\"")
        case "process_failed kind": text = replace("\"kind\":\"js_error\"", "\"kind\":\"process_failed\"")
        case "stop object on an error": text = replace("\"count\":3,", "\"count\":3,\"stop\":{\"code\":\"other\",\"source\":\"stop\"},")
        case "bad mode": text = replace("\"mode\":\"town\"", "\"mode\":\"sleeping\"")
        case "bad stop source": text = replace("\"source\":\"stop\"", "\"source\":\"player\"")
        case "template with forbidden characters": text = replace("Cannot read properties", "Cannot read \\\"x\\\"")
        case "seventeen frames":
            errorBody["frames"] = Array(repeating: "ext", count: 17)
            error["error"] = errorBody
            text = OsbSamples.message([error])
        case "twenty-one trail entries":
            error["trail"] = Array(repeating: ["s": 0, "l": "info", "c": "town", "k": "legacy"] as [String: Any], count: 21)
            text = OsbSamples.message([error])
        case "wrong type": text = replace("\"type\":\"osb-diagnostics-batch\"", "\"type\":\"status\"")
        case "comment": text = replace("{\"events\":", "{/* x */\"events\":")
        case "trailing comma": text = String(valid.dropLast()) + ",}"
        case "not an object": text = "[\(valid)]"
        default:
            Issue.record("unknown case \(broken)")
            return
        }
        #expect(!text.isEmpty && text != valid, "\(broken) did not change the message")
        #expect(try parse(text) == nil, "\(broken) was accepted")
    }

    @Test func aMessageOver12KbIsRejectedEvenWhenEveryFieldIsValid() throws {
        let events = (1...10).map { index -> [String: Any] in
            var event = OsbSamples.errorEvent(Self.now, fp: String(format: "%016x", index))
            event["trail"] = Array(repeating: ["s": -1, "l": "info", "c": "movement", "k": "approach-abandoned"] as [String: Any], count: 20)
            return event
        }
        let text = OsbSamples.message(events)

        #expect(text.utf8.count > OsbPageBatch.maxBytes)
        #expect(try parse(text) == nil)
    }

    @Test func thePerfAnswerIsParsedStrictly() {
        let good = OsbSamples.perfAnswer(CaptureSamples.at("2026-11-12T14:30:00Z"))
        let entry = OsbPageBatch.parsePerf(good, now: Self.now)

        #expect(entry?.tick?.max == 41.0)
        #expect(entry?.gap?.p50 == 100.1)
        #expect(entry?.longTasks == PerfLongTasks(count: 3, totalMs: 412.0))
        #expect(entry?.jsHeapUsed == 131)
        for broken in [
            good.replacingOccurrences(of: "\"samples\":30", with: "\"samples\":30,\"cpu_pct\":{}"),
            good.replacingOccurrences(of: "\"samples\":30", with: "\"samples\":null"),
            good.replacingOccurrences(of: "\"late_pct\":0.3", with: "\"late_pct\":101"),
            good.replacingOccurrences(of: "\"p50\":1.2", with: "\"p50\":-1"),
            good.replacingOccurrences(of: "osb-diagnostics-perf", with: "osb-diagnostics-batch"),
            good.replacingOccurrences(of: "\"used\":131", with: "\"used\":131,\"extra\":1"),
            good.replacingOccurrences(of: "\"span_s\":1800", with: "\"span_s\":\"" + String(repeating: "9", count: 2100) + "\""),
        ] {
            #expect(broken != good)
            #expect(OsbPageBatch.parsePerf(broken, now: Self.now) == nil, "accepted \(broken.prefix(120))")
        }
    }
}

@Suite(.serialized)
struct OsbPageReceiverTests {
    @Test func dg27_aHostilePagesStringsOutsideTheVocabularyAreMapped() throws {
        let kit = try PageKit()
        let now = kit.now
        var error = OsbSamples.errorEvent(now, template: "Leaked secretword from pagezz (reading <q>) 42", frames: ["Evilzz.steal@1:2", "Quest.observe@14210:31", "ext"])
        var body = error["error"] as? [String: Any] ?? [:]
        body["type"] = "EvilzzError"
        body["inner"] = ["EvilzzInner", "RangeError"]
        body["module"] = "evilzz-module"
        error["error"] = body
        error["context"] = ["phase": "evilzz-phase", "mode": "town", "town_phase": "evilzz-walk"] as [String: Any]
        error["trail"] = [["s": -1, "l": "info", "c": "evilzz", "k": "evilzz-code", "o": "evilzz", "e": "evilzz"] as [String: Any]]
        var stop = OsbSamples.stopEvent(now)
        stop["stop"] = ["code": "evilzz-stop", "source": "stop"]
        var warn = OsbSamples.warnEvent(now)
        warn["warn"] = ["category": "evilzz", "code": "evilzz", "error_class": "evilzz", "refusal": ["source": "evilzz", "reason": "evilzz", "native": 1] as [String: Any]] as [String: Any]

        #expect(kit.offer(OsbSamples.message([error, stop, warn]), window: 3))
        let sent = try #require(kit.body())

        #expect(!sent.text.lowercased().contains("evilzz"))
        #expect(!sent.text.contains("secretword"))
        #expect(!sent.text.contains("pagezz"))
        let events = kit.osbEvents(sent.root)
        #expect(events.count == 3)
        let mapped = try #require(events.first { $0["kind"] as? String == "js_error" })
        let detail = try #require(mapped["error"] as? [String: Any])
        #expect(detail["type"] as? String == OsbVocabulary.fallbackType)
        #expect(detail["inner"] as? [String] == [OsbVocabulary.fallbackType, "RangeError"])
        #expect(detail["module"] == nil)
        #expect(detail["template"] as? String == "<x> <x> from <x> (reading <q>) 42")
        #expect(detail["frames"] as? [String] == ["?@1:2", "Quest.observe@14210:31", "ext"])
        let context = try #require(mapped["context"] as? [String: Any])
        #expect(context["phase"] as? String == OsbVocabulary.other)
        #expect(context["town_phase"] == nil)
        #expect(context["window"] as? Int == 3)
        let trail = try #require((mapped["trail"] as? [[String: Any]])?.first)
        #expect(trail["c"] as? String == OsbVocabulary.other)
        #expect(trail["k"] as? String == OsbVocabulary.other)
        #expect(trail["o"] == nil && trail["e"] == nil)
        let stopped = try #require(events.first { $0["kind"] as? String == "bot_stop" }?["stop"] as? [String: Any])
        #expect(stopped["code"] as? String == OsbVocabulary.other)
        let warned = try #require(events.first { $0["kind"] as? String == "warn" }?["warn"] as? [String: Any])
        #expect(warned["category"] as? String == OsbVocabulary.other)
        #expect(warned["error_class"] == nil)
        #expect((warned["refusal"] as? [String: Any])?["reason"] as? String == OsbVocabulary.other)
        #expect(kit.receiver.counts.accepted == 1)
        #expect(kit.receiver.counts.mapped == 17)
    }

    @Test func dg25_aCanaryThePageLetThroughNeverLeavesTheApp() throws {
        let kit = try PageKit()
        kit.terms.add(PageKit.character)
        let now = kit.now
        let leaky = OsbSamples.errorEvent(
            now,
            template: "Cannot read \(PageKit.accountName) at /Users/\(PageKit.macUser)/x",
            frames: ["\(PageKit.loginId).observe@14210:31", "\(PageKit.character).observe@1:2", "Quest.observe@14210:31", "ext"]
        )
        let message = OsbSamples.message([leaky, OsbSamples.stopEvent(now), OsbSamples.warnEvent(now)])
        let canaries = [PageKit.accountName, PageKit.loginId, PageKit.macUser, PageKit.character]

        let withoutScrub = try #require(OsbPageBatch.parse(message, now: now, vocabulary: try OsbSamples.vocabulary()))
        let unscrubbed = withoutScrub.events.map { DiagnosticJson.eventText($0) }.joined()
        for canary in canaries {
            #expect(unscrubbed.contains(canary), "the vocabulary alone already removes \(canary); the canary does not test the re-scrub")
        }

        #expect(kit.offer(message, window: 2))
        let sent = try #require(kit.body())

        for canary in canaries {
            #expect(!sent.text.lowercased().contains(canary.lowercased()), "\(canary) leaked")
        }
        #expect(!sent.text.contains("/Users/"))
        let events = kit.osbEvents(sent.root)
        #expect(events.count == 3)
        #expect(events.allSatisfy { ($0["context"] as? [String: Any])?["window"] as? Int == 2 })
        let error = try #require(events.first { $0["kind"] as? String == "js_error" }?["error"] as? [String: Any])
        #expect((error["frames"] as? [String])?.contains("Quest.observe@14210:31") == true)
    }

    @Test func dg13_batchesAreTakenOnlyWhileRecording() throws {
        let kit = try PageKit(consent: false)
        #expect(!kit.hub.recording)
        #expect(!kit.offer(OsbSamples.valid(kit.now), window: 1))
        #expect(kit.body() == nil)

        kit.consent.value = true
        kit.hub.consentChanged()
        kit.hub.applyServer(CaptureSamples.on)
        #expect(kit.hub.recording)
        #expect(kit.offer(OsbSamples.valid(kit.now), window: 1))
        #expect(kit.receiver.counts.accepted == 1)

        kit.consent.value = false
        kit.hub.consentChanged()
        kit.clock.advance(60)
        #expect(!kit.offer(OsbSamples.valid(kit.now), window: 1))
        #expect(kit.body() == nil)
        #expect(kit.hub.limiter.peek(max: 50).events.isEmpty)
        #expect(kit.receiver.counts.afterOff == 2)
    }

    @Test func dg13_nothingFromAPageIsKeptWhileTheServerFlagIsOff() throws {
        let kit = try PageKit(allow: false)
        kit.receiver.rotation.present(1, at: kit.now)
        kit.capture.tickOsbPerf()

        #expect(!kit.offer(OsbSamples.valid(kit.now), window: 1))
        #expect(!kit.answer(OsbSamples.perfAnswer(kit.now), window: 1))
        #expect(kit.hub.peekOsbPerf() == nil)
        #expect(kit.body() == nil)

        kit.hub.applyServer(CaptureSamples.on)
        #expect(kit.offer(OsbSamples.valid(kit.now), window: 1))
        kit.hub.applyServer(DiagnosticsConfig(enabled: false, perf: false))
        #expect(kit.body() == nil)
        #expect(kit.hub.limiter.peek(max: 50).events.isEmpty)
    }

    @Test func aBatchQueuedBeforeTheSwitchGoesOffIsDropped() throws {
        let kit = try PageKit()
        let queue = DispatchQueue(label: "osb.test.page-queue")
        let receiver = OsbPageBatchReceiver(hub: kit.hub, vocabulary: try OsbSamples.vocabulary(), queue: queue)
        queue.suspend()
        #expect(receiver.offer(OsbSamples.valid(kit.now), window: 1))
        kit.consent.value = false
        kit.hub.consentChanged()
        kit.consent.value = true
        kit.hub.consentChanged()
        kit.hub.applyServer(CaptureSamples.on)
        queue.resume()
        receiver.drain()

        #expect(kit.hub.recording)
        #expect(receiver.counts.accepted == 0)
        #expect(receiver.counts.afterOff == 1)
        #expect(kit.hub.limiter.peek(max: 50).events.isEmpty)
    }

    @Test func tooFrequentOversizeAndInvalidMessagesAreDroppedAndCounted() throws {
        let kit = try PageKit()
        let valid = OsbSamples.valid(kit.now)

        #expect(kit.offer(valid, window: 1))
        kit.clock.advance(30)
        #expect(kit.offer(valid, window: 1))
        #expect(kit.offer(valid, window: 2))
        kit.clock.advance(30)
        #expect(kit.offer("{\"type\":\"osb-diagnostics-batch\",\"events\":[null]}", window: 1))
        #expect(kit.offer(valid, window: 1))
        #expect(!kit.offer("{\"type\":\"osb-diagnostics-batch\",\"events\":[\"" + String(repeating: "a", count: OsbPageBatch.maxBytes) + "\"]}", window: 3))
        #expect(kit.offer(valid.replacingOccurrences(of: "\"source\":\"osb\"", with: "\"source\":\"manager\""), window: 4))
        #expect(kit.offer(valid.replacingOccurrences(of: "\"count\":3,", with: "\"count\":3,\"name\":\"x\","), window: 5))

        var expected = PageBatchCounts()
        expected.accepted = 3
        expected.invalid = 3
        expected.oversize = 1
        expected.tooFrequent = 1
        expected.mapped = 0
        #expect(kit.receiver.counts == expected)
        let dropped = kit.hub.limiter.peek(max: 50).dropped
        #expect(dropped.rateLimited == 1)
        #expect(dropped.oversize == 1)
    }

    @Test func aFloodFillsOnlyThePageQueue() throws {
        let kit = try PageKit()
        let message = OsbSamples.valid(kit.now)
        for _ in 0..<200 {
            kit.receiver.offer(message, window: 1)
        }
        kit.receiver.drain()

        let counts = kit.receiver.counts
        #expect(counts.accepted == 1)
        #expect(counts.accepted + counts.tooFrequent == 200)
        kit.capture.gpuFailed("GPUDevice was lost", retries: 1, context: nil)
        kit.capture.drain()
        #expect(kit.hub.limiter.peek(max: 50).events.contains { $0.kind == .gpuFailed })
    }

    @Test func withoutAVocabularyNoPageMessageIsTaken() throws {
        let kit = try PageKit(vocabulary: .some(nil))

        #expect(!kit.receiver.isAvailable)
        #expect(!kit.offer(OsbSamples.valid(kit.now), window: 1))
        #expect(kit.receiver.counts.afterOff == 1)
    }
}

@Suite(.serialized)
struct OsbPerfRotationTests {
    @Test func dg26_thePerfRotationAsksOneWindowPerSpanAndDropsUnaskedOrSecondAnswers() throws {
        let kit = try PageKit()
        let rotation = kit.receiver.rotation
        rotation.present(1, at: kit.now)
        rotation.present(2, at: kit.now)
        kit.capture.tickOsbPerf()

        #expect(rotation.wanted(1, at: kit.now) != 0)
        #expect(rotation.wanted(2, at: kit.now) == 0)
        #expect(rotation.wanted(nil, at: kit.now) == 0)
        let answer = OsbSamples.perfAnswer(CaptureSamples.at("2026-11-12T14:30:00Z"))
        #expect(kit.answer(answer, window: 2))
        #expect(kit.answer(answer, window: 1))
        #expect(kit.answer(answer, window: 1))
        #expect(kit.receiver.counts.perfAccepted == 1)
        #expect(kit.receiver.counts.perfNotAsked == 2)
        #expect(rotation.wanted(1, at: kit.now) == 0)

        let sent = try #require(kit.body())
        let osbPerf = try #require(sent.root["osb_perf"] as? [[String: Any]])
        #expect(osbPerf.count == 1)
        #expect(osbPerf[0]["app_version"] as? String == OsbSamples.osbVersion)
        #expect((osbPerf[0]["gap_ms"] as? [String: Any])?["max"] as? Double == 912)
        #expect(kit.body() == nil)

        kit.clock.advance(1800)
        rotation.present(1, at: kit.now)
        rotation.present(2, at: kit.now)
        kit.capture.tickOsbPerf()
        #expect(rotation.wanted(2, at: kit.now) != 0)
        #expect(rotation.wanted(1, at: kit.now) == 0)

        kit.clock.advance(1800)
        rotation.present(1, at: kit.now)
        rotation.present(2, at: kit.now)
        kit.capture.tickOsbPerf()
        #expect(rotation.wanted(1, at: kit.now) != 0)
    }

    @Test func aWindowThatStoppedReportingIsNotAsked() throws {
        let kit = try PageKit()
        let rotation = kit.receiver.rotation
        rotation.present(1, at: kit.now)
        kit.clock.advance(OsbPerfRotation.presentFor + 1)
        rotation.present(2, at: kit.now)
        kit.capture.tickOsbPerf()

        #expect(rotation.wanted(1, at: kit.now) == 0)
        #expect(rotation.wanted(2, at: kit.now) != 0)
        rotation.gone(2)
        kit.clock.advance(1800)
        kit.capture.tickOsbPerf()
        #expect(rotation.wanted(2, at: kit.now) != 0)
        kit.clock.advance(OsbPerfRotation.answerGrace)
        kit.capture.tickOsbPerf()
        #expect(rotation.wanted(2, at: kit.now) == 0)
    }

    @Test func dg26_noPerfIsAskedOrKeptWhileThePerfFlagIsOff() throws {
        let kit = try PageKit()
        kit.capture.configure { DiagnosticsConfig(enabled: true, perf: false) }
        kit.receiver.rotation.present(1, at: kit.now)
        kit.capture.tickOsbPerf()

        #expect(kit.receiver.rotation.wanted(1, at: kit.now) == 0)
        #expect(kit.answer(OsbSamples.perfAnswer(CaptureSamples.at("2026-11-12T14:30:00Z")), window: 1))
        #expect(kit.receiver.counts.perfNotAsked == 1)
        #expect(kit.hub.peekOsbPerf() == nil)

        kit.hub.keepOsbPerf(OsbPerfEntry(entry: PerfEntry(at: CaptureSamples.at("2026-11-12T14:30:00Z"), spanSeconds: 1800, samples: 30), appVersion: OsbSamples.osbVersion), session: kit.hub.session)
        #expect(kit.body(DiagnosticsConfig(enabled: true, perf: false)) == nil)
    }

    @Test func aKeptAnswerIsDroppedWhenConsentIsWithdrawn() throws {
        let kit = try PageKit()
        kit.receiver.rotation.present(1, at: kit.now)
        kit.capture.tickOsbPerf()
        #expect(kit.answer(OsbSamples.perfAnswer(CaptureSamples.at("2026-11-12T14:30:00Z")), window: 1))
        #expect(kit.hub.peekOsbPerf() != nil)

        kit.consent.value = false
        kit.hub.consentChanged()

        #expect(kit.hub.peekOsbPerf() == nil)
        #expect(kit.body() == nil)
    }
}
