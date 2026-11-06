import Foundation
import Security

public final class KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func exists(accountId: String) throws -> Bool {
        var query = identity(accountId)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw CredentialStoreError(status: status)
        }
    }

    public func read(accountId: String) throws -> String? {
        var query = identity(accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError(status: status)
        }
    }

    public func save(password: String, accountId: String) throws {
        let data = Data(password.utf8)
        let updateStatus = SecItemUpdate(identity(accountId) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = identity(accountId)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw CredentialStoreError(status: addStatus)
            }
        default:
            throw CredentialStoreError(status: updateStatus)
        }
    }

    public func delete(accountId: String) throws {
        let status = SecItemDelete(identity(accountId) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CredentialStoreError(status: status)
        }
    }

    private func identity(_ accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
    }
}
