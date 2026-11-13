import Foundation
import Testing
@testable import OsbManagerCore

@Suite(.serialized)
struct DiagnosticsConsentTests {
    private func crash(_ kit: TelemetryKit) -> DiagnosticEvent {
        DiagnosticEvent.make(.process(RendererTermination.detail(status: 2, errorCode: 11)), at: Date(timeIntervalSince1970: TelemetryKit.origin))
    }

    private var diagnosticsFolderExists: (TelemetryKit) -> Bool {
        { FileManager.default.fileExists(atPath: $0.directory.file("diagnostics").path) }
    }

    @Test func withConsentOffNothingIsRecordedOrWritten() throws {
        for kit in [try TelemetryKit(), try ConsentVersionTwoTests.versionOneShareKit().kit] {
            kit.diagnostics.trail.info(TrailCodes.windowStart, window: 1)

            #expect(!kit.diagnostics.recording)
            #expect(kit.diagnostics.record(crash(kit)) == nil)
            #expect(!kit.diagnostics.writePending(crash(kit)))
            #expect(kit.diagnostics.trail.count == 0)
            #expect(kit.diagnostics.limiter.pendingCount == 0)
            #expect(!diagnosticsFolderExists(kit))
        }
    }

    @Test func leftoverFilesAreDeletedWhenConsentIsOffAtStart() throws {
        let installId = PrivacySettings.newInstallId()
        let directory = TemporaryDirectory()
        let folder = directory.file("diagnostics")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("pending-1794495600-0a0b0c0d.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("run.json"))
        try ConsentGateTests.staleConsentFile(textVersion: "2026-11-04.1", installId: installId).write(to: directory.file("privacy.json"), atomically: true, encoding: .utf8)
        let settings = PrivacySettings.load(from: directory.file("privacy.json"), keyStore: InMemoryInstallKeyStore(key: PrivacySettings.newInstallKey()))

        _ = DiagnosticsHub(folder: folder, terms: PrivateTerms(), consentOn: { settings.state.granted })

        #expect(settings.state.status == .outdated)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func nothingRecordedBeforeConsentAppearsAfterIt() async throws {
        let kit = try TelemetryKit()
        _ = kit.diagnostics.record(crash(kit))
        kit.diagnostics.trail.error(TrailCodes.windowRendererExited, window: 1)

        await kit.service.accept(characters: false)
        kit.allowDiagnostics()

        #expect(kit.diagnostics.recording)
        #expect(kit.diagnostics.limiter.take().events.isEmpty)
        #expect(kit.diagnostics.trail.count == 0)
        #expect(kit.diagnostics.record(crash(kit)) == .added)
    }

    @Test func switchingOffWipesAtOnceAndDeletesOnce() async throws {
        let kit = try TelemetryKit()
        kit.publish("account-a", hunting())
        kit.settings.grant(characters: false)
        await kit.run(for: .seconds(5 * 60))
        try #require(!kit.server.to("POST /v1/installs").isEmpty)
        kit.allowDiagnostics()
        let wiped = Flag(false)
        kit.diagnostics.onWipe { wiped.value = true }
        let session = kit.diagnostics.session
        kit.diagnostics.trail.info(TrailCodes.windowStart, window: 1)
        #expect(kit.diagnostics.record(crash(kit)) == .added)
        #expect(kit.diagnostics.writePending(crash(kit)))
        #expect(kit.diagnostics.pending.count == 1)
        let before = kit.server.requests.count

        #expect(await kit.service.withdraw() == .deleted)
        await kit.advance(.seconds(6 * 3600))

        #expect(wiped.value)
        #expect(!kit.diagnostics.isCurrent(session: session))
        #expect(kit.diagnostics.limiter.pendingCount == 0)
        #expect(kit.diagnostics.trail.count == 0)
        #expect(kit.diagnostics.pending.count == 0)
        #expect(!diagnosticsFolderExists(kit))
        #expect(kit.diagnostics.record(crash(kit)) == nil)
        #expect(kit.server.requests.dropFirst(before).map(\.endpoint) == ["DELETE /v1/installs/me"])
        await kit.stop()
    }

    @Test func switchingOnAgainStartsEmpty() async throws {
        let kit = try TelemetryKit()
        await kit.service.accept(characters: false)
        kit.allowDiagnostics()
        _ = kit.diagnostics.record(crash(kit))
        _ = await kit.service.withdraw()

        await kit.service.accept(characters: false)
        #expect(!kit.diagnostics.recording)
        kit.allowDiagnostics()

        #expect(kit.diagnostics.recording)
        #expect(kit.diagnostics.limiter.pendingCount == 0)
        #expect(kit.diagnostics.pendingEvents().isEmpty)
    }

    @Test func noThanksOnTheOutdatedPromptWipesDiagnostics() async throws {
        let (kit, _, _, _) = try ConsentVersionTwoTests.versionOneShareKit()
        await kit.service.decline()

        #expect(!kit.diagnostics.recording)
        #expect(!diagnosticsFolderExists(kit))
    }

    @Test func theCharactersSwitchDoesNotResetDiagnostics() async throws {
        let kit = try TelemetryKit()
        await kit.service.accept(characters: false)
        kit.allowDiagnostics()
        _ = kit.diagnostics.record(crash(kit))

        await kit.service.setCharacters(true)

        #expect(kit.diagnostics.limiter.pendingCount == 1)
    }

    @Test func aPendingCrashFileIsScrubbedAndReadBack() async throws {
        let kit = try TelemetryKit()
        await kit.service.accept(characters: false)
        kit.allowDiagnostics()
        kit.diagnostics.terms.add("CanaryAccountXv")
        let event = DiagnosticEvent.make(
            .error(ErrorDetail(type: "Foundation.NSRangeException", origin: "appdomain", handled: false, frames: ["OsbManagerApp.Login.CanaryAccountXv", "/Users/canaryuserkt/x", "OsbManagerApp.AppDelegate.run"])),
            at: Date(timeIntervalSince1970: TelemetryKit.origin)
        )

        #expect(kit.diagnostics.writePending(event))
        let files = kit.diagnostics.pending.load()
        let text = String(decoding: try #require(files.first).content, as: UTF8.self)
        let events = kit.diagnostics.pendingEvents()

        #expect(!text.contains("CanaryAccountXv"))
        #expect(!text.contains("canaryuserkt"))
        #expect(!text.contains("/Users/"))
        #expect(text.contains("OsbManagerApp.AppDelegate.run"))
        #expect(events.count == 1)
        #expect(events.first?.event.kind == .dotnetException)
    }
}
