import Foundation
@testable import OsbManagerCore

final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    struct Tagged: Clock {
        let base: ManualClock
        let tag: String

        var now: Instant { base.now }

        var minimumResolution: Duration { base.minimumResolution }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try await base.sleep(until: deadline, tag: tag)
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let tag: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var resumed = 0

    var now: Instant { lock.withLock { current } }

    var minimumResolution: Duration { .nanoseconds(1) }

    var elapsed: Duration { now.offset }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    var activity: Int { lock.withLock { resumed * 1000 + sleepers.count } }

    func sleeperCount(_ tag: String) -> Int {
        lock.withLock { sleepers.filter { $0.tag == tag }.count }
    }

    func tagged(_ tag: String) -> Tagged {
        Tagged(base: self, tag: tag)
    }

    private enum Registration {
        case ready
        case cancelled
        case waiting
    }

    private func register(_ id: UUID, _ deadline: Instant, _ tag: String, _ continuation: CheckedContinuation<Void, Error>) -> Registration {
        lock.withLock {
            if deadline <= current { return .ready }
            if Task.isCancelled { return .cancelled }
            sleepers.append(Sleeper(id: id, deadline: deadline, tag: tag, continuation: continuation))
            return .waiting
        }
    }

    private func remove(_ id: UUID) -> Sleeper? {
        lock.withLock { sleepers.firstIndex { $0.id == id }.map { sleepers.remove(at: $0) } }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await sleep(until: deadline, tag: "")
    }

    func sleep(until deadline: Instant, tag: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                switch register(id, deadline, tag, continuation) {
                case .ready: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .waiting: break
                }
            }
        } onCancel: {
            remove(id)?.continuation.resume(throwing: CancellationError())
        }
    }

    private func takeDue(upTo target: Instant) -> Sleeper? {
        lock.withLock {
            let due = sleepers.enumerated().filter { $0.element.deadline <= target }.min { $0.element.deadline < $1.element.deadline }
            guard let due else {
                current = target
                return nil
            }
            if due.element.deadline > current { current = due.element.deadline }
            sleepers.remove(at: due.offset)
            resumed += 1
            return due.element
        }
    }

    func advance(by duration: Duration, settle: () async -> Void) async {
        let target = now.advanced(by: duration)
        await settle()
        while let due = takeDue(upTo: target) {
            due.continuation.resume()
            await settle()
        }
        await settle()
    }
}

struct SeenRequest {
    let method: String
    let path: String
    let at: Duration
    let headers: [String: String]
    let body: Data
    let onMainThread: Bool

    var endpoint: String { "\(method) \(path)" }
    var bodyText: String { String(decoding: body, as: UTF8.self) }
    var authorization: String { headers["Authorization"] ?? "" }
    var userAgent: String { headers["User-Agent"] ?? "" }
    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
}

enum Reply {
    case respond(status: Int, headers: [String: String], body: String)
    case hang
    case redirect(String)

    static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Reply {
        .respond(status: status, headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first }, body: body)
    }

    static func problem(_ status: Int, _ code: String, retryAfter: Int? = nil) -> Reply {
        var headers: [String: String] = [:]
        if let retryAfter { headers["Retry-After"] = String(retryAfter) }
        return .json(status, "{\"type\":\"https://osb.lol/errors/\(code)\",\"title\":\"x\",\"status\":\(status),\"code\":\"\(code)\"}", headers: headers)
    }
}

final class FakeServer: @unchecked Sendable {
    nonisolated(unsafe) private static var registry: [String: FakeServer] = [:]
    private static let registryLock = NSLock()

    let host: String
    private let lock = NSLock()
    private var seen: [SeenRequest] = []
    private var routes: [String: (SeenRequest) -> Reply] = [:]
    private var sequences: [String: [Reply]] = [:]
    private var flying = 0
    private var peak = 0
    private var stalls = 0
    private var served = 0
    private let clock: ManualClock

    init(clock: ManualClock, host: String = "fake-\(UUID().uuidString.lowercased()).test") {
        self.clock = clock
        self.host = host
        Self.registryLock.withLock { Self.registry[host] = self }
    }

    deinit {
        Self.registryLock.withLock { _ = Self.registry.removeValue(forKey: host) }
    }

    var baseUrl: URL { URL(string: "https://\(host)/v1") ?? URL(fileURLWithPath: "/") }

    var requests: [SeenRequest] { lock.withLock { seen } }

    var inFlight: Int { lock.withLock { flying } }

    var peakInFlight: Int { lock.withLock { peak } }

    var stalled: Int { lock.withLock { stalls } }

    var activity: Int { lock.withLock { seen.count * 1000 + flying + served } }

    func to(_ endpoint: String) -> [SeenRequest] {
        requests.filter { $0.endpoint == endpoint }
    }

    func route(_ endpoint: String, _ handler: @escaping (SeenRequest) -> Reply) {
        lock.withLock { routes[endpoint] = handler }
    }

    func routeSequence(_ endpoint: String, _ replies: [Reply]) {
        lock.withLock { sequences[endpoint] = replies }
    }

    func failEverything(_ status: Int) {
        for endpoint in ["GET /v1/config", "POST /v1/installs", "POST /v1/telemetry", "PUT /v1/installs/me/consent", "POST /v1/reports", "DELETE /v1/installs/me", "POST /v1/diagnostics"] {
            route(endpoint) { _ in Reply.problem(status, "server_error") }
        }
    }

    func hangEverything() {
        for endpoint in ["GET /v1/config", "POST /v1/installs", "POST /v1/telemetry", "PUT /v1/installs/me/consent", "POST /v1/reports", "DELETE /v1/installs/me", "POST /v1/diagnostics"] {
            route(endpoint) { _ in Reply.hang }
        }
    }

    func hang(_ endpoint: String) {
        route(endpoint) { _ in Reply.hang }
    }

    static func server(for host: String?) -> FakeServer? {
        guard let host else { return nil }
        return registryLock.withLock { registry[host] }
    }

    func receive(_ request: URLRequest) -> Reply {
        let seenRequest = SeenRequest(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            at: clock.elapsed,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request),
            onMainThread: Thread.isMainThread
        )
        return lock.withLock {
            seen.append(seenRequest)
            flying += 1
            peak = max(peak, flying)
            if var sequence = sequences[seenRequest.endpoint], !sequence.isEmpty {
                let reply = sequence.removeFirst()
                sequences[seenRequest.endpoint] = sequence
                return reply
            }
            return (routes[seenRequest.endpoint] ?? Self.defaultReply)(seenRequest)
        }
    }

    func stall() {
        lock.withLock { stalls += 1 }
    }

    func finished(stalled: Bool) {
        lock.withLock {
            flying -= 1
            if stalled { stalls -= 1 }
            served += 1
        }
    }

    private static func defaultReply(_ request: SeenRequest) -> Reply {
        switch request.endpoint {
        case "GET /v1/config":
            return .json(200, #"{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true,"screenshots":true},"client_ok":true,"message":null}"#)
        case "POST /v1/installs":
            return .json(201, #"{"install_id":"x","status":"quarantined"}"#)
        case "POST /v1/telemetry":
            return .json(202, #"{"accepted":1,"next_after_s":600}"#)
        case "POST /v1/reports":
            return .json(201, #"{"code":"R-7K3Q9XAB","screenshot":"none"}"#)
        case "POST /v1/diagnostics":
            return .json(202, #"{"accepted_events":1,"accepted_perf":0,"next_after_s":600}"#)
        case "PUT /v1/installs/me/consent", "DELETE /v1/installs/me":
            return .respond(status: 204, headers: [:], body: "")
        case "GET /v1/installs/me/export":
            return .json(200, #"{"install":{}}"#)
        default:
            return .json(404, #"{"code":"not_found"}"#)
        }
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class FakeServerProtocol: URLProtocol {
    private var server: FakeServer?
    private var stalled = false

    override class func canInit(with request: URLRequest) -> Bool {
        FakeServer.server(for: request.url?.host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = FakeServer.server(for: request.url?.host), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        self.server = server
        switch server.receive(request) {
        case .hang:
            stalled = true
            server.stall()
        case .redirect(let location):
            stalled = true
            server.stall()
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])
            if let response, let target = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
        case .respond(let status, let headers, let body):
            if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            }
            server.finished(stalled: false)
            self.server = nil
        }
    }

    override func stopLoading() {
        if let server {
            server.finished(stalled: stalled)
            self.server = nil
        }
    }
}

final class FakeStatuses: StatusSource, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(id: String, server: String, status: BotStatus)] = []
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    func publish(_ id: String, server: String = "ExampleServer", _ status: BotStatus) {
        lock.withLock {
            entries.removeAll { $0.id == id }
            entries.append((id, server, status))
        }
    }

    func remove(_ id: String) {
        lock.withLock { entries.removeAll { $0.id == id } }
    }

    func snapshot() async throws -> [AccountSnapshot] {
        let moment = now()
        return lock.withLock { entries.map { AccountSnapshot(accountId: $0.id, server: $0.server, status: $0.status, receivedAt: moment) } }
    }
}

struct ThrowingStatuses: StatusSource {
    let counter: CallCounter

    func snapshot() async throws -> [AccountSnapshot] {
        counter.increment()
        throw TelemetryTestError.injected
    }
}

enum TelemetryTestError: Error {
    case injected
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] { lock.withLock { stored } }

    func add(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}

func hunting(_ character: String = "Example", level: Int = 87) -> BotStatus {
    var status = BotStatus()
    status.botVersion = "2.0.4"
    status.phase = "world"
    status.character = character
    status.inWorld = true
    status.level = level
    status.gold = 123_456_789
    status.hpPercent = 92
    status.mpPercent = 70
    status.hunting = true
    status.returnScrolls = 12
    status.reverseScrolls = 3
    status.session = SessionStats(milliseconds: 5_400_000, kills: 812, deaths: 1, experience: 48_211_933, gold: 2_210_450, sox: 0)
    return status
}

final class TelemetryKit: @unchecked Sendable {
    static let origin: TimeInterval = 1_800_000_000
    static let clientTag = "client"
    static let serviceTag = "service"
    static let waitLimit: Duration = .seconds(60)

    let clock = ManualClock()
    let server: FakeServer
    let directory: TemporaryDirectory
    let keys = InMemoryInstallKeyStore()
    let logs = LogBox()
    let settings: PrivacySettings
    let outbox: ReportOutbox
    let statuses: FakeStatuses
    let service: TelemetryService
    let diagnostics: DiagnosticsHub
    let client: TelemetryClient
    private let now: @Sendable () -> Date

    var privacyFile: URL { directory.file("privacy.json") }

    init(random: Double = 0.5, source: StatusSource? = nil, privacyFile contents: String? = nil, keyStore: InstallKeyStore? = nil, consent characters: Bool? = nil, sampleDraw: Int = 0, sampleWindows: (@Sendable ([PerfWindowInfo], Date) -> PerfSample)? = nil, directory: TemporaryDirectory = TemporaryDirectory()) throws {
        self.directory = directory
        let clock = self.clock
        let moment: @Sendable () -> Date = { Date(timeIntervalSince1970: Self.origin + clock.elapsed.seconds) }
        now = moment
        server = FakeServer(clock: clock)
        statuses = FakeStatuses(now: moment)
        let logs = self.logs
        if let contents {
            try contents.write(to: directory.file("privacy.json"), atomically: true, encoding: .utf8)
        }
        let store = keyStore ?? keys
        let loaded = PrivacySettings.load(from: directory.file("privacy.json"), keyStore: store, now: moment, log: { logs.add($0) })
        settings = loaded
        if let characters { settings.grant(characters: characters) }
        outbox = ReportOutbox(directory: directory.file("outbox"), now: moment)
        diagnostics = DiagnosticsHub(folder: directory.file("diagnostics"), terms: PrivateTerms.forMachine(.canary, dataFolder: directory.url.path), now: moment, sampleDraw: sampleDraw, consentOn: { loaded.state.granted })
        let configuration = TelemetryClient.makeConfiguration()
        configuration.protocolClasses = [FakeServerProtocol.self]
        client = try TelemetryClient(baseUrl: server.baseUrl, userAgent: "OSBManager/1.2.0 (macOS)", configuration: configuration, clock: SchedulerClock(clock.tagged(Self.clientTag)))
        service = TelemetryService(
            settings: settings,
            client: client,
            statuses: source ?? statuses,
            outbox: outbox,
            appVersion: "1.2.0",
            locale: "en",
            clock: SchedulerClock(clock.tagged(Self.serviceTag)),
            now: moment,
            random: { random },
            log: { logs.add($0) },
            diagnostics: diagnostics,
            diagnosticsEnv: { DiagnosticEnv(osBuild: "26.5.0", webview2: "156.0.8078.80", ramGb: 16, cores: 8, gpuVendor: "apple") },
            sampleWindows: sampleWindows
        )
    }

    deinit {
        let client = self.client
        Task { await client.close() }
    }

    func publish(_ id: String, server: String = "ExampleServer", _ status: BotStatus) {
        statuses.publish(id, server: server, status)
    }

    var idle: Bool {
        get async {
            let armed = clock.sleeperCount(Self.clientTag)
            guard armed == server.inFlight, armed == server.stalled else { return false }
            if armed > 0 { return true }
            guard let sleeping = await service.idleSleepers else { return false }
            return clock.sleeperCount(Self.serviceTag) == sleeping
        }
    }

    func settle() async {
        let deadline = ContinuousClock.now.advanced(by: Self.waitLimit)
        repeat {
            await settleActivity()
        } while !(await idle) && ContinuousClock.now < deadline
    }

    private func settleActivity() async {
        var stable = 0
        var last = -1
        for _ in 0..<400 {
            try? await Task.sleep(nanoseconds: 2_000_000)
            let signature = clock.activity &* 31 &+ server.activity
            if signature == last {
                stable += 1
                if stable >= 10 { return }
            } else {
                stable = 0
                last = signature
            }
        }
    }

    func advance(_ duration: Duration) async {
        await clock.advance(by: duration) { await self.settle() }
    }

    @discardableResult
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: Self.waitLimit)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 200_000)
        }
        return true
    }

    func waitUntilIdle() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: Self.waitLimit)
        while !(await idle) {
            if ContinuousClock.now >= deadline { return false }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 200_000)
        }
        return true
    }

    func advanceStepByStep(_ duration: Duration) async -> Bool {
        var reached = true
        await clock.advance(by: duration) {
            if !(await self.waitUntilIdle()) { reached = false }
        }
        return reached
    }

    func run(for duration: Duration, startService: Bool = true) async {
        if startService { await service.start(sampling: false) }
        await advance(duration)
    }

    func stop() async {
        await service.stop()
    }

    func allowDiagnostics(_ config: DiagnosticsConfig = DiagnosticsConfig(enabled: true, perf: true)) {
        diagnostics.applyServer(config)
    }
}
