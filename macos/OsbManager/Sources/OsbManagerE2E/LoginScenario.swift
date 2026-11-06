import AppKit
import CryptoKit
import Foundation
import OsbManagerApp
import OsbManagerCore

enum LoginProbe {
    static let script = """
    (() => {
      if (window.top !== window || location.origin !== 'https://opensro.online') return;
      const original = window.chrome && window.chrome.webview;
      if (!original) return;
      const record = { auto: [], credentials: [], denied: [], requests: 0 };
      window.__sroLogin = record;
      const sha256 = async text => [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))].map(byte => byte.toString(16).padStart(2, '0')).join('');
      const proxy = Object.freeze({
        postMessage: message => original.postMessage(message),
        addEventListener: (type, listener) => {
          if (type !== 'message') return original.addEventListener(type, listener);
          original.addEventListener(type, event => {
            const data = event && event.data;
            if (data && data.type === 'credentials') {
              if (typeof data.password === 'string') {
                sha256(data.password).then(hash => record.credentials.push({ id: data.id, hash, length: data.password.length }));
              } else {
                record.denied.push(String(data.reason));
              }
              return;
            }
            if (data && data.type === 'auto-login') {
              record.auto.push({ enabled: data.enabled, character: data.character, server: data.server });
              return;
            }
            listener(event);
          });
        },
        removeEventListener: () => {},
      });
      window.chrome = { webview: proxy };
      window.__sroRequestCredentials = () => { record.requests++; original.postMessage({ type: 'credentials-request' }); };
    })();
    """

    static let request = "window.__sroRequestCredentials(); return window.__sroLogin.requests;"
    static let read = "return JSON.stringify(window.__sroLogin || null);"
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class LoginScenario {
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
    private var credentials: CredentialStore { app.services.credentials }

    func run() async {
        log.write("start", ["scenario": "login", "phase": config.phase, "data": app.services.paths.root.path])
        guard await waitUntil(timeout: 1200, interval: 10, { !screenIsLocked() }) else {
            summary["skipped"] = "the screen stayed locked"
            finish()
            return
        }
        summary["screenLocked"] = screenIsLocked()
        summary["keychainService"] = Bundle.main.bundleIdentifier ?? ""
        if config.phase == "restart" {
            await restartPhase()
        } else {
            await firstPhase()
        }
        finish()
    }

    private func finish() {
        JsonLog.writeDocument(summary, to: config.out.appendingPathComponent("login-summary.json"))
        log.write("quit-requested")
        NSApp.terminate(nil)
    }

    private func game(_ name: String) -> GameWindowController? {
        store.accounts.first { $0.name == name }.flatMap { manager.windows[$0.id] }
    }

    private func account(_ name: String) -> Account? {
        store.accounts.first { $0.name == name }
    }

    private func shot(_ name: String, tab: String) {
        app.main.selectTab(tab)
        app.main.refreshAll()
        summary["screenshot-\(name)"] = snapshotWindow(app.main.window, to: config.out.appendingPathComponent("\(name).png"))
    }

    private func selfTest() {
        let service = "com.corevider.osb-manager.e2e.selftest-\(UUID().uuidString)"
        let keychain = KeychainCredentialStore(service: service)
        let id = "aaaaaaaaaaaa"
        var result: [String: Any] = ["service": service]
        defer { try? keychain.delete(accountId: id) }
        do {
            result["absentAtStart"] = try !keychain.exists(accountId: id)
            let first = "first-\(UUID().uuidString)"
            try keychain.save(password: first, accountId: id)
            result["existsAfterSave"] = try keychain.exists(accountId: id)
            result["readMatches"] = try keychain.read(accountId: id) == first
            let second = "second-\(UUID().uuidString)"
            try keychain.save(password: second, accountId: id)
            result["updateMatches"] = try keychain.read(accountId: id) == second
            try keychain.delete(accountId: id)
            result["goneAfterDelete"] = try !keychain.exists(accountId: id)
            result["deleteAgainIsFine"] = (try? keychain.delete(accountId: id)) != nil
        } catch let error as CredentialStoreError {
            result["errorStatus"] = Int(error.status)
        } catch {
            result["error"] = "other"
        }
        summary["keychainSelfTest"] = result
        log.write("keychain-self-test", result)
    }

    private func credentialSnapshot(_ window: GameWindowController) async -> [String: Any] {
        guard let text = await evaluate(window, LoginProbe.read) as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return ["error": "no answer"] }
        return object
    }

    private func firstPhase() async {
        app.services.preBridgeScripts = [LoginProbe.script]
        selfTest()
        let randomBytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let password = "e2e-" + randomBytes.map { String(format: "%02x", $0) }.joined()
        let expectedHash = sha256Hex(password)
        try? expectedHash.write(to: config.out.appendingPathComponent("expected-hash.txt"), atomically: true, encoding: .utf8)
        do {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let width = min(900, Int(visible.width) - 80)
            let height = min(560, Int(visible.height) - 80)
            let alpha = try store.add(name: "alpha")
            let beta = try store.add(name: "beta")
            try store.update(id: alpha.id) { $0.window = WindowPlacement(x: Int(visible.minX) + 60, y: Int(visible.minY) + 20, width: width, height: height, maximized: false) }
            try store.update(id: beta.id) { $0.window = WindowPlacement(x: Int(visible.minX) + 20, y: Int(visible.minY) + 50, width: width, height: height, maximized: false) }
        } catch {
            summary["setupError"] = String(describing: error)
            return
        }
        guard let alphaAccount = account("alpha"), let betaAccount = account("beta") else { return }

        let problem = app.main.applyAccountForm(accountId: alphaAccount.id, form: AccountForm(
            name: "alpha",
            startLight: false,
            details: LoginDetails(loginId: "e2e-user-alpha", password: password, server: "TestServer", character: "TestChar", autoLogin: true)
        ))
        summary["saveProblem"] = problem ?? NSNull()
        summary["itemExistsAlpha"] = (try? credentials.exists(accountId: alphaAccount.id)) ?? false
        summary["itemExistsBeta"] = (try? credentials.exists(accountId: betaAccount.id)) ?? false
        summary["itemMatchesAfterSave"] = (try? credentials.read(accountId: alphaAccount.id)).flatMap { $0 }.map(sha256Hex) == expectedHash

        let keepProblem = app.main.applyAccountForm(accountId: alphaAccount.id, form: AccountForm(
            name: "alpha",
            startLight: false,
            details: LoginDetails(loginId: "e2e-user-alpha", password: nil, server: "TestServer", character: "TestChar", autoLogin: true)
        ))
        summary["emptyPasswordKeepsIt"] = keepProblem == nil && ((try? credentials.read(accountId: alphaAccount.id)).flatMap { $0 }.map(sha256Hex) == expectedHash)

        let secret = Data(password.utf8)
        let accountsFile = (try? Data(contentsOf: app.services.paths.accountsFile)) ?? Data()
        summary["accountsJsonHasPassword"] = accountsFile.range(of: secret) != nil
        summary["accountsJsonAlpha"] = alphaEntry(accountsFile)

        app.main.refreshAll()
        app.main.select(accountId: alphaAccount.id)
        shot("account-tab-alpha", tab: "Account")

        manager.startAll(light: false)
        let up = await waitUntil(timeout: 120) { game("alpha") != nil && game("beta") != nil }
        guard up, let alpha = game("alpha"), let beta = game("beta") else {
            summary["error"] = "windows did not open"
            return
        }
        _ = await waitUntil(timeout: 240) { alpha.status?.phase == "signed-out" && beta.status?.phase == "signed-out" }
        _ = await waitUntil(timeout: 60) { alpha.statusCount > 3 && beta.statusCount > 3 }
        await pause(3)
        summary["autoLoginMessages"] = ["alpha": (await credentialSnapshot(alpha))["auto"] ?? NSNull(), "beta": (await credentialSnapshot(beta))["auto"] ?? NSNull()]

        let formProbe = """
        const fields = [...document.querySelectorAll('input')];
        return { inputCount: fields.length, filledInputs: fields.filter(field => field.value.length > 0).length, passwordFields: fields.filter(field => field.type === 'password').length, passwordFilled: fields.filter(field => field.type === 'password' && field.value.length > 0).length };
        """
        await pause(20)
        summary["formBlock"] = [
            "alphaLoginStage": alpha.status?.loginStage ?? NSNull(),
            "alphaPhase": alpha.status?.phase ?? NSNull(),
            "alphaForm": await evaluate(alpha, formProbe) ?? NSNull(),
            "betaForm": await evaluate(beta, formProbe) ?? NSNull(),
            "autoLoginMessageSwallowedByTheProbe": ((await credentialSnapshot(alpha))["auto"] as? [Any])?.count ?? 0,
        ] as [String: Any]

        var timeline: [[String: Any]] = []
        func request(_ label: String, wait: Double) async {
            _ = await evaluate(alpha, LoginProbe.request)
            await pause(wait)
            let snapshot = await credentialSnapshot(alpha)
            let received = (snapshot["credentials"] as? [[String: Any]]) ?? []
            timeline.append([
                "request": label,
                "credentialsReceived": received.count,
                "refusals": (snapshot["denied"] as? [String]) ?? [],
                "idsOk": received.allSatisfy { $0["id"] as? String == "e2e-user-alpha" },
                "hashesOk": received.allSatisfy { $0["hash"] as? String == expectedHash },
            ])
            log.write("gate", timeline.last ?? [:])
        }
        await request("1 first", wait: 2)
        await request("2 two seconds later", wait: 16)
        await request("3 after the gap", wait: 16)
        await request("4 after the gap", wait: 16)
        await request("5 fourth within 10 minutes", wait: 2)
        summary["gateTimeline"] = timeline

        _ = await evaluate(beta, LoginProbe.request)
        await pause(2)
        summary["betaSnapshot"] = ["denied": (await credentialSnapshot(beta))["denied"] ?? NSNull(), "credentials": ((await credentialSnapshot(beta))["credentials"] as? [Any])?.count ?? -1]

        summary["statusRows"] = store.accounts.map { manager.statusRow(for: $0) }
        let logLines = app.services.log.recent.map(\.text)
        summary["logLinesAboutLogin"] = logLines.filter { $0.contains("login") || $0.contains("Keychain") || $0.contains("settings saved") }
        summary["logHasPassword"] = logLines.contains { $0.contains(password) }
        let logFiles = (try? FileManager.default.contentsOfDirectory(at: app.services.paths.logs, includingPropertiesForKeys: nil)) ?? []
        summary["logFilesHavePassword"] = logFiles.contains { ((try? Data(contentsOf: $0)) ?? Data()).range(of: secret) != nil }
        shot("log-tab", tab: "Log")
        shot("status-tab", tab: "Status")
        _ = manager.closeAll(prompt: false)
        await pause(2)
    }

    private func restartPhase() async {
        guard let alpha = account("alpha"), let beta = account("beta") else {
            summary["error"] = "accounts missing"
            return
        }
        let expected = config.compare.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        summary["itemExistsAlpha"] = (try? credentials.exists(accountId: alpha.id)) ?? false
        summary["itemExistsBeta"] = (try? credentials.exists(accountId: beta.id)) ?? false
        summary["itemMatchesAfterRestart"] = (try? credentials.read(accountId: alpha.id)).flatMap { $0 }.map(sha256Hex) == expected
        summary["accountsKept"] = store.accounts.map(\.name)
        app.main.select(accountId: alpha.id)
        shot("account-tab-after-restart", tab: "Account")
        let before = profileFolders()
        await app.main.removeAccount(alpha)
        await app.main.removeAccount(beta)
        await pause(3)
        summary["itemExistsAlphaAfterRemoval"] = (try? credentials.exists(accountId: alpha.id)) ?? false
        summary["accountsLeft"] = store.accounts.count
        summary["profileFoldersBeforeRemoval"] = before
        summary["profileFoldersAfterRemoval"] = profileFolders()
    }

    private func alphaEntry(_ data: Data) -> Any {
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let entry = entries.first(where: { $0["name"] as? String == "alpha" }) else { return NSNull() }
        return entry.filter { ["name", "loginId", "server", "character", "autoLogin"].contains($0.key) }
    }

    private func profileFolders() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: app.services.profiles.root.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.sorted()
    }
}
