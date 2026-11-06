import Foundation

public struct AppPaths: Equatable {
    public let root: URL
    public let accountsFile: URL
    public let settingsFile: URL
    public let soxFile: URL
    public let packCache: URL
    public let scripts: URL
    public let logs: URL
    public let cef: URL
    public let privacyFile: URL
    public let outbox: URL
    public let updates: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
        accountsFile = self.root.appendingPathComponent("accounts.json")
        settingsFile = self.root.appendingPathComponent("settings.json")
        soxFile = self.root.appendingPathComponent("sox.json")
        packCache = self.root.appendingPathComponent("packcache", isDirectory: true)
        scripts = self.root.appendingPathComponent("scripts", isDirectory: true)
        logs = self.root.appendingPathComponent("logs", isDirectory: true)
        cef = self.root.appendingPathComponent(AppIdentity.cefFolderName, isDirectory: true)
        privacyFile = self.root.appendingPathComponent("privacy.json")
        outbox = self.root.appendingPathComponent("outbox", isDirectory: true)
        updates = self.root.appendingPathComponent("updates", isDirectory: true)
    }

    public static func standard() -> AppPaths {
        AppPaths(root: supportDirectory().appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true))
    }

    public func ensureCreated() throws {
        for directory in [root, scripts, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }
}
