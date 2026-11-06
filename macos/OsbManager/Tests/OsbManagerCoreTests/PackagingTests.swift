import Darwin
import Foundation
import Testing
@testable import OsbManagerCore

struct AppVersionTests {
    @Test func showsTheVersionAndTheBuild() {
        #expect(AppVersion.text(from: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "31"]) == "1.0.0 (build 31)")
    }

    @Test func showsOnlyTheVersionWithoutABuild() {
        #expect(AppVersion.text(from: ["CFBundleShortVersionString": "1.0.0"]) == "1.0.0")
        #expect(AppVersion.text(from: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": ""]) == "1.0.0")
    }

    @Test func saysSoWhenThereIsNoVersion() {
        #expect(AppVersion.text(from: nil) == "development build")
        #expect(AppVersion.text(from: [:]) == "development build")
        #expect(AppVersion.text(from: ["CFBundleShortVersionString": ""]) == "development build")
    }

    @Test func readsTheVersionFileTheScriptsUse() throws {
        let file = RepositoryPaths.root.appendingPathComponent("macos/OsbManager/VERSION")
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(text.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
    }
}

struct InstanceLockHolderTests {
    @Test func theLockFileNamesTheProcessThatHoldsIt() {
        let temp = TemporaryDirectory()
        let lock = InstanceLock(directory: temp.url)

        #expect(lock != nil)
        #expect(InstanceLock.holderProcessId(directory: temp.url) == getpid())
        #expect(InstanceLock(directory: temp.url) == nil)
        #expect(InstanceLock.holderProcessId(directory: temp.url) == getpid())
        withExtendedLifetime(lock) {}
    }

    @Test func aFailedSecondTryDoesNotWipeTheHolder() {
        let temp = TemporaryDirectory()
        let first = InstanceLock(directory: temp.url)
        _ = InstanceLock(directory: temp.url)
        _ = InstanceLock(directory: temp.url)

        #expect(InstanceLock.holderProcessId(directory: temp.url) == getpid())
        withExtendedLifetime(first) {}
    }

    @Test func thereIsNoHolderBeforeTheFirstStart() {
        let temp = TemporaryDirectory()

        #expect(InstanceLock.holderProcessId(directory: temp.url) == nil)
    }
}

struct CredentialGateThreadTests {
    @Test func handsOutNoMoreThanTheLimitWhenAskedFromManyThreads() async {
        let gate = CredentialGate(maxPerWindow: 3, window: 600, minimumGap: 0)

        let granted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask { gate.tryTake() }
            }
            var count = 0
            for await taken in group where taken {
                count += 1
            }
            return count
        }

        #expect(granted == 3)
    }
}
