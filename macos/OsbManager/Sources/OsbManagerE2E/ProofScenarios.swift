import AppKit
import Foundation
import OsbManagerApp
import OsbManagerCef
import OsbManagerCore

@MainActor
struct MeasureScenario {
    let app: AppDelegate
    let config: E2EConfiguration
    let log: JsonLog

    private let sampler = ProcessSampler()

    init(app: AppDelegate, config: E2EConfiguration, log: JsonLog) {
        self.app = app
        self.config = config
        self.log = log
    }

    private var manager: GameManager { app.manager }
    private var store: AccountStore { app.services.accounts }

    func run() async {
        var summary: [String: Any] = ["cef": CefRuntime.version, "phase": config.phase, "settleSeconds": config.settleSeconds, "measureSeconds": config.measureSeconds]
        guard await waitUntil(timeout: 1200, interval: 10, { !screenIsLocked() }) else {
            summary["skipped"] = "the screen stayed locked"
            finish(summary)
            return
        }
        app.services.preBridgeScripts = [Probe.gpuScript]
        let file = config.out.appendingPathComponent("measure-probe.user.js")
        try? Probe.userScript.write(to: file, atomically: true, encoding: .utf8)
        summary["probeInstalled"] = app.main.installScript(file: file) != nil
        if store.accounts.isEmpty {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let width = min(1000, Int(visible.width) - 80)
            let height = min(640, Int(visible.height) - 80)
            if let alpha = try? store.add(name: "alpha"), let beta = try? store.add(name: "beta") {
                try? store.update(id: alpha.id) { $0.window = WindowPlacement(x: Int(visible.minX) + 56, y: Int(visible.minY) + 20, width: width, height: height, maximized: false) }
                try? store.update(id: beta.id) { $0.window = WindowPlacement(x: Int(visible.minX) + 20, y: Int(visible.minY) + 56, width: width, height: height, maximized: false) }
            }
        }
        guard store.accounts.count >= 2 else {
            summary["error"] = "two accounts are needed"
            finish(summary)
            return
        }
        let alphaAccount = store.accounts[0]
        let betaAccount = store.accounts[1]

        let alphaStarted = Date()
        manager.startOrShow(alphaAccount.id, light: false)
        guard let alpha = await window(of: alphaAccount, timeout: 30), await loaded(alpha) else {
            summary["error"] = "alpha did not reach the title screen"
            finish(summary)
            return
        }
        let alphaSeconds = Date().timeIntervalSince(alphaStarted)
        manager.startOrShow(betaAccount.id, light: false)
        guard let beta = await window(of: betaAccount, timeout: 60) else {
            summary["error"] = "beta did not open"
            finish(summary)
            return
        }
        let betaStarted = Date()
        guard await loaded(beta) else {
            summary["error"] = "beta did not reach the title screen"
            finish(summary)
            return
        }
        summary["secondsToTitleScreen"] = ["alpha": alphaSeconds, "betaAfterItsWindowOpened": Date().timeIntervalSince(betaStarted)]
        let alphaPid = alpha.rendererProcessId.map { Int32($0) }
        let betaPid = beta.rendererProcessId.map { Int32($0) }
        summary["renderers"] = ["alpha": alphaPid.map { Int($0) } ?? 0, "beta": betaPid.map { Int($0) } ?? 0]
        await pause(6)

        summary["facts"] = await factsOf(alpha, beta)
        summary["screenshots"] = [
            "alpha": await snapshotGame(alpha, to: config.out.appendingPathComponent("title-alpha.png")),
            "beta": await snapshotGame(beta, to: config.out.appendingPathComponent("title-beta.png")),
        ]
        summary["bridge"] = await bridge(alpha: alpha, beta: beta)

        let both: [(String, GameWindowController, Int32?)] = [("alpha", alpha, alphaPid), ("beta", beta, betaPid)]
        var phases: [[String: Any]] = []
        phases.append(await phase("both visible", windows: both))
        beta.hide()
        phases.append(await phase("beta hidden", windows: both))
        beta.show(activate: false)
        await pause(2)
        alpha.setLight(true)
        beta.setLight(true)
        await pause(3)
        phases.append(await phase("both visible, light", windows: both))
        beta.hide()
        phases.append(await phase("beta hidden, light", windows: both))
        beta.show(activate: false)
        summary["phases"] = phases
        summary["finalFacts"] = await factsOf(alpha, beta)
        summary["rejectedMessages"] = ["alpha": alpha.rejectedMessages, "beta": beta.rejectedMessages]
        summary["statusCounts"] = ["alpha": alpha.statusCount, "beta": beta.statusCount]
        summary["shareGameFiles"] = app.services.settings.shareGameFiles
        let interception = CefPackInterception.shared.statistics
        summary["interception"] = ["active": CefPackInterception.shared.isActive, "served": interception.served, "fellBack": interception.fellBack, "servedBySource": interception.servedBySource]
        summary["packcacheFolderExists"] = FileManager.default.fileExists(atPath: app.services.paths.packCache.path)
        finish(summary)
    }

    private func finish(_ summary: [String: Any]) {
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("measure-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func window(of account: Account, timeout: Double) async -> GameWindowController? {
        _ = await waitUntil(timeout: timeout, interval: 0.5) { manager.windows[account.id] != nil }
        return manager.windows[account.id]
    }

    private func loaded(_ game: GameWindowController) async -> Bool {
        await waitUntil(timeout: 180, interval: 1) {
            (await evaluate(game, Probe.loginScreen, timeout: 5) as? NSNumber)?.boolValue == true
        }
    }

    private func factsOf(_ alpha: GameWindowController, _ beta: GameWindowController) async -> [String: Any] {
        let first: Any? = await evaluateObject(alpha, Probe.pageState)
        let second: Any? = await evaluateObject(beta, Probe.pageState)
        return ["alpha": first ?? NSNull(), "beta": second ?? NSNull()]
    }

    private func bridge(alpha: GameWindowController, beta: GameWindowController) async -> [String: Any] {
        var result: [String: Any] = [:]
        let before = (alpha.statusCount, beta.statusCount)
        await pause(10)
        result["statusMessagesIn10s"] = ["alpha": alpha.statusCount - before.0, "beta": beta.statusCount - before.1]
        var rates: [String: Any] = [:]
        for limit in [60, 30, 60] {
            app.main.setFrameLimit(limit)
            await pause(2)
            rates["limit\(limit)\(rates["limit\(limit)"] == nil ? "" : "Again")"] = await frameRate(alpha, seconds: 6)
        }
        result["frameLimit"] = rates
        alpha.setLight(true)
        let lit = await waitUntil(timeout: 25, interval: 1) { alpha.status?.light == true }
        let onDigest = digest(alpha)
        alpha.setLight(false)
        let unlit = await waitUntil(timeout: 25, interval: 1) { alpha.status?.light == false }
        result["light"] = ["reachedOn": lit, "on": onDigest, "reachedOff": unlit, "off": digest(alpha)]
        beta.setLight(false)
        return result
    }

    private func digest(_ game: GameWindowController) -> [String: Any] {
        let status = game.status
        return [
            "phase": status?.phase ?? NSNull(),
            "light": status?.light ?? NSNull(),
            "lightWaiting": status?.lightWaiting ?? NSNull(),
            "loginStage": status?.loginStage ?? NSNull(),
            "bot": status?.botVersion ?? NSNull(),
            "statusMessages": game.statusCount,
        ]
    }

    private func frameRate(_ game: GameWindowController, seconds: Double) async -> Double? {
        guard let first = await evaluateObject(game, Probe.counters) else { return nil }
        await pause(seconds)
        guard let second = await evaluateObject(game, Probe.counters) else { return nil }
        return rate(first, second, key: "frames")
    }

    private func rate(_ first: [String: Any], _ second: [String: Any], key: String) -> Double? {
        guard let a = (first[key] as? NSNumber)?.doubleValue, let b = (second[key] as? NSNumber)?.doubleValue,
              let c = (first["clock"] as? NSNumber)?.doubleValue, let d = (second["clock"] as? NSNumber)?.doubleValue, d > c else { return nil }
        return (b - a) / ((d - c) / 1000)
    }

    private func phase(_ label: String, windows: [(String, GameWindowController, Int32?)]) async -> [String: Any] {
        log.write("phase-start", ["label": label])
        await pause(config.settleSeconds)
        var startCounters: [String: [String: Any]] = [:]
        for (name, game, _) in windows {
            startCounters[name] = await evaluateObject(game, Probe.counters) ?? [:]
        }
        let statusStart = Dictionary(uniqueKeysWithValues: windows.map { ($0.0, $0.1.statusCount) })
        let begin = Date()
        let first = Dictionary(uniqueKeysWithValues: sampler.read().map { ($0.pid, $0) })
        var peakFootprint: [String: Double] = [:]
        var gpuSamples: [Double] = []
        var gpuMemoryPeak = 0.0
        var occlusion: [String: [Bool]] = [:]
        for _ in 0..<Int(config.measureSeconds) {
            await pause(1)
            var perKind: [String: Double] = [:]
            for reading in sampler.read() {
                perKind[reading.kind, default: 0] += Double(reading.footprint) / 1_048_576
            }
            perKind["total"] = perKind.values.reduce(0, +)
            for (kind, value) in perKind {
                peakFootprint[kind] = max(peakFootprint[kind] ?? 0, value)
            }
            if let gpu = sampler.gpu() {
                gpuSamples.append(gpu.device)
                gpuMemoryPeak = max(gpuMemoryPeak, gpu.inUseMemory / 1_048_576)
            }
            for (name, game, _) in windows {
                occlusion[name, default: []].append(game.window.occlusionState.contains(.visible))
            }
        }
        let elapsed = Date().timeIntervalSince(begin)
        var perProcess: [[String: Any]] = []
        var kindCpu: [String: Double] = [:]
        for reading in sampler.read() {
            guard let start = first[reading.pid], reading.startedAt == start.startedAt else { continue }
            let percent = Double(reading.cpuNanoseconds - start.cpuNanoseconds) / (elapsed * 1_000_000_000) * 100
            kindCpu[reading.kind, default: 0] += percent
            perProcess.append(["pid": Int(reading.pid), "kind": reading.kind, "cpuPercent": percent, "footprintMB": Double(reading.footprint) / 1_048_576])
        }
        kindCpu["total"] = kindCpu.values.reduce(0, +)
        var pages: [String: Any] = [:]
        for (name, game, pid) in windows {
            let end = await evaluateObject(game, Probe.counters) ?? [:]
            let start = startCounters[name] ?? [:]
            let matching = perProcess.first { ($0["pid"] as? Int) == pid.map { Int($0) } }
            let samples = occlusion[name] ?? []
            var page: [String: Any] = [:]
            page["windowVisibility"] = game.visibilityText
            page["pageVisibility"] = end["visibility"] ?? NSNull()
            page["rendererPid"] = pid.map { Int($0) } ?? NSNull()
            page["rendererCpuPercent"] = matching?["cpuPercent"] ?? NSNull()
            page["timerTicksPerSecond"] = rate(start, end, key: "ticks") ?? NSNull()
            page["framesPerSecond"] = rate(start, end, key: "frames") ?? NSNull()
            page["statusMessages"] = game.statusCount - (statusStart[name] ?? 0)
            page["visibleFraction"] = Double(samples.filter { $0 }.count) / Double(max(samples.count, 1))
            pages[name] = page
        }
        var result: [String: Any] = [:]
        result["label"] = label
        result["seconds"] = elapsed
        result["cpuPercentByKind"] = kindCpu
        result["processes"] = perProcess.sorted { ($0["pid"] as? Int ?? 0) < ($1["pid"] as? Int ?? 0) }
        result["footprintPeakMBByKind"] = peakFootprint
        result["gpuDeviceMean"] = gpuSamples.isEmpty ? NSNull() : gpuSamples.reduce(0, +) / Double(gpuSamples.count)
        result["gpuInUsePeakMB"] = gpuMemoryPeak
        result["pages"] = pages
        log.write("phase-end", ["label": label, "cpu": kindCpu["total"] ?? NSNull()])
        return result
    }
}

@MainActor
struct PersistScenario {
    let app: AppDelegate
    let config: E2EConfiguration
    let log: JsonLog

    private var manager: GameManager { app.manager }
    private var store: AccountStore { app.services.accounts }

    func run() async {
        guard await waitUntil(timeout: 1200, interval: 10, { !screenIsLocked() }) else {
            JsonLog.writeDocument(["skipped": "the screen stayed locked"], to: config.out.appendingPathComponent("persist-\(config.phase).json"))
            finish()
            return
        }
        switch config.phase {
        case "check":
            await check()
        case "remove":
            await remove()
        default:
            await seed()
        }
        finish()
    }

    private func finish() {
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func ensureAccounts() {
        guard store.accounts.isEmpty else { return }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1000, Int(visible.width) - 80)
        let height = min(640, Int(visible.height) - 80)
        for (index, name) in ["alpha", "beta"].enumerated() {
            if let account = try? store.add(name: name) {
                try? store.update(id: account.id) { $0.window = WindowPlacement(x: Int(visible.minX) + 20 + 36 * index, y: Int(visible.minY) + 20 + 36 * index, width: width, height: height, maximized: false) }
            }
        }
    }

    private func startBoth() async -> [(String, GameWindowController)]? {
        ensureAccounts()
        guard store.accounts.count >= 2 else { return nil }
        var games: [(String, GameWindowController)] = []
        for account in store.accounts.prefix(2) {
            let started = Date()
            manager.startOrShow(account.id, light: false)
            _ = await waitUntil(timeout: 60, interval: 0.5) { manager.windows[account.id] != nil }
            guard let game = manager.windows[account.id] else { return nil }
            guard await waitForLoginScreen(game, timeout: 180) else { return nil }
            log.write("title", ["account": account.name, "seconds": Date().timeIntervalSince(started)])
            games.append((account.name, game))
        }
        return games
    }

    private func seed() async {
        guard let games = await startBoth() else {
            JsonLog.writeDocument(["error": "the windows did not reach the title screen"], to: config.out.appendingPathComponent("persist-seed.json"))
            return
        }
        var result: [String: Any] = [:]
        for (name, game) in games {
            let token = "\(name)-\(UUID().uuidString.prefix(8))"
            _ = await evaluate(game, """
            localStorage.setItem('e2e.owner', '\(token)');
            document.cookie = 'e2e_owner=\(token); path=/; max-age=86400; Secure; SameSite=Lax';
            window.__e2eAsync = null;
            (async () => {
              const database = await new Promise((resolve, reject) => {
                const request = indexedDB.open('e2e', 1);
                request.onupgradeneeded = () => request.result.createObjectStore('items');
                request.onsuccess = () => resolve(request.result);
                request.onerror = () => reject(request.error);
              });
              await new Promise((resolve, reject) => {
                const transaction = database.transaction('items', 'readwrite');
                transaction.objectStore('items').put('\(token)', 'owner');
                transaction.oncomplete = resolve;
                transaction.onerror = () => reject(transaction.error);
              });
              database.close();
              const cache = await caches.open('e2e');
              await cache.put('/e2e-owner', new Response('\(token)'));
              return 'done';
            })().then(value => { window.__e2eAsync = value; }, error => { window.__e2eAsync = 'error: ' + error; });
            return true;
            """)
            let finished = await waitUntil(timeout: 20, interval: 0.5) { (await evaluate(game, "return window.__e2eAsync;") as? String) == "done" }
            result[name] = ["token": token, "asyncStored": finished]
        }
        await pause(3)
        JsonLog.writeDocument(["seeded": result], to: config.out.appendingPathComponent("persist-seed.json"))
    }

    private func check() async {
        guard let games = await startBoth() else {
            JsonLog.writeDocument(["error": "the windows did not reach the title screen"], to: config.out.appendingPathComponent("persist-check.json"))
            return
        }
        let seeded = config.compare.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        var result: [String: Any] = [:]
        for (name, game) in games {
            _ = await evaluate(game, """
            window.__e2eRead = null;
            (async () => {
              const database = await new Promise((resolve, reject) => {
                const request = indexedDB.open('e2e', 1);
                request.onsuccess = () => resolve(request.result);
                request.onerror = () => reject(request.error);
              });
              const stored = await new Promise(resolve => {
                if (!database.objectStoreNames.contains('items')) { resolve(null); return; }
                const request = database.transaction('items').objectStore('items').get('owner');
                request.onsuccess = () => resolve(request.result === undefined ? null : request.result);
                request.onerror = () => resolve(null);
              });
              database.close();
              const cache = await caches.open('e2e');
              const response = await cache.match('/e2e-owner');
              return { indexedDb: stored, cacheStorage: response ? await response.text() : null };
            })().then(value => { window.__e2eRead = value; }, error => { window.__e2eRead = { error: String(error) }; });
            return true;
            """)
            _ = await waitUntil(timeout: 20, interval: 0.5) { (await evaluate(game, "return window.__e2eRead;")) is [String: Any] }
            let async = await evaluate(game, "return window.__e2eRead;") as? [String: Any] ?? [:]
            let sync = await evaluateObject(game, "return { local: localStorage.getItem('e2e.owner'), cookie: document.cookie.split('; ').filter(c => c.startsWith('e2e_owner=')).map(c => c.slice(10)) };") ?? [:]
            result[name] = ["sync": sync, "async": async]
        }
        JsonLog.writeDocument(["seededBefore": seeded ?? [:], "found": result], to: config.out.appendingPathComponent("persist-check.json"))
    }

    private func remove() async {
        var result: [String: Any] = [:]
        ensureAccounts()
        guard store.accounts.count >= 2 else {
            JsonLog.writeDocument(["error": "two accounts are needed"], to: config.out.appendingPathComponent("persist-remove.json"))
            return
        }
        let alphaAccount = store.accounts[0]
        let betaAccount = store.accounts[1]
        manager.startOrShow(alphaAccount.id, light: false)
        manager.startOrShow(betaAccount.id, light: false)
        _ = await waitUntil(timeout: 60) { manager.windows[alphaAccount.id] != nil }
        _ = await waitUntil(timeout: 60) { manager.windows[betaAccount.id] != nil }
        guard let alpha = manager.windows[alphaAccount.id], let beta = manager.windows[betaAccount.id] else {
            JsonLog.writeDocument(["error": "the windows did not open"], to: config.out.appendingPathComponent("persist-remove.json"))
            return
        }
        let alphaReady = await waitForLoginScreen(alpha, timeout: 180)
        let betaReady = await waitForLoginScreen(beta, timeout: 180)
        result["bothReachedTitleScreen"] = alphaReady && betaReady
        _ = await evaluate(alpha, "localStorage.setItem('e2e.owner', 'alpha-before-removal'); return true;")
        _ = await evaluate(beta, "localStorage.setItem('e2e.owner', 'beta-keeps-it'); return true;")
        await pause(2)

        let profiles = app.services.profiles
        result["alphaFolderBefore"] = profiles.exists(alphaAccount.dataStoreId)
        await app.main.removeAccount(alphaAccount)
        result["alphaWindowGone"] = manager.windows[alphaAccount.id] == nil
        result["alphaFolderAfter"] = profiles.exists(alphaAccount.dataStoreId)
        result["betaFolderAfter"] = profiles.exists(betaAccount.dataStoreId)
        result["accountsLeft"] = store.accounts.map(\.name)
        let before = beta.statusCount
        await pause(4)
        result["betaStatusMessagesAfterRemoval"] = beta.statusCount - before
        result["betaStorage"] = await evaluate(beta, "return localStorage.getItem('e2e.owner');") ?? NSNull()

        if let again = try? store.add(name: "alpha") {
            manager.startOrShow(again.id, light: false)
            _ = await waitUntil(timeout: 60) { manager.windows[again.id] != nil }
            if let game = manager.windows[again.id] {
                result["alphaAgainReachedTitleScreen"] = await waitForLoginScreen(game, timeout: 180)
                result["alphaAgainStorage"] = await evaluate(game, "return localStorage.getItem('e2e.owner');") ?? NSNull()
                result["alphaAgainHasANewProfile"] = again.dataStoreId != alphaAccount.dataStoreId
            }
        }
        JsonLog.writeDocument(result, to: config.out.appendingPathComponent("persist-remove.json"))
    }
}

@MainActor
struct ProbeScenario {
    let app: AppDelegate
    let config: E2EConfiguration
    let log: JsonLog

    func run() async {
        var summary: [String: Any] = [:]
        app.services.preBridgeScripts = [Probe.gpuScript]
        let file = config.out.appendingPathComponent("probe.user.js")
        try? Probe.userScript.write(to: file, atomically: true, encoding: .utf8)
        summary["installed"] = app.main.installScript(file: file) != nil
        if let account = try? app.services.accounts.add(name: "alpha") {
            app.manager.startOrShow(account.id, light: false)
            _ = await waitUntil(timeout: 30) { app.manager.windows[account.id] != nil }
            if let game = app.manager.windows[account.id] {
                summary["title"] = await waitForLoginScreen(game, timeout: 180)
                await pause(3)
                summary["state"] = await evaluate(game, Probe.pageState) ?? NSNull()
                summary["windowVisible"] = game.window.isVisible
                summary["appHidden"] = NSApp.isHidden
                summary["appActive"] = NSApp.isActive
                summary["occlusion"] = game.window.occlusionState.contains(.visible)
                summary["frame"] = NSStringFromRect(game.window.frame)
                summary["visibilityText"] = game.visibilityText
                _ = await evaluate(game, "window.__e2eMark = 1; return true;")
                summary["pidBefore"] = game.rendererProcessId ?? 0
                game.reloadPage()
                var polls: [[String: Any]] = []
                for _ in 0..<8 {
                    await pause(5)
                    polls.append(["url": game.browser?.currentUrl?.absoluteString ?? "nil", "pid": game.rendererProcessId ?? 0, "answer": await evaluate(game, "return location.href + ' ' + document.readyState + ' ' + typeof window.__sroE2E;") ?? NSNull(), "statusCount": game.statusCount, "loads": game.finishedLoads])
                }
                summary["polls"] = polls
                summary["afterReload"] = await evaluate(game, Probe.pageState) ?? NSNull()
                summary["afterReloadTitle"] = await waitForLoginScreen(game, timeout: 120)
            }
        }
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("probe-summary.json"))
        _ = app.manager.closeAll(prompt: false)
        _ = await waitUntil(timeout: 30) { app.manager.windows.isEmpty }
        NSApp.terminate(nil)
    }
}

@MainActor
struct QuitScenario {
    let app: AppDelegate
    let config: E2EConfiguration
    let log: JsonLog

    func run() async {
        var summary: [String: Any] = ["phase": config.phase]
        let store = app.services.accounts
        for name in ["alpha", "beta"] {
            if let account = try? store.add(name: name) {
                app.manager.startOrShow(account.id, light: true)
            }
        }
        _ = await waitUntil(timeout: 90) { app.manager.windows.count == 2 }
        var ready = true
        for window in app.manager.windows.values {
            ready = await waitForLoginScreen(window, timeout: 180) && ready
        }
        summary["bothAtTitle"] = ready
        summary["openWindows"] = app.manager.windows.count
        summary["pid"] = getpid()
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("quit-summary.json"))
        log.write("ready-to-quit", ["mode": config.phase])
        if config.phase == "hold" {
            await pause(600)
            return
        }
        log.write("terminate-called")
        NSApp.terminate(nil)
    }
}

@MainActor
struct BotScenario {
    let app: AppDelegate
    let config: E2EConfiguration
    let log: JsonLog

    func run() async {
        var summary: [String: Any] = ["url": MainWindowController.botUrl]
        let installed = await app.main.installScript(fromUrl: MainWindowController.botUrl)
        summary["installed"] = installed.map { "\($0.meta.name) \($0.meta.version)" } ?? "failed"
        summary["warnings"] = installed?.warnings ?? []
        summary["runAt"] = installed?.meta.runAt ?? NSNull()
        if let account = try? app.services.accounts.add(name: "alpha") {
            app.manager.startOrShow(account.id, light: false)
            _ = await waitUntil(timeout: 30) { app.manager.windows[account.id] != nil }
            if let game = app.manager.windows[account.id] {
                summary["title"] = await waitForLoginScreen(game, timeout: 180)
                let botSeen = await waitUntil(timeout: 90, interval: 2) { game.status?.botVersion != nil }
                summary["botReportedAVersion"] = botSeen
                summary["botVersion"] = game.status?.botVersion ?? NSNull()
                summary["linked"] = game.status?.linked ?? NSNull()
                summary["state"] = await evaluate(game, "const lean = window.SROLean; return { present: !!lean, version: lean ? lean.version : null, keys: lean ? Object.keys(lean).sort().slice(0, 20) : null, worldPhase: lean && lean.world ? lean.world.phase : null };") ?? NSNull()
                app.main.refreshAll()
                summary["footer"] = app.main.footerText
                summary["statusRow"] = app.manager.statusRow(for: account)
                summary["screenshotStatus"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("status-bot.png"))
                summary["screenshotGame"] = await snapshotGame(game, to: config.out.appendingPathComponent("game-bot.png"))
                summary["scriptErrorsInLog"] = app.services.log.recent.map(\.text).filter { $0.contains("script error") || $0.contains("page script") }
            }
        }
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("bot-summary.json"))
        _ = app.manager.closeAll(prompt: false)
        _ = await waitUntil(timeout: 30) { app.manager.windows.isEmpty }
        NSApp.terminate(nil)
    }
}
