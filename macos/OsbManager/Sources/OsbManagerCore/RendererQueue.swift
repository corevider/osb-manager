import Foundation

/// Lets one game window at a time start the game's renderer (create its WebGPU device), with a short gap between
/// starts. A slot that is not handed back within the lease is taken back, so a page that crashes or reloads while it
/// holds the slot cannot block the others.
public final class RendererQueue {
    public static let defaultGap: TimeInterval = 2
    public static let defaultLease: TimeInterval = 20

    private struct Pending {
        let window: String
        let id: String
        let grant: () -> Void
    }

    private let gap: TimeInterval
    private let lease: TimeInterval
    private let clock: () -> Date
    private var waiting: [Pending] = []
    private var holder: Pending?
    private var holderSince = Date.distantPast
    private var freeAt = Date.distantPast

    public init(gap: TimeInterval = RendererQueue.defaultGap, lease: TimeInterval = RendererQueue.defaultLease, clock: @escaping () -> Date = Date.init) {
        self.gap = gap
        self.lease = lease
        self.clock = clock
    }

    public var holderWindow: String? { holder?.window }

    public func isWaiting(_ window: String) -> Bool {
        waiting.contains { $0.window == window }
    }

    public func request(window: String, id: String, grant: @escaping () -> Void) {
        waiting.removeAll { $0.window == window }
        if holder?.window == window {
            free()
        }
        waiting.append(Pending(window: window, id: id, grant: grant))
        pump()
    }

    public func release(window: String, id: String) {
        waiting.removeAll { $0.window == window && $0.id == id }
        if let current = holder, current.window == window, current.id == id {
            free()
        }
        pump()
    }

    public func forget(_ window: String) {
        waiting.removeAll { $0.window == window }
        if holder?.window == window {
            free()
        }
        pump()
    }

    public func pump() {
        let now = clock()
        if holder != nil, now.timeIntervalSince(holderSince) >= lease {
            free()
        }
        guard holder == nil, !waiting.isEmpty, now >= freeAt else { return }
        let next = waiting.removeFirst()
        holder = next
        holderSince = now
        next.grant()
    }

    private func free() {
        holder = nil
        freeAt = clock().addingTimeInterval(gap)
    }
}
