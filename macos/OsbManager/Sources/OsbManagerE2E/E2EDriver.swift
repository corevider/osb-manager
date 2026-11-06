import AppKit
import Foundation
import OsbManagerApp
import OsbManagerCore

@MainActor
final class E2EDriver {
    private let app: AppDelegate
    private let config: E2EConfiguration
    private let log: JsonLog
    private let recorder = Recorder()
    private var summary: [String: Any] = [:]
    private var launchTimes: [String: Date] = [:]
    private var watcher: Task<Void, Never>?
    private var occlusionSamples: [(at: Date, visible: [String: Bool], onActiveSpace: [String: Bool], locked: Bool)] = []

    init(app: AppDelegate, config: E2EConfiguration) {
        self.app = app
        self.config = config
        try? FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        log = JsonLog(directory: config.out, name: "e2e-log.jsonl")
    }

    private var manager: GameManager { app.manager }
    private var store: AccountStore { app.services.accounts }

    func run() async {
        if let share = config.share, config.scenario != "cache" {
            app.services.settings.shareGameFiles = share
            app.services.applyShareSetting()
        }
        switch config.scenario {
        case "idle":
            return
        case "about":
            await AboutScenario(app: app, config: config, log: log).run()
        case "retention":
            await RetentionScenario(app: app, config: config, log: log).run()
        case "login":
            await LoginScenario(app: app, config: config, log: log).run()
        case "stats":
            await StatsScenario(app: app, config: config, log: log).run()
        case "bot":
            await BotScenario(app: app, config: config, log: log).run()
        case "quit":
            await QuitScenario(app: app, config: config, log: log).run()
        case "hardened":
            await HardenedScenario(app: app, config: config, log: log).run()
        case "probe":
            await ProbeScenario(app: app, config: config, log: log).run()
        case "measure":
            await MeasureScenario(app: app, config: config, log: log).run()
        case "persist":
            await PersistScenario(app: app, config: config, log: log).run()
        case "cache":
            await CacheScenario(app: app, config: config, log: log).run()
        case "scriptupdate":
            await ScriptUpdateScenario(app: app, config: config, log: log).run()
        default:
            await full()
        }
    }

    private func full() async {
        log.write("start", ["out": config.out.path, "data": app.services.paths.root.path])
        guard await waitUntil(timeout: 1200, interval: 10, { !screenIsLocked() }) else {
            summary["skipped"] = "the screen stayed locked"
            finish()
            return
        }
        summary["screen"] = screenInfo()
        recorder.start()
        startWatcher()
        await accountsStep()
        await startQueueStep()
        await titleStep()
        await scriptStep()
        await messagesStep()
        if !config.skipHidden {
            await hiddenStep()
        }
        await windowStep()
        await lifecycleStep()
        summary["memoryAtEnd"] = recorder.memory()
        finish()
    }

    private func finish() {
        watcher?.cancel()
        recorder.stop()
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("e2e-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func screenInfo() -> [String: Any] {
        let screen = NSScreen.main
        return [
            "frame": NSStringFromRect(screen?.frame ?? .zero),
            "visibleFrame": NSStringFromRect(screen?.visibleFrame ?? .zero),
            "backingScaleFactor": screen?.backingScaleFactor ?? 0,
            "maximumFramesPerSecond": screen?.maximumFramesPerSecond ?? 0,
            "screenLocked": screenIsLocked(),
        ]
    }

    private func startWatcher() {
        watcher = Task { @MainActor in
            while !Task.isCancelled {
                var visible: [String: Bool] = [:]
                var space: [String: Bool] = [:]
                for window in manager.windows.values {
                    visible[window.accountName] = window.window.occlusionState.contains(.visible)
                    space[window.accountName] = window.window.isOnActiveSpace
                }
                occlusionSamples.append((Date(), visible, space, screenIsLocked()))
                await pause(1)
            }
        }
    }

    private func account(_ name: String) -> Account? {
        store.accounts.first { $0.name == name }
    }

    private func game(_ name: String) -> GameWindowController? {
        account(name).flatMap { manager.windows[$0.id] }
    }

    private func atTitle(_ window: GameWindowController?) -> Bool {
        window?.status?.phase == "signed-out"
    }

    private func accountsStep() async {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1000, Int(visible.width) - 80)
        let height = min(640, Int(visible.height) - 80)
        do {
            let alpha = try store.add(name: "alpha")
            let beta = try store.add(name: "beta")
            let x = Int(visible.minX) + 20
            let y = Int(visible.minY) + 20
            try store.update(id: alpha.id) { $0.window = WindowPlacement(x: x + 36, y: y, width: width, height: height, maximized: false) }
            try store.update(id: beta.id) { $0.window = WindowPlacement(x: x, y: y + 36, width: width, height: height, maximized: false) }
            summary["accounts"] = store.accounts.map { ["id": $0.id, "name": $0.name, "dataStoreId": $0.dataStoreId.uuidString] }
        } catch {
            summary["accountsError"] = String(describing: error)
        }
        app.main.refreshAll()
        log.write("accounts-created", ["names": store.accounts.map(\.name)])
    }

    private func startQueueStep() async {
        app.main.selectTab("Status")
        let started = Date()
        manager.startAll(light: false)
        app.main.refreshAll()
        var rows: [[String: Any]] = []
        var screenshotTaken = false
        for tick in 0..<40 {
            for name in ["alpha", "beta"] where launchTimes[name] == nil && game(name) != nil {
                launchTimes[name] = Date()
            }
            let states = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.name, manager.stateText(for: $0)) })
            rows.append(["t": Date().timeIntervalSince(started), "states": states])
            log.write("queue", ["t": Date().timeIntervalSince(started), "alpha": states["alpha"] ?? "", "beta": states["beta"] ?? ""])
            if tick == 3 && !screenshotTaken {
                screenshotTaken = true
                app.main.refreshAll()
                summary["screenshotQueue"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("status-queue.png"))
            }
            if launchTimes.count == 2 && tick >= 20 { break }
            await pause(1)
        }
        summary["startQueue"] = [
            "alphaOpenedAfterSeconds": launchTimes["alpha"].map { $0.timeIntervalSince(started) } as Any,
            "betaOpenedAfterSeconds": launchTimes["beta"].map { $0.timeIntervalSince(started) } as Any,
            "rows": rows,
        ]
    }

    private func titleStep() async {
        let reached = await waitUntil(timeout: 240) { atTitle(game("alpha")) && atTitle(game("beta")) }
        var seconds: [String: Any] = [:]
        for name in ["alpha", "beta"] {
            if let launched = launchTimes[name] { seconds[name] = Date().timeIntervalSince(launched) }
        }
        summary["reachedTitle"] = reached
        summary["secondsFromLaunchToTitleCheck"] = seconds
        guard let alpha = game("alpha"), let beta = game("beta") else { return }
        summary["loginScreenReached"] = [
            "alpha": await waitForLoginScreen(alpha, timeout: 180),
            "beta": await waitForLoginScreen(beta, timeout: 180),
        ]
        await pause(3)
        app.main.refreshAll()
        summary["screenshotStatusTab"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("status-title.png"))
        summary["statusRowsAtTitle"] = store.accounts.map { manager.statusRow(for: $0) }
        summary["screenshotAlpha"] = await snapshotGame(alpha, to: config.out.appendingPathComponent("game-alpha.png"))
        summary["screenshotBeta"] = await snapshotGame(beta, to: config.out.appendingPathComponent("game-beta.png"))
        summary["statusAlpha"] = statusDigest(alpha)
        summary["statusBeta"] = statusDigest(beta)
        summary["rejectedMessages"] = alpha.rejectedMessages + beta.rejectedMessages
        summary["footerText"] = app.main.footerText
        summary["countText"] = app.main.countText
        app.main.selectTab("Account")
        app.main.select(accountId: account("alpha")?.id)
        app.main.refreshAll()
        summary["screenshotAccountTab"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("account-tab.png"))
        app.main.selectTab("Status")
    }

    private func statusDigest(_ window: GameWindowController) -> [String: Any] {
        let status = window.status
        return [
            "phase": status?.phase ?? NSNull(),
            "linked": status?.linked ?? NSNull(),
            "light": status?.light ?? NSNull(),
            "lightWaiting": status?.lightWaiting ?? NSNull(),
            "loginStage": status?.loginStage ?? NSNull(),
            "gpuRetries": status?.gpuRetries ?? NSNull(),
            "gpuFailed": status?.gpuFailed ?? NSNull(),
            "bot": status?.botVersion ?? NSNull(),
            "statusMessages": window.statusCount,
            "stateText": window.stateText,
        ]
    }

    private func pageSnapshot(_ window: GameWindowController) async -> [String: Any] {
        (await evaluate(window, Probe.pageState) as? [String: Any]) ?? ["error": "no answer"]
    }

    private func reloadAndWait(_ windows: [GameWindowController], timeout: Double = 180) async -> Bool {
        for window in windows {
            _ = await evaluate(window, "window.__e2eMark = 1; return true;")
        }
        windows.forEach { $0.reloadPage() }
        await pause(2)
        let deadline = Date().addingTimeInterval(timeout)
        for window in windows {
            var newPage = false
            while Date() < deadline && !newPage {
                let answer = await evaluate(window, "return typeof window.__e2eMark === 'undefined' && document.readyState !== 'loading';", timeout: 5)
                newPage = (answer as? NSNumber)?.boolValue == true
                if !newPage { await pause(1) }
            }
            let count = window.statusCount
            let ready = await waitUntil(timeout: max(1, deadline.timeIntervalSinceNow)) {
                window.statusCount > count + 1 && window.status?.phase == "signed-out"
            }
            if !ready { return false }
        }
        return true
    }

    private func scriptStep() async {
        guard let alpha = game("alpha"), let beta = game("beta") else { return }
        let file = config.out.appendingPathComponent("e2e-probe.user.js")
        try? Probe.userScript.write(to: file, atomically: true, encoding: .utf8)
        let installed = app.main.installScript(file: file)
        summary["scriptInstalled"] = installed.map { "\($0.meta.name) \($0.meta.version)" } ?? "failed"
        app.main.selectTab("Scripts")
        app.main.refreshScripts()
        summary["screenshotScriptsTab"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("scripts-tab.png"))
        let first = await reloadAndWait([alpha, beta])
        let one = await (pageSnapshot(alpha), pageSnapshot(beta))
        let second = await reloadAndWait([alpha, beta])
        let two = await (pageSnapshot(alpha), pageSnapshot(beta))
        summary["userscript"] = [
            "firstReloadReachedTitle": first,
            "secondReloadReachedTitle": second,
            "afterFirstReload": ["alpha": one.0, "beta": one.1],
            "afterSecondReload": ["alpha": two.0, "beta": two.1],
            "tokensDiffer": (one.0["token"] as? String) != (one.1["token"] as? String),
            "tokensSurviveReload": (one.0["token"] as? String) == (two.0["token"] as? String) && (one.1["token"] as? String) == (two.1["token"] as? String),
            "styleReachedThePage": (one.0["style"] as? String) == "1" && (one.1["style"] as? String) == "1",
        ]
        app.main.selectTab("Status")
        log.write("userscript", ["alpha": one.0["token"] ?? NSNull(), "beta": one.1["token"] ?? NSNull(), "alphaAfter": two.0["token"] ?? NSNull(), "betaAfter": two.1["token"] ?? NSNull()])
    }

    private func framesPerSecond(_ window: GameWindowController, seconds: Double) async -> Double {
        let before = await pageSnapshot(window)
        await pause(seconds)
        let after = await pageSnapshot(window)
        let elapsed = (number(after["clock"]) - number(before["clock"])) / 1000
        return elapsed > 0 ? (number(after["frames"]) - number(before["frames"])) / elapsed : 0
    }

    private func messagesStep() async {
        guard let alpha = game("alpha"), let beta = game("beta") else { return }
        var result: [String: Any] = [:]
        result["frameLimit60"] = ["alpha": await framesPerSecond(alpha, seconds: 6), "beta": await framesPerSecond(beta, seconds: 6)]
        app.main.setFrameLimit(30)
        await pause(2)
        result["frameLimit30"] = ["alpha": await framesPerSecond(alpha, seconds: 6), "beta": await framesPerSecond(beta, seconds: 6)]
        app.main.setFrameLimit(60)
        await pause(2)
        result["frameLimit60Again"] = ["alpha": await framesPerSecond(alpha, seconds: 6)]

        let mutedAtStart = alpha.browserMuted
        alpha.setLight(true)
        let lit = await waitUntil(timeout: 25, interval: 1) { alpha.status?.light == true }
        let lightOn: [String: Any] = ["reachedOn": lit, "status": statusDigest(alpha), "nativeMuted": alpha.browserMuted, "stateText": alpha.stateText]
        alpha.setLight(false)
        let unlit = await waitUntil(timeout: 25, interval: 1) { alpha.status?.light == false }
        let lightOff: [String: Any] = ["reachedOff": unlit, "status": statusDigest(alpha), "nativeMuted": alpha.browserMuted, "stateText": alpha.stateText]
        alpha.setMuted(true)
        await pause(1)
        let muted = alpha.browserMuted
        alpha.setMuted(false)
        await pause(1)
        let unmuted = alpha.browserMuted
        result["light"] = ["nativeMutedAtStart": mutedAtStart, "on": lightOn, "off": lightOff]
        result["mute"] = ["muted": muted, "unmuted": unmuted, "betaUntouched": beta.browserMuted]
        summary["messages"] = result
        log.write("messages", ["frameLimit60": result["frameLimit60"] ?? NSNull(), "frameLimit30": result["frameLimit30"] ?? NSNull()])
    }

    private func occlusion(from start: Date, to end: Date) -> [String: Any] {
        let inRange = occlusionSamples.filter { $0.at >= start && $0.at <= end }
        var visible: [String: Double] = [:]
        var space: [String: Double] = [:]
        for name in Set(inRange.flatMap { $0.visible.keys }) {
            let samples = inRange.filter { $0.visible[name] != nil }
            visible[name] = Double(samples.filter { $0.visible[name] == true }.count) / Double(max(samples.count, 1))
            space[name] = Double(samples.filter { $0.onActiveSpace[name] == true }.count) / Double(max(samples.count, 1))
        }
        return [
            "visibleFraction": visible,
            "onActiveSpaceFraction": space,
            "screenLockedFraction": Double(inRange.filter(\.locked).count) / Double(max(inRange.count, 1)),
            "samples": inRange.count,
        ]
    }

    private func measurePhase(_ label: String, windows: [GameWindowController]) async -> [String: Any] {
        log.write("phase-start", ["label": label])
        await pause(config.settleSeconds)
        let begin = Date()
        var before: [String: [String: Any]] = [:]
        var countsBefore: [String: Int] = [:]
        for window in windows {
            before[window.accountName] = await pageSnapshot(window)
            countsBefore[window.accountName] = window.statusCount
        }
        await pause(config.measureSeconds)
        let end = Date()
        var pages: [String: Any] = [:]
        for window in windows {
            let after = await pageSnapshot(window)
            let start = before[window.accountName] ?? [:]
            let elapsed = (number(after["clock"]) - number(start["clock"])) / 1000
            pages[window.accountName] = [
                "visibility": after["visibility"] ?? NSNull(),
                "timerTicksPerSecond": elapsed > 0 ? (number(after["ticks"]) - number(start["ticks"])) / elapsed : 0,
                "framesPerSecond": elapsed > 0 ? (number(after["frames"]) - number(start["frames"])) / elapsed : 0,
                "statusMessages": window.statusCount - (countsBefore[window.accountName] ?? 0),
                "pageSeconds": elapsed,
                "windowVisibility": window.visibilityText,
            ]
        }
        let result: [String: Any] = [
            "label": label,
            "process": recorder.summary(from: begin, to: end),
            "pages": pages,
            "occlusion": occlusion(from: begin, to: end),
        ]
        log.write("phase-end", ["label": label, "cpu": (result["process"] as? [String: Any])?["cpuPercent"] ?? NSNull(), "pages": pages])
        return result
    }

    private func hiddenStep() async {
        guard let alpha = game("alpha"), let beta = game("beta") else { return }
        var phases: [[String: Any]] = []
        NSApp.activate()
        alpha.window.orderFrontRegardless()
        beta.window.orderFrontRegardless()
        phases.append(await measurePhase("both-visible", windows: [alpha, beta]))

        beta.hide()
        app.main.refreshAll()
        phases.append(await measurePhase("beta-hidden", windows: [alpha, beta]))
        summary["screenshotHidden"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("status-hidden.png"))

        beta.show(activate: false)
        await pause(4)
        beta.window.miniaturize(nil)
        app.main.refreshAll()
        phases.append(await measurePhase("beta-minimised", windows: [alpha, beta]))
        beta.show(activate: false)
        await pause(8)
        phases.append(await measurePhase("beta-shown-again", windows: [beta]))
        summary["hiddenPhases"] = phases
    }

    private func windowStep() async {
        guard let alpha = game("alpha") else { return }
        var result: [String: Any] = [:]
        alpha.show(activate: true)
        let before = await pageSnapshot(alpha)
        let frame = alpha.window.frame
        alpha.window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width - 120, height: frame.height - 80), display: true)
        await pause(2)
        let smaller = await pageSnapshot(alpha)
        alpha.window.setFrame(frame, display: true)
        await pause(2)
        let restored = await pageSnapshot(alpha)
        result["pageSizeFollowsTheWindow"] = ["before": before["inner"] ?? NSNull(), "smaller": smaller["inner"] ?? NSNull(), "restored": restored["inner"] ?? NSNull()]
        alpha.window.zoom(nil)
        await pause(2)
        let zoomed = await pageSnapshot(alpha)
        result["zoomed"] = ["isZoomed": alpha.window.isZoomed, "inner": zoomed["inner"] ?? NSNull()]
        alpha.window.zoom(nil)
        await pause(2)
        summary["window"] = result
    }

    private func lifecycleStep() async {
        var result: [String: Any] = [:]
        if let alpha = account("alpha"), let window = manager.windows[alpha.id] {
            let before = window.window.frame
            window.closeWithoutPrompt()
            let closed = await waitUntil(timeout: 30) { manager.windows[alpha.id] == nil }
            let saved = store.account(id: alpha.id)?.window
            manager.startOrShow(alpha.id, light: false)
            let reopened = await waitUntil(timeout: 30) { manager.windows[alpha.id] != nil }
            await pause(1)
            let after = manager.windows[alpha.id]?.window.frame
            result["frameMemory"] = [
                "closed": closed,
                "frameBeforeClose": NSStringFromRect(before),
                "savedPlacement": saved.map { "\($0.x),\($0.y) \($0.width)x\($0.height) maximized=\($0.maximized)" } ?? "none",
                "reopened": reopened,
                "frameAfterReopen": after.map(NSStringFromRect) ?? "none",
                "same": after == before,
            ]
        }
        _ = manager.closeAll(prompt: false)
        _ = await waitUntil(timeout: 30) { manager.windows.isEmpty }

        var profileIds: [String: UUID] = [:]
        for account in store.accounts {
            profileIds[account.name] = account.dataStoreId
        }
        do {
            let gamma = try store.add(name: "gamma")
            try store.rename(id: gamma.id, to: "gamma2")
            _ = try store.move(id: gamma.id, by: -2)
            result["orderAfterMove"] = store.accounts.map(\.name)
            profileIds["gamma2"] = gamma.dataStoreId
            manager.startOrShow(gamma.id, light: true)
            _ = await waitUntil(timeout: 30) { manager.windows[gamma.id] != nil }
            await pause(12)
            result["gammaStatus"] = manager.windows[gamma.id].map(statusDigest) ?? [:]
            result["gammaNativeMuted"] = manager.windows[gamma.id]?.browserMuted ?? NSNull()
        } catch {
            result["gammaError"] = String(describing: error)
        }
        let profiles = app.services.profiles
        result["profileFoldersBeforeRemoval"] = profileFolders()
        for account in store.accounts {
            await app.main.removeAccount(account)
        }
        await pause(2)
        result["profileFoldersAfterRemoval"] = profileFolders()
        let ours = Set(profileIds.values.map { $0.uuidString.lowercased() })
        result["ourProfilesStillOnDisk"] = profileFolders().filter { ours.contains($0) }
        result["profileRoot"] = profiles.root.path
        result["accountsLeft"] = store.accounts.count
        summary["lifecycle"] = result
        log.write("lifecycle", ["profilesLeft": result["ourProfilesStillOnDisk"] ?? NSNull()])
    }

    private func profileFolders() -> [String] {
        let root = app.services.profiles.root
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted()
    }
}
