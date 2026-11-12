import Foundation

public enum OsbFirstInstallState: String, Codable, Sendable {
    case pending
    case done
    case skipped
}

public final class AppSettings {
    public static let frameLimits = [30, 60, 120, 0]
    public static let defaultFrameLimit = 60

    private struct Stored: Codable {
        var frameLimit: Int?
        var shareGameFiles: Bool?
        var hideStarSox: Bool?
        var restartAfterRendererFailure: Bool?
        var checkForUpdates: Bool?
        var osbFirstInstall: String?
        var updateOsbAutomatically: Bool?
    }

    private let url: URL
    public var frameLimit = AppSettings.defaultFrameLimit
    public var shareGameFiles = true
    public var hideStarSox = false
    public var restartAfterRendererFailure = true
    public var checkForUpdates = true
    public var osbFirstInstall = OsbFirstInstallState.skipped
    public var updateOsbAutomatically = true

    private init(url: URL) {
        self.url = url
    }

    public static func load(from url: URL) -> AppSettings {
        let settings = AppSettings(url: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            settings.osbFirstInstall = .pending
            return settings
        }
        guard let stored = try? JsonFile.read(Stored.self, from: url) else { return settings }
        if let limit = stored.frameLimit, frameLimits.contains(limit) {
            settings.frameLimit = limit
        }
        settings.shareGameFiles = stored.shareGameFiles ?? true
        settings.hideStarSox = stored.hideStarSox ?? false
        settings.restartAfterRendererFailure = stored.restartAfterRendererFailure ?? true
        settings.checkForUpdates = stored.checkForUpdates ?? true
        settings.osbFirstInstall = stored.osbFirstInstall.flatMap(OsbFirstInstallState.init(rawValue:)) ?? .skipped
        settings.updateOsbAutomatically = stored.updateOsbAutomatically ?? true
        return settings
    }

    public func save() throws {
        try JsonFile.write(
            Stored(
                frameLimit: frameLimit,
                shareGameFiles: shareGameFiles,
                hideStarSox: hideStarSox,
                restartAfterRendererFailure: restartAfterRendererFailure,
                checkForUpdates: checkForUpdates,
                osbFirstInstall: osbFirstInstall.rawValue,
                updateOsbAutomatically: updateOsbAutomatically
            ),
            to: url
        )
    }
}
