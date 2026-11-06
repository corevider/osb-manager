import Foundation

public struct OutboxEntry: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var nextAttemptAt: Date
    public var attempts: Int
    public var anonymous: Bool
    public var reportJson: String
    public var lastNote: String?
    public var hasScreenshot: Bool
}

public enum EnqueueOutcome: Equatable, Sendable {
    case queued
    case full
    case tooLarge
    case failed
}

public final class ReportOutbox: @unchecked Sendable {
    public static let maxPending = 5
    public static let maxReportBytes = 900 * 1024

    private let lock = NSLock()
    private let directory: URL
    private let failedDirectory: URL
    private let now: @Sendable () -> Date
    private var observers: [@Sendable () -> Void] = []

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        failedDirectory = directory.appendingPathComponent("failed", isDirectory: true)
        self.now = now
    }

    public func addObserver(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(observer) }
    }

    public func enqueue(reportJson: Data, screenshot: Data?, anonymous: Bool, retryIn: TimeInterval = 0, note: String? = nil) -> (outcome: EnqueueOutcome, id: String) {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if reportJson.count + (screenshot?.count ?? 0) > Self.maxReportBytes {
            return (.tooLarge, id)
        }
        let outcome: EnqueueOutcome = lock.withLock {
            readAll(directory).count >= Self.maxPending ? .full : write(reportJson, screenshot, anonymous, id, retryIn, note)
        }
        if outcome == .queued { notify() }
        return (outcome, id)
    }

    public func pending() -> [OutboxEntry] {
        lock.withLock { readAll(directory) }
    }

    public func failed() -> [OutboxEntry] {
        lock.withLock { readAll(failedDirectory) }
    }

    public func screenshot(for entry: OutboxEntry, failed: Bool) -> Data? {
        lock.withLock {
            guard entry.hasScreenshot else { return nil }
            return try? Data(contentsOf: screenshotUrl(failed ? failedDirectory : directory, entry.id))
        }
    }

    public func nextAttemptAt() -> Date? {
        lock.withLock { readAll(directory).map(\.nextAttemptAt).min() }
    }

    public func nextExpiryAt() -> Date? {
        lock.withLock { readAll(directory).map { $0.createdAt.addingTimeInterval(TelemetryLimits.reportExpiry) }.min() }
    }

    public func recordAttempt(id: String, retryIn: TimeInterval, note: String, anonymous: Bool) {
        lock.withLock {
            guard var entry = readAll(directory).first(where: { $0.id == id }) else { return }
            entry.attempts += 1
            entry.nextAttemptAt = now().addingTimeInterval(retryIn)
            entry.lastNote = note
            entry.anonymous = entry.anonymous || anonymous
            writeEntry(directory, entry)
        }
    }

    public func remove(id: String) {
        lock.withLock { delete(directory, id) }
        notify()
    }

    @discardableResult
    public func moveExpired() -> Int {
        let moved: Int = lock.withLock {
            let moment = now()
            var count = 0
            for entry in readAll(directory) where moment.timeIntervalSince(entry.createdAt) >= TelemetryLimits.reportExpiry {
                try? FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
                if entry.hasScreenshot { move(screenshotUrl(directory, entry.id), to: screenshotUrl(failedDirectory, entry.id)) }
                move(entryUrl(directory, entry.id), to: entryUrl(failedDirectory, entry.id))
                count += 1
            }
            return count
        }
        if moved > 0 { notify() }
        return moved
    }

    public func sendAgain(id: String) -> Bool {
        let moved: Bool = lock.withLock {
            guard readAll(directory).count < Self.maxPending, var entry = readAll(failedDirectory).first(where: { $0.id == id }) else { return false }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let moment = now()
            entry.createdAt = moment
            entry.nextAttemptAt = moment
            entry.attempts = 0
            if entry.hasScreenshot { move(screenshotUrl(failedDirectory, id), to: screenshotUrl(directory, id)) }
            writeEntry(directory, entry)
            try? FileManager.default.removeItem(at: entryUrl(failedDirectory, id))
            return true
        }
        if moved { notify() }
        return moved
    }

    public func deleteFailed(id: String) {
        lock.withLock { delete(failedDirectory, id) }
        notify()
    }

    public func clearAll() {
        lock.withLock {
            for folder in [directory, failedDirectory] {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for file in files where !file.hasDirectoryPath {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        notify()
    }

    private func notify() {
        let handlers = lock.withLock { observers }
        handlers.forEach { $0() }
    }

    private func write(_ reportJson: Data, _ screenshot: Data?, _ anonymous: Bool, _ id: String, _ retryIn: TimeInterval, _ note: String?) -> EnqueueOutcome {
        let moment = now()
        let entry = OutboxEntry(
            id: id,
            createdAt: moment,
            nextAttemptAt: moment.addingTimeInterval(retryIn),
            attempts: note == nil ? 0 : 1,
            anonymous: anonymous,
            reportJson: String(decoding: reportJson, as: UTF8.self),
            lastNote: note,
            hasScreenshot: screenshot != nil
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let screenshot {
                try screenshot.write(to: screenshotUrl(directory, id), options: .atomic)
            }
            try encode(entry).write(to: entryUrl(directory, id), options: .atomic)
            return .queued
        } catch {
            delete(directory, id)
            return .failed
        }
    }

    private func entryUrl(_ folder: URL, _ id: String) -> URL {
        folder.appendingPathComponent(id + ".json")
    }

    private func screenshotUrl(_ folder: URL, _ id: String) -> URL {
        folder.appendingPathComponent(id + ".png")
    }

    private func delete(_ folder: URL, _ id: String) {
        try? FileManager.default.removeItem(at: entryUrl(folder, id))
        try? FileManager.default.removeItem(at: screenshotUrl(folder, id))
    }

    private func move(_ source: URL, to target: URL) {
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: source, to: target)
    }

    private func readAll(_ folder: URL) -> [OutboxEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var entries: [OutboxEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = try? decode(data), entry.id == file.deletingPathExtension().lastPathComponent else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.createdAt < $1.createdAt }
    }

    private func writeEntry(_ folder: URL, _ entry: OutboxEntry) {
        try? encode(entry).write(to: entryUrl(folder, entry.id), options: .atomic)
    }

    private func encode(_ entry: OutboxEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entry)
    }

    private func decode(_ data: Data) throws -> OutboxEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OutboxEntry.self, from: data)
    }
}
