import AppKit
import OsbManagerCore

@MainActor
final class StatusPanel {
    let table = DataTable(columns: [
        .init("Account", 90), .init("State", 125), .init("Character", 90), .init("Region", 55), .init("Level", 42, .right),
        .init("HP", 42, .right), .init("MP", 42, .right), .init("Gold", 90, .right), .init("Return", 52, .right),
        .init("Reverse", 58, .right), .init("Bot", 70),
    ])

    var view: NSView { table.scrollView }

    func show(_ rows: [[String]]) {
        table.setRows(rows)
    }
}

@MainActor
final class StatsPanel {
    let table = DataTable(columns: [
        .init("Account", 100), .init("Character", 100), .init("Hunting", 70, .right), .init("Kills", 60, .right), .init("Kills/h", 60, .right),
        .init("XP", 70, .right), .init("XP/h", 70, .right), .init("Gold", 80, .right), .init("Gold/h", 80, .right),
        .init("Deaths", 55, .right), .init("SoX", 45, .right),
    ])

    var view: NSView { table.scrollView }

    func show(_ rows: [TableRow]) {
        table.setRows(rows.map(\.cells), styles: rows.map { $0.bold ? .bold : .normal })
    }
}

@MainActor
final class SoxPanel {
    let view = NSView()
    let table = DataTable(columns: [.init("Time", 130), .init("Character", 110), .init("Item", 220), .init("Seal", 60), .init("From", 160), .init("Seen by", 100), .init("Went to", 100)])
    private let mineBox = NSButton(checkboxWithTitle: "Only my characters", target: nil, action: nil)
    private let hideStarBox = NSButton(checkboxWithTitle: "Hide Star items", target: nil, action: nil)
    private let summary = Layout.label("", secondary: true, wraps: true)
    private let onFilterChange: () -> Void
    private let onHideStarChange: () -> Void

    init(hideStar: Bool, onFilterChange: @escaping () -> Void, onHideStarChange: @escaping () -> Void, onClear: @escaping () -> Void) {
        self.onFilterChange = onFilterChange
        self.onHideStarChange = onHideStarChange
        mineBox.state = .on
        mineBox.target = self
        mineBox.action = #selector(filterChanged)
        hideStarBox.state = hideStar ? .on : .off
        hideStarBox.target = self
        hideStarBox.action = #selector(hideStarChanged)
        let bar = Layout.row([mineBox, hideStarBox, ActionButton("Clear list", handler: onClear)])
        summary.preferredMaxLayoutWidth = 700
        let stack = Layout.column([table.scrollView, bar, summary], spacing: 8)
        stack.distribution = .fill
        table.scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        Layout.pin(stack, in: view, insets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8))
        table.scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    var onlyMine: Bool {
        get { mineBox.state == .on }
        set { mineBox.state = newValue ? .on : .off }
    }

    var hideStar: Bool {
        get { hideStarBox.state == .on }
        set { hideStarBox.state = newValue ? .on : .off }
    }

    func show(_ drops: [SoxDrop]) {
        let rows = SoxTable.rows(drops: drops, onlyMine: onlyMine, hideStar: hideStar)
        table.setRows(rows.map(\.cells), styles: rows.map { $0.bold ? .bold : .normal })
        summary.stringValue = SoxTable.summary(drops: drops, onlyMine: onlyMine, hideStar: hideStar)
    }

    @objc private func filterChanged() {
        onFilterChange()
    }

    @objc private func hideStarChanged() {
        onHideStarChange()
    }
}

@MainActor
final class ScriptsPanel {
    let view = NSView()
    let table = DataTable(columns: [.init("Script", 180), .init("Version", 70), .init("Runs on", 220), .init("Run at", 100), .init("Notes", 260)], checkbox: true, multipleSelection: true)
    private let hint = Layout.label("", secondary: true)

    init(addFile: @escaping () -> Void, addUrl: @escaping () -> Void, update: @escaping () -> Void, remove: @escaping () -> Void, reload: @escaping () -> Void) {
        let buttons = Layout.row([
            ActionButton("Add file…", handler: addFile),
            ActionButton("Add from URL…", handler: addUrl),
            ActionButton("Update", handler: update),
            ActionButton("Remove", handler: remove),
            ActionButton("Reload game windows", handler: reload),
        ])
        let stack = Layout.column([table.scrollView, buttons, hint], spacing: 8)
        stack.distribution = .fill
        table.scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        Layout.pin(stack, in: view, insets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8))
        table.scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    var selectedRows: [Int] { table.selectedRows }

    func show(_ scripts: [InstalledScript]) {
        table.setRows(
            scripts.map { [$0.meta.name, $0.meta.version, ($0.meta.matches + $0.meta.includes).joined(separator: " "), $0.meta.runAt, $0.warnings.joined(separator: "; ")] },
            checks: scripts.map(\.enabled)
        )
        hint.stringValue = scripts.isEmpty ? "No scripts yet. Add from URL suggests opensro-bot-lean." : "Changes apply after a game window reloads."
    }
}

@MainActor
final class LogPanel {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var lineCount = 0

    var view: NSView { scrollView }

    init() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Log")
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    func replace(with entries: [LogEntry]) {
        textView.string = ""
        lineCount = 0
        entries.forEach(append)
    }

    func append(_ entry: LogEntry) {
        let atBottom = scrollView.verticalScroller?.floatValue ?? 1 > 0.98 || lineCount == 0
        textView.textStorage?.append(NSAttributedString(string: entry.text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: color(for: entry.level),
        ]))
        lineCount += 1
        if lineCount > AppLog.capacity, let storage = textView.textStorage {
            let first = (storage.string as NSString).range(of: "\n")
            storage.deleteCharacters(in: NSRange(location: 0, length: first.location + first.length))
            lineCount -= 1
        }
        if atBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func color(for level: String) -> NSColor {
        switch level {
        case "error": return .systemRed
        case "warn": return .systemOrange
        default: return .labelColor
        }
    }
}
