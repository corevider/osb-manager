import AppKit
import OsbManagerCef
import OsbManagerCore

final class ManagerStatusSource: StatusSource, @unchecked Sendable {
    private let collect: @MainActor @Sendable () -> [AccountSnapshot]

    init(collect: @escaping @MainActor @Sendable () -> [AccountSnapshot]) {
        self.collect = collect
    }

    func snapshot() async throws -> [AccountSnapshot] {
        await collect()
    }
}

#if DEBUG
struct ScaledClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    let scale: Double
    private let base = ContinuousClock()
    private let origin = ContinuousClock.now

    init(scale: Double) {
        self.scale = scale
    }

    var now: Instant {
        Instant(offset: origin.duration(to: base.now) * scale)
    }

    var minimumResolution: Duration { .milliseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let remaining = deadline.offset - now.offset
        guard remaining > .zero else { return }
        try await base.sleep(for: remaining / scale)
    }
}
#endif

@MainActor
public final class TelemetryController {
    public let service: TelemetryService
    public let settings: PrivacySettings
    public let locale: String
    public let texts = ConsentTexts.english
    public let interface = InterfaceTexts.english
    let services: AppServices
    let manager: GameManager
    private weak var main: MainWindowController?
    private var privacyWindow: PrivacyWindowController?
    private var reportWindow: ReportWindowController?
    private var banner: ConsentBanner?

    private init(service: TelemetryService, settings: PrivacySettings, locale: String, services: AppServices, manager: GameManager) {
        self.service = service
        self.settings = settings
        self.locale = locale
        self.services = services
        self.manager = manager
    }

    public static func resolveLocale(_ options: LaunchOptions) -> String {
        if let forced = options.interfaceLanguage {
            return InterfaceLocale.code([forced])
        }
        return InterfaceLocale.code()
    }

    public static func create(services: AppServices, manager: GameManager, options: LaunchOptions) async -> TelemetryController? {
        let locale = resolveLocale(options)
        let log = services.log
        var keyStore: InstallKeyStore = KeychainInstallKeyStore()
        var baseUrl = URL(string: TelemetryLimits.releaseBaseUrl)
        var schedulerClock = SchedulerClock.continuous
        var grantAtStart = false
        #if DEBUG
        if let override = options.telemetryUrl {
            baseUrl = override
            keyStore = InMemoryInstallKeyStore()
        }
        if options.dialogShots != nil {
            keyStore = InMemoryInstallKeyStore()
        }
        if options.telemetryConsent {
            keyStore = InMemoryInstallKeyStore()
            grantAtStart = true
        }
        if let keyFile = options.testInstallKeyFile {
            let key = (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            keyStore = InMemoryInstallKeyStore(key: key)
        }
        if let scale = options.telemetryTimeScale {
            schedulerClock = SchedulerClock(ScaledClock(scale: scale))
        }
        #endif
        let store = keyStore
        let file = services.paths.privacyFile
        let shouldGrant = grantAtStart
        let settings = await Task.detached(priority: .utility) {
            let loaded = PrivacySettings.load(from: file, keyStore: store, log: { log.warn($0) })
            if shouldGrant { loaded.grant(characters: false) }
            return loaded
        }.value
        guard let baseUrl else { return nil }
        let client: TelemetryClient
        do {
            client = try TelemetryClient(baseUrl: baseUrl, userAgent: "OSBManager/\(AppVersion.short()) (macOS)", clock: schedulerClock)
        } catch {
            log.error("Usage statistics are unavailable", error)
            return nil
        }
        let source = ManagerStatusSource { [weak manager, weak services] in
            guard let manager, let services else { return [] }
            return manager.windows.values.compactMap { window in
                guard let report = window.latestReport else { return nil }
                let server = services.accounts.account(id: window.accountId)?.server ?? ""
                return AccountSnapshot(accountId: window.accountId, server: server, status: report.status, receivedAt: report.receivedAt)
            }
        }
        let cefVersion = CefRuntime.version
        let service = TelemetryService(
            settings: settings,
            client: client,
            statuses: source,
            outbox: ReportOutbox(directory: services.paths.outbox),
            appVersion: AppVersion.short(),
            locale: locale,
            clock: schedulerClock,
            log: { log.info($0) },
            diagnostics: makeDiagnostics(services: services, settings: settings),
            diagnosticsEnv: { DiagnosticEnvironment.forThisMac(cefVersion: cefVersion) },
            crashSignals: true,
            osbVocabulary: loadVocabulary(services: services)
        )
        let controller = TelemetryController(service: service, settings: settings, locale: locale, services: services, manager: manager)
        controller.attachDiagnostics()
        #if DEBUG
        if options.testUncaughtException {
            controller.raiseUncaughtExceptionWhenRecording()
        }
        if let seconds = options.testStopSharingAfter {
            controller.stopSharing(after: seconds)
        }
        #endif
        return controller
    }

    private func attachDiagnostics() {
        guard let capture = service.capture else { return }
        services.diagnostics = capture
        CrashHandlers.install(capture)
        services.log.onError = { [weak capture] error in
            guard let capture, capture.hub.recording else { return }
            capture.caught(error, context: DiagnosticContext(windows: min(capture.windowCache.windows.count, DiagnosticFormats.maxEach)))
        }
        capture.requestPageMemory = { [weak self] in
            Task { @MainActor in self?.readPageMemory() }
        }
    }

    private func readPageMemory() {
        guard let capture = service.capture, capture.hub.recording else { return }
        let windows = manager.windows.values.filter { !$0.isClosed }
        guard !windows.isEmpty else { return }
        let megabyte = 1024.0 * 1024.0
        var used: [Double] = []
        var total: [Double] = []
        var left = windows.count
        for window in windows {
            window.readHeapUsage { result in
                if let result {
                    used.append(result.used / megabyte)
                    total.append(result.total / megabyte)
                }
                left -= 1
                if left == 0, !used.isEmpty {
                    capture.perf.setPageMemory(used: used, total: total)
                }
            }
        }
    }

    public func finishRun() {
        service.finishRun()
    }

    #if DEBUG
    private func stopSharing(after seconds: TimeInterval) {
        let service = self.service
        let log = services.log
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            log.warn("Debug option: switching sharing off.")
            let result = await service.withdraw()
            log.info("Debug option: sharing is off (\(result)).")
        }
    }

    private func raiseUncaughtExceptionWhenRecording() {
        guard let capture = service.capture else { return }
        let log = services.log
        Task.detached(priority: .utility) {
            while !(capture.hub.recording && capture.marker.isWritten) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            log.warn("Debug option: raising an uncaught exception.")
            Thread.detachNewThread {
                NSException(name: .invalidArgumentException, reason: "debug uncaught exception CanaryReasonQz", userInfo: ["account": "CanaryAccountXv"]).raise()
            }
        }
    }
    #endif

    private static func loadVocabulary(services: AppServices) -> OsbVocabulary? {
        do {
            return try OsbVocabulary.load(from: services.library.directory.appendingPathComponent(OsbVocabulary.fileName))
        } catch {
            services.log.warn("OSB error reports from the game pages are off: the OSB vocabulary could not be read.")
            return nil
        }
    }

    private static func makeDiagnostics(services: AppServices, settings: PrivacySettings) -> DiagnosticsHub {
        let terms = PrivateTerms.forThisMac(dataFolder: services.paths.root)
        terms.add(accounts: services.accounts.accounts)
        return DiagnosticsHub(folder: services.paths.diagnostics, terms: terms, consentOn: { settings.state.granted })
    }

    public func attach(main: MainWindowController) {
        self.main = main
        settings.addObserver { [weak self] in
            Task { @MainActor in self?.privacyChanged() }
        }
        service.outbox.addObserver { [weak self] in
            Task { @MainActor in self?.privacyWindow?.refresh() }
        }
        presentConsentPromptIfNeeded()
    }

    public func start() {
        Task(priority: .utility) { [service] in await service.start() }
    }

    public func stop() {
        Task(priority: .utility) { [service] in await service.stop() }
    }

    public func presentConsentPromptIfNeeded() {
        let state = settings.state
        guard state.needsAnswer, let main, banner == nil else { return }
        let view = ConsentBanner(
            texts: texts,
            sharedBefore: state.sharedBefore,
            onShare: { [weak self] in self?.answerShare() },
            onDecline: { [weak self] in self?.answerDecline() },
            onWhatIsSent: { [weak self] in self?.showPrivacy(revealPayload: true) }
        )
        banner = view
        main.setConsentBanner(view)
    }

    public func showPrivacy(revealPayload: Bool = false) {
        if privacyWindow == nil {
            privacyWindow = PrivacyWindowController(controller: self)
        }
        privacyWindow?.show(revealPayload: revealPayload)
    }

    public func showReport() {
        if reportWindow == nil {
            reportWindow = ReportWindowController(controller: self)
        }
        reportWindow?.show()
    }

    public func showUnsentReports() {
        UnsentReports.present(controller: self)
    }

    #if DEBUG
    var privacyWindowForShots: NSWindow? { privacyWindow?.window }
    var reportWindowForShots: ReportWindowController? { reportWindow }

    func showConsentPromptForShots(sharedBefore: Bool) {
        guard let main else { return }
        let view = ConsentBanner(texts: texts, sharedBefore: sharedBefore, onShare: {}, onDecline: {}, onWhatIsSent: {})
        banner = view
        main.setConsentBanner(view)
    }

    func hideConsentPromptForShots() {
        removeBanner()
    }
    #endif

    public func closeAuxiliaryWindows() {
        privacyWindow?.window.close()
        reportWindow?.window.close()
    }

    func answerShare() {
        removeBanner()
        Task { await service.accept(characters: false) }
    }

    func answerDecline() {
        removeBanner()
        Task { await service.decline() }
    }

    private func removeBanner() {
        banner = nil
        main?.setConsentBanner(nil)
    }

    private func privacyChanged() {
        if !settings.state.needsAnswer, banner != nil {
            removeBanner()
        }
        privacyWindow?.refresh()
        reportWindow?.refreshAnonymousNote()
    }

    func windowDiagnostics() -> [WindowDiagnostics] {
        services.accounts.accounts.compactMap { account in
            manager.windows[account.id].map { WindowDiagnostics.from($0.latestReport?.status, light: $0.light) }
        }
    }

    func scriptDiagnostics() -> [ScriptDiagnostics] {
        services.scripts.scripts.map { ScriptDiagnostics(name: $0.meta.name, version: $0.meta.version) }
    }

    func openGameWindows() -> [(id: String, name: String)] {
        services.accounts.accounts.compactMap { account in
            manager.windows[account.id].map { _ in (account.id, account.name) }
        }
    }

    static var operatingSystemText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
