import Foundation
import Testing
@testable import OsbManagerCore

@Suite(.serialized)
struct ConsentGateTests {
    enum OffState: String, CaseIterable, CustomTestStringConvertible {
        case undecided
        case declined
        case withdrawn
        case corruptFile
        case emptyFile
        case olderTextVersion
        case identityKeyMissing
        case grantedThenWithdrawnBeforeFirstSend

        var testDescription: String { rawValue }
    }

    static func staleConsentFile(textVersion: String, installId: String) -> String {
        """
        {
          "usage_consent_version": 1,
          "consent_text_version": "\(textVersion)",
          "usage_consented_at": "2026-10-01T10:00:00Z",
          "characters_consent": true,
          "decision": "granted",
          "install_id": "\(installId)",
          "registered": true,
          "server_knows_characters": true
        }
        """
    }

    private func kit(in state: OffState) async throws -> TelemetryKit {
        let installId = PrivacySettings.newInstallId()
        switch state {
        case .corruptFile:
            return try TelemetryKit(privacyFile: "{ this is not json")
        case .emptyFile:
            return try TelemetryKit(privacyFile: "")
        case .olderTextVersion:
            let store = InMemoryInstallKeyStore(key: PrivacySettings.newInstallKey())
            return try TelemetryKit(privacyFile: Self.staleConsentFile(textVersion: "2026-10-01.1", installId: installId), keyStore: store)
        case .identityKeyMissing:
            return try TelemetryKit(privacyFile: Self.staleConsentFile(textVersion: TelemetryLimits.consentTextVersion, installId: installId))
        default:
            break
        }
        let kit = try TelemetryKit()
        switch state {
        case .declined:
            kit.settings.decline()
        case .withdrawn:
            kit.settings.grant(characters: true)
            _ = kit.settings.withdraw()
        case .grantedThenWithdrawnBeforeFirstSend:
            kit.settings.grant(characters: true)
            await kit.service.start()
            await kit.advance(.seconds(30))
            #expect(await kit.service.withdraw() == .nothingToDelete)
        default:
            break
        }
        return kit
    }

    private func lifecycle() -> [BotStatus] {
        var signedOut = BotStatus()
        signedOut.phase = "signed-out"
        var connecting = signedOut
        connecting.loginStage = "connecting"
        var select = BotStatus()
        select.phase = "character-select"
        var town = hunting()
        town.hunting = false
        town.townTrip = true
        var dead = hunting()
        dead.dead = true
        var gpu = BotStatus()
        gpu.inWorld = true
        gpu.phase = "world"
        gpu.gpuFailed = "adapter lost"
        gpu.gpuRetries = 3
        var odd = BotStatus()
        odd.phase = "weird"
        odd.level = 99_999
        odd.gold = Int64.min
        return [signedOut, connecting, select, hunting(), town, dead, gpu, odd]
    }

    @Test(arguments: OffState.allCases)
    func withoutCurrentConsentTheWholeLifecycleMakesNoRequestAtAll(state: OffState) async throws {
        let kit = try await kit(in: state)
        await kit.service.start()
        var step = 0

        for _ in 0..<(24 * 6) {
            for status in lifecycle() {
                kit.publish("account-\(step % 3)", status)
                step += 1
            }
            kit.statuses.remove("account-1")
            await kit.advance(.seconds(600))
        }
        #expect(await kit.service.previewNextPayload() == nil)
        _ = ReportPayload.build(kind: .bug, description: "draft that is never sent", diagnostics: [:], appVersion: "1.2.0", locale: "en")
        _ = kit.service.reports.wouldBeAnonymous
        await kit.service.setCharacters(true)
        await kit.advance(.seconds(3600))
        await kit.stop()

        #expect(kit.server.requests.isEmpty)
        #expect(kit.clock.sleeperCount == 0)
        #expect(!kit.settings.state.granted)
        #expect(kit.settings.credentials == nil)
        #expect(!kit.settings.state.charactersConsent)
        #expect(kit.outbox.pending().isEmpty)
    }

    @Test func aFreshInstallIsUndecidedAndNeedsAnAnswer() throws {
        let kit = try TelemetryKit()

        #expect(kit.settings.state.status == .undecided)
        #expect(kit.settings.state.needsAnswer)
        #expect(kit.settings.credentials == nil)
        #expect(!FileManager.default.fileExists(atPath: kit.privacyFile.path))
    }

    @Test func aStoredOlderTextVersionIsOutdatedAndAsksAgainUntilAccepted() async throws {
        let store = InMemoryInstallKeyStore(key: PrivacySettings.newInstallKey())
        let kit = try TelemetryKit(privacyFile: Self.staleConsentFile(textVersion: "2026-10-01.1", installId: PrivacySettings.newInstallId()), keyStore: store)

        #expect(kit.settings.state.status == .outdated)
        #expect(kit.settings.state.needsAnswer)
        #expect(!kit.settings.state.charactersConsent)
        #expect(kit.settings.credentials == nil)

        kit.settings.grant(characters: false)

        #expect(kit.settings.state.granted)
        #expect(kit.settings.state.consentTextVersion == TelemetryLimits.consentTextVersion)
        #expect(kit.settings.state.usageConsentVersion == TelemetryLimits.consentVersion)
        let reloaded = PrivacySettings.load(from: kit.privacyFile, keyStore: store)
        #expect(reloaded.state.granted)
        #expect(reloaded.state.consentTextVersion == TelemetryLimits.consentTextVersion)
    }

    @Test func aNewerTextVersionThanTheAppKnowsIsNotConsentEither() throws {
        let store = InMemoryInstallKeyStore(key: PrivacySettings.newInstallKey())
        let kit = try TelemetryKit(privacyFile: Self.staleConsentFile(textVersion: "2027-01-01.1", installId: PrivacySettings.newInstallId()), keyStore: store)

        #expect(!kit.settings.state.granted)
        #expect(kit.settings.credentials == nil)
    }

    @Test func theOnlyRequestWithoutConsentIsTheReportTheUserSends() async throws {
        let kit = try TelemetryKit()
        kit.settings.decline()
        await kit.service.start()
        let report = ReportPayload.build(kind: .bug, description: "The bot stops.", diagnostics: [:], appVersion: "1.2.0", locale: "en")

        let outcome = await kit.service.sendReport(reportJson: report, screenshot: nil)
        await kit.advance(.seconds(24 * 3600))

        #expect(outcome.result == .sent)
        #expect(outcome.anonymous)
        #expect(kit.server.requests.map(\.endpoint) == ["POST /v1/reports"])
        #expect(kit.server.requests[0].headers["Authorization"] == nil)
        await kit.stop()
    }

    @Test func turningConsentOnStartsTheStartDelayAndOnlyThenTheFirstRequest() async throws {
        let kit = try TelemetryKit()
        kit.publish("a", hunting())
        await kit.service.start()
        await kit.advance(.seconds(3 * 3600))
        #expect(kit.server.requests.isEmpty)

        await kit.service.accept(characters: false)
        await kit.settle()
        #expect(kit.server.requests.isEmpty)

        await kit.advance(.seconds(59))
        #expect(kit.server.requests.isEmpty)
        await kit.advance(.seconds(5 * 60))
        #expect(!kit.server.requests.isEmpty)
        await kit.stop()
    }

    @Test func withdrawingStopsAllSendingAtOnceAndDropsTheQueuedReports() async throws {
        let kit = try TelemetryKit()
        kit.publish("a", hunting())
        kit.settings.grant(characters: true)
        kit.server.route("POST /v1/reports") { _ in .problem(500, "server_error") }
        await kit.run(for: .seconds(15 * 60))
        let report = ReportPayload.build(kind: .bug, description: "queued", diagnostics: [:], appVersion: "1.2.0", locale: "en")
        #expect(await kit.service.sendReport(reportJson: report, screenshot: nil).result == .queued)
        #expect(kit.outbox.pending().count == 1)

        #expect(await kit.service.withdraw() == .deleted)
        let count = kit.server.requests.count
        await kit.advance(.seconds(48 * 3600))

        #expect(kit.outbox.pending().isEmpty)
        #expect(kit.server.requests.count == count)
        #expect(kit.server.to("DELETE /v1/installs/me").count == 1)
        #expect(kit.settings.state.status == .withdrawn)
        await kit.stop()
    }

    @Test func consentGivenAgainAfterWithdrawalCreatesANewIdentity() async throws {
        let kit = try TelemetryKit()
        kit.settings.grant(characters: false)
        let first = try #require(kit.settings.credentials)
        _ = kit.settings.withdraw()

        kit.settings.grant(characters: false)

        let second = try #require(kit.settings.credentials)
        #expect(first.id != second.id)
        #expect(first.key != second.key)
        #expect(kit.settings.state.registered == false)
    }
}
