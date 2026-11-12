import Foundation

public struct LogEntry: Equatable, Sendable {
    public let time: Date
    public let level: String
    public let message: String

    public init(time: Date, level: String, message: String) {
        self.time = time
        self.level = level
        self.message = message
    }

    public var text: String {
        "[\(LogEntry.clockFormatter.string(from: time))] \(level): \(message)"
    }

    private static let clockFormatter = makeFormatter("HH:mm:ss")

    static func makeFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }
}

public final class AppLog: @unchecked Sendable {
    public static let capacity = 1000

    private let directory: URL
    private let clock: () -> Date
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let dayFormatter = LogEntry.makeFormatter("yyyyMMdd")
    public var onAdded: ((LogEntry) -> Void)?

    public init(directory: URL, clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.clock = clock
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var recent: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func info(_ message: String) {
        write("info", message)
    }

    public func warn(_ message: String) {
        write("warn", message)
    }

    public func error(_ message: String, _ error: Error? = nil) {
        write("error", error.map { "\(message) (\($0.localizedDescription))" } ?? message)
    }

    private func write(_ level: String, _ message: String) {
        let single = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let entry = LogEntry(time: clock(), level: level, message: single)
        lock.lock()
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        append(entry)
        lock.unlock()
        onAdded?(entry)
    }

    private func append(_ entry: LogEntry) {
        let file = directory.appendingPathComponent("app-\(dayFormatter.string(from: entry.time)).log")
        let line = Data((entry.text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }
}
