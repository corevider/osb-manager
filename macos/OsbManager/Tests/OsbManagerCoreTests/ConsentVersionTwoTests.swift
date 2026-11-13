import Foundation
import Testing
@testable import OsbManagerCore

@Suite(.serialized)
struct ConsentVersionTwoTests {
    static func versionOneShareKit() throws -> (kit: TelemetryKit, installId: String, key: String, store: InMemoryInstallKeyStore) {
        let installId = PrivacySettings.newInstallId()
        let key = PrivacySettings.newInstallKey()
        let store = InMemoryInstallKeyStore(key: key)
        let file = ConsentGateTests.staleConsentFile(textVersion: "2026-11-04.1", installId: installId)
        let kit = try TelemetryKit(privacyFile: file, keyStore: store)
        return (kit, installId, key, store)
    }

    @Test func aVersionOneShareIsOutdatedSendsNothingAndAsksWithTheLeadLine() async throws {
        let (kit, _, _, _) = try Self.versionOneShareKit()
        kit.publish("account-a", hunting())

        #expect(kit.settings.state.status == .outdated)
        #expect(kit.settings.state.needsAnswer)
        #expect(kit.settings.state.sharedBefore)
        #expect(kit.settings.credentials == nil)
        #expect(!kit.settings.state.charactersConsent)

        await kit.run(for: .seconds(24 * 3600))

        #expect(kit.server.requests.isEmpty)
        await kit.stop()
    }

    @Test func aFreshInstallAsksWithoutTheLeadLine() throws {
        let kit = try TelemetryKit()

        #expect(kit.settings.state.needsAnswer)
        #expect(!kit.settings.state.sharedBefore)
    }

    @Test func declinedAndWithdrawnUsersAreNotAskedWithTheLeadLine() throws {
        let declined = try TelemetryKit()
        declined.settings.decline()
        let withdrawn = try TelemetryKit()
        withdrawn.settings.grant(characters: false)
        _ = withdrawn.settings.withdraw()

        #expect(!declined.settings.state.needsAnswer)
        #expect(!declined.settings.state.sharedBefore)
        #expect(!withdrawn.settings.state.needsAnswer)
        #expect(!withdrawn.settings.state.sharedBefore)
    }

    @Test func noThanksOnTheOutdatedPromptWipesTheIdentityAndDeletesOnce() async throws {
        let (kit, installId, key, store) = try Self.versionOneShareKit()
        await kit.service.start()

        await kit.service.decline()
        await kit.advance(.seconds(24 * 3600))

        #expect(kit.server.requests.map(\.endpoint) == ["DELETE /v1/installs/me"])
        #expect(kit.server.requests[0].authorization == "Bearer osb1.\(installId).\(key)")
        #expect(kit.settings.state.status == .withdrawn)
        #expect(!kit.settings.state.needsAnswer)
        #expect(kit.settings.state.installId == nil)
        #expect(store.key == nil)
        let reloaded = PrivacySettings.load(from: kit.privacyFile, keyStore: store)
        #expect(!reloaded.state.needsAnswer)
        await kit.stop()
    }

    @Test func shareOnTheOutdatedPromptRegistersAgainWithVersionTwo() async throws {
        let (kit, installId, _, _) = try Self.versionOneShareKit()
        kit.publish("account-a", hunting())

        await kit.service.accept(characters: false)
        await kit.run(for: .seconds(5 * 60))

        let register = try #require(kit.server.to("POST /v1/installs").first?.json)
        #expect(register["install_id"] as? String == installId)
        #expect((register["consent"] as? [String: Any])?["usage_version"] as? Int == 2)
        #expect(kit.settings.state.usageConsentVersion == 2)
        #expect(kit.settings.state.consentTextVersion == "2026-11-12.1")
        #expect(!kit.settings.state.sharedBefore)
        await kit.stop()
    }

    @Test func theConsentChangeSendsVersionTwo() async throws {
        let kit = try TelemetryKit()
        kit.settings.grant(characters: false)
        kit.publish("account-a", hunting())
        await kit.run(for: .seconds(5 * 60))
        try #require(!kit.server.to("POST /v1/installs").isEmpty)

        await kit.service.setCharacters(true)

        let put = try #require(kit.server.to("PUT /v1/installs/me/consent").first?.json)
        #expect(put["usage_version"] as? Int == 2)
        #expect(put["characters"] as? Bool == true)
        await kit.stop()
    }

    @Test(arguments: [
        "{ not json",
        #"{"usage_consent_version":2,"consent_text_version":"2026-11-12.1","decision":"granted"}"#,
        #"{"usage_consent_version":2,"consent_text_version":"2026-11-12.1","install_id":"not-a-uuid","decision":"granted"}"#,
        #"{"usage_consent_version":"2","decision":"granted"}"#,
    ])
    func aCorruptVersionTwoFileCountsAsOff(contents: String) async throws {
        let kit = try TelemetryKit(privacyFile: contents, keyStore: InMemoryInstallKeyStore(key: PrivacySettings.newInstallKey()))
        kit.publish("account-a", hunting())

        await kit.run(for: .seconds(24 * 3600))

        #expect(!kit.settings.state.granted)
        #expect(!kit.settings.state.sharedBefore)
        #expect(kit.server.requests.isEmpty)
        await kit.stop()
    }
}
