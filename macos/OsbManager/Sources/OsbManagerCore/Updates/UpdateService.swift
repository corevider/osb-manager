import Foundation

public struct UpdateServiceOptions: Sendable {
    public var currentVersion: String
    public var platform: UpdatePlatform
    public var publicKeys: [String]
    public var userAgent: String
    public var transport: UpdateTransport
    public var hosts: UpdateHosts = .gitHub
    public var clock: SchedulerClock = .continuous
    public var firstDelay: Duration = UpdateScheduler.firstDelay
    public var interval: Duration = UpdateScheduler.interval
    public var busyRetry: Duration = UpdateScheduler.busyRetry
    public var metadataTimeout: TimeInterval = UpdateChecker.metadataTimeout
    public var downloadTimeout: TimeInterval = UpdateChecker.downloadTimeout

    public init(currentVersion: String, platform: UpdatePlatform, publicKeys: [String], userAgent: String, transport: UpdateTransport) {
        self.currentVersion = currentVersion
        self.platform = platform
        self.publicKeys = publicKeys
        self.userAgent = userAgent
        self.transport = transport
    }
}

public final class UpdateService: @unchecked Sendable {
    public let checker: UpdateChecker?
    public let problem: String?
    private let enabled: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var scheduler: UpdateScheduler?
    private var isBusy = false
    private var listener: (@Sendable (UpdateCheckResult, Bool) -> Void)?

    public init(options: UpdateServiceOptions, enabled: @escaping @Sendable () -> Bool, log: @escaping @Sendable (String) -> Void) {
        self.enabled = enabled
        self.log = log
        let signature = try? UpdateSignature(publicKeys: options.publicKeys)
        guard let signature, signature.keyCount > 0 else {
            checker = nil
            problem = "No release key is built in, so updates are not checked."
            return
        }
        guard let current = UpdateVersion(options.currentVersion) else {
            checker = nil
            problem = "The running version \(options.currentVersion) is not a release version, so updates are not checked."
            return
        }
        var checker = UpdateChecker(http: UpdateHttp(transport: options.transport, hosts: options.hosts, userAgent: options.userAgent), platform: options.platform, current: current, signature: signature)
        checker.metadataTimeout = options.metadataTimeout
        checker.downloadTimeout = options.downloadTimeout
        self.checker = checker
        problem = nil
        scheduler = UpdateScheduler(
            clock: options.clock,
            firstDelay: options.firstDelay,
            interval: options.interval,
            busyRetry: options.busyRetry,
            enabled: enabled,
            busy: { [weak self] in self?.busy ?? true },
            check: { [weak self] in _ = await self?.run(requestedByUser: false) }
        )
    }

    public var busy: Bool {
        get { lock.withLock { isBusy } }
        set { lock.withLock { isBusy = newValue } }
    }

    public func onChecked(_ listener: @escaping @Sendable (UpdateCheckResult, Bool) -> Void) {
        lock.withLock { self.listener = listener }
    }

    public func start() {
        scheduler?.start()
    }

    public func stop() {
        scheduler?.stop()
    }

    public func checkNow() async -> UpdateCheckResult {
        await run(requestedByUser: true)
    }

    private func run(requestedByUser: Bool) async -> UpdateCheckResult {
        guard let checker else { return UpdateCheckResult(.failed, problem ?? "Updates are not available.") }
        guard requestedByUser || enabled() else { return UpdateCheckResult(.upToDate, "Automatic update checks are off.") }
        let result = await checker.check()
        log(result.message)
        let listener = lock.withLock { self.listener }
        listener?(result, requestedByUser)
        return result
    }
}
