import Foundation

public struct CefProfiles {
    public let root: URL

    public init(dataRoot: URL) {
        root = dataRoot.appendingPathComponent("cef", isDirectory: true).standardizedFileURL
    }

    public func folder(for dataStoreId: UUID) -> URL {
        root.appendingPathComponent(dataStoreId.uuidString.lowercased(), isDirectory: true)
    }

    public func exists(_ dataStoreId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: dataStoreId).path)
    }

    public func remove(_ dataStoreId: UUID, attempts: Int = 20, delay: TimeInterval = 0.25) async throws {
        let folder = folder(for: dataStoreId)
        guard folder.deletingLastPathComponent().standardizedFileURL == root else {
            throw GameBrowserError("Refusing to delete a folder outside the CEF profile folder.")
        }
        var lastError: Error?
        for _ in 0..<max(attempts, 1) {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            do {
                try FileManager.default.removeItem(at: folder)
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        if FileManager.default.fileExists(atPath: folder.path), let lastError {
            throw lastError
        }
    }
}
