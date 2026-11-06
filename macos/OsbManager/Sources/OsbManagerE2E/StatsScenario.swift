import AppKit
import Foundation
import OsbManagerApp
import OsbManagerCore

enum FakeStatus {
    static let script = """
    (() => {
      if (window.top !== window || location.origin !== 'https://opensro.online') return;
      const original = window.chrome && window.chrome.webview;
      if (!original) return;
      const fake = { fields: null, drops: [] };
      window.__sroFake = fake;
      const proxy = Object.freeze({
        postMessage: message => {
          try {
            if (message && message.type === 'status' && fake.fields) {
              const data = Object.assign({}, message, fake.fields);
              if (fake.drops.length) data.drops = fake.drops.splice(0, 20);
              return original.postMessage(data);
            }
          } catch (error) {}
          return original.postMessage(message);
        },
        addEventListener: (type, listener) => original.addEventListener(type, listener),
        removeEventListener: (type, listener) => original.removeEventListener(type, listener),
      });
      window.chrome = { webview: proxy };
    })();
    """

    static let alphaFields = """
    window.__sroFake.fields = { character: 'hunter', inWorld: true, phase: 'world', level: 90, gold: '1685416273', hp: 73.4, mp: 86, region: 23918, hunting: true, bot: '1.2.172', session: { ms: 4080000, kills: 288, deaths: 0, xp: '0', gold: '-175590000', sox: 1 }, scrolls: { ret: 12, reverse: 3 } };
    return window.__sroFake.fields.character;
    """

    static let betaFields = """
    window.__sroFake.fields = { character: 'bard', inWorld: true, phase: 'world', level: 85, gold: '420000', hp: 100, mp: 55, region: 23920, hunting: true, bot: '1.2.172', session: { ms: 4140000, kills: 273, deaths: 3, xp: '2780000', gold: '197330000', sox: 2 }, scrolls: { ret: 4, reverse: 1 } };
    return window.__sroFake.fields.character;
    """

    static let drops = """
    window.__sroFake.drops.push(...drops);
    return window.__sroFake.drops.length;
    """

    static let alphaDrops = [
        "hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser",
        "stranger has dropped Moon Blade (Seal Of Moon) from Mob",
        "SEAL OF SUN: sorcerer has dropped Lynx Valor Phantom from Tiger Woman.",
    ]

    static let betaDrops = [
        "Hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser",
        "bard has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser",
        "SEAL OF SUN: sorcerer has dropped Lynx Valor Phantom from Tiger Woman.",
        "SEAL OF SUN: bard has dropped Lynx Blade from Tiger Woman.",
    ]
}

@MainActor
final class StatsScenario {
    private let app: AppDelegate
    private let config: E2EConfiguration
    private let log: JsonLog
    private var summary: [String: Any] = [:]

    init(app: AppDelegate, config: E2EConfiguration, log: JsonLog) {
        self.app = app
        self.config = config
        self.log = log
    }

    private var manager: GameManager { app.manager }
    private var store: AccountStore { app.services.accounts }

    func run() async {
        log.write("start", ["scenario": "stats", "phase": config.phase, "data": app.services.paths.root.path])
        guard await waitUntil(timeout: 1200, interval: 10, { !screenIsLocked() }) else {
            summary["skipped"] = "the screen stayed locked"
            finish()
            return
        }
        summary["screenLocked"] = screenIsLocked()
        if config.phase == "restart" {
            await restartPhase()
        } else {
            await firstPhase()
        }
        finish()
    }

    private func finish() {
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("stats-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func game(_ name: String) -> GameWindowController? {
        store.accounts.first { $0.name == name }.flatMap { manager.windows[$0.id] }
    }

    private func shot(_ name: String, tab: String) {
        app.main.selectTab(tab)
        app.main.refreshAll()
        app.main.refreshSox()
        summary["screenshot-\(name)"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("\(name).png"))
    }

    private func firstPhase() async {
        app.services.preBridgeScripts = [FakeStatus.script]
        do {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let width = min(900, Int(visible.width) - 80)
            let height = min(560, Int(visible.height) - 80)
            let alpha = try store.add(name: "alpha")
            let beta = try store.add(name: "beta")
            try store.update(id: alpha.id) { $0.window = WindowPlacement(x: Int(visible.minX) + 60, y: Int(visible.minY) + 20, width: width, height: height, maximized: false) }
            try store.update(id: beta.id) {
                $0.character = "bard"
                $0.window = WindowPlacement(x: Int(visible.minX) + 20, y: Int(visible.minY) + 50, width: width, height: height, maximized: false)
            }
        } catch {
            summary["setupError"] = String(describing: error)
            return
        }
        app.main.refreshAll()
        manager.startAll(light: false)
        let up = await waitUntil(timeout: 120) { game("alpha") != nil && game("beta") != nil }
        guard up, let alpha = game("alpha"), let beta = game("beta") else {
            summary["error"] = "windows did not open"
            return
        }
        _ = await waitUntil(timeout: 240) { alpha.status?.phase == "signed-out" && beta.status?.phase == "signed-out" }

        _ = await waitUntil(timeout: 60) { alpha.statusCount > 3 && beta.statusCount > 3 }
        summary["fakeInstalled"] = [
            "alpha": (await evaluate(alpha, "return !!window.__sroFake;") as? NSNumber)?.boolValue ?? false,
            "beta": (await evaluate(beta, "return !!window.__sroFake;") as? NSNumber)?.boolValue ?? false,
        ]

        summary["soxBefore"] = app.services.sox.drops.count
        summary["statsBefore"] = app.main.statsRows
        shot("stats-empty", tab: "Stats")

        summary["alphaFields"] = await evaluate(alpha, FakeStatus.alphaFields) ?? NSNull()
        summary["betaFields"] = await evaluate(beta, FakeStatus.betaFields) ?? NSNull()
        await pause(3)
        summary["alphaDrops"] = await evaluate(alpha, "const drops = \(jsonArray(FakeStatus.alphaDrops)); " + FakeStatus.drops) ?? NSNull()
        await pause(1)
        summary["betaDrops"] = await evaluate(beta, "const drops = \(jsonArray(FakeStatus.betaDrops)); " + FakeStatus.drops) ?? NSNull()
        await pause(5)

        app.main.refreshAll()
        summary["statusRows"] = app.services.accounts.accounts.map { manager.statusRow(for: $0) }
        summary["statsRows"] = app.main.statsRows
        summary["countText"] = app.main.countText
        summary["footerText"] = app.main.footerText
        summary["ourCharacters"] = app.services.ourCharacters()
        summary["windowTitles"] = [alpha.window.title, beta.window.title]
        shot("status-with-session", tab: "Status")
        shot("stats-tab", tab: "Stats")
        app.main.setSoxOnlyMine(true)
        shot("sox-only-mine", tab: "SoX")
        summary["soxRowsOnlyMine"] = app.main.soxRows
        summary["soxSummaryOnlyMine"] = app.main.soxSummaryText
        app.main.setSoxOnlyMine(false)
        shot("sox-all", tab: "SoX")
        summary["soxRowsAll"] = app.main.soxRows
        summary["soxSummaryAll"] = app.main.soxSummaryText
        summary["soxJson"] = soxFileSummary()
        summary["logLines"] = app.services.log.recent.map(\.text).filter { $0.contains("SoX drop") }
        let comparison: [String: Any] = ["rowsAll": app.main.soxRows]
        JsonLog.writeDocument(comparison, to: config.out.appendingPathComponent("sox-rows-first.json"))
        _ = manager.closeAll(prompt: false)
        await pause(2)
    }

    private func restartPhase() async {
        summary["accountsKept"] = store.accounts.map(\.name)
        summary["soxLoaded"] = app.services.sox.drops.count
        summary["soxJson"] = soxFileSummary()
        app.main.setSoxOnlyMine(false)
        shot("sox-after-restart-all", tab: "SoX")
        summary["soxRowsAll"] = app.main.soxRows
        app.main.setSoxOnlyMine(true)
        shot("sox-after-restart-mine", tab: "SoX")
        summary["soxRowsOnlyMine"] = app.main.soxRows
        summary["soxSummaryOnlyMine"] = app.main.soxSummaryText
        if let compare = config.compare, let data = try? Data(contentsOf: compare),
           let first = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let rows = first["rowsAll"] as? [[String]] {
            summary["sameRowsAsBeforeRestart"] = rows == (summary["soxRowsAll"] as? [[String]] ?? [])
        }
        app.main.clearSoxList()
        summary["afterClear"] = ["rows": app.main.soxRows.count, "json": soxFileSummary()]
        let before = profileFolders()
        for account in store.accounts {
            await app.main.removeAccount(account)
        }
        await pause(3)
        summary["profileFoldersBeforeRemoval"] = before
        summary["profileFoldersAfterRemoval"] = profileFolders()
    }

    private func jsonArray(_ values: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func soxFileSummary() -> [String: Any] {
        let url = app.services.paths.soxFile
        guard let data = try? Data(contentsOf: url), let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return ["exists": FileManager.default.fileExists(atPath: url.path)]
        }
        return ["exists": true, "entries": entries.count, "characters": entries.compactMap { $0["character"] as? String }, "firstAt": entries.first?["at"] ?? NSNull()]
    }

    private func profileFolders() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: app.services.profiles.root.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted()
    }
}
