import Foundation

nonisolated(unsafe) private var temporaryRootPath = ""

private let temporaryRoot: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sro-tests-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    temporaryRootPath = url.path
    atexit {
        try? FileManager.default.removeItem(atPath: temporaryRootPath)
    }
    return url
}()

struct TemporaryDirectory {
    let url: URL

    init() {
        url = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}
