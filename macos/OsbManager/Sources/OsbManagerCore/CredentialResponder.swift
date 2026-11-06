import Foundation

public enum CredentialResponse: Equatable {
    case send(id: String, password: String)
    case refuse(String)
}

public enum CredentialResponder {
    public static let noLogin = "No login details are saved for this account."
    public static let tooMany = "Too many login attempts in a short time; automatic login paused."
    public static let unreadable = "The saved password cannot be read. Enter it again."

    public static func respond(account: Account?, gate: CredentialGate, store: CredentialStore, onKeychainStatus: (Int32) -> Void) -> CredentialResponse {
        guard let account, account.autoLogin, !account.loginId.isEmpty else {
            return .refuse(noLogin)
        }
        do {
            guard try store.exists(accountId: account.id) else {
                return .refuse(noLogin)
            }
        } catch {
            onKeychainStatus((error as? CredentialStoreError)?.status ?? -1)
            return .refuse(unreadable)
        }
        guard gate.tryTake() else {
            return .refuse(tooMany)
        }
        do {
            guard let password = try store.read(accountId: account.id), !password.isEmpty else {
                return .refuse(unreadable)
            }
            return .send(id: account.loginId, password: password)
        } catch {
            onKeychainStatus((error as? CredentialStoreError)?.status ?? -1)
            return .refuse(unreadable)
        }
    }

    public static func autoLoginMessage(account: Account, hasPassword: Bool) -> [String: Any] {
        PageMessages.autoLogin(enabled: account.autoLogin && !account.loginId.isEmpty && hasPassword, character: account.character, server: account.server)
    }
}
