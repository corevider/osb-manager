import Foundation

public final class UpdateNotice {
    private var postponed: Set<UpdateVersion> = []
    public private(set) var current: UpdateOffer?
    public private(set) var installing = false

    public init() {}

    public func offer(_ offer: UpdateOffer, requestedByUser: Bool) -> Bool {
        if installing || (!requestedByUser && postponed.contains(offer.version)) {
            return false
        }
        if let current, current.version > offer.version {
            return false
        }
        current = offer
        return true
    }

    public func later() {
        guard let current, !installing else { return }
        postponed.insert(current.version)
        self.current = nil
    }

    public func beginInstall() -> UpdateOffer? {
        guard let current, !installing else { return nil }
        installing = true
        return current
    }

    public func installFailed() {
        installing = false
    }
}

public final class UpdateScheduler: @unchecked Sendable {
    public static let firstDelay: Duration = .seconds(120)
    public static let interval: Duration = .seconds(6 * 3600)
    public static let busyRetry: Duration = .seconds(60)

    private let clock: SchedulerClock
    private let enabled: @Sendable () -> Bool
    private let busy: @Sendable () -> Bool
    private let check: @Sendable () async -> Void
    private let firstDelay: Duration
    private let interval: Duration
    private let busyRetry: Duration
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(
        clock: SchedulerClock = .continuous,
        firstDelay: Duration = UpdateScheduler.firstDelay,
        interval: Duration = UpdateScheduler.interval,
        busyRetry: Duration = UpdateScheduler.busyRetry,
        enabled: @escaping @Sendable () -> Bool,
        busy: @escaping @Sendable () -> Bool,
        check: @escaping @Sendable () async -> Void
    ) {
        self.clock = clock
        self.firstDelay = firstDelay
        self.interval = interval
        self.busyRetry = busyRetry
        self.enabled = enabled
        self.busy = busy
        self.check = check
    }

    public func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached { [clock, firstDelay, interval, busyRetry, enabled, busy, check] in
                var wait = firstDelay
                while !Task.isCancelled {
                    do {
                        try await clock.sleep(for: wait)
                    } catch {
                        return
                    }
                    if !enabled() {
                        wait = interval
                    } else if busy() {
                        wait = busyRetry
                    } else {
                        await check()
                        wait = interval
                    }
                }
            }
        }
    }

    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }
}
