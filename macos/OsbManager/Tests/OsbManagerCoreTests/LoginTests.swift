import Foundation
import Testing
@testable import OsbManagerCore

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
}

struct CredentialGateTests {
    @Test func allowsFewRequestsSpacedApart() {
        let clock = Clock()
        let gate = CredentialGate(maxPerWindow: 3, window: 600, minimumGap: 15, clock: { clock.now })

        #expect(gate.tryTake())
        clock.now.addTimeInterval(5)
        #expect(!gate.tryTake())
        clock.now.addTimeInterval(15)
        #expect(gate.tryTake())
        clock.now.addTimeInterval(20)
        #expect(gate.tryTake())
        clock.now.addTimeInterval(20)
        #expect(!gate.tryTake())
        clock.now.addTimeInterval(600)
        #expect(gate.tryTake())
    }

    @Test func usesThreePerTenMinutesAndFifteenSecondsByDefault() {
        let clock = Clock()
        let gate = CredentialGate(clock: { clock.now })

        #expect(gate.tryTake())
        clock.now.addTimeInterval(14.9)
        #expect(!gate.tryTake())
        clock.now.addTimeInterval(0.1)
        #expect(gate.tryTake())
        clock.now.addTimeInterval(15)
        #expect(gate.tryTake())
        clock.now.addTimeInterval(15)
        #expect(!gate.tryTake())
        clock.now.addTimeInterval(540)
        #expect(!gate.tryTake())
    }
}

struct AccountLoginTests {
    private func makeStore(in temp: TemporaryDirectory) throws -> (AccountStore, URL) {
        let url = temp.file("accounts.json")
        return (try AccountStore.load(from: url), url)
    }

    @Test func keepsThePasswordOutOfAccountsJsonAndInTheCredentialStore() throws {
        let temp = TemporaryDirectory()
        let (store, url) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let account = try store.add(name: "hunter")

        try store.updateLogin(id: account.id, details: LoginDetails(loginId: " demo_account ", password: "s3cret-pass-\u{1F511}", server: "GlobalOfficial", character: "hunter", autoLogin: true), credentials: credentials)

        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("s3cret-pass".utf8)) == nil)
        let reloaded = try #require(try AccountStore.load(from: url).accounts.first)
        #expect(reloaded.loginId == "demo_account")
        #expect(reloaded.autoLogin)
        #expect(reloaded.server == "GlobalOfficial" && reloaded.character == "hunter")
        #expect(try credentials.read(accountId: account.id) == "s3cret-pass-\u{1F511}")
    }

    @Test func keepsTheSavedPasswordWhenNoneIsEntered() throws {
        let temp = TemporaryDirectory()
        let (store, _) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let account = try store.add(name: "hunter")
        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: "first", server: "", character: "", autoLogin: true), credentials: credentials)

        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: nil, server: "", character: "healer", autoLogin: true), credentials: credentials)
        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: "", server: "", character: "healer", autoLogin: true), credentials: credentials)

        #expect(try credentials.read(accountId: account.id) == "first")
        #expect(store.account(id: account.id)?.character == "healer")
    }

    @Test func replacesThePasswordWhenANewOneIsEntered() throws {
        let temp = TemporaryDirectory()
        let (store, _) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let account = try store.add(name: "hunter")
        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: "first", server: "", character: "", autoLogin: false), credentials: credentials)

        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: "second", server: "", character: "", autoLogin: false), credentials: credentials)

        #expect(try credentials.read(accountId: account.id) == "second")
    }

    @Test func forgettingThePasswordRemovesItAndTurnsAutomaticLoginOff() throws {
        let temp = TemporaryDirectory()
        let (store, _) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let account = try store.add(name: "hunter")
        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: "pw", server: "", character: "", autoLogin: true), credentials: credentials)

        try store.clearPassword(id: account.id, credentials: credentials)

        #expect(try !credentials.exists(accountId: account.id))
        #expect(store.account(id: account.id)?.autoLogin == false)
        #expect(store.account(id: account.id)?.loginId == "demo_account")
    }

    @Test func clearingTheLoginIdDropsThePassword() throws {
        let temp = TemporaryDirectory()
        let (store, _) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let account = try store.add(name: "hunter")
        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: "pw", server: "", character: "", autoLogin: false), credentials: credentials)

        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "", password: nil, server: "", character: "", autoLogin: false), credentials: credentials)

        #expect(try !credentials.exists(accountId: account.id))
    }

    @Test func removingAnAccountDeletesItsKeychainItem() throws {
        let temp = TemporaryDirectory()
        let (store, _) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let first = try store.add(name: "first")
        let second = try store.add(name: "second")
        for account in [first, second] {
            try store.updateLogin(id: account.id, details: LoginDetails(loginId: "id", password: "pw", server: "", character: "", autoLogin: false), credentials: credentials)
        }

        try store.remove(id: first.id, credentials: credentials)

        #expect(try !credentials.exists(accountId: first.id))
        #expect(try credentials.exists(accountId: second.id))
        #expect(store.accounts.map(\.name) == ["second"])
    }

    @Test func changesNothingWhenTheKeychainRefusesTheSave() throws {
        let temp = TemporaryDirectory()
        let (store, url) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let account = try store.add(name: "hunter")
        credentials.failure = -25293

        #expect(throws: CredentialStoreError.self) {
            try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: "pw", server: "", character: "", autoLogin: true), credentials: credentials)
        }

        #expect(store.account(id: account.id)?.loginId == "")
        #expect(try AccountStore.load(from: url).accounts.first?.autoLogin == false)
    }

    @Test(arguments: [
        ("", "pw", true, false, "Automatic login needs a login ID and a password."),
        ("demo_account", nil, true, false, "Automatic login needs a login ID and a password."),
        ("ege\tcan", "pw", false, false, "Use a login ID of at most 256 characters, without control characters."),
    ] as [(String, String?, Bool, Bool, String)])
    func explainsInvalidLoginSettings(loginId: String, password: String?, autoLogin: Bool, saved: Bool, problem: String) {
        let details = LoginDetails(loginId: loginId, password: password, server: "", character: "", autoLogin: autoLogin)

        #expect(AccountStore.loginProblem(details, hasSavedPassword: saved) == problem)
    }

    @Test func acceptsAutomaticLoginWithASavedPasswordAndBoundsTheFields() {
        #expect(AccountStore.loginProblem(LoginDetails(loginId: "demo_account", password: nil, server: "", character: "", autoLogin: true), hasSavedPassword: true) == nil)
        #expect(AccountStore.loginProblem(LoginDetails(loginId: "demo_account", password: String(repeating: "x", count: 1025), server: "", character: "", autoLogin: false), hasSavedPassword: false) != nil)
        #expect(AccountStore.loginProblem(LoginDetails(loginId: "demo_account", password: "pw", server: "", character: String(repeating: "c", count: 65), autoLogin: false), hasSavedPassword: false) != nil)
        #expect(AccountStore.loginProblem(LoginDetails(loginId: "demo_account", password: "pw", server: String(repeating: "s", count: 65), character: "", autoLogin: false), hasSavedPassword: false) != nil)
    }

    @Test func refusesToSaveInvalidSettings() throws {
        let temp = TemporaryDirectory()
        let (store, _) = try makeStore(in: temp)
        let credentials = InMemoryCredentialStore()
        let account = try store.add(name: "hunter")

        #expect(throws: AccountError.self) {
            try store.updateLogin(id: account.id, details: LoginDetails(loginId: "", password: "pw", server: "", character: "", autoLogin: true), credentials: credentials)
        }
        #expect(try !credentials.exists(accountId: account.id))
    }
}

struct CredentialResponderTests {
    private let clock = Clock()

    private func fixture(autoLogin: Bool = true, loginId: String = "demo_account", password: String? = "the-password-1234") throws -> (Account, InMemoryCredentialStore, CredentialGate) {
        let credentials = InMemoryCredentialStore()
        let account = Account(id: "aaaaaaaaaaaa", name: "hunter", loginId: loginId, autoLogin: autoLogin)
        if let password {
            try credentials.save(password: password, accountId: account.id)
        }
        return (account, credentials, CredentialGate(clock: { [clock] in clock.now }))
    }

    @Test func sendsTheSavedLogin() throws {
        let (account, credentials, gate) = try fixture()

        let response = CredentialResponder.respond(account: account, gate: gate, store: credentials, onKeychainStatus: { _ in })

        #expect(response == .send(id: "demo_account", password: "the-password-1234"))
    }

    @Test func refusesWhenNoLoginDetailsAreSaved() throws {
        let cases: [(Account?, InMemoryCredentialStore, CredentialGate)] = [
            try fixture(autoLogin: false),
            try fixture(loginId: ""),
            try fixture(password: nil),
        ].map { ($0.0, $0.1, $0.2) } + [(nil, InMemoryCredentialStore(), CredentialGate())]

        for (account, store, gate) in cases {
            let response = CredentialResponder.respond(account: account, gate: gate, store: store, onKeychainStatus: { _ in })
            #expect(response == .refuse("No login details are saved for this account."))
        }
    }

    @Test func refusesTheFourthRequestInTenMinutesAndOneWithinFifteenSeconds() throws {
        let (account, credentials, gate) = try fixture()
        func ask() -> CredentialResponse {
            CredentialResponder.respond(account: account, gate: gate, store: credentials, onKeychainStatus: { _ in })
        }
        let refusal = CredentialResponse.refuse("Too many login attempts in a short time; automatic login paused.")

        guard case .send = ask() else { Issue.record("first request refused"); return }
        clock.now.addTimeInterval(5)
        #expect(ask() == refusal)
        clock.now.addTimeInterval(11)
        guard case .send = ask() else { Issue.record("second request refused"); return }
        clock.now.addTimeInterval(16)
        guard case .send = ask() else { Issue.record("third request refused"); return }
        clock.now.addTimeInterval(16)
        #expect(ask() == refusal)
    }

    @Test(arguments: [Int32(-25300), -25293, -128, -34018, 0])
    func turnsKeychainErrorsIntoTheRefusalAndReportsOnlyTheNumber(status: Int32) throws {
        let (account, credentials, gate) = try fixture()
        credentials.failure = status
        var reported: [Int32] = []

        let response = CredentialResponder.respond(account: account, gate: gate, store: credentials, onKeychainStatus: { reported.append($0) })

        #expect(response == .refuse("The saved password cannot be read. Enter it again."))
        #expect(reported == [status])
    }

    @Test func refusesWhenTheItemVanishesBetweenTheChecks() throws {
        final class Vanishing: CredentialStore {
            func exists(accountId: String) throws -> Bool { true }
            func read(accountId: String) throws -> String? { nil }
            func save(password: String, accountId: String) throws {}
            func delete(accountId: String) throws {}
        }
        let account = Account(id: "aaaaaaaaaaaa", name: "hunter", loginId: "demo_account", autoLogin: true)

        let response = CredentialResponder.respond(account: account, gate: CredentialGate(), store: Vanishing(), onKeychainStatus: { _ in })

        #expect(response == .refuse("The saved password cannot be read. Enter it again."))
    }
}

struct LoginMessagesTests {
    @Test func enablesAutoLoginOnlyWithEverythingSaved() {
        let account = Account(id: "aaaaaaaaaaaa", name: "a", loginId: "demo_account", server: "Global", character: "hunter", autoLogin: true)

        #expect(CredentialResponder.autoLoginMessage(account: account, hasPassword: true) as NSDictionary
            == ["type": "auto-login", "enabled": true, "character": "hunter", "server": "Global"])
        #expect(CredentialResponder.autoLoginMessage(account: account, hasPassword: false)["enabled"] as? Bool == false)
        var off = account
        off.autoLogin = false
        #expect(CredentialResponder.autoLoginMessage(account: off, hasPassword: true)["enabled"] as? Bool == false)
        var noId = account
        noId.loginId = ""
        #expect(CredentialResponder.autoLoginMessage(account: noId, hasPassword: true)["enabled"] as? Bool == false)
    }

    @Test func buildsTheCredentialsMessages() {
        #expect(PageMessages.credentials(id: "demo_account", password: "pw") as NSDictionary == ["type": "credentials", "id": "demo_account", "password": "pw"])
        #expect(PageMessages.credentialsDenied(reason: "no") as NSDictionary == ["type": "credentials", "reason": "no"])
    }

    @Test func putsScriptsBeforeTheBridgeWhenAsked() throws {
        let library = try assembledLibraryForLogin()

        let scripts = try library.scripts(frameLimit: 60, beforeBridge: ["// before"], userScripts: ["// after"])

        let before = try #require(scripts.firstIndex(of: "// before"))
        #expect(scripts[before - 1].contains("window.chrome"))
        #expect(scripts[before + 1].contains("initialFrameLimit"))
        #expect(scripts.last == "// after")
    }
}

struct SecretLeakTests {
    @Test func theLoginFlowNeverWritesThePasswordToDisk() throws {
        let temp = TemporaryDirectory()
        let secret = "Zq9-unique-test-secret-\(UUID().uuidString)"
        let accountsUrl = temp.file("accounts.json")
        let store = try AccountStore.load(from: accountsUrl)
        let credentials = InMemoryCredentialStore()
        let log = AppLog(directory: temp.file("logs"))
        let account = try store.add(name: "hunter")

        try store.updateLogin(id: account.id, details: LoginDetails(loginId: "demo_account", password: secret, server: "", character: "", autoLogin: true), credentials: credentials)
        log.info("hunter: settings saved (automatic login on).")
        let gate = CredentialGate()
        for _ in 0..<2 {
            let response = CredentialResponder.respond(account: store.account(id: account.id), gate: gate, store: credentials, onKeychainStatus: { log.warn("Keychain error \($0)") })
            if case .send(let id, _) = response {
                log.info("hunter: typing the saved login into the game (\(id)).")
            } else if case .refuse(let reason) = response {
                log.warn("hunter: \(reason)")
            }
        }
        credentials.failure = -25293
        _ = CredentialResponder.respond(account: store.account(id: account.id), gate: CredentialGate(), store: credentials, onKeychainStatus: { log.warn("Keychain error \($0)") })
        try store.clearPassword(id: account.id, credentials: InMemoryCredentialStore())

        let needle = Data(secret.utf8)
        let files = try FileManager.default.subpathsOfDirectory(atPath: temp.url.path)
        let logFiles = files.filter { $0.hasPrefix("logs/") && $0.hasSuffix(".log") }
        #expect(!logFiles.isEmpty)
        for file in files where !file.hasSuffix("logs") {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: temp.file(file).path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                #expect(try Data(contentsOf: temp.file(file)).range(of: needle) == nil, "found the secret in \(file)")
            }
        }
        #expect(log.recent.allSatisfy { !$0.text.contains(secret) })
        #expect(try Data(contentsOf: accountsUrl).range(of: needle) == nil)
    }
}

struct RealKeychainTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SRO_REAL_KEYCHAIN"] == "1"))
    func savesReadsUpdatesAndDeletesAnItemUnderATestOnlyService() throws {
        let service = "com.corevider.osb-manager.test-\(UUID().uuidString)"
        let keychain = KeychainCredentialStore(service: service)
        let id = "aaaaaaaaaaaa"
        defer { try? keychain.delete(accountId: id) }

        #expect(try !keychain.exists(accountId: id))
        #expect(try keychain.read(accountId: id) == nil)
        try keychain.save(password: "first-\(UUID().uuidString)", accountId: id)
        #expect(try keychain.exists(accountId: id))
        let second = "second-\(UUID().uuidString)-é"
        try keychain.save(password: second, accountId: id)
        #expect(try keychain.read(accountId: id) == second)
        try keychain.delete(accountId: id)
        #expect(try !keychain.exists(accountId: id))
        try keychain.delete(accountId: id)
    }
}

private func assembledLibraryForLogin() throws -> PageScriptLibrary {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sro-scripts-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    for name in PageScriptLibrary.bridgeParts + [PageScriptLibrary.bridgePage] {
        try FileManager.default.copyItem(at: RepositoryPaths.sharedScripts.appendingPathComponent(name), to: temp.appendingPathComponent(name))
    }
    for name in [PageScriptLibrary.browserShim] {
        try FileManager.default.copyItem(at: RepositoryPaths.resources.appendingPathComponent(name), to: temp.appendingPathComponent(name))
    }
    return PageScriptLibrary(directory: temp)
}
