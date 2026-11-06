import Foundation

public enum DeletionResult: Equatable, Sendable {
    case nothingToDelete
    case deleted
    case failed
}

public struct ExportResult: Sendable {
    public let succeeded: Bool
    public let data: Data
}

public final class TelemetryService: @unchecked Sendable {
    public let settings: PrivacySettings
    public let outbox: ReportOutbox
    public let reports: ReportSender

    private let client: TelemetryClient
    private let statuses: StatusSource
    private let appVersion: String
    private let now: @Sendable () -> Date
    private let scheduler: TelemetryScheduler
    private let retry: ReportRetryScheduler
    private let lock = NSLock()
    private let signals = PendingSignals()
    private var failedDeletion: String?

    public init(
        settings: PrivacySettings,
        client: TelemetryClient,
        statuses: StatusSource,
        outbox: ReportOutbox,
        appVersion: String,
        locale: String,
        clock: SchedulerClock = .continuous,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.settings = settings
        self.client = client
        self.statuses = statuses
        self.outbox = outbox
        self.appVersion = appVersion
        self.now = now
        reports = ReportSender(client: client, settings: settings, outbox: outbox, now: now, random: random)
        scheduler = TelemetryScheduler(
            settings: settings,
            client: client,
            statuses: statuses,
            builder: TelemetryPayloadBuilder(appVersion: appVersion, now: now),
            appVersion: appVersion,
            locale: locale,
            clock: clock,
            now: now,
            random: random,
            log: log
        )
        retry = ReportRetryScheduler(outbox: outbox, sender: reports, clock: clock, now: now, random: random, log: log)
        let scheduler = self.scheduler
        let retry = self.retry
        let signals = self.signals
        settings.addObserver { signals.deliver { await scheduler.privacyChanged() } }
        outbox.addObserver { signals.deliver { await retry.outboxChanged() } }
    }

    public var failedDeletionInstallId: String? {
        lock.withLock { failedDeletion }
    }

    public var disabledByFailSafe: Bool {
        get async { await scheduler.disabledByFailSafe }
    }

    var idleSleepers: Int? {
        get async {
            guard signals.isEmpty else { return nil }
            let states = [await scheduler.waitState, await retry.waitState]
            guard signals.isEmpty, !states.contains(.busy) else { return nil }
            return states.filter { $0 == .sleeping }.count
        }
    }

    public func start() async {
        await scheduler.start()
        await retry.start()
    }

    public func stop() async {
        await scheduler.stop()
        await retry.stop()
        await client.close()
    }

    public func accept(characters: Bool) async {
        lock.withLock { failedDeletion = nil }
        settings.grant(characters: characters)
    }

    public func decline() async {
        settings.decline()
    }

    public func setCharacters(_ on: Bool) async {
        if settings.setCharacters(on) {
            _ = await scheduler.syncCharactersConsent()
        }
    }

    public func withdraw() async -> DeletionResult {
        let result = settings.withdraw()
        outbox.clearAll()
        lock.withLock { failedDeletion = nil }
        guard result.wasRegistered, let credentials = result.credentials else { return .nothingToDelete }
        let response = await client.deleteInstall(credentials)
        if response.succeeded || response.isStatus(404) || response.isStatus(401) {
            return .deleted
        }
        lock.withLock { failedDeletion = credentials.id }
        return .failed
    }

    public func export() async -> ExportResult {
        guard let credentials = settings.credentials, settings.state.registered else { return ExportResult(succeeded: false, data: Data()) }
        let response = await client.export(credentials)
        return ExportResult(succeeded: response.succeeded, data: response.body)
    }

    public func previewNextPayload() async -> String? {
        let state = settings.state
        guard state.granted, let credentials = settings.credentials,
              let snapshots = try? await statuses.snapshot() else { return nil }
        let builder = TelemetryPayloadBuilder(appVersion: appVersion, now: now)
        guard let batch = builder.build(snapshots, installKey: credentials.keyBytes, includeCharacters: state.charactersConsent),
              let object = try? JSONSerialization.jsonObject(with: batch.body),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    public func sendReport(reportJson: Data, screenshot: Data?) async -> ReportOutcome {
        await reports.sendNew(reportJson: reportJson, screenshot: screenshot)
    }
}
