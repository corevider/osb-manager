import Foundation

public final class AppSettings {
    public static let frameLimits = [30, 60, 120, 0]
    public static let defaultFrameLimit = 60

    private struct Stored: Codable {
        var frameLimit: Int?
        var shareGameFiles: Bool?
        var hideStarSox: Bool?
        var restartAfterRendererFailure: Bool?
        var checkForUpdates: Bool?
    }

    private let url: URL
    public var frameLimit = AppSettings.defaultFrameLimit
    public var shareGameFiles = true
    public var hideStarSox = false
    public var restartAfterRendererFailure = true
    public var checkForUpdates = true

    private init(url: URL) {
        self.url = url
    }

    public static func load(from url: URL) -> AppSettings {
        let settings = AppSettings(url: url)
        guard let stored = try? JsonFile.read(Stored.self, from: url) else { return settings }
        if let limit = stored.frameLimit, frameLimits.contains(limit) {
            settings.frameLimit = limit
        }
        settings.shareGameFiles = stored.shareGameFiles ?? true
        settings.hideStarSox = stored.hideStarSox ?? false
        settings.restartAfterRendererFailure = stored.restartAfterRendererFailure ?? true
        settings.checkForUpdates = stored.checkForUpdates ?? true
        return settings
    }

    public func save() throws {
        try JsonFile.write(Stored(frameLimit: frameLimit, shareGameFiles: shareGameFiles, hideStarSox: hideStarSox, restartAfterRendererFailure: restartAfterRendererFailure, checkForUpdates: checkForUpdates), to: url)
    }
}
