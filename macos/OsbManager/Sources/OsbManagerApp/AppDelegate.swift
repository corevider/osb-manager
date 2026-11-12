import AppKit
import OsbManagerCef
import OsbManagerCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private static let closeTimeout: TimeInterval = 20

    public let options: LaunchOptions
    public let services: AppServices
    public private(set) var manager: GameManager!
    public private(set) var main: MainWindowController!
    public private(set) var telemetry: TelemetryController?
    public private(set) var updates: UpdateController?
    public private(set) var osb: OsbController?
    private let driver: ((AppDelegate) async -> Void)?
    private var terminating = false
    private var leftMessageLoop = false

    public init(options: LaunchOptions, services: AppServices, driver: ((AppDelegate) async -> Void)?) {
        self.options = options
        self.services = services
        self.driver = driver
        super.init()
    }

    public func begin() {
        guard manager == nil else { return }
        services.applyShareSetting()
        manager = GameManager(services: services)
        manager.onWindowClosed = { [weak self] in self?.finishTerminationIfReady() }
        main = MainWindowController(services: services, manager: manager)
        let updates = UpdateController(services: services, manager: manager, arguments: Array(CommandLine.arguments.dropFirst()))
        updates.attach(main: main)
        updates.onQuitForUpdate = { [weak self] in self?.requestTermination(confirm: false) }
        self.updates = updates
        NSApp.mainMenu = AppMenu.build(main: main, app: self, services: services)
        main.show()
        NSApp.activate()
        startRequestedAccounts()
        startOsbController()
        startLatencyRecording()
        startTelemetry()
        if driver == nil {
            updates.start()
        }
        if let driver {
            Task { await driver(self) }
        }
    }

    public func requestTermination(confirm: Bool) {
        guard !terminating else { return }
        guard manager != nil else {
            leaveMessageLoop()
            return
        }
        if confirm, let question = ClosePolicy.allWindowsQuestion(inGameCount: manager.inGameCount, verb: "quit"), !Dialogs.confirm(question) {
            return
        }
        terminating = true
        services.log.info("Quitting: closing \(manager.windows.count) game window\(manager.windows.count == 1 ? "" : "s").")
        _ = manager.closeAll(prompt: false)
        finishTerminationIfReady()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeTimeout) { [weak self] in
            guard let self, !self.leftMessageLoop else { return }
            self.services.log.error("Quitting: \(self.manager.windows.count) game windows did not close in time, leaving anyway.")
            self.leaveMessageLoop()
        }
    }

    private func startOsbController() {
        guard driver == nil || options.osbUrl != nil else { return }
        let controller = OsbController(services: services, manager: manager, options: options)
        controller.onInstallLineChange = { [weak self] line in self?.main.setOsbInstallLine(line) }
        osb = controller
        controller.start()
    }

    private func startLatencyRecording() {
        #if DEBUG
        guard let url = options.latencyLog else { return }
        let recorder = LatencyRecorder(url: url)
        LatencyRecorder.shared = recorder
        recorder.startProbe()
        #endif
    }

    private func startTelemetry() {
        Task { @MainActor in
            guard let controller = await TelemetryController.create(services: services, manager: manager, options: options) else { return }
            telemetry = controller
            controller.attach(main: main)
            controller.start()
            #if DEBUG
            if let folder = options.dialogShots {
                await DialogShots.capture(controller: controller, main: main, into: folder)
                requestTermination(confirm: false)
            }
            #endif
        }
    }

    private func finishTerminationIfReady() {
        guard terminating, manager.windows.isEmpty else { return }
        leaveMessageLoop()
    }

    private func leaveMessageLoop() {
        guard !leftMessageLoop else { return }
        leftMessageLoop = true
        telemetry?.stop()
        updates?.stop()
        osb?.stop()
        #if DEBUG
        LatencyRecorder.shared?.flush()
        #endif
        services.shutdownCache()
        services.log.info("Quit.")
        CefRuntime.quit()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination(confirm: true)
        return .terminateCancel
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            main?.show()
        }
        return true
    }

    public func currentGameWindow() -> GameWindowController? {
        guard manager != nil else { return nil }
        if let key = NSApp.keyWindow, let game = manager.windows.values.first(where: { $0.window === key }) {
            return game
        }
        return main.selectedAccount.flatMap { manager.windows[$0.id] }
    }

    @objc func reloadGame() {
        currentGameWindow()?.reloadPage()
    }

    @objc func toggleLight() {
        if let game = currentGameWindow() {
            game.setLight(!game.light)
            main.refreshAll()
        }
    }

    @objc func toggleMute() {
        if let game = currentGameWindow() {
            game.setMuted(!game.muted)
            main.refreshAll()
        }
    }

    @objc func toggleGameVisibility() {
        if let game = currentGameWindow() {
            game.toggleVisibility()
            main.refreshAll()
        }
    }

    @objc func showPrivacyWindow() {
        telemetry?.showPrivacy()
    }

    @objc func showReportWindow() {
        telemetry?.showReport()
    }

    @objc func showUnsentReportsWindow() {
        telemetry?.showUnsentReports()
    }

    @objc func showMainWindow() {
        main.show()
    }

    @objc func showGameWindow(_ sender: NSMenuItem) {
        if let accountId = sender.representedObject as? String {
            manager.windows[accountId]?.show(activate: true)
            main.refreshAll()
        }
    }

    @objc func performEditAction(_ sender: NSMenuItem) {
        guard let command = EditAction(rawValue: sender.tag) else { return }
        if manager != nil, let key = NSApp.keyWindow, let game = manager.windows.values.first(where: { $0.window === key }) {
            game.performEdit(command.gameCommand)
            return
        }
        NSApp.sendAction(command.selector, to: nil, from: sender)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let game = currentGameWindow()
        switch item.action {
        case #selector(reloadGame):
            return game != nil
        case #selector(toggleLight):
            item.state = game?.light == true ? .on : .off
            return game != nil
        case #selector(toggleMute):
            item.state = game?.muted == true ? .on : .off
            return game != nil
        case #selector(toggleGameVisibility):
            item.title = game?.isHidden == true ? "Show window" : "Hide window"
            return game != nil
        case #selector(showPrivacyWindow), #selector(showReportWindow), #selector(showUnsentReportsWindow):
            return telemetry != nil
        default:
            return true
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Window", manager != nil else { return }
        menu.items.filter { $0.tag == AppMenu.gameWindowItemTag }.forEach(menu.removeItem)
        for account in services.accounts.accounts {
            guard let game = manager.windows[account.id] else { continue }
            let item = NSMenuItem(title: "\(account.name)\(game.isHidden ? " (hidden)" : "")", action: #selector(showGameWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.id
            item.tag = AppMenu.gameWindowItemTag
            menu.addItem(item)
        }
    }

    private func startRequestedAccounts() {
        for name in options.start {
            var account = services.accounts.accounts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if account == nil, AccountStore.nameProblem(name, existing: services.accounts.accounts, excluding: nil) == nil {
                account = try? services.accounts.add(name: name)
            }
            if let account {
                manager.startOrShow(account.id, light: options.startLight || account.startLight)
            }
        }
        main.refreshAll()
    }
}

enum EditAction: Int {
    case undo = 1
    case redo
    case cut
    case copy
    case paste
    case selectAll

    var gameCommand: GameEditCommand {
        switch self {
        case .undo: return .undo
        case .redo: return .redo
        case .cut: return .cut
        case .copy: return .copy
        case .paste: return .paste
        case .selectAll: return .selectAll
        }
    }

    var selector: Selector {
        switch self {
        case .undo: return Selector(("undo:"))
        case .redo: return Selector(("redo:"))
        case .cut: return #selector(NSText.cut(_:))
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSText.selectAll(_:))
        }
    }
}
