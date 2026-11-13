import Foundation
import SystemConfiguration

public struct MachineIdentity: Sendable {
    public var userName: String
    public var fullName: String
    public var hostName: String
    public var computerName: String?
    public var localHostName: String?
    public var homeFolder: String

    public init(userName: String, fullName: String, hostName: String, computerName: String?, localHostName: String?, homeFolder: String) {
        self.userName = userName
        self.fullName = fullName
        self.hostName = hostName
        self.computerName = computerName
        self.localHostName = localHostName
        self.homeFolder = homeFolder
    }

    public static func current() -> MachineIdentity {
        MachineIdentity(
            userName: NSUserName(),
            fullName: NSFullUserName(),
            hostName: ProcessInfo.processInfo.hostName,
            computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
            homeFolder: NSHomeDirectory()
        )
    }
}

public final class PrivateTerms: @unchecked Sendable {
    public static let minLength = 3
    public static let wordMinLength = 4
    public static let capacity = 2000
    static let genericWords: Set<String> = ["macbook", "imac", "mini", "studio", "pro", "air", "max", "mac", "the", "and", "user", "admin"]

    private let lock = NSLock()
    private var order: [String] = []
    private var keys: [String: String] = [:]
    private var pinned: Set<String> = []

    public init() {}

    public static func forMachine(_ identity: MachineIdentity, dataFolder: String, bundlePath: String? = nil) -> PrivateTerms {
        let terms = PrivateTerms()
        terms.pin(identity.userName)
        terms.pin(identity.fullName)
        terms.pinWords(of: identity.fullName)
        terms.pin(identity.hostName)
        terms.pin(identity.hostName.split(separator: ".").first.map(String.init))
        terms.pin(identity.computerName)
        terms.pinWords(of: identity.computerName)
        terms.pin(identity.localHostName)
        terms.pin(identity.homeFolder)
        terms.pin(dataFolder)
        terms.pin(trimmedFolder(dataFolder))
        terms.pin(bundlePath)
        return terms
    }

    public static func forThisMac(dataFolder: URL) -> PrivateTerms {
        forMachine(.current(), dataFolder: dataFolder.path, bundlePath: Bundle.main.bundlePath)
    }

    public var count: Int {
        lock.withLock { keys.count }
    }

    public func add(_ term: String?) {
        guard let value = Self.normalise(term) else { return }
        let key = value.lowercased()
        lock.withLock {
            if keys[key] != nil {
                if !pinned.contains(key), let index = order.firstIndex(of: key) {
                    order.remove(at: index)
                    order.append(key)
                }
                return
            }
            keys[key] = value
            order.append(key)
            while keys.count - pinned.count > Self.capacity, let index = order.firstIndex(where: { !pinned.contains($0) }) {
                keys[order.remove(at: index)] = nil
            }
        }
    }

    public func add(contentsOf values: [String?]) {
        values.forEach { add($0) }
    }

    public func add(accounts: [Account]) {
        for account in accounts {
            add(contentsOf: [account.name, account.loginId, account.server, account.character])
        }
    }

    public func hits(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lower = text.lowercased()
        return lock.withLock { keys.keys.contains { lower.contains($0) } }
    }

    private func pin(_ term: String?) {
        guard let value = Self.normalise(term) else { return }
        let key = value.lowercased()
        lock.withLock {
            if keys[key] == nil {
                keys[key] = value
                order.append(key)
            }
            pinned.insert(key)
        }
    }

    private func pinWords(of text: String?) {
        guard let text else { return }
        let words = text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        for word in words where word.count >= Self.wordMinLength && !Self.genericWords.contains(word.lowercased()) {
            pin(word)
        }
    }

    private static func trimmedFolder(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func normalise(_ term: String?) -> String? {
        guard let value = term?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= minLength else { return nil }
        return value
    }
}
