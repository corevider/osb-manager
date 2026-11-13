import Foundation
import Security

public enum ConsentStatus: String, Codable, Sendable {
    case undecided
    case declined
    case granted
    case withdrawn
    case outdated
}

public struct InstallCredentials: Equatable, Sendable {
    public let id: String
    public let key: String

    public init(id: String, key: String) {
        self.id = id
        self.key = key
    }

    public var bearer: String { "osb1.\(id).\(key)" }

    public var keyBytes: Data { PrivacySettings.decodeKey(key) ?? Data() }
}

public struct PrivacyState: Equatable, Sendable {
    public var status: ConsentStatus
    public var usageConsentVersion: Int
    public var consentTextVersion: String?
    public var usageConsentedAt: Date?
    public var charactersConsent: Bool
    public var charactersConsentedAt: Date?
    public var decidedAt: Date?
    public var installId: String?
    public var registered: Bool
    public var serverKnowsCharacters: Bool
    public var config: TelemetryConfig?
    public var configFetchedAt: Date?
    public var lastSentAt: Date?
    public var lastResult: String?

    public var granted: Bool { status == .granted }

    public var needsAnswer: Bool { status == .undecided || status == .outdated }

    public var sharedBefore: Bool { status == .outdated }
}

public struct WithdrawResult: Sendable {
    public let credentials: InstallCredentials?
    public let wasRegistered: Bool
}

struct PrivacyFile: Codable, Equatable {
    var usageConsentVersion = 0
    var consentTextVersion: String?
    var usageConsentedAt: Date?
    var charactersConsent = false
    var charactersConsentedAt: Date?
    var decision: ConsentStatus = .undecided
    var decidedAt: Date?
    var installId: String?
    var registered = false
    var serverKnowsCharacters = false
    var lastConfig: TelemetryConfig?
    var configFetchedAt: Date?
    var lastSentAt: Date?
    var lastResult: String?
}

public final class PrivacySettings: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let keyStore: InstallKeyStore
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var file: PrivacyFile
    private var installKey: String?
    private var observers: [@Sendable () -> Void] = []
    private var counter = 0

    private init(url: URL, keyStore: InstallKeyStore, now: @escaping @Sendable () -> Date, log: @escaping @Sendable (String) -> Void, file: PrivacyFile, installKey: String?) {
        self.url = url
        self.keyStore = keyStore
        self.now = now
        self.log = log
        self.file = file
        self.installKey = installKey
    }

    public static func load(
        from url: URL,
        keyStore: InstallKeyStore,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> PrivacySettings {
        var file = PrivacyFile()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                file = try decoder().decode(PrivacyFile.self, from: Data(contentsOf: url))
            } catch {
                log("privacy.json could not be read; usage statistics stay off.")
                file = PrivacyFile()
            }
        }
        var key: String?
        if file.usageConsentVersion > 0 || file.installId != nil {
            key = try? keyStore.read()
            if !isUuid(file.installId) || decodeKey(key) == nil {
                log("The install identity is missing or unreadable; usage statistics are off.")
                file = PrivacyFile()
                key = nil
            }
        }
        if file.decision == .granted || file.decision == .outdated {
            file.decision = .undecided
        }
        return PrivacySettings(url: url, keyStore: keyStore, now: now, log: log, file: file, installKey: key)
    }

    public var epoch: Int {
        lock.withLock { counter }
    }

    public var state: PrivacyState {
        lock.withLock { snapshot() }
    }

    public var credentials: InstallCredentials? {
        lock.withLock {
            guard snapshot().granted, let id = file.installId, let key = installKey else { return nil }
            return InstallCredentials(id: id, key: key)
        }
    }

    public func addObserver(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(observer) }
    }

    @discardableResult
    public func grant(characters: Bool) -> PrivacyState {
        let result: PrivacyState = lock.withLock {
            let moment = now()
            if !snapshot().granted {
                if file.installId == nil || installKey == nil {
                    let key = Self.newInstallKey()
                    do {
                        try keyStore.save(key)
                    } catch {
                        log("The install key could not be stored in the Keychain; usage statistics stay off.")
                        return snapshot()
                    }
                    file.installId = Self.newInstallId()
                    installKey = key
                }
                file.registered = false
                file.serverKnowsCharacters = false
                file.usageConsentVersion = TelemetryLimits.consentVersion
                file.consentTextVersion = TelemetryLimits.consentTextVersion
                file.usageConsentedAt = moment
                file.decision = .granted
                file.decidedAt = moment
                file.lastSentAt = nil
                file.lastResult = nil
            }
            applyCharacters(characters, at: moment)
            counter += 1
            save()
            return snapshot()
        }
        notify()
        return result
    }

    @discardableResult
    public func setCharacters(_ on: Bool) -> Bool {
        let changed: Bool = lock.withLock {
            guard snapshot().granted else { return false }
            let changed = file.charactersConsent != on
            applyCharacters(on, at: now())
            if changed { save() }
            return changed
        }
        if changed { notify() }
        return changed
    }

    public func decline() {
        let changed: Bool = lock.withLock {
            guard !snapshot().granted else { return false }
            file.decision = .declined
            file.decidedAt = now()
            counter += 1
            save()
            return true
        }
        if changed { notify() }
    }

    public func withdraw() -> WithdrawResult {
        let result: WithdrawResult = lock.withLock {
            var credentials: InstallCredentials?
            if let id = file.installId, let key = installKey {
                credentials = InstallCredentials(id: id, key: key)
            }
            let result = WithdrawResult(credentials: credentials, wasRegistered: credentials != nil && file.registered)
            file = PrivacyFile(decision: .withdrawn, decidedAt: now())
            installKey = nil
            do {
                try keyStore.delete()
            } catch {
                log("The install key could not be removed from the Keychain.")
            }
            counter += 1
            save()
            return result
        }
        notify()
        return result
    }

    public func markRegistered(installId: String, charactersSent: Bool) {
        update(installId) {
            $0.registered = true
            $0.serverKnowsCharacters = charactersSent
        }
    }

    public func markUnregistered(installId: String) {
        update(installId) { $0.registered = false }
    }

    public func markCharactersSynced(installId: String, value: Bool) {
        update(installId) { $0.serverKnowsCharacters = value }
    }

    public func replaceIdentity(installId: String) -> InstallCredentials? {
        lock.withLock {
            guard snapshot().granted, file.installId == installId else { return nil }
            let key = Self.newInstallKey()
            do {
                try keyStore.save(key)
            } catch {
                log("The install key could not be stored in the Keychain.")
                return nil
            }
            let id = Self.newInstallId()
            file.installId = id
            installKey = key
            file.registered = false
            file.serverKnowsCharacters = false
            save()
            return InstallCredentials(id: id, key: key)
        }
    }

    public func storeConfig(installId: String, config: TelemetryConfig) {
        let moment = now()
        update(installId) {
            $0.lastConfig = config
            $0.configFetchedAt = moment
        }
    }

    public func recordSend(installId: String, result: String, sent: Bool) {
        let moment = now()
        update(installId) {
            $0.lastResult = result
            if sent { $0.lastSentAt = moment }
        }
    }

    public static func decodeKey(_ key: String?) -> Data? {
        guard let key, key.utf8.count == 43 else { return nil }
        let standard = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: standard), data.count == 32 else { return nil }
        return data
    }

    public static func newInstallKey() -> String {
        Data(randomBytes(32)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    public static func newInstallId() -> String {
        var bytes = randomBytes(16)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let chars = Array(bytes.map { String(format: "%02x", $0) }.joined())
        func part(_ range: Range<Int>) -> String { String(chars[range]) }
        return [part(0..<8), part(8..<12), part(12..<16), part(16..<20), part(20..<32)].joined(separator: "-")
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        return bytes
    }

    private static func isUuid(_ text: String?) -> Bool {
        guard let text, text.count == 36, let uuid = UUID(uuidString: text) else { return false }
        return uuid.uuidString.lowercased() == text.lowercased()
    }

    private func update(_ installId: String, _ change: (inout PrivacyFile) -> Void) {
        lock.withLock {
            guard snapshot().granted, file.installId == installId else { return }
            change(&file)
            save()
        }
    }

    private func notify() {
        let handlers = lock.withLock { observers }
        handlers.forEach { $0() }
    }

    private func applyCharacters(_ on: Bool, at moment: Date) {
        guard file.charactersConsent != on else { return }
        file.charactersConsent = on
        file.charactersConsentedAt = on ? moment : nil
    }

    private func snapshot() -> PrivacyState {
        let current = file.usageConsentVersion >= TelemetryLimits.consentVersion
            && file.consentTextVersion == TelemetryLimits.consentTextVersion
            && file.installId != nil
            && installKey != nil
        let status: ConsentStatus = current ? .granted : (file.usageConsentVersion > 0 ? .outdated : file.decision)
        let characters = status == .granted && file.charactersConsent
        return PrivacyState(
            status: status,
            usageConsentVersion: file.usageConsentVersion,
            consentTextVersion: file.consentTextVersion,
            usageConsentedAt: file.usageConsentedAt,
            charactersConsent: characters,
            charactersConsentedAt: characters ? file.charactersConsentedAt : nil,
            decidedAt: file.decidedAt,
            installId: file.installId,
            registered: file.registered,
            serverKnowsCharacters: file.serverKnowsCharacters,
            config: file.lastConfig,
            configFetchedAt: file.configFetchedAt,
            lastSentAt: file.lastSentAt,
            lastResult: file.lastResult
        )
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(file).write(to: url, options: .atomic)
        } catch {
            log("privacy.json could not be saved.")
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
