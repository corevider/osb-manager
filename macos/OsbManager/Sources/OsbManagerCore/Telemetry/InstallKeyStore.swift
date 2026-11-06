import Foundation
import Security

public protocol InstallKeyStore: AnyObject, Sendable {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

public final class KeychainInstallKeyStore: InstallKeyStore, @unchecked Sendable {
    private let service: String
    private let account = "install-key"

    public init(service: String = TelemetryLimits.keychainService) {
        self.service = service
    }

    public func read() throws -> String? {
        var query = identity()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError(status: status)
        }
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(identity() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = identity()
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw CredentialStoreError(status: addStatus)
            }
        default:
            throw CredentialStoreError(status: updateStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(identity() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CredentialStoreError(status: status)
        }
    }

    private func identity() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public final class InMemoryInstallKeyStore: InstallKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var failure: Int32?

    public init(key: String? = nil) {
        stored = key
    }

    public var key: String? {
        lock.withLock { stored }
    }

    public func failAll(with status: Int32?) {
        lock.withLock { failure = status }
    }

    public func read() throws -> String? {
        try lock.withLock {
            try failIfNeeded()
            return stored
        }
    }

    public func save(_ key: String) throws {
        try lock.withLock {
            try failIfNeeded()
            stored = key
        }
    }

    public func delete() throws {
        try lock.withLock {
            try failIfNeeded()
            stored = nil
        }
    }

    private func failIfNeeded() throws {
        if let failure {
            throw CredentialStoreError(status: failure)
        }
    }
}
