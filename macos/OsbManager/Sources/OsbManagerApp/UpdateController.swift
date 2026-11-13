import AppKit
import OsbManagerCore

final class SettingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
public final class UpdateController: NSObject, NSMenuItemValidation {
    private static let launchQuietPeriod: TimeInterval = 60
    private static let closeTimeout: TimeInterval = 20

    private let services: AppServices
    private let manager: GameManager
    private let arguments: [String]
    private let updates: UpdateService
    private let enabled: SettingFlag
    private let notice = UpdateNotice()
    private weak var main: MainWindowController?
    private var banner: UpdateBanner?
    private var busyTimer: Timer?
    private var lastWindowCount = 0
    private var lastLaunch = Date.distantPast
    public var onQuitForUpdate: (() -> Void)?

    public init(services: AppServices, manager: GameManager, arguments: [String]) {
        self.services = services
        self.manager = manager
        self.arguments = arguments
        let flag = SettingFlag(services.settings.checkForUpdates)
        enabled = flag
        let log = services.log
        let options = UpdateServiceOptions(
            currentVersion: AppVersion.short(),
            platform: .macosArm64,
            publicKeys: UpdateKeys.release,
            userAgent: "OSBManager/\(AppVersion.short()) (macOS)",
            transport: UrlSessionUpdateTransport()
        )
        updates = UpdateService(options: options, enabled: { flag.value }, log: { log.info($0) })
        super.init()
    }

    public func attach(main: MainWindowController) {
        self.main = main
    }

    public func start() {
        cleanUpAfterUpdate()
        updates.onChecked { [weak self] result, requestedByUser in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(result, requestedByUser: requestedByUser) }
            }
        }
        busyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBusy() }
        }
        updates.start()
    }

    public func stop() {
        busyTimer?.invalidate()
        busyTimer = nil
        updates.stop()
    }

    @objc public func checkNow() {
        if let problem = updates.problem {
            Dialogs.info("Check for updates", detail: problem)
            return
        }
        Task { @MainActor in
            let result = await updates.checkNow()
            if result.status != .available {
                Dialogs.info("Check for updates", detail: result.message, style: result.status == .failed ? .warning : .informational)
            }
        }
    }

    @objc public func toggleAutomaticChecks() {
        services.settings.checkForUpdates.toggle()
        enabled.value = services.settings.checkForUpdates
        do {
            try services.settings.save()
        } catch {
            services.log.error("Could not save the settings", error)
        }
        services.log.info("Check for updates: \(services.settings.checkForUpdates ? "on" : "off").")
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomaticChecks) {
            item.state = services.settings.checkForUpdates ? .on : .off
        }
        return true
    }

    private func refreshBusy() {
        let count = manager.windows.count
        if count > lastWindowCount {
            lastLaunch = Date()
        }
        lastWindowCount = count
        updates.busy = manager.queue.count > 0 || Date().timeIntervalSince(lastLaunch) < Self.launchQuietPeriod
    }

    private func cleanUpAfterUpdate() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app", AppBundleSwap(target: bundle).cleanUp() > 0 {
            services.log.info("Removed the previous version left by an update.")
        }
        try? FileManager.default.removeItem(at: services.paths.updates)
    }

    private func handle(_ result: UpdateCheckResult, requestedByUser: Bool) {
        guard let offer = result.offer, notice.offer(offer, requestedByUser: requestedByUser) else { return }
        showBanner(offer)
    }

    private func showBanner(_ offer: UpdateOffer) {
        let banner = UpdateBanner(
            title: "Update available",
            body: "\(offer.title): OSB Manager \(offer.version) is ready to install (you have \(AppVersion.short())). Install and restart closes the game windows, installs the signed update and starts the app again with the same settings.",
            releasePage: offer.releasePage,
            onInstall: { [weak self] in self?.install() },
            onLater: { [weak self] in self?.later() }
        )
        self.banner = banner
        main?.setUpdateBanner(banner)
    }

    private func hideBanner() {
        banner = nil
        main?.setUpdateBanner(nil)
    }

    private func later() {
        if let offer = notice.current {
            services.log.info("Update to \(offer.version) postponed. It is offered again at the next start.")
        }
        notice.later()
        hideBanner()
    }

    private func install() {
        guard let offer = notice.beginInstall(), let checker = updates.checker else { return }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            notice.installFailed()
            offerReleasePage(offer, "This copy of OSB Manager does not run from an app bundle, so it cannot update itself.")
            return
        }
        let swap = AppBundleSwap(target: target)
        guard AppBundleSwap.canWrite(swap.folder) else {
            notice.installFailed()
            services.log.warn("Cannot install the update: \(swap.folder.path) is not writable.")
            offerReleasePage(offer, "OSB Manager cannot write to its folder (\(swap.folder.path)), so it cannot update itself there.")
            return
        }
        if let question = ClosePolicy.allWindowsQuestion(inGameCount: manager.inGameCount, verb: "close"), !Dialogs.confirm(question) {
            notice.installFailed()
            return
        }
        banner?.setBusy("Downloading OSB Manager \(offer.version)...")
        let folder = services.paths.updates.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let log = services.log
        let services = self.services
        Task { @MainActor in
            var swapped = false
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                log.info("Downloading the update to \(offer.version).")
                services.note("info", TrailCodes.updateDownload)
                let zip = try await checker.download(offer, into: folder)
                log.info("The download matches the signed manifest of \(offer.version).")
                banner?.setBusy("Checking the signature of OSB Manager \(offer.version)...")
                let app = try await Task.detached(priority: .userInitiated) {
                    let check = AppBundleCheck()
                    let app = try check.extract(zip: zip, into: folder.appendingPathComponent("app", isDirectory: true))
                    try check.verify(app: app, version: offer.version)
                    return app
                }.value
                log.info("The new app passed codesign, Gatekeeper and the team and bundle id checks.")
                try swap.stage(app)
                banner?.setBusy("Closing the game windows...")
                try await closeAllWindows()
                try swap.swap()
                swapped = true
                banner?.setBusy("Starting OSB Manager \(offer.version)...")
                guard await relaunch(target) else {
                    try swap.rollBack()
                    swapped = false
                    throw UpdateError("The new version did not start, so the previous version was put back.")
                }
                log.info("Updated to \(offer.version); the new version is starting.")
                onQuitForUpdate?()
            } catch {
                if swapped {
                    do {
                        try swap.rollBack()
                    } catch {
                        log.error("Could not put the previous version back. Rename \(swap.previous.path) to \(swap.target.path) by hand", error)
                    }
                }
                swap.cleanUp()
                log.error("The update failed", error)
                services.note("error", TrailCodes.updateFailed)
                notice.installFailed()
                showBanner(offer)
                offerReleasePage(offer, "The update to \(offer.version) failed: \(error.localizedDescription)")
            }
        }
    }

    private func closeAllWindows() async throws {
        _ = manager.closeAll(prompt: false)
        let deadline = Date().addingTimeInterval(Self.closeTimeout)
        while !manager.windows.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard manager.windows.isEmpty else {
            throw UpdateError("\(manager.windows.count) game window(s) did not close. Nothing was changed.")
        }
    }

    private func relaunch(_ app: URL) async -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let marker = UpdateRelaunch.marker(paths: services.paths, previousProcess: pid)
        try? FileManager.default.removeItem(at: marker)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", app.path, "--args"] + UpdateRelaunch.argumentsForRestart(arguments) + [UpdateRelaunch.option, String(pid)]
        do {
            try process.run()
        } catch {
            services.log.error("Could not start the new version", error)
            return false
        }
        let deadline = Date().addingTimeInterval(UpdateRelaunch.startTimeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func offerReleasePage(_ offer: UpdateOffer, _ message: String) {
        if Dialogs.confirm(message, detail: "Open the release page to download it by hand?", yes: "Open release page", no: "Close") {
            NSWorkspace.shared.open(offer.releasePage)
        }
    }
}

@MainActor
final class UpdateBanner: NSView {
    private let body: NSTextField
    private let buttons: NSStackView

    init(title: String, body text: String, releasePage: URL, onInstall: @escaping () -> Void, onLater: @escaping () -> Void) {
        body = Layout.label(text, wraps: true)
        let install = ActionButton("Install and restart", handler: onInstall)
        let later = ActionButton("Later", handler: onLater)
        install.keyEquivalent = ""
        later.keyEquivalent = ""
        buttons = Layout.row([install, later, LinkButton("Release notes", url: releasePage)], spacing: 10)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let heading = Layout.label(title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        body.preferredMaxLayoutWidth = 1100
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = Layout.column([heading, body, buttons], spacing: 8)
        Layout.pin(stack, in: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    func setBusy(_ text: String) {
        body.stringValue = text
        buttons.isHidden = true
    }
}
