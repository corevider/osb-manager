import Foundation

public struct InstalledScript: Equatable, Identifiable {
    public let id: String
    public var enabled: Bool
    public var sourceUrl: String?
    public let meta: UserScriptMeta
    public let injection: String

    public var updateSource: String? { meta.downloadUrl ?? sourceUrl }

    public var warnings: [String] {
        meta.unsupportedGrants.map { "unsupported @grant \($0)" } + (meta.requires.isEmpty ? [] : ["@require is not loaded"])
    }
}

public protocol ScriptDownloading {
    func download(_ url: URL) async throws -> String
}

@MainActor
public final class ScriptStore {
    public static let maxScriptBytes = 16 << 20

    private struct Entry: Codable {
        var id: String
        var enabled: Bool
        var sourceUrl: String?
    }

    private let directory: URL
    private let indexUrl: URL
    public private(set) var scripts: [InstalledScript] = []
    public var onChange: (() -> Void)?

    public init(directory: URL, log: (String) -> Void) {
        self.directory = directory
        indexUrl = directory.appendingPathComponent("scripts.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries: [LossyElement<Entry>]
        do {
            entries = try JsonFile.read([LossyElement<Entry>].self, from: indexUrl) ?? []
        } catch {
            log("Could not read the script list: \(error.localizedDescription)")
            return
        }
        for case let entry? in entries.map(\.value) {
            guard Self.isValidId(entry.id) else { continue }
            do {
                let source = try String(contentsOf: fileUrl(entry.id), encoding: .utf8)
                let meta = try UserScriptMeta.parse(source)
                scripts.append(InstalledScript(
                    id: entry.id,
                    enabled: entry.enabled,
                    sourceUrl: entry.sourceUrl,
                    meta: meta,
                    injection: try ScriptInjection.build(meta: meta, source: source)
                ))
            } catch {
                log("Skipped installed script \(entry.id): \(error.localizedDescription)")
            }
        }
    }

    public var enabledInjections: [String] {
        scripts.filter(\.enabled).map(\.injection)
    }

    @discardableResult
    public func install(source: String, sourceUrl: String?) throws -> InstalledScript {
        let meta = try UserScriptMeta.parse(source)
        let injection = try ScriptInjection.build(meta: meta, source: source)
        let existing = scripts.firstIndex { $0.meta.name == meta.name && $0.meta.namespace == meta.namespace }
        let previous = existing.map { scripts[$0] }
        let installed = InstalledScript(
            id: previous?.id ?? Self.randomId(),
            enabled: previous?.enabled ?? true,
            sourceUrl: sourceUrl ?? previous?.sourceUrl,
            meta: meta,
            injection: injection
        )
        try source.write(to: fileUrl(installed.id), atomically: true, encoding: .utf8)
        if let existing {
            scripts[existing] = installed
        } else {
            scripts.append(installed)
        }
        try save()
        return installed
    }

    @discardableResult
    public func install(fromUrl address: String, downloader: ScriptDownloading) async throws -> InstalledScript {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil else {
            throw ScriptFormatError("Use an https:// address.")
        }
        let source = try await downloader.download(url)
        if source.utf8.count > Self.maxScriptBytes {
            throw ScriptFormatError("The script is too large.")
        }
        return try install(source: source, sourceUrl: url.absoluteString)
    }

    @discardableResult
    public func install(fromFile url: URL) throws -> InstalledScript {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > Self.maxScriptBytes {
            throw ScriptFormatError("The script is too large.")
        }
        return try install(source: String(contentsOf: url, encoding: .utf8), sourceUrl: nil)
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].enabled = enabled
        try save()
    }

    public func remove(_ id: String) throws {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts.remove(at: index)
        try? FileManager.default.removeItem(at: fileUrl(id))
        try save()
    }

    private func save() throws {
        try JsonFile.write(scripts.map { Entry(id: $0.id, enabled: $0.enabled, sourceUrl: $0.sourceUrl) }, to: indexUrl)
        onChange?()
    }

    private func fileUrl(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".user.js")
    }

    private static func isValidId(_ id: String) -> Bool {
        id.count == 12 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func randomId() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

public struct HttpScriptDownloader: ScriptDownloading {
    public init() {}

    public func download(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("OsbManager/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScriptFormatError("The server answered with status \(http.statusCode).")
        }
        if response.expectedContentLength > Int64(ScriptStore.maxScriptBytes) {
            throw ScriptFormatError("The script is too large.")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > ScriptStore.maxScriptBytes {
                throw ScriptFormatError("The script is too large.")
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScriptFormatError("The script is not UTF-8 text.")
        }
        return text
    }
}
