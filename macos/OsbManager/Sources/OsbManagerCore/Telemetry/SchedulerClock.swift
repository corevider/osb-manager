import Foundation

public struct SchedulerClock: Sendable {
    private let elapsedSinceOrigin: @Sendable () -> Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        elapsedSinceOrigin = { origin.duration(to: clock.now) }
        sleeper = { try await clock.sleep(for: $0) }
    }

    public static let continuous = SchedulerClock(ContinuousClock())

    public var now: Duration { elapsedSinceOrigin() }

    public func sleep(for duration: Duration) async throws {
        try await sleeper(duration)
    }

    public func sleep(until due: Duration) async throws {
        let remaining = due - now
        if remaining > .zero {
            try await sleeper(remaining)
        }
    }
}
