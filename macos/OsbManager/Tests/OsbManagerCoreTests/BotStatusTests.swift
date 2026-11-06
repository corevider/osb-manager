import Foundation
import Testing
@testable import OsbManagerCore

struct BotStatusTests {
    private static let report = """
    {"type":"status","bot":"1.2.172","phase":"world","character":"hunter","inWorld":true,"dead":false,"level":90,
     "gold":"1685416273","hp":73.4,"mp":86,"region":23918,"hunting":true,"town":false,"light":true,
     "session":{"ms":4080000,"kills":288,"deaths":0,"xp":"0","gold":"-175590000"}}
    """

    @Test func readsAFullReport() throws {
        let status = try #require(BotStatus.parse(Self.report))

        #expect(status.botVersion == "1.2.172")
        #expect(status.character == "hunter")
        #expect(status.inWorld)
        #expect(status.level == 90)
        #expect(status.gold == 1_685_416_273)
        #expect(status.hpPercent == 73.4)
        #expect(status.region == 23918)
        #expect(status.hunting)
        #expect(status.light)
        #expect(status.session == SessionStats(milliseconds: 4_080_000, kills: 288, deaths: 0, experience: 0, gold: -175_590_000))
    }

    @Test(arguments: [
        nil, "", "not json", "[1,2]", #"{"type":"other"}"#,
        #"{"type":"status","a":{"b":{"c":{"d":{"e":1}}}}}"#,
    ] as [String?])
    func ignoresOtherMessages(json: String?) {
        #expect(BotStatus.parse(json) == nil)
    }

    @Test func ignoresOversizedMessages() {
        let json = #"{"type":"status","character":""# + String(repeating: "x", count: BotStatus.maxMessageLength) + #""}"#

        #expect(BotStatus.parse(json) == nil)
    }

    @Test func boundsUntrustedValues() throws {
        let status = try #require(BotStatus.parse("""
        {"type":"status","character":"a\\u0007b","phase":"\(String(repeating: "x", count: 70))",
         "level":-5,"hp":250,"mp":"50","region":1.5e300,"gold":"12abc","inWorld":"yes","hunting":1}
        """))

        #expect(status.character == "ab")
        #expect(status.phase?.count == 64)
        #expect(status.level == nil)
        #expect(status.hpPercent == 100)
        #expect(status.mpPercent == nil)
        #expect(status.region == nil)
        #expect(status.gold == nil)
        #expect(!status.inWorld)
        #expect(!status.hunting)
        #expect(status.session == nil)
    }

    @Test func rejectsNumbersTooLargeForTheCounters() throws {
        let status = try #require(BotStatus.parse(#"{"type":"status","session":{"ms":9.3e18,"kills":1e300,"deaths":-1}}"#))

        #expect(status.session == SessionStats(milliseconds: 0, kills: 0, deaths: 0, experience: nil, gold: nil))
    }

    @Test func readsLightWaitingAndGpuRetries() throws {
        let status = try #require(BotStatus.parse(#"{"type":"status","lightWaiting":true,"gpu":{"retries":2,"failed":null}}"#))

        #expect(status.lightWaiting)
        #expect(status.gpuRetries == 2)
        #expect(status.gpuFailed == nil)
    }

    @Test func readsARendererFailureAndBoundsTheRetryCount() throws {
        let status = try #require(BotStatus.parse(#"{"type":"status","gpu":{"retries":5000,"failed":"OperationError: CreateDescriptorHeap"}}"#))

        #expect(status.gpuRetries == 0)
        #expect(status.gpuFailed == "OperationError: CreateDescriptorHeap")
    }

    @Test func readsScrollsLoginAndDrops() throws {
        let drops = (0..<30).map { "\"drop \($0)\"" }.joined(separator: ",")
        let status = try #require(BotStatus.parse("""
        {"type":"status","scrolls":{"ret":12,"reverse":3},"login":{"stage":"connecting","message":"trying"},
         "drops":[\(drops),5,null,"\\u0001"],"linked":true}
        """))

        #expect(status.returnScrolls == 12)
        #expect(status.reverseScrolls == 3)
        #expect(status.loginStage == "connecting")
        #expect(status.loginMessage == "trying")
        #expect(status.drops.count == 20)
        #expect(status.drops.first == "drop 0")
        #expect(status.linked)
    }

    @Test func boundsTheDropText() throws {
        let long = String(repeating: "y", count: 500)

        let status = try #require(BotStatus.parse(#"{"type":"status","drops":["\#(long)"]}"#))

        #expect(status.drops.first?.count == 300)
    }

    @Test func readsTheMessageType() {
        #expect(BotStatus.messageType(of: #"{"type":"credentials-request"}"#) == "credentials-request")
        #expect(BotStatus.messageType(of: "[1]") == nil)
        #expect(BotStatus.messageType(of: nil) == nil)
    }
}

struct PageMessageInboxTests {
    private let status = #"{"type":"status","phase":"signed-out"}"#

    @Test func acceptsAStatusFromTheGamePage() {
        let message = PageMessageInbox.accept(body: status, isMainFrame: true, scheme: "https", host: "opensro.online", port: 0)

        #expect(message == .status(BotStatus.parse(status)!))
    }

    @Test func acceptsTheDefaultHttpsPort() {
        #expect(PageMessageInbox.accept(body: status, isMainFrame: true, scheme: "https", host: "opensro.online", port: 443) != nil)
    }

    @Test(arguments: [
        (false, "https", "opensro.online", 0),
        (true, "http", "opensro.online", 0),
        (true, "https", "opensro.online.evil.example", 0),
        (true, "https", "evil.example", 0),
        (true, "https", "opensro.online", 8443),
        (true, "file", "", 0),
    ])
    func refusesMessagesFromAnywhereElse(isMainFrame: Bool, scheme: String, host: String, port: Int) {
        #expect(PageMessageInbox.accept(body: status, isMainFrame: isMainFrame, scheme: scheme, host: host, port: port) == nil)
    }

    @Test func refusesBodiesThatAreNotJsonText() {
        #expect(PageMessageInbox.accept(body: ["type": "status"], isMainFrame: true, scheme: "https", host: "opensro.online", port: 0) == nil)
        #expect(PageMessageInbox.accept(body: 5, isMainFrame: true, scheme: "https", host: "opensro.online", port: 0) == nil)
    }

    @Test func recognisesACredentialsRequest() {
        let message = PageMessageInbox.accept(body: #"{"type":"credentials-request"}"#, isMainFrame: true, scheme: "https", host: "opensro.online", port: 0)

        #expect(message == .credentialsRequest)
    }

    @Test func ignoresUnknownTypes() {
        #expect(PageMessageInbox.accept(body: #"{"type":"probe"}"#, isMainFrame: true, scheme: "https", host: "opensro.online", port: 0) == nil)
    }
}

struct PageMessagesTests {
    @Test func buildsTheMessagesTheBridgeUnderstands() {
        #expect(PageMessages.light(on: true) as NSDictionary == ["type": "light", "on": true])
        #expect(PageMessages.frameLimit(30) as NSDictionary == ["type": "frame-limit", "fps": 30])
        #expect(PageMessages.autoLogin(enabled: false, character: "c", server: "s") as NSDictionary
            == ["type": "auto-login", "enabled": false, "character": "c", "server": "s"])
        #expect(PageMessages.credentialsDenied(reason: "no") as NSDictionary == ["type": "credentials", "reason": "no"])
    }
}

struct GameWindowStateTests {
    private func status(_ configure: (inout BotStatus) -> Void) -> BotStatus {
        var value = BotStatus()
        configure(&value)
        return value
    }

    @Test func describesTheWindowBeforeAndWithoutReports() {
        #expect(GameWindowState.text(failure: nil, browserReady: false, everReported: false, status: nil) == "Starting")
        #expect(GameWindowState.text(failure: nil, browserReady: true, everReported: false, status: nil) == "Loading")
        #expect(GameWindowState.text(failure: nil, browserReady: true, everReported: true, status: nil) == "Not responding")
        #expect(GameWindowState.text(failure: "Page crashed, use Reload", browserReady: true, everReported: true, status: BotStatus()) == "Page crashed, use Reload")
    }

    @Test func describesTheGameStages() {
        func text(_ configure: (inout BotStatus) -> Void) -> String {
            GameWindowState.text(failure: nil, browserReady: true, everReported: true, status: status(configure))
        }

        #expect(text { $0.phase = "signed-out" } == "Login")
        #expect(text { $0.phase = "character-select" } == "Character select")
        #expect(text { $0.phase = "world" } == "Entering world")
        #expect(text { $0.inWorld = true } == "In game")
        #expect(text { $0.inWorld = true; $0.dead = true; $0.light = true } == "Dead (light)")
        #expect(text { $0.phase = "signed-out"; $0.lightWaiting = true } == "Login (light after loading)")
        #expect(text { $0.loginStage = "connecting" } == "Logging in")
        #expect(text { $0.loginStage = "choose" } == "Choose a character")
        #expect(text { $0.loginStage = "failed" } == "Auto login stopped")
        #expect(text { _ in } == "Loading")
    }

    @Test func describesTheBotColumn() {
        #expect(GameWindowState.botColumn(nil) == "")
        #expect(GameWindowState.botColumn(BotStatus()) == "No bot")
        #expect(GameWindowState.botColumn(status { $0.botVersion = "1"; $0.townTrip = true; $0.hunting = true }) == "Town trip")
        #expect(GameWindowState.botColumn(status { $0.botVersion = "1"; $0.hunting = true }) == "Hunting")
        #expect(GameWindowState.botColumn(status { $0.botVersion = "1" }) == "Stopped")
    }
}

struct FormatTests {
    @Test func formatsPercentWithTheWindowsRounding() {
        #expect(Format.percent(73.4) == "73%")
        #expect(Format.percent(72.5) == "72%")
        #expect(Format.percent(100) == "100%")
        #expect(Format.percent(nil) == "—")
    }

    @Test func groupsThousands() {
        #expect(Format.number(1_685_416_273, locale: Locale(identifier: "en_US")) == "1,685,416,273")
        #expect(Format.number(-5, locale: Locale(identifier: "en_US")) == "-5")
    }
}
