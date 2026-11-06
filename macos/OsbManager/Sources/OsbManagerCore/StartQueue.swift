import Foundation

public final class StartQueue {
    public struct Entry: Equatable {
        public let accountId: String
        public let light: Bool
    }

    private let gap: TimeInterval
    private let clock: () -> Date
    private var waiting: [Entry] = []
    private var lastStart = Date.distantPast

    public init(gap: TimeInterval, clock: @escaping () -> Date = Date.init) {
        self.gap = gap
        self.clock = clock
    }

    public var count: Int { waiting.count }

    public func contains(_ accountId: String) -> Bool {
        waiting.contains { $0.accountId == accountId }
    }

    public func add(_ accountId: String, light: Bool) {
        if !contains(accountId) {
            waiting.append(Entry(accountId: accountId, light: light))
        }
    }

    @discardableResult
    public func remove(_ accountId: String) -> Bool {
        let before = waiting.count
        waiting.removeAll { $0.accountId == accountId }
        return waiting.count < before
    }

    public func clear() {
        waiting.removeAll()
    }

    public func sort(by order: [String]) {
        let positions = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        waiting = waiting.enumerated()
            .sorted { left, right in
                let leftPosition = positions[left.element.accountId] ?? Int.max
                let rightPosition = positions[right.element.accountId] ?? Int.max
                return leftPosition != rightPosition ? leftPosition < rightPosition : left.offset < right.offset
            }
            .map(\.element)
    }

    public func takeDue() -> Entry? {
        let now = clock()
        guard !waiting.isEmpty, now.timeIntervalSince(lastStart) >= gap else { return nil }
        lastStart = now
        return waiting.removeFirst()
    }

    public func wait(for accountId: String) -> TimeInterval? {
        guard let position = waiting.firstIndex(where: { $0.accountId == accountId }) else { return nil }
        let first = lastStart.addingTimeInterval(gap).timeIntervalSince(clock())
        return max(first, 0) + gap * Double(position)
    }
}
