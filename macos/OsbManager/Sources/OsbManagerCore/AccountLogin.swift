import Foundation

public struct LoginDetails: Equatable {
    public var loginId: String
    public var password: String?
    public var server: String
    public var character: String
    public var autoLogin: Bool

    public init(loginId: String, password: String?, server: String, character: String, autoLogin: Bool) {
        self.loginId = loginId
        self.password = password
        self.server = server
        self.character = character
        self.autoLogin = autoLogin
    }
}

extension AccountStore {
    public static func loginProblem(_ details: LoginDetails, hasSavedPassword: Bool) -> String? {
        let loginId = details.loginId.trimmingCharacters(in: .whitespacesAndNewlines)
        if loginId.count > 256 || hasControl(loginId) {
            return "Use a login ID of at most 256 characters, without control characters."
        }
        if (details.password?.count ?? 0) > 1024 {
            return "Use a password of at most 1024 characters."
        }
        if details.character.trimmingCharacters(in: .whitespacesAndNewlines).count > 64 || hasControl(details.character) {
            return "Use a character name of at most 64 characters."
        }
        if details.server.trimmingCharacters(in: .whitespacesAndNewlines).count > 64 || hasControl(details.server) {
            return "Use a server name of at most 64 characters."
        }
        let hasPassword = !(details.password ?? "").isEmpty || hasSavedPassword
        if details.autoLogin && (loginId.isEmpty || !hasPassword) {
            return "Automatic login needs a login ID and a password."
        }
        return nil
    }

    public func updateLogin(id: String, details: LoginDetails, credentials: CredentialStore) throws {
        guard account(id: id) != nil else { return }
        let saved = (try? credentials.exists(accountId: id)) ?? false
        if let problem = Self.loginProblem(details, hasSavedPassword: saved) {
            throw AccountError(problem)
        }
        let loginId = details.loginId.trimmingCharacters(in: .whitespacesAndNewlines)
        if let password = details.password, !password.isEmpty {
            try credentials.save(password: password, accountId: id)
        }
        if loginId.isEmpty {
            try credentials.delete(accountId: id)
        }
        try update(id: id) {
            $0.loginId = loginId
            $0.server = details.server.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.character = details.character.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.autoLogin = details.autoLogin
        }
    }

    @discardableResult
    public func remove(id: String, credentials: CredentialStore) throws -> Account? {
        try credentials.delete(accountId: id)
        return try remove(id: id)
    }

    public func clearPassword(id: String, credentials: CredentialStore) throws {
        try credentials.delete(accountId: id)
        try update(id: id) { $0.autoLogin = false }
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
