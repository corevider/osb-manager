import Foundation

public enum RecordOutcome: Equatable, Sendable {
    case added
    case merged
    case rateLimited
    case sampledOut
}

public enum DiagnosticRules {
    public static let maxPerHour = 30
    public static let maxPerDay = 200
    public static let hour: TimeInterval = 3600
    public static let day: TimeInterval = 24 * 3600

    public static func sampledIn(draw: Int, percent: Int) -> Bool {
        draw < DiagnosticFormats.clamp(percent, 0, 100)
    }

    public static func admits(acceptedAt: [Date], now: Date) -> Bool {
        let today = acceptedAt.filter { now.timeIntervalSince($0) < day }
        let lastHour = today.filter { now.timeIntervalSince($0) < hour }
        return today.count < maxPerDay && lastHour.count < maxPerHour
    }

    public static func mayResend(lastSent: Date?, now: Date) -> Bool {
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) >= hour
    }

    public static func merged(_ existing: Int, _ added: Int) -> Int {
        DiagnosticFormats.cappedSum(existing, added)
    }
}

public final class DiagnosticLimiter: @unchecked Sendable {
    public static let maxPending = DiagnosticRules.maxPerDay + 10

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var pending: [String: DiagnosticEvent] = [:]
    private var order: [String] = []
    private var lastSent: [String: Date] = [:]
    private var trailSent: Set<String> = []
    private var accepted: [Date] = []
    private var rateLimited = 0
    private var oversize = 0
    private var samplePercentValue: Int

    public let sampleDraw: Int

    public init(now: @escaping @Sendable () -> Date, sampleDraw: Int = 0, samplePercent: Int = 100) {
        self.now = now
        self.sampleDraw = sampleDraw
        samplePercentValue = samplePercent
    }

    public var samplePercent: Int {
        get { lock.withLock { samplePercentValue } }
        set { lock.withLock { samplePercentValue = newValue } }
    }

    public var pendingCount: Int {
        lock.withLock { pending.count }
    }

    public func record(_ candidate: DiagnosticEvent) -> RecordOutcome {
        guard DiagnosticRules.sampledIn(draw: sampleDraw, percent: samplePercent) else { return .sampledOut }
        let moment = now()
        return lock.withLock {
            if var existing = pending[candidate.fingerprint] {
                existing.count = DiagnosticRules.merged(existing.count, candidate.count)
                pending[candidate.fingerprint] = existing
                return .merged
            }
            if candidate.kind != .runEnd {
                accepted.removeAll { moment.timeIntervalSince($0) >= DiagnosticRules.day }
                guard DiagnosticRules.admits(acceptedAt: accepted, now: moment), pending.count < Self.maxPending else {
                    rateLimited = DiagnosticRules.merged(rateLimited, 1)
                    return .rateLimited
                }
                accepted.append(moment)
            }
            var stored = candidate
            if stored.trail?.isEmpty == false {
                if trailSent.contains(candidate.fingerprint) {
                    stored.trail = nil
                } else {
                    trailSent.insert(candidate.fingerprint)
                }
            } else {
                stored.trail = nil
            }
            pending[candidate.fingerprint] = stored
            order.append(candidate.fingerprint)
            return .added
        }
    }

    public func countRateLimited(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock { rateLimited = DiagnosticRules.merged(rateLimited, count) }
    }

    public func countOversize(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock { oversize = DiagnosticRules.merged(oversize, count) }
    }

    public func peek(max: Int = DiagnosticFormats.maxEvents) -> (events: [DiagnosticEvent], dropped: DroppedCounts) {
        let moment = now()
        return lock.withLock {
            let ready = order.filter { DiagnosticRules.mayResend(lastSent: lastSent[$0], now: moment) }.prefix(max)
            return (ready.compactMap { pending[$0] }, DroppedCounts(rateLimited: rateLimited, oversize: oversize))
        }
    }

    public func take(max: Int = DiagnosticFormats.maxEvents) -> (events: [DiagnosticEvent], dropped: DroppedCounts) {
        let moment = now()
        return lock.withLock {
            let ready = Array(order.filter { DiagnosticRules.mayResend(lastSent: lastSent[$0], now: moment) }.prefix(max))
            let events = ready.compactMap { pending[$0] }
            for fingerprint in ready {
                pending[fingerprint] = nil
                lastSent[fingerprint] = moment
            }
            order.removeAll { ready.contains($0) }
            let dropped = DroppedCounts(rateLimited: rateLimited, oversize: oversize)
            rateLimited = 0
            oversize = 0
            return (events, dropped)
        }
    }

    public func giveBack(_ events: [DiagnosticEvent], dropped: DroppedCounts) {
        lock.withLock {
            for event in events.reversed() {
                lastSent[event.fingerprint] = nil
                var restored = event
                if let existing = pending[event.fingerprint] {
                    restored.count = DiagnosticRules.merged(existing.count, event.count)
                    order.removeAll { $0 == event.fingerprint }
                }
                pending[event.fingerprint] = restored
                order.insert(event.fingerprint, at: 0)
            }
            rateLimited = DiagnosticRules.merged(rateLimited, dropped.rateLimited)
            oversize = DiagnosticRules.merged(oversize, dropped.oversize)
        }
    }

    public func clear() {
        lock.withLock {
            pending.removeAll()
            order.removeAll()
            lastSent.removeAll()
            trailSent.removeAll()
            accepted.removeAll()
            rateLimited = 0
            oversize = 0
        }
    }
}
