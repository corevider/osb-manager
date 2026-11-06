import AppKit
import OsbManagerCore

@MainActor
final class LinkButton: NSButton {
    private let url: URL?
    private let handler: (() -> Void)?

    init(_ title: String, url: URL) {
        self.url = url
        handler = nil
        super.init(frame: .zero)
        configure(title)
    }

    init(_ title: String, handler: @escaping () -> Void) {
        url = nil
        self.handler = handler
        super.init(frame: .zero)
        configure(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    private func configure(_ title: String) {
        isBordered = false
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        setAccessibilityLabel(title)
        target = self
        action = #selector(fire)
    }

    @objc private func fire() {
        if let handler {
            handler()
        } else if let url {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class CloseButton: NSButton {
    private let handler: () -> Void

    init(label: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: label)
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    @objc private func fire() {
        handler()
    }
}

@MainActor
final class ConsentBanner: NSView {
    init(texts: ConsentTexts, onShare: @escaping () -> Void, onDecline: @escaping () -> Void, onWhatIsSent: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = Layout.label(texts.firstRunTitle)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let body = Layout.label(texts.firstRunBody, wraps: true)
        body.preferredMaxLayoutWidth = 1100
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var links: [NSView] = [LinkButton(texts.whatIsSent, handler: onWhatIsSent), LinkButton(texts.privacyPolicy, url: texts.privacyPolicyUrl)]
        if let title = texts.kvkkNotice, let url = texts.kvkkNoticeUrl {
            links.append(LinkButton(title, url: url))
        }
        if let title = texts.explicitConsent, let url = texts.explicitConsentUrl {
            links.append(LinkButton(title, url: url))
        }

        let share = ActionButton(texts.share, handler: onShare)
        let decline = ActionButton(texts.noThanks, handler: onDecline)
        share.keyEquivalent = ""
        decline.keyEquivalent = ""
        let width = max(share.fittingSize.width, decline.fittingSize.width, 120)
        for button in [share, decline] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        let close = CloseButton(label: texts.noThanks, handler: onDecline)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = Layout.row([title, close], spacing: 8)
        let stack = Layout.column([header, body, Layout.row(links, spacing: 16), Layout.row([share, decline], spacing: 10)], spacing: 8)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        Layout.pin(stack, in: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setAccessibilityLabel(texts.firstRunTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }
}
