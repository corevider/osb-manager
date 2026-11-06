import Foundation

public struct UserScriptMeta: Equatable, Sendable {
    public static let supportedGrants: Set<String> = [
        "none", "unsafeWindow", "GM_info", "GM_addStyle", "GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues",
        "GM.info", "GM.addStyle", "GM.getValue", "GM.setValue", "GM.deleteValue", "GM.listValues",
    ]

    public var name = ""
    public var namespace = ""
    public var version = ""
    public var runAt = "document-idle"
    public var noFrames = false
    public var matches: [String] = []
    public var includes: [String] = []
    public var excludes: [String] = []
    public var grants: [String] = []
    public var requires: [String] = []
    public var updateUrl: String?
    public var downloadUrl: String?

    public var unsupportedGrants: [String] {
        grants.filter { !Self.supportedGrants.contains($0) }
    }

    public static func parse(_ source: String) throws -> UserScriptMeta {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "// ==UserScript==" }),
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "// ==/UserScript==" }) else {
            throw ScriptFormatError("This file has no ==UserScript== header.")
        }
        var values: [String: [String]] = [:]
        for line in lines[(start + 1)..<end] {
            if let (key, value) = metaLine(line) {
                values[key, default: []].append(value)
            }
        }
        func first(_ key: String) -> String? { values[key]?.first }
        func all(_ key: String) -> [String] { (values[key] ?? []).filter { !$0.isEmpty } }

        var meta = UserScriptMeta()
        meta.name = first("name") ?? ""
        meta.namespace = first("namespace") ?? ""
        meta.version = first("version") ?? ""
        if let runAt = first("run-at"), !runAt.isEmpty {
            meta.runAt = runAt
        }
        meta.noFrames = values["noframes"] != nil
        meta.matches = all("match")
        meta.includes = all("include")
        meta.excludes = all("exclude")
        meta.grants = all("grant")
        meta.requires = all("require")
        meta.updateUrl = first("updateURL")
        meta.downloadUrl = first("downloadURL")
        if meta.name.isEmpty {
            throw ScriptFormatError("The script header has no @name.")
        }
        if meta.matches.isEmpty && meta.includes.isEmpty {
            throw ScriptFormatError("The script header has no @match or @include.")
        }
        return meta
    }

    private static func metaLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("//") else { return nil }
        let afterSlashes = trimmed.dropFirst(2).drop { $0 == " " || $0 == "\t" }
        guard afterSlashes.hasPrefix("@") else { return nil }
        let body = afterSlashes.dropFirst()
        let key = body.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        guard !key.isEmpty else { return nil }
        let rest = body.dropFirst(key.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (String(key), rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
