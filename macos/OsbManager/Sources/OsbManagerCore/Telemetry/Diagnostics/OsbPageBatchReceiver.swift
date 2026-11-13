import Foundation

public struct PageBatchCounts: Equatable, Sendable {
    public var accepted = 0
    public var invalid = 0
    public var oversize = 0
    public var tooFrequent = 0
    public var afterOff = 0
    public var perfAccepted = 0
    public var perfNotAsked = 0
    public var mapped = 0

    public init() {}
}

public final class OsbPageBatchReceiver: @unchecked Sendable {
    public static let queueCapacity = 4
    public static let minGap: TimeInterval = 55

    public let rotation = OsbPerfRotation()

    private struct Item {
        let json: String
        let window: Int?
        let session: Int
        let at: Date
        let osbVersion: String?
    }

    private let hub: DiagnosticsHub
    private let vocabulary: OsbVocabulary?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var lastByWindow: [Int: Date] = [:]
    private var outstanding = 0
    private var tally = PageBatchCounts()

    public init(hub: DiagnosticsHub, vocabulary: OsbVocabulary?, queue: DispatchQueue) {
        self.hub = hub
        self.vocabulary = vocabulary
        self.queue = queue
        hub.onWipe { [weak self] in self?.forget() }
    }

    public var counts: PageBatchCounts {
        lock.withLock { tally }
    }

    public var isAvailable: Bool { vocabulary != nil }

    @discardableResult
    public func offer(_ json: String, window: Int?) -> Bool {
        push(json, window: window, osbVersion: nil, maxBytes: OsbPageBatch.maxBytes)
    }

    @discardableResult
    public func offerPerf(_ json: String, window: Int?, osbVersion: String?) -> Bool {
        push(json, window: window, osbVersion: osbVersion ?? "", maxBytes: OsbPageBatch.maxPerfBytes)
    }

    public func drain() {
        queue.sync {}
    }

    private func push(_ json: String, window: Int?, osbVersion: String?, maxBytes: Int) -> Bool {
        guard vocabulary != nil, hub.recording else {
            count { $0.afterOff += 1 }
            return false
        }
        guard json.utf16.count <= maxBytes else {
            count { $0.oversize += 1 }
            hub.limiter.countOversize(1)
            return false
        }
        let admitted: Bool = lock.withLock {
            guard outstanding < Self.queueCapacity else {
                tally.tooFrequent += 1
                return false
            }
            outstanding += 1
            return true
        }
        guard admitted else {
            hub.limiter.countRateLimited(1)
            return false
        }
        let item = Item(json: json, window: window, session: hub.session, at: hub.now(), osbVersion: osbVersion)
        queue.async { [weak self] in
            guard let self else { return }
            self.process(item)
            self.lock.withLock { self.outstanding -= 1 }
        }
        return true
    }

    private func process(_ item: Item) {
        guard hub.isCurrent(session: item.session), let vocabulary else {
            count { $0.afterOff += 1 }
            return
        }
        if item.osbVersion != nil {
            processPerf(item)
            return
        }
        let key = item.window ?? 0
        let tooSoon: Bool = lock.withLock {
            guard let previous = lastByWindow[key] else { return false }
            return item.at.timeIntervalSince(previous) < Self.minGap
        }
        if tooSoon {
            count { $0.tooFrequent += 1 }
            hub.limiter.countRateLimited(1)
            return
        }
        guard item.json.utf8.count <= OsbPageBatch.maxBytes else {
            count { $0.oversize += 1 }
            hub.limiter.countOversize(1)
            return
        }
        guard let parsed = OsbPageBatch.parse(item.json, now: hub.now(), vocabulary: vocabulary) else {
            count { $0.invalid += 1 }
            return
        }
        lock.withLock { lastByWindow[key] = item.at }
        count { $0.mapped += parsed.mapped }
        for event in parsed.events {
            guard hub.isCurrent(session: item.session) else { return }
            var placed = event
            var context = event.context ?? DiagnosticContext()
            context.window = item.window
            placed.context = context
            hub.record(placed)
        }
        count { $0.accepted += 1 }
    }

    private func processPerf(_ item: Item) {
        guard item.json.utf8.count <= OsbPageBatch.maxPerfBytes else {
            count { $0.oversize += 1 }
            hub.limiter.countOversize(1)
            return
        }
        guard rotation.accept(item.window, at: item.at) else {
            count { $0.perfNotAsked += 1 }
            hub.limiter.countRateLimited(1)
            return
        }
        guard let entry = OsbPageBatch.parsePerf(item.json, now: hub.now()),
              let version = DiagnosticScrubber.version(item.osbVersion, hub.terms) else {
            count { $0.invalid += 1 }
            return
        }
        hub.keepOsbPerf(OsbPerfEntry(entry: entry, appVersion: version), session: item.session)
        count { $0.perfAccepted += 1 }
    }

    private func forget() {
        lock.withLock { lastByWindow.removeAll() }
    }

    private func count(_ change: (inout PageBatchCounts) -> Void) {
        lock.withLock { change(&tally) }
    }
}
