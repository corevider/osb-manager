import Foundation
import OsbManagerCore
import Testing
@testable import OsbManagerCef

struct PageOriginTests {
    @Test func readsTheOriginOfTheGamePage() {
        let origin = PageOrigin(isMainFrame: true, pageUrl: "https://opensro.online/play?server=1")

        #expect(origin == PageOrigin(isMainFrame: true, scheme: "https", host: "opensro.online", port: 0))
    }

    @Test func keepsAnExplicitPort() {
        #expect(PageOrigin(isMainFrame: true, pageUrl: "https://opensro.online:8443/play").port == 8443)
    }

    @Test func gameMessagesPassTheInbox() {
        let origin = PageOrigin(isMainFrame: true, pageUrl: "https://opensro.online/play")
        let accepted = PageMessageInbox.accept(body: #"{"type":"credentials-request"}"#, isMainFrame: origin.isMainFrame, scheme: origin.scheme, host: origin.host, port: origin.port)

        #expect(accepted == .credentialsRequest)
    }

    @Test func otherHostsAndSubframesAreRejected() {
        let other = PageOrigin(isMainFrame: true, pageUrl: "https://evil.example/play")
        let frame = PageOrigin(isMainFrame: false, pageUrl: "https://opensro.online/play")
        let body = #"{"type":"credentials-request"}"#

        #expect(PageMessageInbox.accept(body: body, isMainFrame: other.isMainFrame, scheme: other.scheme, host: other.host, port: other.port) == nil)
        #expect(PageMessageInbox.accept(body: body, isMainFrame: frame.isMainFrame, scheme: frame.scheme, host: frame.host, port: frame.port) == nil)
    }

    @Test func plainHttpIsRejected() {
        let origin = PageOrigin(isMainFrame: true, pageUrl: "http://opensro.online/play")

        #expect(PageMessageInbox.accept(body: #"{"type":"credentials-request"}"#, isMainFrame: true, scheme: origin.scheme, host: origin.host, port: origin.port) == nil)
    }
}

struct GameScriptsTests {
    private func folder(with names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            try "// \(name)\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return folder
    }

    @Test func putsTheShimFirstAndTheUserScriptsLast() throws {
        let directory = try folder(with: ["cef-shim.js", "autologin.js", "light.js", "gpu.js", "drops.js", "bridge.js"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let scripts = try PageScriptLibrary(directory: directory).scripts(frameLimit: 30, beforeBridge: ["BEFORE"], userScripts: ["USER"])

        #expect(scripts.count == 4)
        #expect(scripts[0].contains("cef-shim.js"))
        #expect(scripts[1] == "BEFORE")
        #expect(scripts[2].contains("initialFrameLimit = 30"))
        #expect(scripts[3] == "USER")
    }

    @Test func injectsNoTimerShimAndNoMuteShim() throws {
        let directory = try folder(with: ["cef-shim.js", "autologin.js", "light.js", "gpu.js", "drops.js", "bridge.js"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let scripts = try PageScriptLibrary(directory: directory).scripts(frameLimit: 60, userScripts: [])

        #expect(scripts.count == 2)
        #expect(!scripts.contains { $0.contains("timer") || $0.contains("initialMuted") })
    }

    @Test func saysSoWhenTheShimIsMissing() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)

        #expect(throws: ScriptFormatError.self) { try PageScriptLibrary(directory: directory).scripts(frameLimit: 60, userScripts: []) }
    }
}
