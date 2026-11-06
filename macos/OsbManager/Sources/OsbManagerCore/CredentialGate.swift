import Foundation

public final class CredentialGate {
    private let maxPerWindow: Int
    private let window: TimeInterval
    private let minimumGap: TimeInterval
    private let clock: () -> Date
    private var given: [Date] = []
    private let lock = NSLock()

    public init(maxPerWindow: Int = 3, window: TimeInterval = 600, minimumGap: TimeInterval = 15, clock: @escaping () -> Date = Date.init) {
        self.maxPerWindow = maxPerWindow
        self.window = window
        self.minimumGap = minimumGap
        self.clock = clock
    }

    public func tryTake() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        given.removeAll { now.timeIntervalSince($0) >= window }
        if given.count >= maxPerWindow {
            return false
        }
        if let last = given.last, now.timeIntervalSince(last) < minimumGap {
            return false
        }
        given.append(now)
        return true
    }
}
