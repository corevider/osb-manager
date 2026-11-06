import Foundation

public struct Interval: Equatable, Sendable {
    public let start: Int64
    public let end: Int64

    public init(_ start: Int64, _ end: Int64) {
        self.start = start
        self.end = end
    }
}

public struct IntervalSet {
    public private(set) var items: [Interval] = []
    public private(set) var coveredBytes: Int64 = 0

    public init() {}

    public var count: Int { items.count }

    public mutating func add(_ start: Int64, _ end: Int64) {
        guard end > start else { return }
        var start = start
        var end = end
        let first = firstEnding(atOrAfter: start)
        var last = first
        while last < items.count && items[last].start <= end {
            start = min(start, items[last].start)
            end = max(end, items[last].end)
            coveredBytes -= items[last].end - items[last].start
            last += 1
        }
        items.removeSubrange(first..<last)
        items.insert(Interval(start, end), at: first)
        coveredBytes += end - start
    }

    public func contains(_ start: Int64, _ end: Int64) -> Bool {
        guard end > start else { return true }
        let index = firstEnding(atOrAfter: end)
        return index < items.count && items[index].start <= start
    }

    private func firstEnding(atOrAfter position: Int64) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle].end < position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
