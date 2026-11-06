import AppKit
import OsbManagerCore

@MainActor
final class ReportWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private static let contentWidth: CGFloat = 640

    let window: NSWindow
    private let controller: TelemetryController
    private let texts: ConsentTexts
    private let interface: InterfaceTexts
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let descriptionView = NSTextView()
    private let counterLabel = Layout.label("", secondary: true)
    private let gamePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thumbnail = NSImageView()
    private let previewView = NSTextView()
    private let anonymousNote = Layout.label("", wraps: true)
    private let statusLabel = Layout.label("", wraps: true)
    private var addButton: ActionButton!
    private var removeButton: ActionButton!
    private var sendButton: ActionButton!
    private var cancelButton: ActionButton!
    private var screenshot: Data?
    private var diagnostics: [String: Any] = [:]
    private var windowChoices: [(id: String, name: String)] = []
    private var sending = false
    private var sent = false

    init(controller: TelemetryController) {
        self.controller = controller
        texts = controller.texts
        interface = controller.interface
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 40, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        build()
    }

    func show() {
        if !window.isVisible || sent {
            reset()
        }
        refreshAnonymousNote()
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    #if DEBUG
    func prefill(description: String) {
        descriptionView.string = description
        updatePreview()
    }
    #endif

    func refreshAnonymousNote() {
        let anonymous = controller.service.reports.wouldBeAnonymous
        anonymousNote.stringValue = anonymous ? texts.reportAnonymousNote : ""
        anonymousNote.isHidden = !anonymous
    }

    func textDidChange(_ notification: Notification) {
        let scalars = descriptionView.string.unicodeScalars
        if scalars.count > ReportPayload.maxDescription {
            descriptionView.string = String(String.UnicodeScalarView(scalars.prefix(ReportPayload.maxDescription)))
        }
        updatePreview()
    }

    private var kind: ReportKind {
        kindPopup.indexOfSelectedItem == 1 ? .feature : .bug
    }

    private func reset() {
        sent = false
        sending = false
        kindPopup.selectItem(at: 0)
        descriptionView.string = ""
        screenshot = nil
        thumbnail.image = nil
        thumbnail.isHidden = true
        removeButton.isHidden = true
        statusLabel.stringValue = ""
        sendButton.isHidden = false
        sendButton.isEnabled = true
        cancelButton.title = interface.cancel
        diagnostics = ReportDiagnostics.build(
            appVersion: AppVersion.short(),
            osVersion: TelemetryController.operatingSystemText,
            windows: controller.windowDiagnostics(),
            scripts: controller.scriptDiagnostics()
        )
        windowChoices = controller.openGameWindows()
        gamePopup.removeAllItems()
        gamePopup.addItems(withTitles: windowChoices.map(\.name))
        gamePopup.isHidden = windowChoices.isEmpty
        addButton.isEnabled = !windowChoices.isEmpty
        if windowChoices.isEmpty {
            gamePopup.addItem(withTitle: interface.noGameWindow)
            gamePopup.isHidden = false
            gamePopup.isEnabled = false
        } else {
            gamePopup.isEnabled = true
        }
        updatePreview()
    }

    private func updatePreview() {
        counterLabel.stringValue = "\(descriptionView.string.unicodeScalars.count)/\(ReportPayload.maxDescription)"
        previewView.string = ReportPayload.preview(currentJson())
    }

    private func currentJson() -> Data {
        ReportPayload.build(
            kind: kind,
            description: descriptionView.string,
            diagnostics: diagnostics,
            appVersion: AppVersion.short(),
            locale: controller.language.code
        )
    }

    private func build() {
        window.title = interface.reportTitle
        window.isReleasedWhenClosed = false
        window.delegate = self

        kindPopup.addItems(withTitles: [interface.bug, interface.feature])
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        kindPopup.setAccessibilityLabel(interface.kind)

        descriptionView.isRichText = false
        descriptionView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionView.font = .systemFont(ofSize: NSFont.systemFontSize)
        descriptionView.delegate = self
        descriptionView.isVerticallyResizable = true
        descriptionView.textContainerInset = NSSize(width: 4, height: 4)
        descriptionView.setAccessibilityLabel(interface.description)
        let descriptionScroll = NSScrollView()
        descriptionScroll.documentView = descriptionView
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.borderType = .bezelBorder

        gamePopup.setAccessibilityLabel(interface.chooseWindow)
        addButton = ActionButton(texts.screenshotButton) { [weak self] in self?.addScreenshot() }
        removeButton = ActionButton(texts.screenshotRemove) { [weak self] in self?.removeScreenshot() }
        removeButton.isHidden = true
        let screenshotRow = Layout.row([gamePopup, addButton, removeButton], spacing: 8)
        let screenshotHelp = Layout.label(texts.screenshotText, secondary: true, wraps: true)
        screenshotHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        screenshotHelp.preferredMaxLayoutWidth = Self.contentWidth
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.isHidden = true
        thumbnail.wantsLayer = true
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbnail.setAccessibilityLabel(texts.screenshotButton)

        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        previewView.isVerticallyResizable = true
        previewView.textContainerInset = NSSize(width: 6, height: 6)
        previewView.setAccessibilityLabel(interface.preview)
        let previewScroll = NSScrollView()
        previewScroll.documentView = previewView
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder

        let confirmation = Layout.label(texts.reportConfirmation, secondary: true, wraps: true)
        confirmation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        confirmation.preferredMaxLayoutWidth = Self.contentWidth
        anonymousNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        anonymousNote.preferredMaxLayoutWidth = Self.contentWidth
        statusLabel.preferredMaxLayoutWidth = Self.contentWidth

        sendButton = ActionButton(interface.send) { [weak self] in self?.send() }
        cancelButton = ActionButton(interface.cancel) { [weak self] in self?.window.close() }
        let buttons = Layout.row([cancelButton, sendButton], spacing: 8)
        buttons.userInterfaceLayoutDirection = .rightToLeft

        let stack = Layout.column([
            Layout.row([Layout.label(interface.kind + ":"), kindPopup], spacing: 8),
            Layout.label(interface.description + ":"),
            descriptionScroll,
            counterLabel,
            screenshotRow,
            screenshotHelp,
            thumbnail,
            Layout.label(interface.preview + ":"),
            previewScroll,
            confirmation,
            anonymousNote,
            LinkButton(texts.privacyPolicy, url: texts.privacyPolicyUrl),
            statusLabel,
            buttons,
        ], spacing: 8)
        let content = NSView()
        Layout.pin(stack, in: content, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for view in [descriptionScroll, screenshotHelp, previewScroll, confirmation, anonymousNote, statusLabel, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        descriptionScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        previewScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        thumbnail.widthAnchor.constraint(equalToConstant: 240).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 135).isActive = true
        window.contentView = content
        window.contentView?.layoutSubtreeIfNeeded()
        if let size = window.contentView?.fittingSize {
            window.setContentSize(size)
        }
        reset()
    }

    @objc private func kindChanged() {
        updatePreview()
    }

    private func addScreenshot() {
        let index = gamePopup.indexOfSelectedItem
        guard index >= 0, index < windowChoices.count, let game = controller.manager.windows[windowChoices[index].id] else { return }
        addButton.isEnabled = false
        Task {
            let raw = await game.screenshot()
            let encoded = await Task.detached(priority: .userInitiated) { raw.flatMap { ScreenshotEncoder.encode($0) } }.value
            addButton.isEnabled = true
            guard let encoded, let image = NSImage(data: encoded) else {
                statusLabel.stringValue = interface.screenshotFailed
                return
            }
            screenshot = encoded
            thumbnail.image = image
            thumbnail.isHidden = false
            removeButton.isHidden = false
            statusLabel.stringValue = ""
        }
    }

    private func removeScreenshot() {
        screenshot = nil
        thumbnail.image = nil
        thumbnail.isHidden = true
        removeButton.isHidden = true
    }

    private func send() {
        guard !sending, !sent else { return }
        sending = true
        sendButton.isEnabled = false
        statusLabel.stringValue = interface.sending
        let json = currentJson()
        let picture = screenshot
        let service = controller.service
        Task {
            let outcome = await service.sendReport(reportJson: json, screenshot: picture)
            sending = false
            finish(outcome)
        }
    }

    private func finish(_ outcome: ReportOutcome) {
        switch outcome.result {
        case .sent:
            sent = true
            statusLabel.stringValue = outcome.code.map { texts.reportSent(code: $0) } ?? interface.send
            sendButton.isHidden = true
            cancelButton.title = interface.close
        case .queued:
            sent = true
            statusLabel.stringValue = interface.queued
            sendButton.isHidden = true
            cancelButton.title = interface.close
        case .queueFull:
            statusLabel.stringValue = interface.queueFull
            sendButton.isEnabled = true
        case .rejected:
            statusLabel.stringValue = interface.rejected + (outcome.detail.map { " (\($0))" } ?? "")
            sendButton.isEnabled = true
        case .tooLarge, .notSaved, .cancelled:
            statusLabel.stringValue = interface.notSent
            sendButton.isEnabled = true
        }
    }
}
