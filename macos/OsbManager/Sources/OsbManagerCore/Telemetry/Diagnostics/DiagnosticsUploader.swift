import Foundation

public struct PreparedDiagnostics: Sendable {
    public let body: Data
    public let session: Int
    let taken: [DiagnosticEvent]
    let dropped: DroppedCounts
    let perf: [PerfEntry]
    let pendingIds: [String]
    var osbPerf: OsbPerfEntry?
}

public final class DiagnosticsUploader: @unchecked Sendable {
    private let hub: DiagnosticsHub
    private let perf: PerfCollector
    private let appVersion: String
    private let envSource: @Sendable () -> DiagnosticEnv
    private let lock = NSLock()
    private var cachedEnv: DiagnosticEnv?

    public init(hub: DiagnosticsHub, perf: PerfCollector, appVersion: String, env: @escaping @Sendable () -> DiagnosticEnv) {
        self.hub = hub
        self.perf = perf
        self.appVersion = appVersion
        envSource = env
    }

    public func hasSomethingToSend(_ config: DiagnosticsConfig) -> Bool {
        build(config, take: false) != nil
    }

    public func preview(_ config: DiagnosticsConfig) -> String? {
        guard let prepared = build(config, take: false),
              let object = try? JSONSerialization.jsonObject(with: prepared.body),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    public func prepare(_ config: DiagnosticsConfig) -> PreparedDiagnostics? {
        build(config, take: true)
    }

    public func commit(_ prepared: PreparedDiagnostics) {
        prepared.pendingIds.forEach(hub.pending.delete(id:))
    }

    public func giveBack(_ prepared: PreparedDiagnostics) {
        guard hub.isCurrent(session: prepared.session) else { return }
        hub.limiter.giveBack(prepared.taken, dropped: prepared.dropped)
        perf.giveBack(prepared.perf)
        if let osb = prepared.osbPerf { hub.returnOsbPerf(osb) }
    }

    private var env: DiagnosticEnv {
        if let cached = lock.withLock({ cachedEnv }) { return cached }
        let fresh = envSource()
        lock.withLock { cachedEnv = fresh }
        return fresh
    }

    private func build(_ config: DiagnosticsConfig, take: Bool) -> PreparedDiagnostics? {
        guard hub.recording, config.enabled else { return nil }
        let session = hub.session
        var events: [DiagnosticEvent] = []
        var pendingIds: [String] = []
        for file in hub.pendingEvents() {
            pendingIds.append(file.id)
            events.append(file.event)
        }
        let room = max(0, DiagnosticFormats.maxEvents - events.count)
        let peeked = hub.limiter.peek(max: room)
        let perfReady = config.perf ? perf.peekReady() : []
        var osbReady = config.perf ? hub.peekOsbPerf() : nil
        guard !events.isEmpty || !peeked.events.isEmpty || !perfReady.isEmpty || osbReady != nil else { return nil }
        var taken = peeked.events
        var dropped = peeked.dropped
        var perfTaken = perfReady
        if take {
            (taken, dropped) = hub.limiter.take(max: room)
            perfTaken = config.perf ? perf.takeReady() : []
            osbReady = config.perf ? hub.takeOsbPerf() : nil
        }
        let batch = DiagnosticBatch(appVersion: appVersion, run: hub.run, env: env, events: events + taken, perf: perfTaken, osbPerf: osbReady.map { [$0] } ?? [], dropped: dropped)
        guard let body = try? DiagnosticJson.batch(batch, terms: hub.terms, now: hub.now()) else {
            if take {
                hub.limiter.giveBack(taken, dropped: dropped)
                perf.giveBack(perfTaken)
                if let osbReady { hub.returnOsbPerf(osbReady) }
            }
            return nil
        }
        if body.events.isEmpty && body.perfCount == 0 && body.osbPerfCount == 0 {
            if take { pendingIds.forEach(hub.pending.delete(id:)) }
            return nil
        }
        var prepared = PreparedDiagnostics(body: body.body, session: session, taken: taken, dropped: dropped, perf: perfTaken, pendingIds: pendingIds)
        prepared.osbPerf = body.osbPerfCount > 0 ? osbReady : nil
        return prepared
    }
}
