import Foundation

public struct PageScriptLibrary {
    public static let bridgeParts = ["autologin.js", "light.js", "gpu.js", "drops.js"]
    public static let bridgePage = "bridge.js"
    public static let browserShim = "cef-shim.js"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func bridge(frameLimit: Int) throws -> String {
        let parts = try Self.bridgeParts.map(load).joined(separator: "\n")
        let page = try load(Self.bridgePage)
        return "(() => {\nconst initialFrameLimit = \(max(0, frameLimit));\n\(parts)\n\(page)\n})();\n"
    }

    public func scripts(frameLimit: Int, beforeBridge: [String] = [], userScripts: [String]) throws -> [String] {
        var scripts = [try load(Self.browserShim)]
        scripts += beforeBridge
        scripts.append(try bridge(frameLimit: frameLimit))
        return scripts + userScripts
    }

    private func load(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ScriptFormatError("The page script \(name) is missing from the build.")
        }
    }
}
