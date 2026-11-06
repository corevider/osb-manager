import Foundation

public protocol CredentialStore: AnyObject {
    func exists(accountId: String) throws -> Bool
    func read(accountId: String) throws -> String?
    func save(password: String, accountId: String) throws
    func delete(accountId: String) throws
}

public struct CredentialStoreError: Error, Equatable, LocalizedError {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }

    public var errorDescription: String? { "Keychain error \(status)." }
}

public final class InMemoryCredentialStore: CredentialStore {
    public private(set) var items: [String: String] = [:]
    public var failure: Int32?

    public init() {}

    public func exists(accountId: String) throws -> Bool {
        try failIfNeeded()
        return items[accountId] != nil
    }

    public func read(accountId: String) throws -> String? {
        try failIfNeeded()
        return items[accountId]
    }

    public func save(password: String, accountId: String) throws {
        try failIfNeeded()
        items[accountId] = password
    }

    public func delete(accountId: String) throws {
        try failIfNeeded()
        items[accountId] = nil
    }

    private func failIfNeeded() throws {
        if let failure {
            throw CredentialStoreError(status: failure)
        }
    }
}
