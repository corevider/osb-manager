import Foundation

public enum TrailCodes {
    public static let windowStart = "window.start"
    public static let windowClosed = "window.closed"
    public static let windowRendererExited = "window.renderer-exited"
    public static let windowUnresponsive = "window.unresponsive"
    public static let windowResponding = "window.responding"
    public static let windowReload = "window.reload"
    public static let windowRestart = "window.restart"
    public static let windowGaveUp = "window.gave-up"
    public static let loginReload = "login.reload"
    public static let gpuRetry = "gpu.retry"
    public static let updateDownload = "update.download"
    public static let updateFailed = "update.failed"
    public static let scriptInstallFailed = "script.install-failed"
    public static let scriptUpdateFailed = "script.update-failed"
    public static let settingsLightOn = "settings.light-on"
    public static let settingsFpsLimit = "settings.fps-limit"

    public static func loginFailed(_ stage: String?) -> String {
        "login.failed:" + (DiagnosticScrubber.loginStage(stage) ?? DiagnosticScrubber.other)
    }

    public static func gpuFailed(_ text: String?) -> String {
        "gpu.failed:" + (DiagnosticScrubber.gpuFailure(text) ?? DiagnosticScrubber.other)
    }

    public static func category(_ code: String) -> String {
        code.split(separator: ".", maxSplits: 1).first.map(String.init) ?? code
    }
}

public final class DiagnosticTrail: @unchecked Sendable {
    public static let capacity = DiagnosticFormats.maxTrail

    private struct Entry {
        var at: Date
        var level: String
        var code: String
        var window: Int?
        var count: Int
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let recording: @Sendable () -> Bool
    private var entries: [Entry] = []

    public init(now: @escaping @Sendable () -> Date, recording: @escaping @Sendable () -> Bool = { true }) {
        self.now = now
        self.recording = recording
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    public func add(level: String, code: String, window: Int? = nil, at time: Date? = nil) {
        guard DiagnosticFormats.trailLevels.contains(level), DiagnosticFormats.isCode(code), recording() else { return }
        let moment = time ?? now()
        lock.withLock {
            if var newest = entries.last, newest.level == level, newest.code == code, newest.window == window {
                newest.at = moment
                newest.count = min(newest.count + 1, DiagnosticFormats.maxCount)
                entries[entries.count - 1] = newest
                return
            }
            entries.append(Entry(at: moment, level: level, code: code, window: window, count: 1))
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
            }
        }
    }

    public func info(_ code: String, window: Int? = nil) { add(level: "info", code: code, window: window) }
    public func warning(_ code: String, window: Int? = nil) { add(level: "warn", code: code, window: window) }
    public func error(_ code: String, window: Int? = nil) { add(level: "error", code: code, window: window) }

    public func snapshot(before eventAt: Date) -> [TrailItem] {
        lock.withLock {
            entries.compactMap { entry in
                let before = Int((entry.at.timeIntervalSince(eventAt)).rounded())
                guard before <= 0, before >= -86_400 else { return nil }
                return TrailItem(secondsBefore: before, level: entry.level, category: TrailCodes.category(entry.code), code: entry.code, count: entry.count, window: entry.window)
            }
        }
    }

    public func clear() {
        lock.withLock { entries.removeAll() }
    }
}
