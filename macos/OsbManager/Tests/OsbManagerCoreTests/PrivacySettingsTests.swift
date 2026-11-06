import Foundation
import Testing
@testable import OsbManagerCore

struct PrivacySettingsTests {
    private func load(_ temp: TemporaryDirectory, keys: InMemoryInstallKeyStore = InMemoryInstallKeyStore()) -> PrivacySettings {
        PrivacySettings.load(from: temp.file("privacy.json"), keyStore: keys)
    }

    @Test func consentIsOffWithoutAFile() {
        let settings = load(TemporaryDirectory())

        #expect(settings.state.status == .undecided)
        #expect(!settings.state.granted)
        #expect(settings.credentials == nil)
    }

    @Test(arguments: [
        "{ not json",
        "",
        "[]",
        "null",
        #"{"usage_consent_version":"one"}"#,
        #"{"usage_consent_version":1,"consent_text_version":"2026-11-04.1"}"#,
        #"{"usage_consent_version":1,"consent_text_version":"2026-11-04.1","install_id":"not-a-uuid"}"#,
        #"{"characters_consent":"yes","decision":"granted"}"#,
        #"{"decision":"maybe"}"#,
    ])
    func aCorruptPrivacyFileFallsBackToConsentOff(contents: String) throws {
        let temp = TemporaryDirectory()
        try contents.write(to: temp.file("privacy.json"), atomically: true, encoding: .utf8)
        let keys = InMemoryInstallKeyStore(key: PrivacySettings.newInstallKey())

        let settings = load(temp, keys: keys)

        #expect(!settings.state.granted)
        #expect(settings.credentials == nil)
        #expect(!settings.state.charactersConsent)
    }

    @Test func aFileThatClaimsConsentButHasNoKeyInTheKeychainIsOff() throws {
        let temp = TemporaryDirectory()
        let first = load(temp)
        first.grant(characters: true)

        let second = load(temp, keys: InMemoryInstallKeyStore())

        #expect(!second.state.granted)
        #expect(second.credentials == nil)
        #expect(second.state.installId == nil)
    }

    @Test func grantingCreatesAnIdentityStoresTheKeyOnlyInTheKeyStoreAndSurvivesARestart() throws {
        let temp = TemporaryDirectory()
        let keys = InMemoryInstallKeyStore()
        let settings = load(temp, keys: keys)

        let state = settings.grant(characters: true)

        #expect(state.granted)
        #expect(state.charactersConsent)
        let credentials = try #require(settings.credentials)
        #expect(credentials.key.count == 43)
        #expect(PrivacySettings.decodeKey(credentials.key)?.count == 32)
        #expect(UUID(uuidString: credentials.id) != nil)
        #expect(keys.key == credentials.key)
        let file = try String(contentsOf: temp.file("privacy.json"), encoding: .utf8)
        #expect(!file.contains(credentials.key))
        #expect(file.contains(credentials.id))
        #expect(file.contains("usage_consent_version"))
        #expect(file.contains("consent_text_version"))

        let reloaded = load(temp, keys: keys)
        #expect(reloaded.state.granted)
        #expect(reloaded.state.charactersConsent)
        #expect(reloaded.credentials == credentials)
    }

    @Test func aKeyStoreThatFailsLeavesConsentOff() {
        let keys = InMemoryInstallKeyStore()
        keys.failAll(with: -25293)
        let settings = load(TemporaryDirectory(), keys: keys)

        settings.grant(characters: false)

        #expect(!settings.state.granted)
        #expect(settings.credentials == nil)
    }

    @Test func theCharactersSwitchWorksOnlyWhileUsageConsentIsOn() {
        let settings = load(TemporaryDirectory())

        #expect(!settings.setCharacters(true))
        #expect(!settings.state.charactersConsent)

        settings.grant(characters: false)
        #expect(settings.setCharacters(true))
        #expect(settings.state.charactersConsent)
        #expect(settings.state.charactersConsentedAt != nil)
        #expect(settings.setCharacters(false))
        #expect(settings.state.charactersConsentedAt == nil)
        #expect(!settings.setCharacters(false))
    }

    @Test func withdrawingWipesTheIdentityTheKeyAndTheCharactersConsent() throws {
        let temp = TemporaryDirectory()
        let keys = InMemoryInstallKeyStore()
        let settings = load(temp, keys: keys)
        settings.grant(characters: true)
        let credentials = try #require(settings.credentials)
        settings.markRegistered(installId: credentials.id, charactersSent: true)

        let result = settings.withdraw()

        #expect(result.credentials == credentials)
        #expect(result.wasRegistered)
        #expect(settings.state.status == .withdrawn)
        #expect(settings.credentials == nil)
        #expect(settings.state.installId == nil)
        #expect(!settings.state.charactersConsent)
        #expect(keys.key == nil)
        let reloaded = load(temp, keys: keys)
        #expect(reloaded.state.status == .withdrawn)
        #expect(!reloaded.state.granted)
    }

    @Test func withdrawingWipesLocallyEvenWhenTheKeychainRefusesTheDeletion() throws {
        let keys = InMemoryInstallKeyStore()
        let settings = load(TemporaryDirectory(), keys: keys)
        settings.grant(characters: false)
        keys.failAll(with: -25244)

        _ = settings.withdraw()

        #expect(settings.credentials == nil)
        #expect(!settings.state.granted)
    }

    @Test func decliningRecordsTheDecisionAndStaysOffAcrossARestart() {
        let temp = TemporaryDirectory()
        let settings = load(temp)

        settings.decline()

        #expect(settings.state.status == .declined)
        #expect(!settings.state.needsAnswer)
        #expect(load(temp).state.status == .declined)
    }

    @Test func aDeclineDoesNotOverwriteAGrantedConsent() {
        let settings = load(TemporaryDirectory())
        settings.grant(characters: false)

        settings.decline()

        #expect(settings.state.granted)
    }

    @Test func observersHearEveryConsentChange() {
        let settings = load(TemporaryDirectory())
        let counter = CallCounter()
        settings.addObserver { counter.increment() }

        settings.grant(characters: false)
        settings.setCharacters(true)
        _ = settings.withdraw()

        #expect(counter.value == 3)
    }

    @Test func installIdsAndKeysAreRandomAndWellFormed() {
        let ids = Set((0..<50).map { _ in PrivacySettings.newInstallId() })
        let keys = Set((0..<50).map { _ in PrivacySettings.newInstallKey() })

        #expect(ids.count == 50)
        #expect(keys.count == 50)
        for id in ids {
            #expect(id.count == 36)
            #expect(Array(id)[14] == "4")
            #expect("89ab".contains(Array(id)[19]))
            #expect(UUID(uuidString: id) != nil)
        }
        for key in keys {
            #expect(key.count == 43)
            #expect(key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test func aMalformedKeyIsRejected() {
        #expect(PrivacySettings.decodeKey(nil) == nil)
        #expect(PrivacySettings.decodeKey("short") == nil)
        #expect(PrivacySettings.decodeKey(String(repeating: "!", count: 43)) == nil)
        #expect(PrivacySettings.decodeKey(PrivacySettings.newInstallKey()) != nil)
    }

    @Test func theKeychainStoreRoundTripsTheInstallKeyInMemoryStandIn() throws {
        let store = InMemoryInstallKeyStore()

        #expect(try store.read() == nil)
        try store.save("abc")
        #expect(try store.read() == "abc")
        try store.save("def")
        #expect(try store.read() == "def")
        try store.delete()
        #expect(try store.read() == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SRO_REAL_KEYCHAIN"] == "1"))
    func theRealKeychainRoundTripsTheInstallKey() throws {
        let store = KeychainInstallKeyStore(service: "com.corevider.osb-manager.install-key.test-\(UUID().uuidString)")
        defer { try? store.delete() }
        let key = PrivacySettings.newInstallKey()

        #expect(try store.read() == nil)
        try store.save(key)
        #expect(try store.read() == key)
        let replacement = PrivacySettings.newInstallKey()
        try store.save(replacement)
        #expect(try store.read() == replacement)
        try store.delete()
        #expect(try store.read() == nil)
    }

    @Test func theReleaseKeychainServiceIsTheDocumentedOne() {
        #expect(TelemetryLimits.keychainService == "com.corevider.osb-manager.install-key")
        #expect(TelemetryLimits.releaseBaseUrl == "https://api.osb.lol/v1")
        #expect(TelemetryLimits.appName == "manager-mac")
        #expect(TelemetryLimits.osName == "macos")
    }
}
