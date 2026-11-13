import Foundation
import OsbManagerCore

@MainActor
public final class OsbController {
    public static let installingLine = "Installing OSB…"
    public static let failedLine = "Could not install OSB. It will try again at the next start, or add it with Add from URL."

    private let services: AppServices
    private let manager: GameManager
    private let osbUrl: String
    private let allowLoopbackHttp: Bool
    private let schedule: OsbUpdateSchedule
    private let update: OsbAutoUpdate
    private var running: Task<Void, Never>?
    public private(set) var installLine: String?
    public var onInstallLineChange: ((String?) -> Void)?

    public init(services: AppServices, manager: GameManager, options: LaunchOptions) {
        self.services = services
        self.manager = manager
        osbUrl = options.osbUrl ?? BotScripts.osbUrl
        allowLoopbackHttp = options.osbUrl != nil
        schedule = options.osbUrl == nil ? .production : .testing
        update = OsbAutoUpdate(
            scripts: services.scripts,
            downloader: services.downloader,
            jobs: services.scriptJobs,
            enabled: { [unowned services] in services.settings.updateOsbAutomatically },
            addressOverride: options.osbUrl
        )
    }

    public func start() {
        guard running == nil else { return }
        running = Task { await installThenWatchForUpdates() }
    }

    public func stop() {
        running?.cancel()
    }

    public func installThenWatchForUpdates() async {
        let job = services.scriptJobs.begin()
        await installOnFirstStart()
        job.end()
        await watchForUpdates()
    }

    public func installOnFirstStart() async {
        guard services.settings.osbFirstInstall == .pending else { return }
        setInstallLine(Self.installingLine)
        let result = await OsbFirstInstall.run(
            scripts: services.scripts,
            downloader: services.downloader,
            settings: services.settings,
            osbUrl: osbUrl,
            allowLoopbackHttp: allowLoopbackHttp
        )
        if let problem = result.settingsError {
            services.log.error("Could not save the settings", problem)
        }
        switch result.outcome {
        case .installed:
            let version = result.script.map { "\($0.meta.name) \($0.meta.version)" } ?? "OSB"
            let reload = manager.windows.isEmpty ? "" : " Reload the game windows to apply it."
            services.log.info("Installed \(version). You can turn it off or remove it on the Scripts tab.\(reload)")
            setInstallLine(nil)
        case .failed:
            let reason = result.error?.localizedDescription ?? "unknown error"
            services.log.warn("Could not install OSB on the first start (\(reason)). It will try again at the next start.")
            services.note("warn", TrailCodes.scriptInstallFailed)
            setInstallLine(Self.failedLine)
        case .skipped, .notDue:
            setInstallLine(nil)
        }
    }

    public func watchForUpdates() async {
        var delay = schedule.firstDelay
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let result = await checkForUpdate()
            delay = schedule.nextDelay(after: result.outcome)
        }
    }

    @discardableResult
    public func checkForUpdate() async -> OsbUpdateResult {
        let result = await update.check()
        switch result.outcome {
        case .updated:
            services.log.info("Updated OSB from \(result.oldVersion ?? "?") to \(result.newVersion ?? "?"). Reload the game windows to apply it.")
        case .failed where result.firstFailureInStreak:
            let reason = result.error?.localizedDescription ?? "unknown error"
            services.log.warn("Could not check for an OSB update (\(reason)). It will try again later.")
            services.note("warn", TrailCodes.scriptUpdateFailed)
        default:
            break
        }
        return result
    }

    private func setInstallLine(_ line: String?) {
        installLine = line
        onInstallLineChange?(line)
    }
}
