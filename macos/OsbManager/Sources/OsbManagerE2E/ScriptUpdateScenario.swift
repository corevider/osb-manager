import AppKit
import Foundation
import OsbManagerApp
import OsbManagerCore

@MainActor
final class ScriptUpdateScenario {
    static let oldReleaseUrl = "https://github.com/corevider/osb/releases/download/v2.0.1/osb.user.js"

    private let app: AppDelegate
    private let config: E2EConfiguration
    private let log: JsonLog
    private var summary: [String: Any] = [:]

    init(app: AppDelegate, config: E2EConfiguration, log: JsonLog) {
        self.app = app
        self.config = config
        self.log = log
    }

    private var store: ScriptStore { app.services.scripts }

    func run() async {
        log.write("start", ["out": config.out.path, "data": app.services.paths.root.path])
        if await seedOldRelease() {
            await pressUpdate()
        }
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("script-update-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func seedOldRelease() async -> Bool {
        guard let url = URL(string: Self.oldReleaseUrl) else { return false }
        do {
            let source = try await HttpScriptDownloader().download(url)
            let installed = try store.install(source: source, sourceUrl: Self.oldReleaseUrl)
            summary["seeded"] = "\(installed.meta.name) \(installed.meta.version)"
            summary["updateSource"] = installed.updateSource ?? NSNull()
            log.write("seeded", ["version": installed.meta.version])
            return true
        } catch {
            summary["seedError"] = String(describing: error)
            log.write("seed-failed", ["error": String(describing: error)])
            return false
        }
    }

    private func pressUpdate() async {
        app.main.selectTab("Scripts")
        await pause(1)
        let before = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("scripts-before.png"))
        summary["screenshotBefore"] = before
        guard let button = findButton(titled: "Update", in: app.main.window.contentView) else {
            summary["error"] = "no Update button"
            return
        }
        log.write("update-pressed")
        button.performClick(nil)
        let updated = await waitUntil(timeout: 120) { [store] in
            store.scripts.first?.meta.version != "2.0.1"
        }
        await pause(1)
        summary["updated"] = updated
        summary["scriptsAfter"] = store.scripts.map { "\($0.meta.name) \($0.meta.version) enabled=\($0.enabled)" }
        summary["tableRowsAfter"] = tableVersions()
        summary["screenshotAfter"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("scripts-after.png"))
        log.write("update-finished", ["updated": updated])
    }

    private func tableVersions() -> [String] {
        guard let table = findTable(in: app.main.window.contentView) else { return [] }
        let versionColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("c1"))
        guard versionColumn >= 0 else { return [] }
        return (0..<table.numberOfRows).map { row in
            (table.view(atColumn: versionColumn, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue ?? "row \(row)"
        }
    }

    private func findButton(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title, button.window != nil, !button.isHiddenOrHasHiddenAncestor {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(titled: title, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor, table.tableColumns.first?.identifier.rawValue == "check" {
            return table
        }
        for subview in view.subviews {
            if let found = findTable(in: subview) {
                return found
            }
        }
        return nil
    }
}
