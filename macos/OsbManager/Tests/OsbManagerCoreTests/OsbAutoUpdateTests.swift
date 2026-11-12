import Foundation
import Testing
@testable import OsbManagerCore

@MainActor
struct OsbAutoUpdateTests {
    private final class SpyDownloader: ScriptDownloading, @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [String] = []
        private let answers: [String: String]

        init(_ answers: [String: String]) {
            self.answers = answers
        }

        var urls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requested
        }

        func download(_ url: URL, maxBytes: Int) async throws -> String {
            lock.lock()
            requested.append(url.absoluteString)
            lock.unlock()
            guard let answer = answers[url.absoluteString] else { throw ScriptFormatError("No answer for \(url.absoluteString).") }
            return answer
        }
    }

    @MainActor private struct Setup {
        let temp: TemporaryDirectory
        let server: FakeHttpServer
        let scripts: ScriptStore
        let jobs: ScriptJobs
        let settings: AppSettings
        let update: OsbAutoUpdate
        let address: String

        var osb: InstalledScript? { scripts.scripts.first(where: BotScripts.isOsb) }
    }

    private func makeSetup(installed: String = "2.0.13", enabled: Bool = true) throws -> Setup {
        let temp = TemporaryDirectory()
        let server = try FakeHttpServer()
        let address = server.base + "/osb.user.js"
        let scripts = ScriptStore(directory: temp.file("scripts"), log: { _ in })
        let script = try scripts.install(source: OsbFixtures.osbSource(version: installed), sourceUrl: address)
        try scripts.setEnabled(script.id, enabled)
        let jobs = ScriptJobs()
        let settings = AppSettings.load(from: temp.file("settings.json"))
        let update = OsbAutoUpdate(scripts: scripts, downloader: HttpScriptDownloader(), jobs: jobs, enabled: { settings.updateOsbAutomatically }, addressOverride: address)
        return Setup(temp: temp, server: server, scripts: scripts, jobs: jobs, settings: settings, update: update, address: address)
    }

    private func announce(_ setup: Setup, meta: String, download: String? = nil, name: String = "OSB", namespace: String = BotScripts.osbNamespace) {
        setup.server.serve("/osb.meta.js", OsbFixtures.osbHeader(version: meta, name: name, namespace: namespace))
        setup.server.serve("/osb.user.js", OsbFixtures.osbSource(version: download ?? meta, name: name, namespace: namespace))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @Test(arguments: [true, false])
    func aNewerVersionUpdatesOnceAndKeepsOnOrOff(enabled: Bool) async throws {
        let setup = try makeSetup(enabled: enabled)
        announce(setup, meta: "2.0.14")

        let result = await setup.update.check()

        #expect(result.outcome == .updated)
        #expect(result.oldVersion == "2.0.13")
        #expect(result.newVersion == "2.0.14")
        #expect(setup.scripts.scripts.count == 1)
        #expect(setup.osb?.meta.version == "2.0.14")
        #expect(setup.osb?.enabled == enabled)
        #expect(setup.server.count("/osb.user.js") == 1)
        #expect(setup.server.count("/osb.meta.js") == 1)
        let reloaded = ScriptStore(directory: setup.temp.file("scripts"), log: { _ in })
        #expect(reloaded.scripts.first?.meta.version == "2.0.14")
        #expect(reloaded.scripts.first?.enabled == enabled)

        let again = await setup.update.check()
        #expect(again.outcome == .upToDate)
        #expect(setup.server.count("/osb.user.js") == 1)
    }

    @Test func theSameVersionNeverDownloadsTheScript() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.13")

        let result = await setup.update.check()

        #expect(result.outcome == .upToDate)
        #expect(setup.server.count("/osb.meta.js") == 1)
        #expect(setup.server.count("/osb.user.js") == 0)
    }

    @Test(arguments: [("2.0.9", "2.0.10", true), ("2.0.10", "2.0.9", false), ("1.9.99", "2.0.0", true), ("2.0.13", "2.0.13", false)])
    func comparesVersionsAsNumbers(installed: String, announced: String, updates: Bool) async throws {
        let setup = try makeSetup(installed: installed)
        announce(setup, meta: announced)

        let result = await setup.update.check()

        #expect(result.outcome == (updates ? .updated : .upToDate))
        #expect(setup.osb?.meta.version == (updates ? announced : installed))
        #expect(setup.server.count("/osb.user.js") == (updates ? 1 : 0))
    }

    @Test func aDownloadOlderThanAnnouncedIsNotKept() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.15", download: "2.0.14")

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func aDownloadOlderThanInstalledIsNotKept() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.14", download: "2.0.12")

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func aDownloadWithAnotherNamespaceIsNotInstalled() async throws {
        let setup = try makeSetup()
        setup.server.serve("/osb.meta.js", OsbFixtures.osbHeader(version: "2.0.14"))
        setup.server.serve("/osb.user.js", OsbFixtures.osbSource(version: "2.0.14", namespace: "https://example.com/other"))

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.scripts.scripts.count == 1)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func aMetaFileWithAnotherNamespaceDownloadsNothing() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.14", namespace: "https://example.com/other")

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.server.count("/osb.user.js") == 0)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func aMetaFileWithAnotherNameDownloadsNothing() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.14", name: "Something else")

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.server.count("/osb.user.js") == 0)
    }

    @Test func anUnparseableMetaFileFailsWithoutChange() async throws {
        let setup = try makeSetup()
        setup.server.serve("/osb.meta.js", "<html>maintenance</html>")

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.server.count("/osb.user.js") == 0)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func aMetaFileWithoutAUsableVersionFails() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "latest")

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.server.count("/osb.user.js") == 0)
    }

    @Test func aTooLargeMetaFileFails() async throws {
        let setup = try makeSetup()
        setup.server.serve("/osb.meta.js", OsbFixtures.osbHeader(version: "2.0.14") + "\n" + String(repeating: "x", count: OsbAutoUpdate.maxMetaBytes + 10))

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.server.count("/osb.user.js") == 0)
    }

    @Test func anInstalledVersionThatIsNotNumericFailsOnce() async throws {
        let setup = try makeSetup(installed: "2.0.13-beta")
        announce(setup, meta: "2.0.14")

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.osb?.meta.version == "2.0.13-beta")
    }

    @Test func anErrorStatusFailsWithoutChange() async throws {
        let setup = try makeSetup()
        setup.server.serve("/osb.meta.js", "gone", status: 500)

        let result = await setup.update.check()

        #expect(result.outcome == .failed)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func offlineWarnsOncePerStreakAndTheNextCheckTriesAgain() async throws {
        let setup = try makeSetup()
        setup.server.stop()

        let first = await setup.update.check()
        let second = await setup.update.check()
        let third = await setup.update.check()

        #expect(first.outcome == .failed)
        #expect(first.firstFailureInStreak)
        #expect(second.outcome == .failed)
        #expect(!second.firstFailureInStreak)
        #expect(!third.firstFailureInStreak)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func aRecoveryEndsTheStreakAndANewFailureWarnsAgain() async throws {
        let setup = try makeSetup()
        let failing = await setup.update.check()
        announce(setup, meta: "2.0.13")
        let recovered = await setup.update.check()
        setup.server.serve("/osb.meta.js", "broken")
        let again = await setup.update.check()

        #expect(failing.firstFailureInStreak)
        #expect(recovered.outcome == .upToDate)
        #expect(again.outcome == .failed)
        #expect(again.firstFailureInStreak)
    }

    @Test func theNextCheckTriesAgainAfterAFailure() async throws {
        let setup = try makeSetup()
        setup.server.serve("/osb.meta.js", "broken")
        _ = await setup.update.check()
        announce(setup, meta: "2.0.14")

        let result = await setup.update.check()

        #expect(result.outcome == .updated)
        #expect(setup.server.count("/osb.meta.js") == 2)
    }

    @Test func theSettingOffMakesNoRequest() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.14")
        setup.settings.updateOsbAutomatically = false

        let result = await setup.update.check()

        #expect(result.outcome == .disabled)
        #expect(setup.server.total == 0)
        #expect(setup.osb?.meta.version == "2.0.13")
    }

    @Test func aThirdPartyScriptIsNeverUpdated() async throws {
        let temp = TemporaryDirectory()
        let server = try FakeHttpServer()
        server.serve("/osb.meta.js", OsbFixtures.thirdPartySource(version: "9.0.0"))
        let scripts = ScriptStore(directory: temp.file("scripts"), log: { _ in })
        try scripts.install(source: OsbFixtures.thirdPartySource(version: "1.0.0"), sourceUrl: server.base + "/other.user.js")
        let update = OsbAutoUpdate(scripts: scripts, downloader: HttpScriptDownloader(), jobs: ScriptJobs(), enabled: { true }, addressOverride: server.base + "/osb.user.js")

        let result = await update.check()

        #expect(result.outcome == .notApplicable)
        #expect(server.total == 0)
        #expect(scripts.scripts.first?.meta.version == "1.0.0")
    }

    @Test func withoutOsbInstalledNothingIsRequested() async throws {
        let temp = TemporaryDirectory()
        let server = try FakeHttpServer()
        let scripts = ScriptStore(directory: temp.file("scripts"), log: { _ in })
        let update = OsbAutoUpdate(scripts: scripts, downloader: HttpScriptDownloader(), jobs: ScriptJobs(), enabled: { true }, addressOverride: server.base + "/osb.user.js")

        let result = await update.check()

        #expect(result.outcome == .notApplicable)
        #expect(server.total == 0)
    }

    @Test func theInstalledAddressesAreUsedWithoutTheTestAddress() async throws {
        let temp = TemporaryDirectory()
        let scripts = ScriptStore(directory: temp.file("scripts"), log: { _ in })
        try scripts.install(source: OsbFixtures.osbSource(version: "2.0.13"), sourceUrl: BotScripts.osbUrl)
        let spy = SpyDownloader([
            "https://raw.githubusercontent.com/corevider/osb/main/osb.meta.js": OsbFixtures.osbHeader(version: "2.0.14"),
            "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js": OsbFixtures.osbSource(version: "2.0.14"),
        ])
        let update = OsbAutoUpdate(scripts: scripts, downloader: spy, jobs: ScriptJobs(), enabled: { true })

        let result = await update.check()

        #expect(result.outcome == .updated)
        #expect(spy.urls == [
            "https://raw.githubusercontent.com/corevider/osb/main/osb.meta.js",
            "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js",
        ])
    }

    @Test(arguments: [
        ("http://raw.githubusercontent.com/corevider/osb/main/osb.meta.js", "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js"),
        ("https://raw.githubusercontent.com/corevider/osb/main/osb.meta.js", "https://example.com/corevider/osb/osb.user.js"),
        ("https://raw.githubusercontent.com/someone/osb/main/osb.meta.js", "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js"),
        ("https://example.com/osb.meta.js", "https://example.com/osb.user.js"),
    ])
    func addressesOutsideTheOsbRepositoryAreRefusedWithoutTheTestAddress(meta: String, download: String) async throws {
        let temp = TemporaryDirectory()
        let scripts = ScriptStore(directory: temp.file("scripts"), log: { _ in })
        let source = OsbFixtures.osbSource(version: "2.0.13")
            .replacingOccurrences(of: "https://raw.githubusercontent.com/corevider/osb/main/osb.meta.js", with: meta)
            .replacingOccurrences(of: "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js", with: download)
        try scripts.install(source: source, sourceUrl: nil)
        let spy = SpyDownloader([:])
        let update = OsbAutoUpdate(scripts: scripts, downloader: spy, jobs: ScriptJobs(), enabled: { true })

        let result = await update.check()

        #expect(result.outcome == .notApplicable)
        #expect(spy.urls.isEmpty)
    }

    @Test func noUpdateRunsWhileAnotherScriptJobRuns() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.14")
        let job = setup.jobs.begin()

        let busy = await setup.update.check()
        #expect(busy.outcome == .busy)
        #expect(setup.server.total == 0)

        job.end()
        let later = await setup.update.check()
        #expect(later.outcome == .updated)
    }

    @Test func noUpdateRunsWhileTheFirstStartInstallRuns() async throws {
        let temp = TemporaryDirectory()
        let server = try FakeHttpServer()
        server.serve("/osb.user.js", OsbFixtures.osbSource(version: "2.0.13"))
        server.serve("/osb.meta.js", OsbFixtures.osbHeader(version: "2.0.14"))
        let held = server.hold("/osb.user.js")
        let scripts = ScriptStore(directory: temp.file("scripts"), log: { _ in })
        let settings = AppSettings.load(from: temp.file("settings.json"))
        let jobs = ScriptJobs()
        let address = server.base + "/osb.user.js"
        let update = OsbAutoUpdate(scripts: scripts, downloader: HttpScriptDownloader(), jobs: jobs, enabled: { true }, addressOverride: address)

        let job = jobs.begin()
        let install = Task { await OsbFirstInstall.run(scripts: scripts, downloader: HttpScriptDownloader(), settings: settings, osbUrl: address, allowLoopbackHttp: true) }
        try await waitUntil { server.count("/osb.user.js") == 1 }

        let during = await update.check()
        #expect(during.outcome == .busy)
        #expect(server.count("/osb.meta.js") == 0)

        held.release.signal()
        let installed = await install.value
        job.end()
        #expect(installed.outcome == .installed)

        server.serve("/osb.user.js", OsbFixtures.osbSource(version: "2.0.14"))
        let after = await update.check()
        #expect(after.outcome == .updated)
        #expect(scripts.scripts.first?.meta.version == "2.0.14")
    }

    @Test func twoChecksNeverOverlap() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.14")
        let held = setup.server.hold("/osb.meta.js")
        let update = setup.update

        let first = Task { await update.check() }
        try await waitUntil { setup.server.count("/osb.meta.js") == 1 }

        let second = await update.check()
        #expect(second.outcome == .busy)
        #expect(setup.server.count("/osb.meta.js") == 1)

        held.release.signal()
        let result = await first.value
        #expect(result.outcome == .updated)
        #expect(setup.server.count("/osb.user.js") == 1)
    }

    @Test func osbRemovedDuringACheckIsNotInstalledAgain() async throws {
        let setup = try makeSetup()
        announce(setup, meta: "2.0.14")
        let held = setup.server.hold("/osb.user.js")
        let update = setup.update

        let check = Task { await update.check() }
        try await waitUntil { setup.server.count("/osb.user.js") == 1 }
        let script = try #require(setup.osb)
        try setup.scripts.remove(script.id)
        held.release.signal()
        let result = await check.value

        #expect(result.outcome == .failed)
        #expect(setup.scripts.scripts.isEmpty)
    }

    @Test func theSettingIsOnByDefaultAndKept() throws {
        let temp = TemporaryDirectory()
        #expect(AppSettings.load(from: temp.file("settings.json")).updateOsbAutomatically)
        try #"{"frameLimit":60}"#.write(to: temp.file("old.json"), atomically: true, encoding: .utf8)
        #expect(AppSettings.load(from: temp.file("old.json")).updateOsbAutomatically)

        let settings = AppSettings.load(from: temp.file("settings.json"))
        settings.updateOsbAutomatically = false
        try settings.save()

        #expect(!AppSettings.load(from: temp.file("settings.json")).updateOsbAutomatically)
        #expect(try String(contentsOf: temp.file("settings.json"), encoding: .utf8).contains("\"updateOsbAutomatically\" : false"))
    }

    @Test func theScheduleHasProductionAndTestTimings() {
        #expect(OsbUpdateSchedule.production.firstDelay == 60)
        #expect(OsbUpdateSchedule.production.interval == 6 * 3600)
        #expect(OsbUpdateSchedule.testing.firstDelay == 3)
        #expect(OsbUpdateSchedule.testing.interval == 15)
        #expect(OsbUpdateSchedule.production.nextDelay(after: .busy) == 60)
        #expect(OsbUpdateSchedule.production.nextDelay(after: .disabled) == 6 * 3600)
        #expect(OsbUpdateSchedule.production.nextDelay(after: .failed) == 6 * 3600)
        #expect(OsbUpdateSchedule.testing.nextDelay(after: .updated) == 15)
    }
}
