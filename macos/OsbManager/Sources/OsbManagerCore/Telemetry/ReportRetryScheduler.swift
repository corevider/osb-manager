import Foundation

public actor ReportRetryScheduler {
    private let outbox: ReportOutbox
    private let sender: ReportSender
    private let clock: SchedulerClock
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let log: @Sendable (String) -> Void

    private var loop: Task<Void, Never>?
    private var currentStep: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var pendingChange = false
    private var stopped = false
    private var unexpected = 0
    private var notBefore: Date
    private(set) var waitState = SchedulerWaitState.parked

    public init(
        outbox: ReportOutbox,
        sender: ReportSender,
        clock: SchedulerClock = .continuous,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.outbox = outbox
        self.sender = sender
        self.clock = clock
        self.now = now
        self.random = random
        self.log = log
        notBefore = now().addingTimeInterval(Backoff.startDelay(random: random()).seconds)
    }

    public func start() {
        guard loop == nil else { return }
        waitState = .busy
        loop = Task(priority: .utility) { [self] in await run() }
    }

    public func stop() {
        stopped = true
        currentStep?.cancel()
        resumeWake()
    }

    public func outboxChanged() {
        pendingChange = true
        currentStep?.cancel()
        resumeWake()
    }

    private func resumeWake() {
        if currentStep != nil || wake != nil { waitState = .busy }
        wake?.resume()
        wake = nil
    }

    private func run() async {
        while !stopped && unexpected < TelemetryLimits.unexpectedLimit {
            outbox.moveExpired()
            if outbox.nextAttemptAt() == nil {
                if !pendingChange {
                    await park()
                }
                pendingChange = false
                continue
            }
            pendingChange = false
            let step = Task(priority: .utility) { [self] in await performStep() }
            currentStep = step
            await step.value
            currentStep = nil
        }
        waitState = .parked
    }

    private func park() async {
        waitState = .parked
        defer { waitState = .busy }
        await withCheckedContinuation { wake = $0 }
    }

    private func sleep(for duration: Duration) async throws {
        waitState = .sleeping
        defer { waitState = .busy }
        try await clock.sleep(for: duration)
    }

    private func performStep() async {
        do {
            guard let next = outbox.nextAttemptAt() else { return }
            let due = max(next, notBefore)
            let wakeAt = min(due, outbox.nextExpiryAt() ?? due)
            let remaining = wakeAt.timeIntervalSince(now())
            if remaining > 0 {
                try await sleep(for: .seconds(remaining))
            }
            try Task.checkCancellation()
            guard due <= now() else { return }
            for entry in outbox.pending() where entry.nextAttemptAt <= now() {
                if await sender.trySendQueued(entry) {
                    log("A queued report was sent.")
                }
            }
        } catch is CancellationError {
            return
        } catch {
            unexpected += 1
            log("Queued reports hit an unexpected error (\(type(of: error))).")
            notBefore = now().addingTimeInterval(Backoff.next(failures: unexpected, random: random()).seconds)
        }
    }
}
