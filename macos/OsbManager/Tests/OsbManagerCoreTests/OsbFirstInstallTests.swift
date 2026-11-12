import Foundation
import Testing
@testable import OsbManagerCore

@MainActor
struct OsbFirstInstallTests {
    private struct Start {
        let scripts: ScriptStore
        let settings: AppSettings
    }

    private func start(_ temp: TemporaryDirectory) -> Start {
        Start(
            scripts: ScriptStore(directory: temp.file("scripts"), log: { _ in }),
            settings: AppSettings.load(from: temp.file("settings.json"))
        )
    }

    private func install(_ start: Start, address: String, allowLoopbackHttp: Bool = true) async -> FirstInstallResult {
        await OsbFirstInstall.run(scripts: start.scripts, downloader: HttpScriptDownloader(), settings: start.settings, osbUrl: address, allowLoopbackHttp: allowLoopbackHttp)
    }

    private func server(version: String = "2.0.13") throws -> FakeHttpServer {
        let server = try FakeHttpServer()
        server.serve("/osb.user.js", OsbFixtures.osbSource(version: version))
        return server
    }

    @Test func aFreshFolderInstallsOsbOnceTurnedOn() async throws {
        let temp = TemporaryDirectory()
        let server = try server()
        let first = start(temp)
        #expect(first.settings.osbFirstInstall == .pending)

        let result = await install(first, address: server.base + "/osb.user.js")

        #expect(result.outcome == .installed)
        #expect(server.count("/osb.user.js") == 1)
        let script = try #require(first.scripts.scripts.first)
        #expect(script.enabled)
        #expect(script.meta.version == "2.0.13")
        #expect(script.sourceUrl == server.base + "/osb.user.js")
        #expect(first.settings.osbFirstInstall == .done)

        let second = start(temp)
        let again = await install(second, address: server.base + "/osb.user.js")
        #expect(second.settings.osbFirstInstall == .done)
        #expect(again.outcome == .notDue)
        #expect(server.count("/osb.user.js") == 1)
        #expect(second.scripts.scripts.count == 1)
    }

    @Test func anExistingSettingsFileMakesNoRequestAndMeansSkipped() async throws {
        let temp = TemporaryDirectory()
        let server = try server()
        let old = #"{"frameLimit":60,"shareGameFiles":true}"#
        try old.write(to: temp.file("settings.json"), atomically: true, encoding: .utf8)
        let existing = start(temp)

        let result = await install(existing, address: server.base + "/osb.user.js")

        #expect(existing.settings.osbFirstInstall == .skipped)
        #expect(result.outcome == .notDue)
        #expect(server.total == 0)
        #expect(existing.scripts.scripts.isEmpty)
        #expect(try String(contentsOf: temp.file("settings.json"), encoding: .utf8) == old)
    }

    @Test(arguments: [OsbFixtures.osbSource(version: "2.0.1"), ScriptFixtures.botHeader])
    func anInstalledBotScriptMakesNoRequestAndStoresSkipped(source: String) async throws {
        let temp = TemporaryDirectory()
        let server = try server()
        let first = start(temp)
        try first.scripts.install(source: source, sourceUrl: nil)

        let result = await install(first, address: server.base + "/osb.user.js")

        #expect(result.outcome == .skipped)
        #expect(server.total == 0)
        #expect(first.scripts.scripts.count == 1)
        #expect(first.settings.osbFirstInstall == .skipped)
        #expect(start(temp).settings.osbFirstInstall == .skipped)
    }

    @Test func anInstalledThirdPartyScriptDoesNotStopTheInstall() async throws {
        let temp = TemporaryDirectory()
        let server = try server()
        let first = start(temp)
        try first.scripts.install(source: OsbFixtures.thirdPartySource(version: "1.0.0"), sourceUrl: nil)

        let result = await install(first, address: server.base + "/osb.user.js")

        #expect(result.outcome == .installed)
        #expect(first.scripts.scripts.count == 2)
    }

    @Test func offlineAtTheFirstStartLeavesPendingAndTheNextStartInstalls() async throws {
        let temp = TemporaryDirectory()
        let offline = try OsbFixtures.closedPort()
        let first = start(temp)

        let failed = await install(first, address: offline + "/osb.user.js")

        #expect(failed.outcome == .failed)
        #expect(failed.error != nil)
        #expect(first.scripts.scripts.isEmpty)
        #expect(first.settings.osbFirstInstall == .pending)
        #expect(start(temp).settings.osbFirstInstall == .pending)

        let server = try server()
        let second = start(temp)
        let installed = await install(second, address: server.base + "/osb.user.js")

        #expect(installed.outcome == .installed)
        #expect(second.settings.osbFirstInstall == .done)
        #expect(server.count("/osb.user.js") == 1)
    }

    @Test func aFailureKeepsPendingInASavedSettingsFile() async throws {
        let temp = TemporaryDirectory()
        let offline = try OsbFixtures.closedPort()
        let first = start(temp)
        _ = await install(first, address: offline + "/osb.user.js")
        first.settings.frameLimit = 30
        try first.settings.save()

        let reloaded = start(temp)

        #expect(reloaded.settings.osbFirstInstall == .pending)
        #expect(reloaded.settings.frameLimit == 30)
    }

    @Test func aBotScriptInstalledByHandAfterAFailureEndsTheAttempts() async throws {
        let temp = TemporaryDirectory()
        let offline = try OsbFixtures.closedPort()
        let first = start(temp)
        _ = await install(first, address: offline + "/osb.user.js")
        try first.settings.save()
        try first.scripts.install(source: OsbFixtures.osbSource(version: "2.0.2"), sourceUrl: nil)
        let server = try server()

        let second = start(temp)
        let result = await install(second, address: server.base + "/osb.user.js")

        #expect(result.outcome == .skipped)
        #expect(server.total == 0)
        #expect(second.settings.osbFirstInstall == .skipped)
    }

    @Test func osbRemovedAfterTheFirstInstallIsNotInstalledAgain() async throws {
        let temp = TemporaryDirectory()
        let server = try server()
        let first = start(temp)
        _ = await install(first, address: server.base + "/osb.user.js")
        let script = try #require(first.scripts.scripts.first)
        try first.scripts.remove(script.id)

        let second = start(temp)
        let result = await install(second, address: server.base + "/osb.user.js")

        #expect(result.outcome == .notDue)
        #expect(second.scripts.scripts.isEmpty)
        #expect(server.count("/osb.user.js") == 1)
    }

    @Test func osbTurnedOffStaysOffAndMakesNoRequest() async throws {
        let temp = TemporaryDirectory()
        let server = try server()
        let first = start(temp)
        _ = await install(first, address: server.base + "/osb.user.js")
        let script = try #require(first.scripts.scripts.first)
        try first.scripts.setEnabled(script.id, false)

        let second = start(temp)
        _ = await install(second, address: server.base + "/osb.user.js")

        #expect(second.scripts.scripts.first?.enabled == false)
        #expect(server.count("/osb.user.js") == 1)
    }

    @Test func anHttpAddressWithoutTheTestSeamIsRefusedWithoutARequest() async throws {
        let temp = TemporaryDirectory()
        let server = try server()
        let first = start(temp)

        let result = await install(first, address: server.base + "/osb.user.js", allowLoopbackHttp: false)

        #expect(result.outcome == .failed)
        #expect(result.error is ScriptFormatError)
        #expect(server.total == 0)
        #expect(first.scripts.scripts.isEmpty)
        #expect(first.settings.osbFirstInstall == .pending)
    }

    @Test func theTestSeamAcceptsOnlyLoopbackForHttp() async throws {
        let first = start(TemporaryDirectory())

        let result = await install(first, address: "http://example.com/osb.user.js")

        #expect(result.outcome == .failed)
        #expect(result.error is ScriptFormatError)
    }

    @Test func aDownloadThatIsNotAUserscriptFailsAndStaysPending() async throws {
        let temp = TemporaryDirectory()
        let server = try FakeHttpServer()
        server.serve("/osb.user.js", "<html>not a script</html>")
        let first = start(temp)

        let result = await install(first, address: server.base + "/osb.user.js")

        #expect(result.outcome == .failed)
        #expect(first.scripts.scripts.isEmpty)
        #expect(first.settings.osbFirstInstall == .pending)
    }

    @Test func anErrorStatusFailsAndStaysPending() async throws {
        let server = try FakeHttpServer()
        let first = start(TemporaryDirectory())

        let result = await install(first, address: server.base + "/osb.user.js")

        #expect(result.outcome == .failed)
        #expect(first.settings.osbFirstInstall == .pending)
    }
}

struct FirstStartDetectionTests {
    @Test func aMissingFileIsPendingAndLoadingDoesNotCreateIt() {
        let temp = TemporaryDirectory()

        let settings = AppSettings.load(from: temp.file("settings.json"))

        #expect(settings.osbFirstInstall == .pending)
        #expect(!FileManager.default.fileExists(atPath: temp.file("settings.json").path))
    }

    @Test(arguments: [#"{"frameLimit":60}"#, "not json", #"{"osbFirstInstall":"other"}"#, #"{"osbFirstInstall":3}"#])
    func anOldOrBrokenFileIsSkipped(json: String) throws {
        let temp = TemporaryDirectory()
        try json.write(to: temp.file("settings.json"), atomically: true, encoding: .utf8)

        #expect(AppSettings.load(from: temp.file("settings.json")).osbFirstInstall == .skipped)
    }

    @Test(arguments: [OsbFirstInstallState.pending, .done, .skipped])
    func theStateIsKept(state: OsbFirstInstallState) throws {
        let temp = TemporaryDirectory()
        let settings = AppSettings.load(from: temp.file("settings.json"))
        settings.osbFirstInstall = state
        try settings.save()

        #expect(AppSettings.load(from: temp.file("settings.json")).osbFirstInstall == state)
        #expect(try String(contentsOf: temp.file("settings.json"), encoding: .utf8).contains("\"osbFirstInstall\" : \"\(state.rawValue)\""))
    }
}

struct OsbIdentityTests {
    @Test(arguments: [
        ("https://raw.githubusercontent.com/corevider/osb/main/osb.user.js", true),
        ("https://github.com/corevider/osb/releases/download/v2.0.1/osb.user.js", true),
        ("https://github.com/Corevider/OSB/raw/main/osb.user.js", true),
        ("http://raw.githubusercontent.com/corevider/osb/main/osb.user.js", false),
        ("https://raw.githubusercontent.com/corevider/osb-other/main/osb.user.js", false),
        ("https://raw.githubusercontent.com/someone/osb/main/osb.user.js", false),
        ("https://example.com/corevider/osb/osb.user.js", false),
        ("https://raw.githubusercontent.com/corevider", false),
        ("not a url", false),
    ])
    func recognisesTheRepositoryAddress(address: String, expected: Bool) {
        #expect(BotScripts.isOsbUrl(address) == expected)
    }

    @Test func recognisesTheScriptByNamespaceOrAddress() throws {
        let byNamespace = InstalledScript(id: "a", enabled: true, sourceUrl: nil, meta: try UserScriptMeta.parse(OsbFixtures.osbSource(version: "1.0.0")), injection: "")
        let byAddress = InstalledScript(id: "b", enabled: true, sourceUrl: BotScripts.osbUrl, meta: try UserScriptMeta.parse(OsbFixtures.thirdPartySource(version: "1.0.0")), injection: "")
        let other = InstalledScript(id: "c", enabled: true, sourceUrl: "https://example.com/x.user.js", meta: try UserScriptMeta.parse(OsbFixtures.thirdPartySource(version: "1.0.0")), injection: "")
        let previous = InstalledScript(id: "d", enabled: true, sourceUrl: nil, meta: try UserScriptMeta.parse(ScriptFixtures.botHeader), injection: "")

        #expect(BotScripts.isOsb(byNamespace))
        #expect(BotScripts.isOsb(byAddress))
        #expect(!BotScripts.isOsb(other))
        #expect(!BotScripts.isOsb(previous))
        #expect(BotScripts.isNixxane(previous))
        #expect(!BotScripts.isNixxane(byNamespace))
    }

    @Test func theLaunchOptionTakesTheOsbAddress() throws {
        #expect(try LaunchOptions.parse([]).osbUrl == nil)
        #expect(try LaunchOptions.parse(["--osb-url", "http://127.0.0.1:9/osb.user.js"]).osbUrl == "http://127.0.0.1:9/osb.user.js")
        #expect(throws: LaunchOptionsError.self) { try LaunchOptions.parse(["--osb-url"]) }
        #expect(throws: LaunchOptionsError.self) { try LaunchOptions.parse(["--osb-url", "osb.user.js"]) }
        #expect(LaunchOptions.usage.contains("--osb-url"))
    }
}
