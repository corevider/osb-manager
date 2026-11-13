import Foundation

public final class OsbPerfRotation: @unchecked Sendable {
    public static let answerGrace: TimeInterval = 5 * 60
    public static let presentFor: TimeInterval = 15

    private final class Ask {
        let window: Int
        let id: Int
        let at: Date
        var answered = false

        init(window: Int, id: Int, at: Date) {
            self.window = window
            self.id = id
            self.at = at
        }
    }

    private let lock = NSLock()
    private var present: [Int: Date] = [:]
    private var current: Ask?
    private var previous: Ask?
    private var lastAsked = 0
    private var nextId = 0
    private var span: TimeInterval = 0

    public init() {}

    public func present(_ window: Int, at now: Date) {
        lock.withLock { present[window] = now }
    }

    public func gone(_ window: Int) {
        lock.withLock { _ = present.removeValue(forKey: window) }
    }

    public func tick(now: Date, span perfSpan: TimeInterval, enabled: Bool) {
        lock.withLock {
            guard enabled else {
                current = nil
                previous = nil
                return
            }
            span = perfSpan
            if let running = current, now.timeIntervalSince(running.at) < span { return }
            let candidates = present.filter { now.timeIntervalSince($0.value) < Self.presentFor }.map(\.key).sorted()
            guard let first = candidates.first else {
                if current != nil {
                    previous = current
                    current = nil
                }
                return
            }
            let next = candidates.first { $0 > lastAsked } ?? first
            if current != nil { previous = current }
            nextId += 1
            current = Ask(window: next, id: nextId, at: now)
            lastAsked = next
        }
    }

    public func wanted(_ window: Int?, at now: Date) -> Int {
        guard let window else { return 0 }
        return lock.withLock {
            if let ask = current, !ask.answered, ask.window == window { return ask.id }
            if let ask = previous, waiting(ask, window, now) { return ask.id }
            return 0
        }
    }

    public func accept(_ window: Int?, at now: Date) -> Bool {
        guard let window else { return false }
        return lock.withLock {
            if let ask = previous, waiting(ask, window, now) {
                ask.answered = true
                if let same = current, !same.answered, same.window == window {
                    nextId += 1
                    current = Ask(window: window, id: nextId, at: same.at)
                }
                return true
            }
            if let ask = current, !ask.answered, ask.window == window {
                ask.answered = true
                return true
            }
            return false
        }
    }

    private func waiting(_ ask: Ask, _ window: Int, _ now: Date) -> Bool {
        !ask.answered && ask.window == window && now.timeIntervalSince(ask.at) < span + Self.answerGrace
    }
}
