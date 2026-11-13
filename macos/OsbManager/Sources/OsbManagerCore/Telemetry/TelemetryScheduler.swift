import Foundation

struct JobState {
    var failures = 0
    var featureOff = false
    var pausedUntil: Duration?
    var lastLogAt: Duration?
}

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
    private let hub: DiagnosticsHub?
    private let uploader: DiagnosticsUploader?

    private var loop: Task<Void, Never>?
    private var currentStep: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var pendingChange = false
    private var stopped = false
    private var nextDue: Duration?
    private var diagnosticsDue: Duration?
    private var configDueAt: Duration?
    private var usage = JobState()
    private var reports = JobState()
    private var stoppedByServer = false
    private var diagnosticsStopped = false
    private var seenEpoch = -1
    private var unauthorized = 0
    private var diagnosticsUnauthorized = 0
    private var diagnosticsForbidden = 0
    private var unexpected = 0
    private(set) var diagnosticsRequests = 0

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
        log: @escaping @Sendable (String) -> Void = { _ in },
        hub: DiagnosticsHub? = nil,
        uploader: DiagnosticsUploader? = nil
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
        self.hub = hub
        self.uploader = uploader
    }

    public var diagnosticsHaveStopped: Bool { diagnosticsStopped }

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
                diagnosticsDue = nil
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
                diagnosticsDue = nextDue
            }
            guard let usageDue = nextDue else { return }
            var due = usageDue
            if uploader != nil, let diagnosticsAt = diagnosticsDue, diagnosticsAt < due {
                due = diagnosticsAt
            }
            try await sleep(until: due)
            try Task.checkCancellation()
            guard settings.state.granted, settings.epoch == seenEpoch else { return }
            if clock.now >= usageDue {
                let wait = try await cycle()
                nextDue = clock.now + wait
            }
            try Task.checkCancellation()
            if uploader != nil, let diagnosticsAt = diagnosticsDue, clock.now >= diagnosticsAt, settings.state.granted, settings.epoch == seenEpoch {
                let wait = await diagnosticsCycle()
                diagnosticsDue = clock.now + wait
            }
        } catch is CancellationError {
            return
        } catch {
            recordUnexpected(error)
            usage.failures += 1
            nextDue = clock.now + Backoff.next(failures: usage.failures, random: random())
        }
    }

    private func resetSchedule() {
        configDueAt = nil
        usage = JobState(lastLogAt: usage.lastLogAt)
        reports = JobState(lastLogAt: reports.lastLogAt)
        stoppedByServer = false
        diagnosticsStopped = false
        unauthorized = 0
        diagnosticsUnauthorized = 0
        diagnosticsForbidden = 0
    }

    private func recordUnexpected(_ error: Error) {
        unexpected += 1
        logLimited(&usage, "Usage statistics hit an unexpected error (\(type(of: error))).")
        if unexpected >= TelemetryLimits.unexpectedLimit && !disabledByFailSafe {
            disabledByFailSafe = true
            log("Usage statistics are switched off until \(AppIdentity.name) restarts: \(TelemetryLimits.unexpectedLimit) unexpected errors.")
        }
    }

    private func logLimited(_ job: inout JobState, _ message: String) {
        let moment = clock.now
        if let last = job.lastLogAt, moment - last < TelemetryLimits.logInterval { return }
        job.lastLogAt = moment
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
        if let paused = usage.pausedUntil, paused > moment { return paused - moment }
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
        if !config.clientOk || !config.telemetryEnabled || usage.featureOff {
            let untilRead = (configDueAt ?? moment) - moment
            return max(untilRead, TelemetryLimits.minWait)
        }
        let interval = Duration.seconds(config.intervalSeconds)
        let includeCharacters = settings.state.charactersConsent
        var batch = try await buildBatch(credentials, includeCharacters)
        guard batch != nil else { return Backoff.jitter(interval, random: random()) }
        guard stillGranted(credentials) else { return TelemetryLimits.minWait }
        if !settings.state.registered {
            let registration = await register(credentials, reportsJob: false)
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
            if settings.state.granted {
                hub?.applyServer(config.diagnosticsSettings)
            }
            configDueAt = clock.now + TelemetryLimits.configRefresh
            usage.featureOff = false
            reports.featureOff = false
            usage.failures = 0
            return nil
        }
        return failureWait(response, reportsJob: false)
    }

    private func register(_ credentials: InstallCredentials, reportsJob: Bool) async -> (wait: Duration?, credentials: InstallCredentials) {
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
            if reportsJob { reports.failures = 0 } else { usage.failures = 0 }
            return (nil, active)
        }
        return (failureWait(response, reportsJob: reportsJob), active)
    }

    private func failureWait(_ response: ApiResponse, reportsJob: Bool) -> Duration {
        var job = reportsJob ? reports : usage
        defer {
            if reportsJob { reports = job } else { usage = job }
        }
        let name = reportsJob ? "Error reports" : "Usage statistics"
        switch response.outcome {
        case .busy, .cancelled:
            return TelemetryLimits.minWait
        case .httpError where response.statusCode == 429:
            return Backoff.retryAfter(response.retryAfter, random: random(), failures: job.failures + 1)
        case .httpError where response.statusCode == 503:
            if response.code == "disabled" { job.featureOff = true }
            return Backoff.retryAfter(response.retryAfter, random: random(), failures: job.failures + 1)
        case .httpError where response.statusCode == 403:
            job.pausedUntil = clock.now + TelemetryLimits.forbiddenPause
            return TelemetryLimits.forbiddenPause
        case .httpError where [400, 404, 413, 415].contains(response.statusCode):
            return .seconds(TelemetryLimits.backoffCapSeconds)
        default:
            job.failures += 1
            logLimited(&job, "\(name) could not reach the server; trying again later.")
            return Backoff.next(failures: job.failures, random: random())
        }
    }

    private func afterTelemetry(_ response: ApiResponse, batch: TelemetryBatch, credentials: InstallCredentials, interval: Duration) -> Duration {
        if response.succeeded {
            usage.failures = 0
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
            let wait = failureWait(response, reportsJob: false)
            let switchedOff = response.outcome == .httpError && response.statusCode == 503 && usage.featureOff
            settings.recordSend(installId: credentials.id, result: switchedOff ? "switched off by the server" : "server unreachable", sent: false)
            if usage.featureOff { configDueAt = clock.now + wait }
            return wait
        }
    }

    private func diagnosticsCycle() async -> Duration {
        guard let hub else { return TelemetryLimits.maxWait }
        do {
            return try await diagnosticsStep(hub)
        } catch is CancellationError {
            return TelemetryLimits.minWait
        } catch {
            hub.reportFault()
            logLimited(&reports, "Error reports hit an unexpected error (\(type(of: error))).")
            if hub.faulted {
                log("Error reports are switched off until \(AppIdentity.name) restarts: \(DiagnosticsHub.faultLimit) unexpected errors.")
            }
            reports.failures += 1
            return Backoff.next(failures: reports.failures, random: random())
        }
    }

    private func diagnosticsStep(_ hub: DiagnosticsHub) async throws -> Duration {
        guard let uploader, !diagnosticsStopped, !hub.faulted else { return TelemetryLimits.maxWait }
        let moment = clock.now
        if let paused = reports.pausedUntil, paused > moment { return paused - moment }
        guard var credentials = settings.credentials else { return TelemetryLimits.minWait }
        let config = effectiveConfig(settings.state).diagnosticsSettings
        hub.applyServer(config)
        if !config.enabled || reports.featureOff {
            let untilRead = (configDueAt ?? nextDue ?? moment) - moment
            return max(untilRead, TelemetryLimits.minWait)
        }
        guard hub.recording else { return TelemetryLimits.minWait }
        let interval = Duration.seconds(config.intervalSeconds)
        try checkDiagnostics()
        guard uploader.hasSomethingToSend(config) else { return Backoff.jitter(interval, random: random()) }
        guard stillGranted(credentials) else { return TelemetryLimits.minWait }
        if !settings.state.registered {
            let registration = await register(credentials, reportsJob: true)
            if let wait = registration.wait { return wait }
            credentials = registration.credentials
        }
        try Task.checkCancellation()
        guard stillGranted(credentials), let prepared = uploader.prepare(config) else { return Backoff.jitter(interval, random: random()) }
        guard hub.isCurrent(session: prepared.session) else { return TelemetryLimits.minWait }
        diagnosticsRequests += 1
        let response = await client.sendDiagnostics(credentials, body: prepared.body)
        guard hub.isCurrent(session: prepared.session), stillGranted(credentials) else { return TelemetryLimits.minWait }
        return await afterDiagnostics(response, prepared: prepared, credentials: credentials, interval: interval)
    }

    private func afterDiagnostics(_ response: ApiResponse, prepared: PreparedDiagnostics, credentials: InstallCredentials, interval: Duration) async -> Duration {
        guard let uploader else { return TelemetryLimits.maxWait }
        if response.succeeded {
            reports.failures = 0
            diagnosticsUnauthorized = 0
            uploader.commit(prepared)
            return Backoff.jitter(max(interval, .seconds(Self.nextAfter(response.body))), random: random())
        }
        if response.outcome == .httpError, [400, 404, 413, 415].contains(response.statusCode) {
            uploader.commit(prepared)
            logLimited(&reports, "Error reports were rejected by the server (\(response.statusCode)); they are dropped.")
            reports.failures += 1
            return Backoff.next(failures: reports.failures, random: random())
        }
        uploader.giveBack(prepared)
        switch response.outcome {
        case .busy, .cancelled:
            return TelemetryLimits.minWait
        case .httpError where response.statusCode == 401:
            settings.markUnregistered(installId: credentials.id)
            diagnosticsUnauthorized += 1
            if diagnosticsUnauthorized >= 2 {
                diagnosticsStopped = true
                log("Error reports stopped: the server did not accept this install.")
                return TelemetryLimits.maxWait
            }
            return TelemetryLimits.minWait
        case .httpError where response.statusCode == 403 && response.code == "consent_required":
            diagnosticsForbidden += 1
            if diagnosticsForbidden >= 2 {
                diagnosticsStopped = true
                log("Error reports stopped: the server says consent is missing.")
                return TelemetryLimits.maxWait
            }
            if stillGranted(credentials) {
                _ = await client.updateConsent(credentials, characters: settings.state.charactersConsent, background: true)
            }
            return Backoff.jitter(interval, random: random())
        default:
            return failureWait(response, reportsJob: true)
        }
    }

    #if DEBUG
    var diagnosticsFault: (@Sendable () throws -> Void)?

    func injectDiagnosticsFault(_ fault: (@Sendable () throws -> Void)?) {
        diagnosticsFault = fault
    }

    private func checkDiagnostics() throws {
        try diagnosticsFault?()
    }
    #else
    private func checkDiagnostics() throws {}
    #endif

    private static func nextAfter(_ body: Data) -> Double {
        guard let root = StrictJson.object(body, maxDepth: 4), let value = StrictJson.integer(root["next_after_s"]) else { return 0 }
        return Double(min(max(value, 0), Int64(TelemetryLimits.maxWait.seconds)))
    }
}
