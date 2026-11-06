import Foundation

enum SchedulerWaitState: Sendable {
    case busy
    case parked
    case sleeping
}

final class PendingSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var isEmpty: Bool { lock.withLock { count == 0 } }

    func deliver(_ signal: @escaping @Sendable () async -> Void) {
        lock.withLock { count += 1 }
        Task {
            await signal()
            self.lock.withLock { self.count -= 1 }
        }
    }
}
