import AppKit
import OsbManagerCore

@MainActor
public final class GameManager {
    public nonisolated static let startGap: TimeInterval = 15

    public let services: AppServices
    public let queue: StartQueue
    public let feed: ShowcaseFeed?
    public private(set) var windows: [String: GameWindowController] = [:]
    public var onChange: (() -> Void)?
    public var onWindowClosed: (() -> Void)?
    private var launchedCount = 0
    private var recoveries: [String: RendererRecovery] = [:]
    private var pageHealth: [String: PageHealth] = [:]
    private let restarting = WindowRestarts()

    public init(services: AppServices, queue: StartQueue = StartQueue(gap: GameManager.startGap), feed: ShowcaseFeed? = nil) {
        self.services = services
        self.queue = queue
        self.feed = feed
    }

    public var views: [String: GameView] {
        feed?.views ?? windows.mapValues { $0 as GameView }
    }

    public var inGameCount: Int {
        views.values.filter(\.inGame).count
    }

    public func startOrShow(_ accountId: String, light: Bool) {
        guard let account = services.accounts.account(id: accountId) else { return }
        if let open = windows[accountId] {
            open.show(activate: true)
            return
        }
        if !queue.contains(accountId) {
            queue.add(accountId, light: light)
            if let wait = queue.wait(for: accountId), wait > 0 {
                services.log.info("\(account.name): starts in \(Int(wait.rounded(.up))) s, after the windows before it.")
            }
        }
        startQueued()
    }

    public func startAll(light: Bool) {
        let closed = services.accounts.accounts.filter { windows[$0.id] == nil && !queue.contains($0.id) }
        guard !closed.isEmpty else { return }
        services.log.info("Starting \(closed.count) account\(closed.count == 1 ? "" : "s")\(light ? " in light mode" : ""), one every \(Int(Self.startGap)) s.")
        for account in closed {
            startOrShow(account.id, light: light)
        }
    }

    public func startQueued() {
        if let next = queue.takeDue() {
            launch(next.accountId, light: next.light)
        }
        services.renderers.pump()
    }

    public func watchPages() {
        services.diagnostics?.tickOsbPerf()
        for window in Array(windows.values) {
            window.watchPage()
        }
        if let diagnostics = services.diagnostics, diagnostics.hub.recording {
            diagnostics.windowCache.windows = windows.values.filter { !$0.isClosed }.map(\.perfInfo)
        }
    }

    private func restart(_ window: GameWindowController) {
        guard windows[window.accountId] === window, restarting.request(window.accountId) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { window.closeWithoutPrompt() }
        }
    }

    public func closeAll(prompt: Bool, verb: String = "close") -> Bool {
        if prompt, let question = ClosePolicy.allWindowsQuestion(inGameCount: inGameCount, verb: verb), !Dialogs.confirm(question) {
            return false
        }
        queue.clear()
        restarting.clear()
        for window in Array(windows.values) {
            window.closeWithoutPrompt()
        }
        return true
    }

    public func close(_ accountId: String) {
        windows[accountId]?.window.performClose(nil)
    }

    public func closeAndWait(_ accountId: String, timeout: TimeInterval = 30) async {
        guard let window = windows[accountId] else { return }
        window.requestClose()
        let deadline = Date().addingTimeInterval(timeout)
        while windows[accountId] != nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    public func reloadAll() {
        windows.values.forEach { $0.reloadPage() }
    }

    public func applyFrameLimitToAll() {
        windows.values.forEach { $0.applyFrameLimit() }
    }

    public func savePlacements() {
        windows.values.forEach { $0.savePlacement() }
    }

    public func forget(_ accountId: String) {
        queue.remove(accountId)
    }

    public func stateText(for account: Account) -> String {
        if let window = views[account.id] {
            return window.stateText
        }
        if let wait = queue.wait(for: account.id) {
            return "Starts in \(Int(wait.rounded(.up))) s"
        }
        return "Closed"
    }

    public func listText(for account: Account) -> String {
        guard let window = views[account.id] else {
            return queue.contains(account.id) ? "\(account.name) (queued)" : account.name
        }
        let marks = [window.light ? "light" : nil, window.muted ? "muted" : nil, window.isHidden ? "hidden" : nil, window.isMinimised ? "minimised" : nil]
        return ([account.name, "●"] + marks.compactMap { $0 }).joined(separator: " ")
    }

    public func statusRow(for account: Account) -> [String] {
        guard let window = views[account.id] else {
            return [account.name, stateText(for: account), "", "", "", "", "", "", "", "", ""]
        }
        let status = window.status
        let inWorld = status?.inWorld == true
        return [
            account.name,
            window.stateText,
            status?.character ?? "",
            status?.region.map { "R\($0)" } ?? "",
            status?.level.map(String.init) ?? "",
            inWorld ? Format.percent(status?.hpPercent) : "",
            inWorld ? Format.percent(status?.mpPercent) : "",
            status?.gold.map { Format.number($0) } ?? "",
            inWorld ? (status?.returnScrolls.map { Format.number(Int64($0)) } ?? "") : "",
            inWorld ? (status?.reverseScrolls.map { Format.number(Int64($0)) } ?? "") : "",
            GameWindowState.botColumn(status),
        ]
    }

    private func launch(_ accountId: String, light: Bool) {
        guard feed == nil, windows[accountId] == nil, let account = services.accounts.account(id: accountId) else { return }
        let recovery = recoveries[accountId] ?? RendererRecovery()
        recoveries[accountId] = recovery
        let health = pageHealth[accountId] ?? PageHealth()
        pageHealth[accountId] = health
        let window = GameWindowController(services: services, account: account, light: light, cascadeIndex: launchedCount, recovery: recovery, health: health)
        launchedCount += 1
        window.onRestartRequested = { [weak self] window in self?.restart(window) }
        window.onClosed = { [weak self] closed in
            guard let self else { return }
            self.windows[closed.accountId] = nil
            let restart = self.restarting.takeOnClose(closed.accountId, quitting: false)
            if !restart {
                self.recoveries[closed.accountId] = nil
                self.pageHealth[closed.accountId] = nil
            }
            self.services.log.info("\(self.services.accounts.account(id: closed.accountId)?.name ?? "Account"): closed\(restart ? " for a restart" : "").")
            if restart {
                self.startOrShow(closed.accountId, light: closed.light)
            }
            self.onChange?()
            self.onWindowClosed?()
        }
        window.onStatus = { [weak self] _ in self?.onChange?() }
        windows[accountId] = window
        services.log.info("\(account.name): starting\(light ? " in light mode" : "").")
        window.start()
        window.show(activate: false)
        onChange?()
    }
}
