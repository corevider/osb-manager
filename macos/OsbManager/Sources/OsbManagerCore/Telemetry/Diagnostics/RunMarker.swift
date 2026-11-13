import CrashSignals
import Darwin
import Foundation

public struct PreviousRun: Equatable, Sendable {
    public let version: String
    public let startedAt: Date
    public let aliveAt: Date
    public let crashed: Bool
    public let endedCleanly: Bool
    public let signal: String?
    public let signalled: Bool

    public var outcome: String {
        crashed || signalled ? "crash" : endedCleanly ? "clean" : "unclean"
    }

    public var uptimeSeconds: Int {
        DiagnosticFormats.clamp(Int(aliveAt.timeIntervalSince(startedAt)), 0, DiagnosticFormats.maxUptimeSeconds)
    }

    public var detail: RunEndDetail {
        RunEndDetail(outcome: outcome, uptimeSeconds: uptimeSeconds, previousVersion: version, signal: outcome == "crash" ? signal : nil)
    }
}

public final class RunMarker: @unchecked Sendable {
    public static let fileName = "run.json"
    public static let signalFileName = "run.signal"
    static let maxFileBytes = 1024

    public let folder: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let recording: @Sendable () -> Bool
    private let useSignals: Bool
    private var version: String?
    private var startedAt = Date(timeIntervalSince1970: 0)
    private var written = false
    private var crashed = false
    private var endedCleanly = false
    private var descriptor: Int32 = -1

    public init(folder: URL, now: @escaping @Sendable () -> Date, recording: @escaping @Sendable () -> Bool, useSignals: Bool = true) {
        self.folder = folder
        self.now = now
        self.recording = recording
        self.useSignals = useSignals
    }

    public var file: URL { folder.appendingPathComponent(Self.fileName) }
    public var signalFile: URL { folder.appendingPathComponent(Self.signalFileName) }

    public var isWritten: Bool {
        lock.withLock { written }
    }

    public func readPrevious() -> PreviousRun? {
        lock.withLock {
            guard recording() else { return nil }
            let signal = readSignalByte()
            guard let data = try? Data(contentsOf: file), data.count <= Self.maxFileBytes,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = root["version"] as? String, DiagnosticFormats.isVersion(version),
                  let started = (root["started"] as? String).flatMap(Self.parseMinute),
                  let alive = (root["alive"] as? String).flatMap(Self.parseMinute) else { return nil }
            let moment = now()
            guard alive >= started, moment.timeIntervalSince(alive) < DiagnosticFormats.maxAge,
                  alive.timeIntervalSince(moment) < DiagnosticFormats.maxAhead else { return nil }
            return PreviousRun(
                version: version,
                startedAt: started,
                aliveAt: alive,
                crashed: root["crashed"] as? Bool == true,
                endedCleanly: root["clean"] as? Bool == true,
                signal: signal.flatMap(DiagnosticFormats.signalName),
                signalled: signal != nil
            )
        }
    }

    @discardableResult
    public func begin(version runVersion: String) -> Bool {
        lock.withLock {
            guard recording(), DiagnosticFormats.isVersion(runVersion) else { return false }
            version = runVersion
            startedAt = DiagnosticFormats.minute(now())
            crashed = false
            endedCleanly = false
            guard write() else { return false }
            openSignalFile()
            return true
        }
    }

    public func touch() {
        lock.withLock {
            if written, recording() {
                write()
            }
        }
    }

    public func markCrashed() {
        lock.withLock {
            crashed = true
            if written {
                write()
            }
        }
    }

    public func clean() {
        lock.withLock {
            closeSignalFile(delete: !crashed)
            guard !crashed else { return }
            if written, recording() {
                endedCleanly = true
                write()
                return
            }
            written = false
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func forget() {
        lock.withLock {
            closeSignalFile(delete: false)
            written = false
        }
    }

    @discardableResult
    private func write() -> Bool {
        guard let version else { return false }
        let body: [String: Any] = [
            "version": version,
            "started": DiagnosticFormats.minuteText(startedAt),
            "alive": DiagnosticFormats.minuteText(now()),
            "crashed": crashed,
            "clean": endedCleanly,
        ]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            try data.write(to: file, options: [.atomic])
            written = true
            return true
        } catch {
            return false
        }
    }

    private func openSignalFile() {
        guard useSignals else { return }
        closeSignalFile(delete: false)
        let opened = open(signalFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return }
        descriptor = opened
        crash_signals_set_descriptor(opened)
        crash_signals_install()
    }

    private func closeSignalFile(delete: Bool) {
        if descriptor >= 0 {
            if crash_signals_descriptor() == descriptor {
                crash_signals_set_descriptor(-1)
            }
            close(descriptor)
            descriptor = -1
        }
        if delete {
            try? FileManager.default.removeItem(at: signalFile)
        }
    }

    private func readSignalByte() -> Int32? {
        guard let handle = try? FileHandle(forReadingFrom: signalFile) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1), let first = data.first else { return nil }
        return Int32(first)
    }

    static func parseMinute(_ text: String) -> Date? {
        guard text.count == 20, text.hasSuffix(":00Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
