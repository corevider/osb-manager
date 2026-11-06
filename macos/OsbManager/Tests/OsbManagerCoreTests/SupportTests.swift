import CoreGraphics
import Foundation
import Testing
@testable import OsbManagerCore

struct LaunchOptionsTests {
    @Test func parsesTheSwitches() throws {
        let options = try LaunchOptions.parse(["--data", "/tmp/sro", "--start", "a, b,,c", "--light"])

        #expect(options.dataRoot?.path == "/tmp/sro")
        #expect(options.start == ["a", "b", "c"])
        #expect(options.startLight)
    }

    @Test func expandsTheHomeFolder() throws {
        let options = try LaunchOptions.parse(["--data", "~/sro/x"])

        #expect(options.dataRoot?.path == NSHomeDirectory() + "/sro/x")
    }

    @Test func defaultsToNothing() throws {
        #expect(try LaunchOptions.parse([]) == LaunchOptions())
    }

    @Test(arguments: [["--data"], ["--data", ""], ["--start"], ["--nope"]])
    func rejectsBadArguments(arguments: [String]) {
        #expect(throws: LaunchOptionsError.self) { try LaunchOptions.parse(arguments) }
    }
}

struct AppPathsTests {
    @Test func placesTheFilesUnderOneRoot() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/sro-data", isDirectory: true))

        #expect(paths.accountsFile.path == "/tmp/sro-data/accounts.json")
        #expect(paths.settingsFile.path == "/tmp/sro-data/settings.json")
        #expect(paths.scripts.path == "/tmp/sro-data/scripts")
        #expect(paths.logs.path == "/tmp/sro-data/logs")
    }

    @Test func usesApplicationSupportByDefault() {
        #expect(AppPaths.standard().root.path.hasSuffix("/Library/Application Support/OSB Manager"))
    }

    @Test func createsTheFolders() throws {
        let temp = TemporaryDirectory()
        let paths = AppPaths(root: temp.file("data"))

        try paths.ensureCreated()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.logs.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(FileManager.default.fileExists(atPath: paths.scripts.path))
    }
}

struct AppLogTests {
    @Test func keepsRecentLinesAndWritesOneFilePerDay() throws {
        let temp = TemporaryDirectory()
        var now = Date(timeIntervalSince1970: 1_767_225_600)
        let log = AppLog(directory: temp.url, clock: { now })

        log.info("first")
        now.addTimeInterval(86_400)
        log.warn("second")
        log.error("third", CocoaError(.fileNoSuchFile))

        #expect(log.recent.map(\.message).prefix(2) == ["first", "second"])
        #expect(log.recent[2].level == "error")
        let files = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).sorted()
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.hasPrefix("app-") && $0.hasSuffix(".log") })
        let secondDay = try String(contentsOf: temp.file(files[1]), encoding: .utf8)
        #expect(secondDay.contains("warn: second"))
        #expect(secondDay.contains("error: third"))
        #expect(secondDay.split(separator: "\n").count == 2)
    }

    @Test func keepsOnlyTheLastThousandLines() {
        let temp = TemporaryDirectory()
        let log = AppLog(directory: temp.url)

        for index in 0..<(AppLog.capacity + 5) {
            log.info("line \(index)")
        }

        #expect(log.recent.count == AppLog.capacity)
        #expect(log.recent.first?.message == "line 5")
    }

    @Test func keepsEveryLineOnOneLineAndTellsTheListener() {
        let temp = TemporaryDirectory()
        let log = AppLog(directory: temp.url)
        var heard: [String] = []
        log.onAdded = { heard.append($0.text) }

        log.info("a\nb\r\nc")

        #expect(log.recent.first?.message == "a b  c")
        #expect(heard.count == 1)
        #expect(heard[0].hasSuffix("info: a b  c"))
        #expect(heard[0].hasPrefix("["))
    }
}

struct WindowPlacementPolicyTests {
    private let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]

    @Test func restoresAFrameThatIsOnAScreen() {
        let placement = WindowPlacement(x: 100, y: 120, width: 1280, height: 800, maximized: false)

        #expect(WindowPlacementPolicy.restoredFrame(for: placement, screens: screens) == CGRect(x: 100, y: 120, width: 1280, height: 800))
    }

    @Test func ignoresAFrameThatIsOffEveryScreenOrTooSmall() {
        let off = WindowPlacement(x: 5000, y: 0, width: 1280, height: 800, maximized: false)
        let small = WindowPlacement(x: 0, y: 0, width: 300, height: 200, maximized: false)

        #expect(WindowPlacementPolicy.restoredFrame(for: off, screens: screens) == nil)
        #expect(WindowPlacementPolicy.restoredFrame(for: small, screens: screens) == nil)
        #expect(WindowPlacementPolicy.restoredFrame(for: nil, screens: screens) == nil)
    }

    @Test func roundsAFrameIntoAPlacement() {
        let placement = WindowPlacementPolicy.placement(frame: CGRect(x: 10.4, y: 20.6, width: 1280.2, height: 799.9), maximized: true)

        #expect(placement == WindowPlacement(x: 10, y: 21, width: 1280, height: 800, maximized: true))
    }
}

struct ClosePolicyTests {
    @Test func asksBeforeClosingAWindowThatIsInTheGame() {
        #expect(ClosePolicy.windowQuestion(accountName: "hunter", inGame: true) == "Close hunter? The character leaves the game.")
        #expect(ClosePolicy.windowQuestion(accountName: "hunter", inGame: false) == nil)
    }

    @Test func asksBeforeClosingEveryWindowWhileCharactersAreInTheGame() {
        #expect(ClosePolicy.allWindowsQuestion(inGameCount: 0, verb: "quit") == nil)
        #expect(ClosePolicy.allWindowsQuestion(inGameCount: 1, verb: "quit") == "1 character is in the game. Quit all game windows?")
        #expect(ClosePolicy.allWindowsQuestion(inGameCount: 3, verb: "close") == "3 characters are in the game. Close all game windows?")
    }
}

struct InstanceLockTests {
    @Test func allowsOnlyOneHolderPerFolder() {
        let temp = TemporaryDirectory()
        var first = InstanceLock(directory: temp.url)

        #expect(first != nil)
        #expect(InstanceLock(directory: temp.url) == nil)
        first = nil
        #expect(InstanceLock(directory: temp.url) != nil)
    }

    @Test func letsDifferentFoldersRunTogether() {
        let one = TemporaryDirectory()
        let two = TemporaryDirectory()
        let first = InstanceLock(directory: one.url)
        let second = InstanceLock(directory: two.url)

        #expect(first != nil && second != nil)
    }
}
