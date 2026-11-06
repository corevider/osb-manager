import AppKit

@MainActor
final class DataTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Column {
        let title: String
        let width: CGFloat
        let alignment: NSTextAlignment

        init(_ title: String, _ width: CGFloat, _ alignment: NSTextAlignment = .left) {
            self.title = title
            self.width = width
            self.alignment = alignment
        }
    }

    enum RowStyle {
        case normal
        case dimmed
        case positive
        case bold
    }

    let scrollView = NSScrollView()
    let tableView = NSTableView()
    var onSelectionChange: (() -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onToggle: ((Int, Bool) -> Void)?

    private let columns: [Column]
    private let hasCheckbox: Bool
    private(set) var rows: [[String]] = []
    private var styles: [RowStyle] = []
    private var checks: [Bool] = []
    private var refreshing = false

    init(columns: [Column], checkbox: Bool = false, multipleSelection: Bool = false) {
        self.columns = columns
        hasCheckbox = checkbox
        super.init()
        if checkbox {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
            column.title = "On"
            column.width = 36
            column.minWidth = 36
            column.maxWidth = 36
            tableView.addTableColumn(column)
        }
        for (index, definition) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = definition.title
            column.width = definition.width
            column.minWidth = 40
            column.headerCell.alignment = definition.alignment
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = multipleSelection
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
    }

    var selectedRows: [Int] {
        tableView.selectedRowIndexes.map { $0 }
    }

    var selectedRow: Int? {
        tableView.selectedRow >= 0 ? tableView.selectedRow : nil
    }

    func select(row: Int?) {
        if let row, row >= 0, row < rows.count {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    func setRows(_ newRows: [[String]], styles newStyles: [RowStyle]? = nil, checks newChecks: [Bool]? = nil) {
        let resolvedStyles = newStyles ?? Array(repeating: .normal, count: newRows.count)
        let resolvedChecks = newChecks ?? Array(repeating: false, count: newRows.count)
        if newRows == rows && resolvedStyles == styles && resolvedChecks == checks {
            return
        }
        let selection = tableView.selectedRowIndexes
        rows = newRows
        styles = resolvedStyles
        checks = resolvedChecks
        refreshing = true
        tableView.reloadData()
        tableView.selectRowIndexes(selection.filteredIndexSet { $0 < newRows.count }, byExtendingSelection: false)
        refreshing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, row < rows.count else { return nil }
        if identifier.rawValue == "check" {
            let button = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton) ?? {
                let created = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
                created.identifier = identifier
                return created
            }()
            button.tag = row
            button.state = checks[row] ? .on : .off
            return button
        }
        guard let column = Int(identifier.rawValue.dropFirst()), column < columns.count else { return nil }
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? {
            let created = NSTextField(labelWithString: "")
            created.identifier = identifier
            created.lineBreakMode = .byTruncatingTail
            return created
        }()
        field.alignment = columns[column].alignment
        field.stringValue = column < rows[row].count ? rows[row][column] : ""
        switch styles[row] {
        case .normal:
            field.textColor = .labelColor
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
        case .dimmed:
            field.textColor = .secondaryLabelColor
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
        case .positive:
            field.textColor = .systemGreen
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
        case .bold:
            field.textColor = .labelColor
            field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !refreshing {
            onSelectionChange?()
        }
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        if row >= 0 {
            onDoubleClick?(row)
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < checks.count else { return }
        onToggle?(sender.tag, sender.state == .on)
    }
}
