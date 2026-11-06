import Foundation

public final class AccountStore {
    public static let maxNameLength = 40

    private let url: URL
    public private(set) var accounts: [Account] = []

    private init(url: URL) {
        self.url = url
    }

    public static func load(from url: URL) throws -> AccountStore {
        let store = AccountStore(url: url)
        let entries = try JsonFile.read([LossyElement<Account>].self, from: url) ?? []
        for entry in entries {
            guard var account = entry.value, isValidId(account.id),
                  nameProblem(account.name, existing: store.accounts, excluding: nil) == nil,
                  !store.accounts.contains(where: { $0.id == account.id || $0.dataStoreId == account.dataStoreId }) else {
                continue
            }
            account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
            store.accounts.append(account)
        }
        return store
    }

    public func account(id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    @discardableResult
    public func add(name: String) throws -> Account {
        try throwIfInvalid(name, excluding: nil)
        let account = Account(id: Self.randomId(), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        accounts.append(account)
        try save()
        return account
    }

    public func rename(id: String, to name: String) throws {
        try throwIfInvalid(name, excluding: id)
        try update(id: id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func update(id: String, _ change: (inout Account) -> Void) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
        try save()
    }

    @discardableResult
    public func remove(id: String) throws -> Account? {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = accounts.remove(at: index)
        try save()
        return removed
    }

    public func move(id: String, by offset: Int) throws -> Bool {
        guard let from = accounts.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(from + offset, 0), accounts.count - 1)
        guard to != from else { return false }
        let account = accounts.remove(at: from)
        accounts.insert(account, at: to)
        try save()
        return true
    }

    public func save() throws {
        try JsonFile.write(accounts, to: url)
    }

    public static func nameProblem(_ name: String?, existing: [Account], excluding id: String?) -> String? {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a name."
        }
        if trimmed.count > maxNameLength {
            return "Use at most \(maxNameLength) characters."
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Remove control characters from the name."
        }
        if existing.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "Another account already uses this name."
        }
        return nil
    }

    private func throwIfInvalid(_ name: String, excluding id: String?) throws {
        if let problem = Self.nameProblem(name, existing: accounts, excluding: id) {
            throw AccountError(problem)
        }
    }

    private static func isValidId(_ id: String) -> Bool {
        id.count == 12 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func randomId() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

public struct AccountError: Error, LocalizedError, Equatable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
