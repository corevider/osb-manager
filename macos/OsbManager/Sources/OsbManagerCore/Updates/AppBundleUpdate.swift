import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol UpdateCommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
}

public struct ProcessCommandRunner: UpdateCommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

public struct AppBundleCheck: Sendable {
    public static let teamIdentifier = "F2JRW9TB5A"

    private let runner: UpdateCommandRunner

    public init(runner: UpdateCommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func extract(zip: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = runner.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        guard result.status == 0 else { throw UpdateError("The update zip could not be unpacked: \(Self.firstLine(result.output))") }
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        guard contents == [AppIdentity.bundleName] else {
            throw UpdateError("The update zip does not contain exactly \(AppIdentity.bundleName).")
        }
        let app = folder.appendingPathComponent(AppIdentity.bundleName, isDirectory: true)
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw UpdateError("\(AppIdentity.bundleName) in the update zip is not a folder.")
        }
        return app
    }

    public func verify(app: URL, version: UpdateVersion) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: info) as? [String: Any] else {
            throw UpdateError("The new app has no readable Info.plist.")
        }
        guard plist["CFBundleIdentifier"] as? String == AppIdentity.bundleIdentifier else {
            throw UpdateError("The new app has another bundle identifier.")
        }
        guard plist["CFBundleShortVersionString"] as? String == version.description else {
            throw UpdateError("The new app's version is not the signed version \(version).")
        }
        let codesign = runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard codesign.status == 0 else { throw UpdateError("The new app's code signature is not valid: \(Self.firstLine(codesign.output))") }
        let gatekeeper = runner.run("/usr/sbin/spctl", ["--assess", "--type", "exec", app.path])
        guard gatekeeper.status == 0 else { throw UpdateError("Gatekeeper does not accept the new app: \(Self.firstLine(gatekeeper.output))") }
        let details = runner.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard details.status == 0 else { throw UpdateError("The new app's signature could not be read.") }
        let lines = details.output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.contains("TeamIdentifier=\(Self.teamIdentifier)") else {
            throw UpdateError("The new app is not signed by team \(Self.teamIdentifier).")
        }
        guard lines.contains("Identifier=\(AppIdentity.bundleIdentifier)") else {
            throw UpdateError("The new app is not signed as \(AppIdentity.bundleIdentifier).")
        }
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "").prefix(200).description
    }
}

public struct AppBundleSwap {
    public let target: URL
    public let staging: URL
    public let previous: URL

    public init(target: URL) {
        self.target = target.standardizedFileURL
        let folder = self.target.deletingLastPathComponent()
        let name = self.target.lastPathComponent
        staging = folder.appendingPathComponent(".\(name).new", isDirectory: true)
        previous = folder.appendingPathComponent(".\(name).old", isDirectory: true)
    }

    public var folder: URL { target.deletingLastPathComponent() }

    public static func canWrite(_ folder: URL) -> Bool {
        let probe = folder.appendingPathComponent(".osb-write-test-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    public func stage(_ app: URL) throws {
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.moveItem(at: app, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw UpdateError("Could not put the new app next to the old one: \(error.localizedDescription). Nothing was changed.")
        }
    }

    public func swap() throws {
        guard FileManager.default.fileExists(atPath: staging.path) else { throw UpdateError("The new app has not been prepared.") }
        try? FileManager.default.removeItem(at: previous)
        guard rename(target.path, previous.path) == 0 else {
            throw UpdateError("Could not move the running app aside (\(String(cString: strerror(errno)))). Nothing was changed.")
        }
        guard rename(staging.path, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = rename(previous.path, target.path)
            throw UpdateError("Could not put the new app in place (\(reason)). The previous app was restored.")
        }
    }

    public func rollBack() throws {
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        try? FileManager.default.removeItem(at: staging)
        if FileManager.default.fileExists(atPath: target.path) {
            guard rename(target.path, staging.path) == 0 else { throw UpdateError("Could not move the new app aside.") }
        }
        guard rename(previous.path, target.path) == 0 else { throw UpdateError("Could not put the previous app back.") }
        try? FileManager.default.removeItem(at: staging)
    }

    @discardableResult
    public func cleanUp() -> Int {
        var removed = 0
        for url in [previous, staging] where FileManager.default.fileExists(atPath: url.path) {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

public enum UpdateRelaunch {
    public static let option = "--updated-from"
    public static let startTimeout: TimeInterval = 30
    public static let previousExitTimeout: TimeInterval = 60

    public static func argumentsForRestart(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == option {
                index += 2
                continue
            }
            if !arguments[index].hasPrefix("-psn_") {
                result.append(arguments[index])
            }
            index += 1
        }
        return result
    }

    public static func marker(paths: AppPaths, previousProcess: Int32) -> URL {
        paths.updates.appendingPathComponent("started-\(previousProcess)")
    }

    public static func announceAndWait(paths: AppPaths, previousProcess: Int32) {
        try? FileManager.default.createDirectory(at: paths.updates, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker(paths: paths, previousProcess: previousProcess).path, contents: Data())
        let deadline = Date().addingTimeInterval(previousExitTimeout)
        while kill(previousProcess, 0) == 0 && Date() < deadline {
            usleep(100_000)
        }
    }
}
