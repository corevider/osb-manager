import AppKit
import OsbManagerCef
import OsbManagerCore

@MainActor
public final class GameWindowController: NSObject, NSWindowDelegate, GameBrowserDelegate {
    public static let gameUrl = URL(string: "https://opensro.online/play")!
    private static let statusTimeout: TimeInterval = 5

    public let accountId: String
    public let window: NSWindow
    public private(set) var browser: GameBrowser?
    public private(set) var light: Bool
    public private(set) var muted = false
    public private(set) var rejectedMessages = 0
    public private(set) var statusCount = 0
    public private(set) var finishedLoads = 0
    public private(set) var failure: String?
    public var onClosed: ((GameWindowController) -> Void)?
    public var onStatus: ((GameWindowController) -> Void)?
    public var onRestartRequested: ((GameWindowController) -> Void)?

    private let services: AppServices
    private let gate = CredentialGate()
    private let recovery: RendererRecovery
    private var lastStatus: BotStatus?
    private var statusAt = Date.distantPast
    private var everReported = false
    private var lastNormalFrame = NSRect.zero
    private var showMaximized = false
    private var closing = false
    private var closed = false

    public init(services: AppServices, account: Account, light: Bool, cascadeIndex: Int, recovery: RendererRecovery = RendererRecovery()) {
        self.services = services
        self.recovery = recovery
        self.accountId = account.id
        self.light = light
        window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowPlacementPolicy.defaultSize), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.title = title(character: nil)
        placeWindow(account.window, cascadeIndex: cascadeIndex)
    }

    public var accountName: String {
        services.accounts.account(id: accountId)?.name ?? "Account"
    }

    public var status: BotStatus? {
        Date().timeIntervalSince(statusAt) < Self.statusTimeout ? lastStatus : nil
    }

    public var latestReport: (status: BotStatus, receivedAt: Date)? {
        lastStatus.map { ($0, statusAt) }
    }

    public var inGame: Bool { status?.inWorld == true }

    public var isClosed: Bool { closed }

    public var isHidden: Bool { !window.isVisible && !window.isMiniaturized }

    public var visibilityText: String {
        window.isMiniaturized ? "minimised" : isHidden ? "hidden" : "visible"
    }

    public var browserMuted: Bool { browser?.isMuted ?? false }

    public var rendererProcessId: Int? {
        let pid = browser?.rendererProcessId ?? 0
        return pid > 0 ? pid : nil
    }

    public var stateText: String {
        let normal = GameWindowState.text(failure: failure, browserReady: browser?.currentUrl != nil || everReported, everReported: everReported, status: status)
        let text = failure == nil ? recovery.stateText(status: status, waitingForSlot: services.renderers.isWaiting(accountId), normal: normal) ?? normal : normal
        return isHidden || window.isMiniaturized ? "\(text) (\(visibilityText))" : text
    }

    public func start() {
        let scripts: [String]
        do {
            scripts = try pageScripts()
        } catch {
            fail("Could not start the page scripts", error)
            return
        }
        let view = NSView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFront(nil)
        let dataFolder = services.profiles.folder(for: dataStoreId)
        let configuration = GameBrowserConfiguration(dataFolder: dataFolder, startUrl: Self.gameUrl, scripts: scripts, allowEvaluate: services.allowEvaluate)
        do {
            browser = try services.browserFactory.makeBrowser(in: view, configuration: configuration, delegate: self)
        } catch {
            fail("Could not start the browser", error)
            return
        }
        services.log.info("\(accountName): browser started (profile \(dataFolder.lastPathComponent)).")
    }

    public func show(activate: Bool) {
        window.contentView?.isHidden = false
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        if showMaximized {
            showMaximized = false
            window.zoom(nil)
        }
    }

    public func hide() {
        window.contentView?.isHidden = true
        window.orderOut(nil)
    }

    public func toggleVisibility() {
        isHidden ? show(activate: true) : hide()
    }

    public func setLight(_ on: Bool) {
        light = on
        applyLight()
    }

    public func setMuted(_ on: Bool) {
        muted = on
        applyMute()
    }

    public func reloadPage() {
        failure = nil
        services.renderers.forget(accountId)
        guard let browser else { return }
        do {
            browser.updateScripts(try pageScripts())
        } catch {
            fail("Reload failed", error)
            return
        }
        if browser.currentUrl == nil {
            browser.load(Self.gameUrl)
        } else {
            browser.reload()
        }
    }

    public func applyFrameLimit() {
        send(PageMessages.frameLimit(services.settings.frameLimit))
    }

    public func sendAutoLogin() {
        guard let account = services.accounts.account(id: accountId) else { return }
        let saved = (try? services.credentials.exists(accountId: accountId)) ?? false
        send(CredentialResponder.autoLoginMessage(account: account, hasPassword: saved))
    }

    public func evaluate(_ code: String) async -> String? {
        try? await browser?.evaluate(code)
    }

    public func screenshot() async -> Data? {
        try? await browser?.captureScreenshot()
    }

    public func performEdit(_ command: GameEditCommand) {
        browser?.perform(command)
    }

    public func closeWithoutPrompt() {
        requestClose()
    }

    public func requestClose() {
        guard !closing else { return }
        closing = true
        savePlacement()
        if let browser, !browser.isClosed {
            browser.close()
            window.close()
            window.contentView = nil
        } else {
            finishClosing()
        }
    }

    public func savePlacement() {
        let frame = window.isZoomed || window.isMiniaturized ? lastNormalFrame : window.frame
        guard frame.width >= CGFloat(WindowPlacementPolicy.minimumWidth) else { return }
        let placement = WindowPlacementPolicy.placement(frame: frame, maximized: window.isZoomed)
        do {
            try services.accounts.update(id: accountId) { $0.window = placement }
        } catch {
            services.log.error("\(accountName): could not save the window position", error)
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing {
            return true
        }
        if let question = ClosePolicy.windowQuestion(accountName: accountName, inGame: inGame), !Dialogs.confirm(question) {
            return false
        }
        requestClose()
        return false
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        window.contentView?.isHidden = true
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        window.contentView?.isHidden = false
    }

    public func windowDidMove(_ notification: Notification) {
        rememberFrame()
    }

    public func windowDidResize(_ notification: Notification) {
        rememberFrame()
    }

    public func gameBrowser(_ browser: GameBrowser, didReceivePageMessage json: String, from origin: PageOrigin) {
        #if DEBUG
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer { LatencyRecorder.shared?.recordMessage(since: startedAt) }
        #endif
        guard let accepted = PageMessageInbox.accept(body: json, isMainFrame: origin.isMainFrame, scheme: origin.scheme, host: origin.host, port: origin.port) else {
            rejectedMessages += 1
            return
        }
        switch accepted {
        case .status(let report):
            record(report)
        case .credentialsRequest:
            answerCredentialsRequest()
        case .rendererSlot(let slot):
            handleRendererSlot(slot)
        }
    }

    public func gameBrowserDidFinishLoading(_ browser: GameBrowser) {
        finishedLoads += 1
        applyLight()
        applyFrameLimit()
        sendAutoLogin()
    }

    public func gameBrowser(_ browser: GameBrowser, didFailLoading description: String) {
        failure = "Could not load the game"
        services.log.error("\(accountName): could not load the game (\(description))")
    }

    public func gameBrowser(_ browser: GameBrowser, rendererDidTerminate reason: String) {
        services.renderers.forget(accountId)
        failure = "Page crashed, use Reload"
        services.log.error("\(accountName): \(failure ?? "") (the page process ended: \(reason)).")
    }

    public func gameBrowser(_ browser: GameBrowser, wantsToOpen url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func gameBrowser(_ browser: GameBrowser, didReportScriptError description: String) {
        services.log.warn("\(accountName): page script error \(description)")
    }

    public func gameBrowserDidClose(_ browser: GameBrowser) {
        finishClosing()
    }

    private func finishClosing() {
        guard !closed else { return }
        closed = true
        services.renderers.forget(accountId)
        window.delegate = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        onClosed?(self)
    }

    private func answerCredentialsRequest() {
        guard isGamePage else { return }
        let name = accountName
        let account = services.accounts.account(id: accountId)
        let gate = self.gate
        let store = services.credentials
        let log = services.log
        Task { [weak self] in
            let response = await Task.detached {
                CredentialResponder.respond(
                    account: account,
                    gate: gate,
                    store: store,
                    onKeychainStatus: { log.warn("\(name): Keychain error \($0).") }
                )
            }.value
            guard let self, self.isGamePage else { return }
            switch response {
            case .send(let id, let password):
                self.send(PageMessages.credentials(id: id, password: password))
                log.info("\(name): typing the saved login into the game.")
            case .refuse(let reason):
                self.send(PageMessages.credentialsDenied(reason: reason))
                log.info("\(name): login details not sent. \(reason)")
            }
        }
    }

    private func record(_ report: BotStatus) {
        let before = lastStatus
        if report.loginStage != before?.loginStage, report.loginStage == "failed" {
            services.log.warn("\(accountName): auto login stopped. \(report.loginMessage ?? "")")
        }
        if report.linked, before?.linked != true {
            services.log.info("\(accountName): linked to the game.")
        }
        logRenderer(report, before: before)
        let step = recovery.observe(previous: before, report: report, restartAllowed: services.settings.restartAfterRendererFailure)
        if let character = report.character {
            services.characters[accountId] = character
        }
        for drop in report.drops {
            if let added = services.sox.add(drop, seenBy: accountName, ours: services.ourCharacters()), added.ours {
                services.log.info("SoX drop: \(added.character) got \(added.item) (Seal of \(added.seal))\(added.monster.isEmpty ? "" : " from " + added.monster).")
            }
        }
        for receipt in report.received {
            let result = services.sox.receive(receipt, ownCharacter: report.character)
            if let matched = result.drop {
                services.log.info("SoX drop: \(matched.item) (Seal of \(matched.seal)) went to \(matched.receivedBy).")
            }
            if result.shouldLog {
                services.log.info("\(accountName): item notice \(receipt.key) [\(receipt.item), \(receipt.count.map { String($0) } ?? "-"), \(receipt.member)] in party \(receipt.inParty), \(result.outcome).")
            }
        }
        lastStatus = report
        statusAt = Date()
        everReported = true
        statusCount += 1
        failure = nil
        window.title = title(character: report.character)
        onStatus?(self)
        recover(step)
    }

    private func logRenderer(_ report: BotStatus, before: BotStatus?) {
        if report.gpuRetries > 0, report.gpuRetries != (before?.gpuRetries ?? 0), report.gpuFailed == nil {
            services.log.warn(RendererTexts.retrying(account: accountName, retries: report.gpuRetries, limit: report.gpuRetryLimit, seconds: report.gpuRetryIn))
        }
        if let failed = report.gpuFailed, before?.gpuFailed == nil {
            services.log.error(RendererTexts.failed(account: accountName, reason: failed))
        }
    }

    private func recover(_ step: RendererStep) {
        guard step != .none else { return }
        let line = RendererTexts.step(account: accountName, step: step, restarted: recovery.restarted)
        switch step {
        case .giveUp:
            services.log.error(line)
        case .reload:
            services.log.warn(line)
            reloadPage()
        case .restart:
            services.log.warn(line)
            onRestartRequested?(self)
        case .none:
            break
        }
    }

    private func handleRendererSlot(_ slot: RendererSlotMessage) {
        if slot.done {
            services.renderers.release(window: accountId, id: slot.id)
            return
        }
        services.renderers.request(window: accountId, id: slot.id) { [weak self] in
            guard let self, !self.closed else { return }
            self.send(PageMessages.rendererSlotGrant(id: slot.id))
        }
    }

    private func pageScripts() throws -> [String] {
        try services.library.scripts(
            frameLimit: services.settings.frameLimit,
            beforeBridge: services.preBridgeScripts,
            userScripts: services.scripts.enabledInjections
        )
    }

    private func applyLight() {
        applyMute()
        send(PageMessages.light(on: light))
    }

    private func applyMute() {
        browser?.setMuted(light || muted)
    }

    private func send(_ message: [String: Any]) {
        guard isGamePage else { return }
        browser?.send(message)
    }

    private var isGamePage: Bool {
        guard let url = browser?.currentUrl else { return false }
        return url.scheme == "https" && url.host == PageMessageInbox.gameHost
    }

    private func fail(_ message: String, _ error: Error) {
        failure = message
        services.log.error("\(accountName): \(message)", error)
    }

    private func title(character: String?) -> String {
        accountName + (character.map { " (\($0))" } ?? "") + " · " + AppIdentity.name
    }

    private var dataStoreId: UUID {
        services.accounts.account(id: accountId)?.dataStoreId ?? UUID()
    }

    private func rememberFrame() {
        if !window.isZoomed && !window.isMiniaturized && window.isVisible {
            lastNormalFrame = window.frame
        }
    }

    private func placeWindow(_ placement: WindowPlacement?, cascadeIndex: Int) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let frame = WindowPlacementPolicy.restoredFrame(for: placement, screens: screens) {
            window.setFrame(frame, display: false)
            showMaximized = placement?.maximized == true
        } else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let content = NSSize(
                width: min(WindowPlacementPolicy.defaultSize.width, visible.width),
                height: min(WindowPlacementPolicy.defaultSize.height, visible.height - 40)
            )
            window.setContentSize(content)
            window.center()
            let offset = CGFloat(cascadeIndex % 6) * 28
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x + offset, y: window.frame.origin.y - offset))
        }
        lastNormalFrame = window.frame
    }
}
