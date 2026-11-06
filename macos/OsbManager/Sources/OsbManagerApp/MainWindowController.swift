import AppKit
import OsbManagerCore
import UniformTypeIdentifiers

@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    public static let botUrl = "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js"

    public let window: NSWindow
    public let tabView = NSTabView()
    let services: AppServices
    let manager: GameManager

    private let accountsTable = DataTable(columns: [.init("Accounts", 200)])
    private let framePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = Layout.label("")
    private var accountPanel: AccountPanel!
    private let statusPanel = StatusPanel()
    private let statsPanel = StatsPanel()
    private var soxPanel: SoxPanel!
    private let footerLabel = Layout.label("", secondary: true)
    private let startedAt = Date()
    private var scriptsPanel: ScriptsPanel!
    private let logPanel = LogPanel()
    private var refreshTimer: Timer?
    private var rootStack: NSStackView?
    private var consentBanner: NSView?
    private var updateBanner: NSView?

    public init(services: AppServices, manager: GameManager) {
        self.services = services
        self.manager = manager
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        accountPanel = AccountPanel(
            onSave: { [unowned self] form in self.saveSelectedAccount(form) },
            onForgetPassword: { [unowned self] in self.forgetSelectedPassword() },
            onStart: { [unowned self] light in self.startSelected(light: light) },
            onToggleVisibility: { [unowned self] in self.toggleSelectedVisibility() }
        )
        soxPanel = SoxPanel(
            hideStar: services.settings.hideStarSox,
            onFilterChange: { [unowned self] in self.refreshSox() },
            onHideStarChange: { [unowned self] in self.setSoxHideStar(self.soxPanel.hideStar) },
            onClear: { [unowned self] in self.confirmAndClearSox() }
        )
        scriptsPanel = ScriptsPanel(
            addFile: { [unowned self] in self.addScriptFromFile() },
            addUrl: { [unowned self] in self.addScriptFromUrl() },
            update: { [unowned self] in self.updateScripts() },
            remove: { [unowned self] in self.removeSelectedScripts() },
            reload: { [unowned self] in self.reloadGameWindows() }
        )
        buildWindow()
        wire()
        refreshAll()
    }

    public var selectedAccount: Account? {
        guard let row = accountsTable.selectedRow, row < services.accounts.accounts.count else { return nil }
        return services.accounts.accounts[row]
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
    }

    public func setConsentBanner(_ banner: NSView?) {
        consentBanner?.removeFromSuperview()
        consentBanner = banner
        guard let banner, let rootStack else { return }
        rootStack.insertArrangedSubview(banner, at: 0)
        banner.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    public func setUpdateBanner(_ banner: NSView?) {
        updateBanner?.removeFromSuperview()
        updateBanner = banner
        guard let banner, let rootStack else { return }
        rootStack.insertArrangedSubview(banner, at: 0)
        banner.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    public func select(accountId: String?) {
        accountsTable.select(row: services.accounts.accounts.firstIndex { $0.id == accountId })
        showSelectedAccount()
    }

    public func selectTab(_ title: String) {
        tabView.selectTabViewItem(withIdentifier: title)
    }

    public func refreshAll() {
        let accounts = services.accounts.accounts
        accountsTable.setRows(
            accounts.map { [manager.listText(for: $0)] },
            styles: accounts.map { account in
                guard let game = manager.windows[account.id] else { return .dimmed }
                return game.inGame ? .positive : .normal
            }
        )
        statusPanel.show(accounts.map(manager.statusRow(for:)))
        statsPanel.show(StatsTable.rows(entries: statsEntries(), drops: services.sox.drops, since: startedAt))
        let cacheText = services.settings.shareGameFiles ? services.cacheIfCreated.map { CacheText.line($0.counters) } : nil
        footerLabel.stringValue = FooterText.line(botVersion: accounts.lazy.compactMap { self.manager.windows[$0.id]?.status?.botVersion }.first, cache: cacheText)
        let inGame = manager.inGameCount
        countLabel.stringValue = "\(inGame)/\(accounts.count) in game · \(manager.windows.count) open"
        countLabel.textColor = inGame > 0 ? .systemGreen : .labelColor
        if let index = AppSettings.frameLimits.firstIndex(of: services.settings.frameLimit), framePopup.indexOfSelectedItem != index {
            framePopup.selectItem(at: index)
        }
    }

    public var statsRows: [[String]] { statsPanel.table.rows }
    public var soxRows: [[String]] { soxPanel.table.rows }
    public var soxSummaryText: String { SoxTable.summary(drops: services.sox.drops, onlyMine: soxPanel.onlyMine, hideStar: soxPanel.hideStar) }
    public var footerText: String { footerLabel.stringValue }
    public var passwordNoteText: String { accountPanel.passwordNoteText }
    public var countText: String { countLabel.stringValue }

    public func refreshSox() {
        soxPanel.show(services.sox.drops)
    }

    public func setSoxOnlyMine(_ on: Bool) {
        soxPanel.onlyMine = on
        refreshSox()
    }

    public func setSoxHideStar(_ on: Bool) {
        soxPanel.hideStar = on
        services.settings.hideStarSox = on
        saveSettings()
        refreshSox()
    }

    public func clearSoxList() {
        do {
            try services.sox.clear()
        } catch {
            services.log.error("Could not clear the SoX list", error)
        }
        refreshSox()
        refreshAll()
    }

    public func refreshScripts() {
        scriptsPanel.show(services.scripts.scripts)
    }

    public func removeAccount(_ account: Account) async {
        manager.forget(account.id)
        await manager.closeAndWait(account.id)
        do {
            try services.accounts.remove(id: account.id, credentials: services.credentials)
        } catch {
            services.log.error("\(account.name): the saved password could not be deleted", error)
            do {
                try services.accounts.remove(id: account.id)
            } catch {
                services.log.error("\(account.name): could not remove the account", error)
                return
            }
        }
        refreshAll()
        showSelectedAccount()
        await removeProfile(of: account)
    }

    public func installScript(file: URL) -> InstalledScript? {
        do {
            let script = try services.scripts.install(fromFile: file)
            services.log.info("Installed \(script.meta.name) \(script.meta.version) from \(file.lastPathComponent).")
            return script
        } catch {
            services.log.error("Could not install \(file.lastPathComponent)", error)
            return nil
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func confirmAndClearSox() {
        if Dialogs.confirm("Clear the SoX list?") {
            clearSoxList()
        }
    }

    private func statsEntries() -> [StatsEntry] {
        services.accounts.accounts.compactMap { account in
            guard let window = manager.windows[account.id], let status = window.status, let session = status.session else { return nil }
            return StatsEntry(account: account.name, character: status.character ?? "", session: session)
        }
    }

    @objc func addAccount() {
        let name = Dialogs.ask(title: "Add account", prompt: "Account name (shown in this app only):", initial: "") {
            AccountStore.nameProblem($0, existing: services.accounts.accounts, excluding: nil)
        }
        guard let name else { return }
        do {
            let account = try services.accounts.add(name: name)
            services.log.info("\(account.name): added.")
            refreshAll()
            select(accountId: account.id)
        } catch {
            Dialogs.info("Could not add the account", detail: error.localizedDescription, style: .warning)
        }
    }

    @objc func removeSelectedAccount() {
        guard let account = selectedAccount else { return }
        manager.forget(account.id)
        let closing = manager.windows[account.id] != nil ? "Its game window is closed first. " : ""
        let detail = closing + "Its browser data (cookies, saved logins, local storage and the game's own cache for this account) and its saved password are deleted as well. This cannot be undone."
        guard Dialogs.confirm("Remove \(account.name)?", detail: detail, yes: "Remove", no: "Cancel", defaultYes: false) else { return }
        Task { await removeAccount(account) }
    }

    @objc func moveSelectedUp() {
        moveSelected(by: -1)
    }

    @objc func moveSelectedDown() {
        moveSelected(by: 1)
    }

    @objc func startSelectedAccount() {
        startSelected(light: false)
    }

    @objc func startSelectedAccountLight() {
        startSelected(light: true)
    }

    @objc func startAllAccounts() {
        manager.startAll(light: false)
        refreshAll()
    }

    @objc func startAllAccountsLight() {
        manager.startAll(light: true)
        refreshAll()
    }

    @objc func closeAllWindows() {
        _ = manager.closeAll(prompt: true)
        refreshAll()
    }

    @objc func closeSelectedWindow() {
        if let account = selectedAccount {
            manager.close(account.id)
        }
    }

    @objc func openDataFolder() {
        NSWorkspace.shared.open(services.paths.root)
    }

    @objc func addScriptFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Add userscript"
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .javaScript]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if installScript(file: url) == nil {
            Dialogs.info("Could not add the userscript", detail: "See the Log tab for the reason.", style: .warning)
        }
    }

    @objc func addScriptFromUrl() {
        let address = Dialogs.ask(title: "Add userscript", prompt: "Script address (https://…/*.user.js):", initial: Self.botUrl) {
            URL(string: $0.trimmingCharacters(in: .whitespaces))?.scheme == "https" ? nil : "Use an https:// address."
        }
        guard let address else { return }
        Task {
            if await installScript(fromUrl: address.trimmingCharacters(in: .whitespaces)) == nil {
                Dialogs.info("Could not add the userscript", detail: "See the Log tab for the reason.", style: .warning)
            }
        }
    }

    public func installScript(fromUrl address: String) async -> InstalledScript? {
        do {
            let script = try await services.scripts.install(fromUrl: address, downloader: services.downloader)
            services.log.info("Installed \(script.meta.name) \(script.meta.version) from \(address).")
            return script
        } catch {
            services.log.error("Could not install \(address)", error)
            return nil
        }
    }

    @objc func updateScripts() {
        let installed = services.scripts.scripts
        let selected = scriptsPanel.selectedRows.filter { $0 < installed.count }.map { installed[$0] }
        let targets = selected.isEmpty ? installed : selected
        Task {
            for script in targets {
                guard let source = script.updateSource else {
                    services.log.warn("\(script.meta.name) has no download address; add the new file instead.")
                    continue
                }
                do {
                    let updated = try await services.scripts.install(fromUrl: source, downloader: services.downloader)
                    services.log.info(script.meta.version == updated.meta.version
                        ? "\(updated.meta.name) is up to date (\(script.meta.version))."
                        : "Updated \(updated.meta.name) from \(script.meta.version) to \(updated.meta.version).")
                } catch {
                    services.log.error("Could not update \(script.meta.name)", error)
                }
            }
        }
    }

    @objc func removeSelectedScripts() {
        let installed = services.scripts.scripts
        for row in scriptsPanel.selectedRows where row < installed.count {
            let script = installed[row]
            guard Dialogs.confirm("Remove \(script.meta.name)?") else { continue }
            do {
                try services.scripts.remove(script.id)
                services.log.info("Removed \(script.meta.name).")
            } catch {
                services.log.error("Could not remove \(script.meta.name)", error)
            }
        }
    }

    @objc func reloadGameWindows() {
        manager.reloadAll()
    }

    @objc func chooseFrameLimit(_ sender: NSMenuItem) {
        setFrameLimit(sender.tag)
    }

    @objc public func toggleRestartAfterRendererFailure() {
        services.settings.restartAfterRendererFailure.toggle()
        saveSettings()
        services.log.info("Restart a window when its renderer cannot start: \(services.settings.restartAfterRendererFailure ? "on" : "off").")
    }

    @objc public func toggleShareGameFiles() {
        services.settings.shareGameFiles.toggle()
        services.applyShareSetting()
        saveSettings()
        services.log.info(services.settings.shareGameFiles
            ? "Game files are shared between accounts."
            : "Game files are no longer shared between accounts.")
    }

    @objc func clearSharedCache() {
        if !manager.windows.isEmpty {
            Dialogs.info("Close all game windows first.")
            return
        }
        guard Dialogs.confirm("Delete the shared game asset cache? Accounts download the files again on their next start.") else { return }
        performClearSharedCache()
    }

    public func performClearSharedCache() {
        services.sharedCache().clear()
        services.log.info("Cleared the shared asset cache.")
        refreshAll()
    }

    public func setFrameLimit(_ fps: Int) {
        guard AppSettings.frameLimits.contains(fps) else { return }
        services.settings.frameLimit = fps
        saveSettings()
        manager.applyFrameLimitToAll()
        services.log.info(fps == 0 ? "Frame rate limit off." : "Frame rate limited to \(fps) FPS.")
        refreshAll()
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(chooseFrameLimit(_:)):
            item.state = item.tag == services.settings.frameLimit ? .on : .off
            return true
        case #selector(toggleShareGameFiles):
            item.state = services.settings.shareGameFiles ? .on : .off
            return true
        case #selector(toggleRestartAfterRendererFailure):
            item.state = services.settings.restartAfterRendererFailure ? .on : .off
            return true
        case #selector(removeSelectedAccount), #selector(moveSelectedUp), #selector(moveSelectedDown), #selector(startSelectedAccount), #selector(startSelectedAccountLight), #selector(closeSelectedWindow):
            return selectedAccount != nil
        default:
            return true
        }
    }

    @objc private func framePopupChanged() {
        let index = framePopup.indexOfSelectedItem
        if index >= 0, index < AppSettings.frameLimits.count {
            setFrameLimit(AppSettings.frameLimits[index])
        }
    }

    private func startSelected(light: Bool) {
        guard let account = selectedAccount else {
            Dialogs.info("Select an account first.")
            return
        }
        manager.startOrShow(account.id, light: light)
        refreshAll()
    }

    private func toggleSelectedVisibility() {
        if let account = selectedAccount, let game = manager.windows[account.id] {
            game.toggleVisibility()
            refreshAll()
        }
    }

    private func moveSelected(by offset: Int) {
        guard let account = selectedAccount else { return }
        do {
            if try services.accounts.move(id: account.id, by: offset) {
                manager.queue.sort(by: services.accounts.accounts.map(\.id))
                refreshAll()
                select(accountId: account.id)
            }
        } catch {
            services.log.error("Could not save the new order", error)
        }
    }

    private func saveSelectedAccount(_ form: AccountForm) {
        guard let account = selectedAccount else { return }
        if let problem = applyAccountForm(accountId: account.id, form: form) {
            Dialogs.info(problem, style: .warning)
            return
        }
        accountPanel.clearPasswordField()
        refreshAll()
        select(accountId: account.id)
    }

    public func applyAccountForm(accountId: String, form: AccountForm) -> String? {
        guard services.accounts.account(id: accountId) != nil else { return nil }
        let saved = (try? services.credentials.exists(accountId: accountId)) ?? false
        if let problem = AccountStore.nameProblem(form.name, existing: services.accounts.accounts, excluding: accountId)
            ?? AccountStore.loginProblem(form.details, hasSavedPassword: saved) {
            return problem
        }
        do {
            try services.accounts.rename(id: accountId, to: form.name)
            try services.accounts.update(id: accountId) { $0.startLight = form.startLight }
            try services.accounts.updateLogin(id: accountId, details: form.details, credentials: services.credentials)
        } catch let error as CredentialStoreError {
            services.log.error("Could not save the password to the Keychain", error)
            return "The password could not be saved to your Keychain (error \(error.status))."
        } catch {
            services.log.error("Could not save the account", error)
            return error.localizedDescription
        }
        let name = services.accounts.account(id: accountId)?.name ?? "Account"
        services.log.info("\(name): settings saved\(form.details.autoLogin ? " (automatic login on)" : "").")
        manager.windows[accountId]?.sendAutoLogin()
        return nil
    }

    public func forgetPassword(accountId: String) {
        guard let account = services.accounts.account(id: accountId) else { return }
        do {
            try services.accounts.clearPassword(id: accountId, credentials: services.credentials)
            services.log.info("\(account.name): saved password removed; automatic login off.")
        } catch {
            services.log.error("\(account.name): could not remove the saved password", error)
        }
        manager.windows[accountId]?.sendAutoLogin()
        showSelectedAccount()
    }

    private func forgetSelectedPassword() {
        if let account = selectedAccount {
            forgetPassword(accountId: account.id)
        }
    }

    public func showSelectedAccount() {
        let account = selectedAccount
        let saved = account.map { (try? services.credentials.exists(accountId: $0.id)) ?? false } ?? false
        accountPanel.show(account, hasPassword: saved)
    }

    private func saveSettings() {
        do {
            try services.settings.save()
        } catch {
            services.log.error("Could not save the settings", error)
        }
        refreshAll()
    }

    private func removeProfile(of account: Account) async {
        do {
            try await services.profiles.remove(account.dataStoreId)
            services.log.info("\(account.name): removed with its browser data.")
        } catch {
            services.log.error("\(account.name): removed, but its browser data could not be deleted (profile \(account.dataStoreId.uuidString.lowercased()))", error)
        }
    }

    private func buildWindow() {
        window.title = AppIdentity.name
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 440)
        window.delegate = self
        window.center()

        for (identifier, label, view) in [
            ("Account", "Account", accountPanel.view),
            ("Status", "Status", statusPanel.view),
            ("Stats", "Stats", statsPanel.view),
            ("SoX", "SoX", soxPanel.view),
            ("Scripts", "Scripts", scriptsPanel.view),
            ("Log", "Log", logPanel.view),
        ] as [(String, String, NSView)] {
            let item = NSTabViewItem(identifier: identifier)
            item.label = label
            item.view = view
            tabView.addTabViewItem(item)
        }

        let accountButtons = Layout.row([
            ActionButton("+", tip: "Add account") { [unowned self] in self.addAccount() },
            ActionButton("−", tip: "Remove account") { [unowned self] in self.removeSelectedAccount() },
            ActionButton("▲", tip: "Move up") { [unowned self] in self.moveSelectedUp() },
            ActionButton("▼", tip: "Move down") { [unowned self] in self.moveSelectedDown() },
        ], spacing: 4)
        let left = Layout.column([accountsTable.scrollView, accountButtons], spacing: 6)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        accountsTable.scrollView.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(tabView)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        for fps in AppSettings.frameLimits {
            framePopup.addItem(withTitle: fps == 0 ? "Frame limit: none" : "Frame limit: \(fps) FPS")
        }
        framePopup.target = self
        framePopup.action = #selector(framePopupChanged)
        framePopup.setAccessibilityLabel("Frame rate limit")

        let bottom = Layout.row([
            ActionButton("Start") { [unowned self] in self.startSelected(light: false) },
            ActionButton("Start light") { [unowned self] in self.startSelected(light: true) },
            ActionButton("Start all") { [unowned self] in self.startAllAccounts() },
            ActionButton("Start all light") { [unowned self] in self.startAllAccountsLight() },
            ActionButton("Close all") { [unowned self] in self.closeAllWindows() },
            framePopup,
            ActionButton("Open data folder") { [unowned self] in self.openDataFolder() },
            countLabel,
        ])
        let root = Layout.column([split, bottom, footerLabel], spacing: 10)
        root.distribution = .fill
        rootStack = root
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        let content = NSView()
        Layout.pin(root, in: content, insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.contentView = content
        DispatchQueue.main.async { split.setPosition(230, ofDividerAt: 0) }
    }

    private func wire() {
        accountsTable.onSelectionChange = { [unowned self] in self.showSelectedAccount() }
        accountsTable.onDoubleClick = { [unowned self] row in
            guard row < self.services.accounts.accounts.count else { return }
            let account = self.services.accounts.accounts[row]
            self.manager.startOrShow(account.id, light: account.startLight)
            self.refreshAll()
        }
        scriptsPanel.table.onToggle = { [unowned self] row, enabled in
            let installed = self.services.scripts.scripts
            guard row < installed.count else { return }
            do {
                try self.services.scripts.setEnabled(installed[row].id, enabled)
            } catch {
                self.services.log.error("Could not save the script setting", error)
            }
        }
        services.scripts.onChange = { [weak self] in self?.refreshScripts() }
        services.sox.onAdded = { [weak self] _ in self?.refreshSox(); self?.refreshAll() }
        services.sox.onUpdated = { [weak self] _ in self?.refreshSox() }
        services.log.onAdded = { [weak self] entry in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.logPanel.append(entry) }
            }
        }
        logPanel.replace(with: services.log.recent)
        manager.onChange = { [weak self] in self?.refreshAll() }
        refreshScripts()
        refreshSox()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                #if DEBUG
                LatencyRecorder.shared?.recordTimerFire()
                #endif
                self?.manager.startQueued()
                self?.refreshAll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        showSelectedAccount()
    }
}
