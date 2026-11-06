import Foundation
import Testing
@testable import OsbManagerCef

struct CefProfilesTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func eachAccountGetsItsOwnFolderUnderTheCefFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = CefProfiles(dataRoot: root)
        let first = UUID()
        let second = UUID()

        #expect(profiles.folder(for: first) != profiles.folder(for: second))
        #expect(profiles.folder(for: first).deletingLastPathComponent() == profiles.root)
        #expect(profiles.root.lastPathComponent == "cef")
        #expect(profiles.folder(for: first).lastPathComponent == first.uuidString.lowercased())
    }

    @Test func removesOnlyTheFolderOfTheGivenAccount() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = CefProfiles(dataRoot: root)
        let doomed = UUID()
        let kept = UUID()
        for id in [doomed, kept] {
            try FileManager.default.createDirectory(at: profiles.folder(for: id).appendingPathComponent("Default"), withIntermediateDirectories: true)
            try "data".write(to: profiles.folder(for: id).appendingPathComponent("Default/Cookies"), atomically: true, encoding: .utf8)
        }

        try await profiles.remove(doomed)

        #expect(!profiles.exists(doomed))
        #expect(profiles.exists(kept))
    }

    @Test func removingAMissingFolderIsNotAnError() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await CefProfiles(dataRoot: root).remove(UUID())
    }
}
