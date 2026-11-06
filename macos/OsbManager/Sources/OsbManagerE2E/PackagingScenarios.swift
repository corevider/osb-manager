import AppKit
import CryptoKit
import Foundation
import OsbManagerApp
import OsbManagerCore

@MainActor
final class RetentionScenario {
    private let app: AppDelegate
    private let config: E2EConfiguration
    private let log: JsonLog
    private var summary: [String: Any] = [:]

    init(app: AppDelegate, config: E2EConfiguration, log: JsonLog) {
        self.app = app
        self.config = config
        self.log = log
    }

    private var store: AccountStore { app.services.accounts }
    private var credentials: CredentialStore { app.services.credentials }
    private var manager: GameManager { app.manager }

    func run() async {
        summary["phase"] = config.phase
        summary["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? ""
        summary["version"] = AppVersion.current()
        summary["executable"] = Bundle.main.executablePath ?? ""
        app.services.preBridgeScripts = [LoginProbe.script]
        guard await waitUntil(timeout: 1200, interval: 10, { !screenIsLocked() }) else {
            summary["skipped"] = "the screen stayed locked"
            finish()
            return
        }
        if config.phase == "check" {
            await check()
        } else {
            await seed()
        }
        finish()
    }

    private func finish() {
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("retention-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func fileHashes() -> [String: String] {
        let root = app.services.paths.root
        var result: [String: String] = [:]
        var files = ["accounts.json", "settings.json", "sox.json"]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("scripts").path)) ?? [] {
            files.append("scripts/\(name)")
        }
        for file in files {
            if let data = try? Data(contentsOf: root.appendingPathComponent(file)) {
                result[file] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    private func profileFolders() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: app.services.profiles.root.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted()
    }

    private func settingsSummary() -> [String: Any] {
        let settings = app.services.settings
        return ["frameLimit": settings.frameLimit]
    }

    private func seed() async {
        let randomBytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let password = "e2e-" + randomBytes.map { String(format: "%02x", $0) }.joined()
        let token = "tok-" + UUID().uuidString
        app.main.setFrameLimit(30)
        guard let alpha = try? store.add(name: "alpha"), (try? store.add(name: "beta")) != nil else {
            summary["error"] = "could not add accounts"
            return
        }
        let problem = app.main.applyAccountForm(accountId: alpha.id, form: AccountForm(
            name: "alpha", startLight: true,
            details: LoginDetails(loginId: "e2e-user-alpha", password: password, server: "TestServer", character: "TestChar", autoLogin: true)
        ))
        summary["saveProblem"] = problem ?? NSNull()

        let script = """
        // ==UserScript==
        // @name         Retention probe
        // @namespace    https://osb-manager.test/
        // @version      1.0
        // @match        https://opensro.online/play*
        // @run-at       document-start
        // ==/UserScript==
        window.__retention = true;
        """
        let scriptFile = config.out.appendingPathComponent("retention.user.js")
        try? script.write(to: scriptFile, atomically: true, encoding: .utf8)
        _ = app.main.installScript(file: scriptFile)
        _ = app.services.sox.add("hunter has dropped Demon Polearm (Seal Of Star) from Wing Tribe Chaser", seenBy: "retention", ours: ["hunter"])

        manager.startOrShow(alpha.id, light: true)
        _ = await waitUntil(timeout: 60) { manager.windows[alpha.id] != nil }
        if let window = manager.windows[alpha.id] {
            let reached = await waitForLoginScreen(window, timeout: 180)
            summary["alphaReachedTitle"] = reached
            _ = await evaluate(window, "localStorage.setItem('retention', '\(token)'); return localStorage.getItem('retention');")
            summary["tokenWritten"] = await evaluate(window, "return localStorage.getItem('retention');") ?? NSNull()
            await pause(4)
        }
        _ = manager.closeAll(prompt: false)
        _ = await waitUntil(timeout: 30) { manager.windows.isEmpty }
        await pause(2)

        let expected: [String: Any] = [
            "passwordHash": sha256Hex(password),
            "token": token,
            "alphaProfile": alpha.dataStoreId.uuidString.lowercased(),
            "files": fileHashes(),
            "profileFolders": profileFolders(),
        ]
        JsonLog.writeDocument(expected, to: config.out.appendingPathComponent("retention-expected.json"))
        summary["files"] = fileHashes()
        summary["keychainItemExists"] = (try? credentials.exists(accountId: alpha.id)) ?? false
        summary["keychainItemMatches"] = (try? credentials.read(accountId: alpha.id)).flatMap { $0 }.map(sha256Hex) == sha256Hex(password)
        summary["profileFolders"] = profileFolders()
        summary["settings"] = settingsSummary()
    }

    private func check() async {
        guard let compare = config.compare, let data = try? Data(contentsOf: compare),
              let expected = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            summary["error"] = "no expected file"
            return
        }
        let before = expected["files"] as? [String: String] ?? [:]
        let now = fileHashes()
        summary["filesUnchanged"] = before == now
        summary["filesChanged"] = now.filter { before[$0.key] != $0.value }.map(\.key)
        summary["accounts"] = store.accounts.map { ["name": $0.name, "loginId": $0.loginId, "autoLogin": $0.autoLogin, "startLight": $0.startLight, "character": $0.character] }
        summary["settings"] = settingsSummary()
        summary["scripts"] = app.services.scripts.scripts.map { "\($0.meta.name) \($0.meta.version) enabled=\($0.enabled)" }
        summary["soxDrops"] = app.services.sox.drops.map(\.item)
        summary["profileFoldersNow"] = profileFolders()
        summary["profileFoldersKept"] = (expected["profileFolders"] as? [String] ?? []) == profileFolders()

        guard let alpha = store.accounts.first(where: { $0.name == "alpha" }), let beta = store.accounts.first(where: { $0.name == "beta" }) else {
            summary["error"] = "accounts missing"
            return
        }
        summary["keychainItemExists"] = (try? credentials.exists(accountId: alpha.id)) ?? false
        summary["keychainPasswordRead"] = "not read: an ad-hoc update makes macOS ask before another build reads the password"

        manager.startOrShow(alpha.id, light: true)
        _ = await waitUntil(timeout: 60) { manager.windows[alpha.id] != nil }
        if let window = manager.windows[alpha.id] {
            summary["alphaReachedTitle"] = await waitForLoginScreen(window, timeout: 180)
            summary["tokenSurvivesTheUpdate"] = (await evaluate(window, "return localStorage.getItem('retention');") as? String) == (expected["token"] as? String)
        }
        _ = manager.closeAll(prompt: false)
        _ = await waitUntil(timeout: 30) { manager.windows.isEmpty }

        await app.main.removeAccount(alpha)
        await app.main.removeAccount(beta)
        await pause(2)
        summary["keychainItemAfterRemoval"] = (try? credentials.exists(accountId: alpha.id)) ?? false
        summary["profileFoldersAfterRemoval"] = profileFolders()
        try? app.services.sox.clear()
    }
}

@MainActor
final class AboutScenario {
    private let app: AppDelegate
    private let config: E2EConfiguration
    private let log: JsonLog

    init(app: AppDelegate, config: E2EConfiguration, log: JsonLog) {
        self.app = app
        self.config = config
        self.log = log
    }

    func run() async {
        var summary: [String: Any] = [
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "version": AppVersion.current(),
            "iconFile": Bundle.main.infoDictionary?["CFBundleIconFile"] ?? NSNull(),
            "bundleName": Bundle.main.infoDictionary?["CFBundleName"] ?? NSNull(),
            "displayName": Bundle.main.infoDictionary?["CFBundleDisplayName"] ?? NSNull(),
            "dataFolder": app.services.paths.root.path,
            "keychainService": Bundle.main.bundleIdentifier ?? "",
            "mainWindowTitle": app.main.window.title,
            "menuTitle": NSApp.mainMenu?.items.first?.submenu?.title ?? "",
            "menuItems": NSApp.mainMenu?.items.compactMap { $0.submenu?.items.map(\.title) }.flatMap { $0 } ?? [],
        ]
        await pause(2)
        app.main.selectTab("Status")
        summary["screenshotMain"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("main-window.png"))
        NSApp.orderFrontStandardAboutPanel(nil)
        await pause(2)
        let panels = NSApp.windows.filter { $0.isVisible && $0 !== app.main.window }
        summary["aboutPanels"] = panels.map { "\(type(of: $0)) title=\($0.title)" }
        if let panel = panels.first {
            summary["screenshotAbout"] = snapshotWindow(panel, to: config.out.appendingPathComponent("about-panel.png"))
        }
        summary["iconSizes"] = renderIcon(to: config.out.appendingPathComponent("dock-icon-sizes.png"))
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("about-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func renderIcon(to url: URL) -> [String: Any] {
        guard let icon = NSApp.applicationIconImage else { return ["error": "no icon"] }
        let sizes = [16, 32, 64, 128, 256]
        let width = sizes.reduce(0) { $0 + $1 + 24 } + 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return ["error": "no bitmap"] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: 300).fill()
        var x = 24
        for size in sizes {
            icon.draw(in: NSRect(x: x, y: 20, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
            x += size + 24
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return ["sizes": sizes, "representations": icon.representations.count]
    }
}
