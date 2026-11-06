import Foundation
import Testing
@testable import OsbManagerCore

final class FakeCommands: UpdateCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    var answers: [String: CommandResult] = [:]
    var realDitto = true

    var seen: [[String]] { lock.withLock { calls } }

    init(team: String = AppBundleCheck.teamIdentifier, identifier: String = AppIdentity.bundleIdentifier) {
        answers["codesign --verify"] = CommandResult(status: 0, output: "")
        answers["spctl"] = CommandResult(status: 0, output: "accepted\nsource=Notarized Developer ID")
        answers["codesign -dv"] = CommandResult(status: 0, output: "Executable=/x\nIdentifier=\(identifier)\nFormat=app bundle\nTeamIdentifier=\(team)\n")
    }

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        lock.withLock { calls.append([executable] + arguments) }
        switch executable {
        case "/usr/bin/ditto":
            return realDitto ? ProcessCommandRunner().run(executable, arguments) : CommandResult(status: 1, output: "ditto failed")
        case "/usr/sbin/spctl":
            return answers["spctl"]!
        case "/usr/bin/codesign":
            return arguments.first == "--verify" ? answers["codesign --verify"]! : answers["codesign -dv"]!
        default:
            return CommandResult(status: 127, output: "unexpected \(executable)")
        }
    }
}

private func makeApp(in folder: URL, name: String = AppIdentity.bundleName, identifier: String = AppIdentity.bundleIdentifier, version: String = "1.0.3", marker: String = "new") throws -> URL {
    let app = folder.appendingPathComponent(name, isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try Data(marker.utf8).write(to: contents.appendingPathComponent("MacOS/marker"))
    return app
}

private func marker(_ app: URL) -> String? {
    (try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/marker"), encoding: .utf8))
}

private func zip(_ folder: URL, into file: URL) {
    _ = ProcessCommandRunner().run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, file.path])
}

struct AppBundleCheckTests {
    @Test func extractsAndVerifiesASignedApp() throws {
        let temp = TemporaryDirectory()
        let source = temp.file("source")
        let app = try makeApp(in: source)
        zip(app, into: temp.file("update.zip"))
        let commands = FakeCommands()
        let check = AppBundleCheck(runner: commands)

        let extracted = try check.extract(zip: temp.file("update.zip"), into: temp.file("x"))
        try check.verify(app: extracted, version: UpdateVersion("1.0.3")!)

        #expect(marker(extracted) == "new")
        let commandsRun = commands.seen.map { $0.prefix(3).joined(separator: " ") }
        #expect(commandsRun.contains("/usr/bin/codesign --verify --deep"))
        #expect(commands.seen.contains { $0 == ["/usr/sbin/spctl", "--assess", "--type", "exec", extracted.path] })
        #expect(commands.seen.contains { $0.first == "/usr/bin/codesign" && $0.contains("--strict") })
    }

    @Test func refusesAZipWithAnotherTopLevelFolder() throws {
        let temp = TemporaryDirectory()
        let app = try makeApp(in: temp.file("source"), name: "Other.app")
        zip(app, into: temp.file("update.zip"))

        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: FakeCommands()).extract(zip: temp.file("update.zip"), into: temp.file("x")) }
    }

    @Test func refusesWhenDittoFails() {
        let temp = TemporaryDirectory()
        let commands = FakeCommands()
        commands.realDitto = false

        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: commands).extract(zip: temp.file("missing.zip"), into: temp.file("x")) }
    }

    @Test func refusesABrokenSignature() throws {
        let temp = TemporaryDirectory()
        let app = try makeApp(in: temp.url)
        let commands = FakeCommands()
        commands.answers["codesign --verify"] = CommandResult(status: 1, output: "a sealed resource is missing or invalid")

        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: commands).verify(app: app, version: UpdateVersion("1.0.3")!) }
        #expect(!commands.seen.contains { $0.first == "/usr/sbin/spctl" })
    }

    @Test func refusesWhatGatekeeperRejects() throws {
        let temp = TemporaryDirectory()
        let app = try makeApp(in: temp.url)
        let commands = FakeCommands()
        commands.answers["spctl"] = CommandResult(status: 3, output: "rejected")

        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: commands).verify(app: app, version: UpdateVersion("1.0.3")!) }
    }

    @Test(arguments: ["ABCDE12345", "F2JRW9TB5", "F2JRW9TB5AX"])
    func refusesAnotherTeam(_ team: String) throws {
        let temp = TemporaryDirectory()
        let app = try makeApp(in: temp.url)

        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: FakeCommands(team: team)).verify(app: app, version: UpdateVersion("1.0.3")!) }
    }

    @Test func refusesAnotherSignedIdentifier() throws {
        let temp = TemporaryDirectory()
        let app = try makeApp(in: temp.url)

        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: FakeCommands(identifier: "com.example.other")).verify(app: app, version: UpdateVersion("1.0.3")!) }
    }

    @Test func refusesAnotherBundleIdentifierOrVersion() throws {
        let temp = TemporaryDirectory()
        let other = try makeApp(in: temp.file("a"), identifier: "com.corevider.osb-manager.e2e")
        let older = try makeApp(in: temp.file("b"), version: "1.0.2")

        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: FakeCommands()).verify(app: other, version: UpdateVersion("1.0.3")!) }
        #expect(throws: UpdateError.self) { try AppBundleCheck(runner: FakeCommands()).verify(app: older, version: UpdateVersion("1.0.3")!) }
    }
}

struct AppBundleSwapTests {
    @Test func replacesTheAppAndKeepsTheOldOneUntilCleanUp() throws {
        let temp = TemporaryDirectory()
        let applications = temp.file("Applications")
        let installed = try makeApp(in: applications, version: "1.0.2", marker: "old")
        let fresh = try makeApp(in: temp.file("download"))
        let swap = AppBundleSwap(target: installed)

        try swap.stage(fresh)
        #expect(marker(installed) == "old")
        #expect(swap.staging.lastPathComponent == ".OSB Manager.app.new")
        try swap.swap()

        #expect(marker(installed) == "new")
        #expect(marker(swap.previous) == "old")
        #expect(swap.previous.lastPathComponent == ".OSB Manager.app.old")
        #expect(swap.cleanUp() == 1)
        #expect(!FileManager.default.fileExists(atPath: swap.previous.path))
    }

    @Test func rollsBackToThePreviousApp() throws {
        let temp = TemporaryDirectory()
        let installed = try makeApp(in: temp.file("Applications"), marker: "old")
        let swap = AppBundleSwap(target: installed)
        try swap.stage(try makeApp(in: temp.file("download")))
        try swap.swap()

        try swap.rollBack()

        #expect(marker(installed) == "old")
        #expect(!FileManager.default.fileExists(atPath: swap.previous.path))
        #expect(!FileManager.default.fileExists(atPath: swap.staging.path))
    }

    @Test func changesNothingWithoutAStagedApp() throws {
        let temp = TemporaryDirectory()
        let installed = try makeApp(in: temp.file("Applications"), marker: "old")
        let swap = AppBundleSwap(target: installed)

        #expect(throws: UpdateError.self) { try swap.swap() }
        #expect(marker(installed) == "old")
    }

    @Test func tellsAWritableFolderFromOneThatIsNot() throws {
        let temp = TemporaryDirectory()
        let locked = temp.file("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(AppBundleSwap.canWrite(temp.url))
        #expect(!AppBundleSwap.canWrite(locked))
        #expect(!AppBundleSwap.canWrite(URL(fileURLWithPath: "/System/Applications")))
    }

    @Test func restartsWithTheSameArguments() throws {
        #expect(UpdateRelaunch.argumentsForRestart(["--data", "/tmp/My Data", "--updated-from", "12", "-psn_0_1", "--light"]) == ["--data", "/tmp/My Data", "--light"])
        #expect(try LaunchOptions.parse(["--updated-from", "4242"]).updatedFrom == 4242)
        #expect(throws: LaunchOptionsError.self) { try LaunchOptions.parse(["--updated-from", "x"]) }
        #expect(throws: LaunchOptionsError.self) { try LaunchOptions.parse(["--updated-from", "0"]) }
        #expect(!LaunchOptions.usage.contains(UpdateRelaunch.option))
    }

    @Test func checkForUpdatesIsOnByDefaultAndKept() throws {
        let temp = TemporaryDirectory()
        let settings = AppSettings.load(from: temp.file("settings.json"))
        #expect(settings.checkForUpdates)

        settings.checkForUpdates = false
        try settings.save()

        #expect(!AppSettings.load(from: temp.file("settings.json")).checkForUpdates)
    }
}
