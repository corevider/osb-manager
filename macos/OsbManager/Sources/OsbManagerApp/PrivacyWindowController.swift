import AppKit
import OsbManagerCore
import UniformTypeIdentifiers

@MainActor
final class PrivacyWindowController: NSObject, NSWindowDelegate {
    private static let contentWidth: CGFloat = 600

    let window: NSWindow
    private let controller: TelemetryController
    private let texts: ConsentTexts
    private let interface: InterfaceTexts
    private let usageSwitch: NSButton
    private let charactersSwitch: NSButton
    private let messageLabel = Layout.label("", secondary: true, wraps: true)
    private let installIdField = NSTextField(labelWithString: "")
    private let lastSentLabel = Layout.label("")
    private let payloadView = NSTextView()
    private let payloadScroll = NSScrollView()
    private var payloadShown = false
    private var deleteButton: ActionButton!
    private var downloadButton: ActionButton!
    private var payloadButton: ActionButton!
    private var timer: Timer?
    private var refreshingControls = false

    init(controller: TelemetryController) {
        self.controller = controller
        texts = controller.texts
        interface = controller.interface
        usageSwitch = NSButton(checkboxWithTitle: controller.texts.usageLabel, target: nil, action: nil)
        charactersSwitch = NSButton(checkboxWithTitle: controller.texts.charactersLabel, target: nil, action: nil)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 40, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        build()
        refresh()
    }

    func show(revealPayload: Bool) {
        refresh()
        if revealPayload, !payloadShown {
            togglePayload()
        } else if payloadShown {
            updatePayload()
        }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startTimer()
    }

    func refresh() {
        let state = controller.settings.state
        refreshingControls = true
        usageSwitch.state = state.granted ? .on : .off
        charactersSwitch.state = state.charactersConsent ? .on : .off
        charactersSwitch.isEnabled = state.granted
        refreshingControls = false
        let shownId = state.granted ? state.installId : controller.service.failedDeletionInstallId
        installIdField.stringValue = shownId ?? interface.noInstallYet
        deleteButton.isEnabled = state.granted
        downloadButton.isEnabled = state.granted && state.registered
        lastSentLabel.stringValue = "\(interface.lastSent): \(lastSentText(state))"
        let message = state.granted ? state.config?.message : nil
        messageLabel.stringValue = message.map { "\(interface.serverMessage): \($0)" } ?? ""
        messageLabel.isHidden = message == nil
        if payloadShown {
            updatePayload()
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func lastSentText(_ state: PrivacyState) -> String {
        if let sent = state.lastSentAt {
            return Self.dateFormatter.string(from: sent)
        }
        if state.granted, let result = state.lastResult {
            return result == "server unreachable" ? interface.serverUnreachable : result
        }
        return interface.notSentYet
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func startTimer() {
        guard timer == nil else { return }
        let fresh = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(fresh, forMode: .common)
        timer = fresh
    }

    private func build() {
        window.title = interface.privacyTitle
        window.isReleasedWhenClosed = false
        window.delegate = self

        usageSwitch.target = self
        usageSwitch.action = #selector(usageChanged)
        charactersSwitch.target = self
        charactersSwitch.action = #selector(charactersChanged)

        var links: [NSView] = [LinkButton(texts.privacyPolicy, url: texts.privacyPolicyUrl)]
        if let title = texts.kvkkNotice, let url = texts.kvkkNoticeUrl {
            links.append(LinkButton(title, url: url))
        }
        if let title = texts.explicitConsent, let url = texts.explicitConsentUrl {
            links.append(LinkButton(title, url: url))
        }

        installIdField.isSelectable = true
        installIdField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let copy = ActionButton(interface.copy) { [weak self] in self?.copyInstallId() }
        let idRow = Layout.row([Layout.label(interface.installId + ":"), installIdField, copy], spacing: 8)

        payloadView.isEditable = false
        payloadView.isSelectable = true
        payloadView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        payloadView.isVerticallyResizable = true
        payloadView.textContainerInset = NSSize(width: 6, height: 6)
        payloadView.setAccessibilityLabel(interface.showWhatIsSent)
        payloadScroll.documentView = payloadView
        payloadScroll.hasVerticalScroller = true
        payloadScroll.borderType = .bezelBorder
        payloadScroll.isHidden = true

        payloadButton = ActionButton(interface.showWhatIsSent) { [weak self] in self?.togglePayload() }
        deleteButton = ActionButton(interface.deleteData) { [weak self] in self?.confirmDelete() }
        downloadButton = ActionButton(interface.downloadData) { [weak self] in self?.downloadData() }
        let close = ActionButton(interface.close) { [weak self] in self?.window.close() }

        let usageHelp = help(texts.usageHelp)
        let charactersHelp = help(texts.charactersHelp)
        let buttons = Layout.row([payloadButton, deleteButton, downloadButton], spacing: 8)
        let footer = Layout.row([close], spacing: 8)
        footer.userInterfaceLayoutDirection = .rightToLeft
        let stack = Layout.column([
            usageSwitch, usageHelp,
            charactersSwitch, charactersHelp,
            Layout.row(links, spacing: 16),
            messageLabel,
            idRow,
            lastSentLabel,
            buttons,
            payloadScroll,
            footer,
        ], spacing: 10)
        stack.setCustomSpacing(18, after: usageHelp)
        stack.setCustomSpacing(18, after: charactersHelp)
        let content = NSView()
        Layout.pin(stack, in: content, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for view in [usageHelp, charactersHelp, messageLabel, payloadScroll, footer] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        payloadScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        window.contentView = content
        resizeToFit()
    }

    private func help(_ text: String) -> NSTextField {
        let field = Layout.label(text, secondary: true, wraps: true)
        field.preferredMaxLayoutWidth = Self.contentWidth
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return field
    }

    private func resizeToFit() {
        window.contentView?.layoutSubtreeIfNeeded()
        if let size = window.contentView?.fittingSize {
            window.setContentSize(size)
        }
    }

    private func togglePayload() {
        payloadShown.toggle()
        payloadScroll.isHidden = !payloadShown
        if payloadShown {
            updatePayload()
        }
        resizeToFit()
    }

    private func updatePayload() {
        let service = controller.service
        let granted = controller.settings.state.granted
        let empty = granted ? interface.nothingToShow : interface.nothingSentWhileOff
        Task { [weak self] in
            let text = await service.previewNextPayload()
            self?.payloadView.string = text ?? empty
        }
    }

    private func copyInstallId() {
        guard let id = controller.settings.state.installId ?? controller.service.failedDeletionInstallId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    @objc private func usageChanged() {
        guard !refreshingControls else { return }
        if usageSwitch.state == .on {
            Task {
                await controller.service.accept(characters: false)
                refresh()
            }
        } else if confirm(texts.stopSharingQuestion, yes: interface.stopButton, no: interface.keep) {
            withdraw()
        } else {
            refresh()
        }
    }

    @objc private func charactersChanged() {
        guard !refreshingControls else { return }
        let on = charactersSwitch.state == .on
        Task {
            await controller.service.setCharacters(on)
            refresh()
        }
    }

    private func confirmDelete() {
        guard confirm(texts.deleteQuestion, yes: interface.deleteButton, no: interface.cancel) else { return }
        withdraw()
    }

    private func withdraw() {
        Task {
            let result = await controller.service.withdraw()
            refresh()
            if result == .failed {
                let alert = NSAlert()
                alert.messageText = interface.deletionFailed
                alert.informativeText = controller.service.failedDeletionInstallId ?? ""
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                _ = await alert.beginSheetModal(for: window)
            }
        }
    }

    private func confirm(_ question: String, yes: String, no: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.alertStyle = .warning
        alert.addButton(withTitle: no)
        alert.addButton(withTitle: yes)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func downloadData() {
        guard let id = controller.settings.state.installId else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "osb-data-\(id).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let service = controller.service
        Task {
            let result = await service.export()
            let alert = NSAlert()
            if result.succeeded, (try? result.data.write(to: url, options: .atomic)) != nil {
                alert.messageText = interface.exportSaved
                alert.alertStyle = .informational
            } else {
                alert.messageText = interface.exportFailed
                alert.alertStyle = .warning
            }
            alert.addButton(withTitle: "OK")
            _ = await alert.beginSheetModal(for: window)
        }
    }
}
