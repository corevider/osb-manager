import Foundation

final class JsonLog {
    private let handle: FileHandle
    private let start = Date()

    init(directory: URL, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
    }

    func write(_ event: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["event"] = event
        line["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
        guard JSONSerialization.isValidJSONObject(line),
              let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    static func writeDocument(_ document: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
