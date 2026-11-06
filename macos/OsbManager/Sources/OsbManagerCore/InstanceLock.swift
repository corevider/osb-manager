import Darwin
import Foundation

public final class InstanceLock {
    private let descriptor: Int32

    public init?(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".lock").path
        let opened = open(path, O_CREAT | O_RDWR, 0o600)
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return nil
        }
        descriptor = opened
        ftruncate(opened, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { pwrite(opened, $0, strlen($0), 0) }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func holderProcessId(directory: URL) -> Int32? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(".lock"), encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
