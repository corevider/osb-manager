import Foundation

public struct PendingFile: Equatable, Sendable {
    public let id: String
    public let writtenAt: Date
    public let content: Data
}

public final class PendingDiagnostics: @unchecked Sendable {
    public static let maxFiles = 10
    public static let maxFileBytes = 16 * 1024
    public static let prefix = "pending-"
    public static let fileExtension = ".json"
    public static let expiry: TimeInterval = 7 * 24 * 3600

    public let folder: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let consentOn: @Sendable () -> Bool

    public init(folder: URL, now: @escaping @Sendable () -> Date, consentOn: @escaping @Sendable () -> Bool) {
        self.folder = folder
        self.now = now
        self.consentOn = consentOn
    }

    @discardableResult
    public func write(_ content: Data) -> Bool {
        guard !content.isEmpty, content.count <= Self.maxFileBytes else { return false }
        return lock.withLock {
            guard consentOn() else { return false }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let seconds = Int64(now().timeIntervalSince1970)
                let suffix = PrivacySettings.randomBytes(4).map { String(format: "%02x", $0) }.joined()
                let url = folder.appendingPathComponent("\(Self.prefix)\(seconds)-\(suffix)\(Self.fileExtension)")
                try content.write(to: url, options: [.atomic])
                let files = self.files().sorted { ($0.writtenAt, $0.url.lastPathComponent) > ($1.writtenAt, $1.url.lastPathComponent) }
                files.dropFirst(Self.maxFiles).forEach { Self.remove($0.url) }
                return true
            } catch {
                return false
            }
        }
    }

    public func load() -> [PendingFile] {
        lock.withLock {
            guard consentOn() else {
                wipeLocked()
                return []
            }
            let moment = now()
            var result: [PendingFile] = []
            for file in files().sorted(by: { ($0.writtenAt, $0.url.lastPathComponent) < ($1.writtenAt, $1.url.lastPathComponent) }) {
                if moment.timeIntervalSince(file.writtenAt) >= Self.expiry || file.writtenAt.timeIntervalSince(moment) > 24 * 3600 {
                    Self.remove(file.url)
                    continue
                }
                guard let data = try? Data(contentsOf: file.url), !data.isEmpty, data.count <= Self.maxFileBytes else {
                    Self.remove(file.url)
                    continue
                }
                result.append(PendingFile(id: file.url.lastPathComponent, writtenAt: file.writtenAt, content: data))
            }
            return Array(result.suffix(Self.maxFiles))
        }
    }

    public func delete(id: String) {
        guard !id.contains("/"), !id.contains("\\"), id.hasPrefix(Self.prefix), id.hasSuffix(Self.fileExtension) else { return }
        lock.withLock { Self.remove(folder.appendingPathComponent(id)) }
    }

    public func wipeAll() {
        lock.withLock { wipeLocked() }
    }

    public var count: Int {
        lock.withLock { files().count }
    }

    private func wipeLocked() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        names.forEach { Self.remove(folder.appendingPathComponent($0)) }
        try? FileManager.default.removeItem(at: folder)
    }

    private func files() -> [(url: URL, writtenAt: Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var result: [(URL, Date)] = []
        for name in names where name.hasPrefix(Self.prefix) && name.hasSuffix(Self.fileExtension) {
            let url = folder.appendingPathComponent(name)
            let stem = name.dropFirst(Self.prefix.count).dropLast(Self.fileExtension.count)
            let parts = stem.split(separator: "-")
            if parts.count == 2, parts[0].allSatisfy(\.isASCII), let seconds = Int64(parts[0]), seconds > 0, seconds < 253_402_300_799 {
                result.append((url, Date(timeIntervalSince1970: TimeInterval(seconds))))
            } else {
                Self.remove(url)
            }
        }
        return result
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
