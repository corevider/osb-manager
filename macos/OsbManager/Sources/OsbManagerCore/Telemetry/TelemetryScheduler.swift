import Foundation

public actor TelemetryScheduler {
    private let settings: PrivacySettings
    private let client: TelemetryClient
    private let statuses: StatusSource
    private let builder: TelemetryPayloadBuilder
    private let appVersion: String
    private let locale: String
    private let clock: SchedulerClock
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let log: @Sendable (String) -> Void

    private var loop: Task<Void, Never>?
    private var currentStep: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var pendingChange = false
    private var stopped = false
    private var nextDue: Duration?
    private var configDueAt: Duration?
    private var pausedUntil: Duration?
    private var lastLogAt: Duration?
    private var featureOff = false
    private var stoppedByServer = false
    private var seenEpoch = -1
    private var failures = 0
    private var unauthorized = 0
    private var unexpected = 0

    public private(set) var disabledByFailSafe = false
    private(set) var waitState = SchedulerWaitState.parked

    public init(
        settings: PrivacySettings,
        client: TelemetryClient,
        statuses: StatusSource,
        builder: TelemetryPayloadBuilder,
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
        self.builder = builder
        self.appVersion = appVersion
        self.locale = locale
        self.clock = clock
        self.now = now
        self.random = random
        self.log = log
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

    public func privacyChanged() {
        pendingChange = true
        currentStep?.cancel()
        resumeWake()
    }

    public func syncCharactersConsent() async -> Bool {
        let state = settings.state
        guard state.granted, state.registered, state.serverKnowsCharacters != state.charactersConsent, let credentials = settings.credentials else { return true }
        let response = await client.updateConsent(credentials, characters: state.charactersConsent, background: false)
        if response.succeeded {
            settings.markCharactersSynced(installId: credentials.id, value: state.charactersConsent)
            return true
        }
        return false
    }

    private func resumeWake() {
        if currentStep != nil || wake != nil { waitState = .busy }
        wake?.resume()
        wake = nil
    }

    private func run() async {
        while !stopped && !disabledByFailSafe {
            if !settings.state.granted {
                nextDue = nil
                seenEpoch = -1
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

    private func sleep(until due: Duration) async throws {
        guard due > clock.now else { return }
        waitState = .sleeping
        defer { waitState = .busy }
        try await clock.sleep(until: due)
    }

    private func performStep() async {
        do {
            let epoch = settings.epoch
            if nextDue == nil || epoch != seenEpoch {
                seenEpoch = epoch
                resetSchedule()
                nextDue = clock.now + Backoff.startDelay(random: random())
            }
            guard let due = nextDue else { return }
            try await sleep(until: due)
            try Task.checkCancellation()
            guard settings.state.granted, settings.epoch == seenEpoch else { return }
            let wait = try await cycle()
            nextDue = clock.now + wait
        } catch is CancellationError {
            return
        } catch {
            recordUnexpected(error)
            failures += 1
            nextDue = clock.now + Backoff.next(failures: failures, random: random())
        }
    }

    private func resetSchedule() {
        configDueAt = nil
        pausedUntil = nil
        featureOff = false
        stoppedByServer = false
        failures = 0
        unauthorized = 0
    }

    private func recordUnexpected(_ error: Error) {
        unexpected += 1
        logLimited("Usage statistics hit an unexpected error (\(type(of: error))).")
        if unexpected >= TelemetryLimits.unexpectedLimit && !disabledByFailSafe {
            disabledByFailSafe = true
            log("Usage statistics are switched off until \(AppIdentity.name) restarts: \(TelemetryLimits.unexpectedLimit) unexpected errors.")
        }
    }

    private func logLimited(_ message: String) {
        let moment = clock.now
        if let last = lastLogAt, moment - last < TelemetryLimits.logInterval { return }
        lastLogAt = moment
        log(message)
    }

    private func stillGranted(_ credentials: InstallCredentials) -> Bool {
        settings.credentials?.id == credentials.id
    }

    private func effectiveConfig(_ state: PrivacyState) -> TelemetryConfig {
        if let config = state.config, let fetched = state.configFetchedAt, now().timeIntervalSince(fetched) < TelemetryLimits.configMaxAge {
            return config
        }
        return .disabled
    }

    private func cycle() async throws -> Duration {
        var moment = clock.now
        if stoppedByServer { return TelemetryLimits.maxWait }
        if let paused = pausedUntil, paused > moment { return paused - moment }
        guard var credentials = settings.credentials else { return TelemetryLimits.minWait }
        if configDueAt == nil || configDueAt.map({ $0 <= moment }) == true {
            guard stillGranted(credentials) else { return TelemetryLimits.minWait }
            if let wait = await readConfig(credentials) {
                if effectiveConfig(settings.state) == .disabled { return wait }
                configDueAt = clock.now + wait
            }
            moment = clock.now
        }
        let config = effectiveConfig(settings.state)
        if !config.clientOk || !config.telemetryEnabled || featureOff {
            let untilRead = (configDueAt ?? moment) - moment
            return max(untilRead, TelemetryLimits.minWait)
        }
        let interval = Duration.seconds(config.intervalSeconds)
        let includeCharacters = settings.state.charactersConsent
        var batch = try await buildBatch(credentials, includeCharacters)
        guard batch != nil else { return Backoff.jitter(interval, random: random()) }
        guard stillGranted(credentials) else { return TelemetryLimits.minWait }
        if !settings.state.registered {
            let registration = await register(credentials)
            if let wait = registration.wait { return wait }
            if registration.credentials != credentials {
                credentials = registration.credentials
                batch = try await buildBatch(credentials, includeCharacters)
                guard batch != nil else { return Backoff.jitter(interval, random: random()) }
            }
        }
        await syncCharactersInBackground()
        guard stillGranted(credentials), let ready = batch else { return TelemetryLimits.minWait }
        let response = await client.sendTelemetry(credentials, body: ready.body)
        return afterTelemetry(response, batch: ready, credentials: credentials, interval: interval)
    }

    private func buildBatch(_ credentials: InstallCredentials, _ includeCharacters: Bool) async throws -> TelemetryBatch? {
        let snapshots = try await statuses.snapshot()
        return builder.build(snapshots, installKey: credentials.keyBytes, includeCharacters: includeCharacters)
    }

    private func syncCharactersInBackground() async {
        let state = settings.state
        guard state.registered, state.serverKnowsCharacters != state.charactersConsent, let credentials = settings.credentials else { return }
        let response = await client.updateConsent(credentials, characters: state.charactersConsent, background: true)
        if response.succeeded {
            settings.markCharactersSynced(installId: credentials.id, value: state.charactersConsent)
        }
    }

    private func readConfig(_ credentials: InstallCredentials) async -> Duration? {
        let response = await client.getConfig(version: appVersion, background: true)
        if response.succeeded {
            let config = TelemetryConfig.parse(response.body) ?? .disabled
            settings.storeConfig(installId: credentials.id, config: config)
            configDueAt = clock.now + TelemetryLimits.configRefresh
            featureOff = false
            failures = 0
            return nil
        }
        return failureWait(response)
    }

    private func register(_ credentials: InstallCredentials) async -> (wait: Duration?, credentials: InstallCredentials) {
        var active = credentials
        let characters = settings.state.charactersConsent
        var response = await client.register(active, version: appVersion, locale: locale, characters: characters, background: true)
        if response.isStatus(409) {
            guard let replacement = settings.replaceIdentity(installId: active.id) else { return (TelemetryLimits.minWait, active) }
            active = replacement
            response = await client.register(active, version: appVersion, locale: locale, characters: characters, background: true)
        }
        if response.succeeded {
            settings.markRegistered(installId: active.id, charactersSent: characters)
            failures = 0
            return (nil, active)
        }
        return (failureWait(response), active)
    }

    private func failureWait(_ response: ApiResponse) -> Duration {
        switch response.outcome {
        case .busy, .cancelled:
            return TelemetryLimits.minWait
        case .httpError where response.statusCode == 429:
            return Backoff.retryAfter(response.retryAfter, random: random(), failures: failures + 1)
        case .httpError where response.statusCode == 503:
            if response.code == "disabled" { featureOff = true }
            return Backoff.retryAfter(response.retryAfter, random: random(), failures: failures + 1)
        case .httpError where response.statusCode == 403:
            pausedUntil = clock.now + TelemetryLimits.forbiddenPause
            return TelemetryLimits.forbiddenPause
        case .httpError where [400, 404, 413, 415].contains(response.statusCode):
            return .seconds(TelemetryLimits.backoffCapSeconds)
        default:
            failures += 1
            logLimited("Usage statistics could not reach the server; trying again later.")
            return Backoff.next(failures: failures, random: random())
        }
    }

    private func afterTelemetry(_ response: ApiResponse, batch: TelemetryBatch, credentials: InstallCredentials, interval: Duration) -> Duration {
        if response.succeeded {
            failures = 0
            unauthorized = 0
            batch.commit()
            settings.recordSend(installId: credentials.id, result: "sent", sent: true)
            return Backoff.jitter(max(interval, .seconds(Self.nextAfter(response.body))), random: random())
        }
        switch response.outcome {
        case .busy, .cancelled:
            return TelemetryLimits.minWait
        case .httpError where response.statusCode == 401:
            settings.markUnregistered(installId: credentials.id)
            unauthorized += 1
            if unauthorized >= 2 {
                stoppedByServer = true
                settings.recordSend(installId: credentials.id, result: "stopped: the server does not accept this install", sent: false)
                log("Usage statistics stopped: the server did not accept this install.")
                return TelemetryLimits.maxWait
            }
            return TelemetryLimits.minWait
        case .httpError where [400, 404, 413, 415].contains(response.statusCode):
            settings.recordSend(installId: credentials.id, result: "rejected by the server (\(response.statusCode))", sent: false)
            return Backoff.jitter(interval, random: random())
        default:
            let wait = failureWait(response)
            let switchedOff = response.outcome == .httpError && response.statusCode == 503 && featureOff
            settings.recordSend(installId: credentials.id, result: switchedOff ? "switched off by the server" : "server unreachable", sent: false)
            if featureOff { configDueAt = clock.now + wait }
            return wait
        }
    }

    private static func nextAfter(_ body: Data) -> Double {
        guard let root = StrictJson.object(body, maxDepth: 4), let value = StrictJson.integer(root["next_after_s"]) else { return 0 }
        return Double(min(max(value, 0), Int64(TelemetryLimits.maxWait.seconds)))
    }
}
