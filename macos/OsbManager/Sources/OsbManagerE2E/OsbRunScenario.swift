import AppKit
import Foundation
import OsbManagerApp
import OsbManagerCore

@MainActor
final class OsbRunScenario {
    private let app: AppDelegate
    private let config: E2EConfiguration
    private let log: JsonLog
    private var summary: [String: Any] = [:]

    init(app: AppDelegate, config: E2EConfiguration, log: JsonLog) {
        self.app = app
        self.config = config
        self.log = log
    }

    private var scripts: ScriptStore { app.services.scripts }
    private var osbVersion: String? { scripts.scripts.first(where: BotScripts.isOsb)?.meta.version }

    func run() async {
        log.write("start", ["out": config.out.path, "data": app.services.paths.root.path])
        await firstStart()
        await accountMenus()
        if config.phase == "menus" {
            JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("osb-menus-summary.json"))
            NSApp.terminate(nil)
            return
        }
        mark("stage-1")
        await update()
        mark("stage-2")
        await offline()
        mark("stage-3")
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("osb-run-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func firstStart() async {
        let installed = await waitUntil(timeout: 60) { [self] in osbVersion != nil && app.services.settings.osbFirstInstall == .done }
        await pause(1)
        app.main.selectTab("Scripts")
        await pause(1)
        summary["firstStart"] = [
            "installed": installed,
            "scripts": scripts.scripts.map { "\($0.meta.name) \($0.meta.version) enabled=\($0.enabled) source=\($0.sourceUrl ?? "-")" },
            "state": app.services.settings.osbFirstInstall.rawValue,
            "installLine": app.main.osbInstallLineText,
            "log": logLines(),
            "screenshot": snapshotWindow(app.main.window, to: config.out.appendingPathComponent("scripts-first-start.png")),
        ] as [String: Any]
        log.write("first-start", ["installed": installed])
    }

    private func accountMenus() async {
        guard let account = try? app.services.accounts.add(name: "Test one") else {
            summary["menuError"] = "could not add the account"
            return
        }
        app.main.refreshAll()
        app.main.select(accountId: account.id)
        app.main.selectTab("Status")
        await pause(1)
        var menus: [String: Any] = [:]
        menus["list-row"] = menuItems(app.main.window, tableWith: "Accounts", clickRow: 0)
        menus["status-row"] = menuItems(app.main.window, tableWith: "State", clickRow: 0)
        menus["status-empty-area"] = menuItems(app.main.window, tableWith: "State", clickRow: nil)
        menus["list-empty-area"] = menuItems(app.main.window, tableWith: "Accounts", clickRow: nil)
        app.main.selectTab("Stats")
        await pause(0.5)
        menus["stats-empty-area"] = menuItems(app.main.window, tableWith: "Kills", clickRow: nil)
        app.main.selectTab("Status")
        await pause(0.5)
        summary["menus"] = menus
        summary["menuShot"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("account-selected-status.png"))

        let before = account.startLight
        if let toggle = app.main.accountMenuItems(for: account).first(where: { $0.action == .toggleLight }) {
            app.main.perform(toggle)
        }
        let after = app.services.accounts.account(id: account.id)?.startLight
        summary["toggleLight"] = ["before": before, "after": after as Any, "log": logLines().last as Any] as [String: Any]

        app.manager.queue.add(account.id, light: false)
        let queued = app.main.accountMenuItems(for: account).map(\.text)
        if let cancel = app.main.accountMenuItems(for: account).first(where: { $0.action == .cancelStart }) {
            app.main.perform(cancel)
        }
        summary["queued"] = ["items": queued, "stillQueued": app.manager.queue.contains(account.id), "log": logLines().last as Any] as [String: Any]
        log.write("menus-done")
    }

    private func update() async {
        let updated = await waitUntil(timeout: 90) { [self] in
            FileManager.default.fileExists(atPath: config.out.appendingPathComponent("go-update").path) && osbVersion != "2.0.13" && osbVersion != nil
        }
        await pause(1)
        app.main.selectTab("Scripts")
        await pause(1)
        summary["update"] = [
            "updated": updated,
            "version": osbVersion ?? "-",
            "enabled": scripts.scripts.first(where: BotScripts.isOsb)?.enabled as Any,
            "scriptCount": scripts.scripts.count,
            "log": logLines(),
            "screenshot": snapshotWindow(app.main.window, to: config.out.appendingPathComponent("scripts-updated.png")),
        ] as [String: Any]
        log.write("update-done", ["updated": updated])
    }

    private func offline() async {
        _ = await waitUntil(timeout: 120) { [self] in FileManager.default.fileExists(atPath: config.out.appendingPathComponent("go-offline").path) }
        let warned = await waitUntil(timeout: 60) { [self] in warnings().count >= 1 }
        await pause(50)
        app.main.selectTab("Log")
        await pause(1)
        summary["offline"] = [
            "warned": warned,
            "warningCount": warnings().count,
            "warnings": warnings(),
            "screenshot": snapshotWindow(app.main.window, to: config.out.appendingPathComponent("log-offline.png")),
        ] as [String: Any]
        log.write("offline-done", ["warnings": warnings().count])
    }

    private func warnings() -> [String] {
        app.services.log.recent.filter { $0.level == "warn" && $0.message.contains("OSB update") }.map(\.text)
    }

    private func logLines() -> [String] {
        app.services.log.recent.map(\.text)
    }

    private func mark(_ stage: String) {
        FileManager.default.createFile(atPath: config.out.appendingPathComponent("\(stage)-done").path, contents: Data())
    }

    private func menuItems(_ window: NSWindow, tableWith title: String, clickRow: Int?) -> Any {
        guard let table = tables(in: window.contentView).first(where: { $0.tableColumns.contains { $0.title == title } }) else {
            return ["error": "no table with column \(title)"]
        }
        let point: NSPoint
        if let clickRow {
            guard clickRow < table.numberOfRows else { return ["error": "no row \(clickRow)"] }
            let rect = table.rect(ofRow: clickRow)
            point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        } else {
            let rect = table.rect(ofRow: max(table.numberOfRows - 1, 0))
            point = table.convert(NSPoint(x: rect.midX, y: rect.maxY + 30), to: nil)
        }
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            return ["error": "no event"]
        }
        guard let menu = table.menu(for: event) else { return ["menu": NSNull()] }
        var rows: [[String: Any]] = []
        var separator = false
        for item in menu.items {
            if item.isSeparatorItem {
                separator = true
                continue
            }
            rows.append(["text": item.title, "enabled": item.isEnabled, "separatorBefore": separator])
            separator = false
        }
        return ["menu": rows, "selectedRow": table.selectedRow]
    }

    private func tables(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        let own = (view as? NSTableView).map { [$0] } ?? []
        return own + view.subviews.flatMap(tables(in:))
    }
}
