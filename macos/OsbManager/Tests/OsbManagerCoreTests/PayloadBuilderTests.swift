import Foundation
import Testing
@testable import OsbManagerCore

struct PayloadBuilderTests {
    private let moment = Date(timeIntervalSince1970: TelemetryKit.origin)
    private let key = Data((0..<32).map { UInt8($0) })

    private func builder(at date: Date? = nil, randomBytes: @escaping (Int) -> [UInt8] = PrivacySettings.randomBytes) -> TelemetryPayloadBuilder {
        let fixed = date ?? moment
        return TelemetryPayloadBuilder(appVersion: "1.2.0", now: { fixed }, randomBytes: randomBytes)
    }

    private func accounts(_ batch: TelemetryBatch?) throws -> [[String: Any]] {
        let data = try #require(batch?.body)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["accounts"] as? [[String: Any]])
    }

    private func snapshot(_ id: String, _ status: BotStatus, server: String = "", age: TimeInterval = 0) -> AccountSnapshot {
        AccountSnapshot(accountId: id, server: server, status: status, receivedAt: moment.addingTimeInterval(-age))
    }

    private func status(inWorld: Bool = false, dead: Bool = false, bot: String? = nil, town: Bool = false, hunting: Bool = false, stage: String? = nil, phase: String? = nil) -> BotStatus {
        var value = BotStatus()
        value.inWorld = inWorld
        value.dead = dead
        value.botVersion = bot
        value.townTrip = town
        value.hunting = hunting
        value.loginStage = stage
        value.phase = phase
        return value
    }

    @Test(arguments: [
        (true, true, "2.0", false, false, nil as String?, nil as String?, "dead"),
        (true, false, nil as String?, false, false, nil as String?, nil as String?, "idle"),
        (true, false, "2.0", true, true, nil as String?, nil as String?, "town"),
        (true, false, "2.0", false, true, nil as String?, nil as String?, "hunting"),
        (true, false, "2.0", false, false, nil as String?, nil as String?, "stopped"),
        (false, false, nil as String?, false, false, "title", "world", "login"),
        (false, false, nil as String?, false, false, "connecting", nil as String?, "login"),
        (false, false, nil as String?, false, false, "failed", "signed-out", "login"),
        (false, false, nil as String?, false, false, nil as String?, "signed-out", "login"),
        (false, false, nil as String?, false, false, nil as String?, "character-select", "login"),
        (false, false, nil as String?, false, false, nil as String?, nil as String?, "loading"),
        (false, false, nil as String?, false, false, nil as String?, "world", "loading"),
        (false, false, nil as String?, false, false, "something-else", "world", "loading"),
        (false, false, nil as String?, false, false, nil as String?, "weird", "unknown"),
    ])
    func theStateMappingTableHolds(inWorld: Bool, dead: Bool, bot: String?, town: Bool, hunting: Bool, stage: String?, phase: String?, expected: String) {
        let mapped = AccountStates.map(status(inWorld: inWorld, dead: dead, bot: bot, town: town, hunting: hunting, stage: stage, phase: phase))

        #expect(mapped == expected)
    }

    @Test func anAccountWithoutAWindowIsReportedOnceAsOffline() throws {
        let sut = builder()
        let first = sut.build([snapshot("a", hunting())], installKey: key, includeCharacters: false)
        first?.commit()

        let second = try accounts(sut.build([], installKey: key, includeCharacters: false))
        #expect(second.count == 1)
        #expect(second[0]["state"] as? String == "offline")
        #expect(second[0]["slot"] as? String == TelemetryPayloadBuilder.slot(installKey: key, accountId: "a"))
        #expect(second[0]["level"] == nil)
    }

    @Test func offlineIsSentOnlyOnceAfterItWasAccepted() {
        let sut = builder()
        sut.build([snapshot("a", hunting())], installKey: key, includeCharacters: false)?.commit()
        let offline = sut.build([], installKey: key, includeCharacters: false)
        offline?.commit()

        #expect(sut.build([], installKey: key, includeCharacters: false) == nil)
    }

    @Test func aBatchThatWasNotAcceptedIsSentAgain() throws {
        let sut = builder()
        sut.build([snapshot("a", hunting())], installKey: key, includeCharacters: false)?.commit()
        _ = sut.build([], installKey: key, includeCharacters: false)

        let again = try accounts(sut.build([], installKey: key, includeCharacters: false))

        #expect(again.first?["state"] as? String == "offline")
    }

    @Test func anIdleAccountWithoutAChangeIsSentAtMostOncePerHour() {
        var idle = BotStatus()
        idle.phase = "character-select"
        let now = TestNow()
        let sut = TelemetryPayloadBuilder(appVersion: "1.2.0", now: { now.value })
        func current() -> AccountSnapshot {
            AccountSnapshot(accountId: "a", server: "", status: idle, receivedAt: now.value)
        }
        sut.build([current()], installKey: key, includeCharacters: false)?.commit()

        #expect(sut.build([current()], installKey: key, includeCharacters: false) == nil)
        now.advance(3599)
        #expect(sut.build([current()], installKey: key, includeCharacters: false) == nil)
        now.advance(2)
        #expect(sut.build([current()], installKey: key, includeCharacters: false) != nil)
    }

    @Test func anAccountWithARunningSessionIsAlwaysSent() throws {
        let sut = builder()
        sut.build([snapshot("a", hunting())], installKey: key, includeCharacters: false)?.commit()

        let again = try accounts(sut.build([snapshot("a", hunting())], installKey: key, includeCharacters: false))

        #expect(again.count == 1)
    }

    @Test func theSessionKeyStaysWhileCountersGrowAndChangesWhenTheyGoDown() throws {
        let sut = builder()
        let first = try accounts(sut.build([snapshot("a", hunting())], installKey: key, includeCharacters: false))
        var grown = hunting()
        grown.session = SessionStats(milliseconds: 6_000_000, kills: 900, deaths: 1, experience: 1, gold: 1, sox: 0)
        let second = try accounts(sut.build([snapshot("a", grown)], installKey: key, includeCharacters: false))
        var restarted = hunting()
        restarted.session = SessionStats(milliseconds: 1000, kills: 1, deaths: 0, experience: 1, gold: 1, sox: 0)
        let third = try accounts(sut.build([snapshot("a", restarted)], installKey: key, includeCharacters: false))

        let keys = try [first, second, third].map { try #require(($0[0]["session"] as? [String: Any])?["key"] as? String) }
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
    }

    @Test func statusesOlderThanTwoMinutesAreLeftOut() {
        let sut = builder()

        #expect(sut.build([snapshot("a", hunting(), age: 121)], installKey: key, includeCharacters: false) == nil)
        #expect(sut.build([snapshot("a", hunting(), age: 119)], installKey: key, includeCharacters: false) != nil)
    }

    @Test func atMostTwentyAccountsAreSentNewestFirst() throws {
        let sut = builder()
        let snapshots = (0..<25).map { snapshot("a\($0)", hunting(), age: Double($0)) }

        let sent = try accounts(sut.build(snapshots, installKey: key, includeCharacters: false))
        let slots = Set(sent.compactMap { $0["slot"] as? String })

        #expect(sent.count == 20)
        #expect(slots.contains(TelemetryPayloadBuilder.slot(installKey: key, accountId: "a0")))
        #expect(!slots.contains(TelemetryPayloadBuilder.slot(installKey: key, accountId: "a24")))
    }

    @Test func neverSendsLoginsPasswordsAccountNamesOrServersWithoutTheSecondConsent() throws {
        var status = hunting("SecretHero")
        status.loginMessage = "password rejected for user1"
        status.drops = ["SecretHero got Seal of Star"]
        let batch = builder().build([snapshot("account-id-123", status, server: "SecretServer")], installKey: key, includeCharacters: false)
        let text = String(decoding: try #require(batch?.body), as: UTF8.self)

        for forbidden in ["SecretHero", "SecretServer", "account-id-123", "password", "user1", "Seal of Star", "drops", "loginMessage"] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
    }

    @Test func fieldsOutsideTheWorldAreLeftOut() throws {
        var status = BotStatus()
        status.phase = "character-select"
        status.gold = 5
        status.hpPercent = 50
        status.mpPercent = 50
        status.returnScrolls = 3
        status.level = 10

        let sent = try accounts(builder().build([snapshot("a", status)], installKey: key, includeCharacters: false))

        #expect(sent[0]["gold"] == nil)
        #expect(sent[0]["hp_pct"] == nil)
        #expect(sent[0]["mp_pct"] == nil)
        #expect(sent[0]["scrolls"] == nil)
        #expect(sent[0]["level"] as? Int == 10)
    }

    @Test func valuesAreClampedToTheServerRanges() throws {
        var status = hunting()
        status.level = 300
        status.hpPercent = 140.4
        status.mpPercent = -3
        status.returnScrolls = 200_000
        status.reverseScrolls = 2
        status.session = SessionStats(milliseconds: Int64.max / 4, kills: 99_999_999, deaths: -4, experience: -1, gold: nil, sox: 12_000_000)

        let sent = try accounts(builder().build([snapshot("a", status)], installKey: key, includeCharacters: false))
        let session = try #require(sent[0]["session"] as? [String: Any])
        let scrolls = try #require(sent[0]["scrolls"] as? [String: Any])

        #expect(sent[0]["level"] == nil)
        #expect(sent[0]["hp_pct"] as? Int == 100)
        #expect(sent[0]["mp_pct"] as? Int == 0)
        #expect(scrolls["return"] == nil)
        #expect(scrolls["reverse"] as? Int == 2)
        #expect(session["ms"] as? Int64 == TelemetryLimits.maxSessionMilliseconds)
        #expect(session["kills"] as? Int64 == TelemetryLimits.maxCounter)
        #expect(session["deaths"] as? Int64 == 0)
        #expect(session["xp"] == nil)
        #expect(session["sox"] as? Int64 == TelemetryLimits.maxCounter)
    }

    @Test func percentagesRoundHalfToEvenLikeTheWindowsApp() throws {
        var low = hunting()
        low.hpPercent = 92.5
        low.mpPercent = 93.5

        let sent = try accounts(builder().build([snapshot("a", low)], installKey: key, includeCharacters: false))

        #expect(sent[0]["hp_pct"] as? Int == 92)
        #expect(sent[0]["mp_pct"] as? Int == 94)
    }

    @Test(arguments: ["2.0.4", "1.0.0-beta+7", "v1"])
    func aWellFormedBotVersionIsSent(version: String) throws {
        var status = hunting()
        status.botVersion = version

        let sent = try accounts(builder().build([snapshot("a", status)], installKey: key, includeCharacters: false))

        #expect(sent[0]["bot_version"] as? String == version)
    }

    @Test(arguments: ["2.0 4", "<script>", String(repeating: "1", count: 33), "ü1"])
    func aMalformedBotVersionIsLeftOut(version: String) throws {
        var status = hunting()
        status.botVersion = version

        let sent = try accounts(builder().build([snapshot("a", status)], installKey: key, includeCharacters: false))

        #expect(sent[0]["bot_version"] == nil)
    }

    @Test func characterNamesAreCleanedAndCutToThirtyTwoCharacters() throws {
        var status = hunting("  Hero\u{0007}\(String(repeating: "x", count: 40))  ")

        let sent = try accounts(builder().build([snapshot("a", status, server: "Srv\n1")], installKey: key, includeCharacters: true))
        let character = try #require(sent[0]["character"] as? [String: Any])

        #expect((character["name"] as? String)?.unicodeScalars.count == 32)
        #expect((character["name"] as? String)?.hasPrefix("Herox") == true)
        #expect(character["server"] as? String == "Srv1")
        status.character = nil
        let none = try accounts(builder().build([snapshot("b", status, server: "")], installKey: key, includeCharacters: true))
        #expect(none[0]["character"] == nil)
    }

    @Test func theBodyIsNeverOverTheHardLimit() {
        let longName = String(repeating: "y", count: 32)
        let snapshots = (0..<40).map { snapshot("a\($0)", hunting(longName), server: longName) }

        let batch = builder().build(snapshots, installKey: key, includeCharacters: true)

        #expect((batch?.body.count ?? Int.max) <= TelemetryLimits.maxBodyBytes)
    }

    @Test func theConfigIsParsedStrictlyAndClamped() {
        let good = #"{"schema":1,"telemetry":{"enabled":true,"interval_s":50},"reports":{"enabled":true,"screenshots":false},"client_ok":true,"message":"  hello\u0001 "}"#
        let parsed = TelemetryConfig.parse(Data(good.utf8))

        #expect(parsed?.intervalSeconds == 300)
        #expect(parsed?.message == "hello")
        #expect(TelemetryConfig.parse(Data(#"{"schema":1,"telemetry":{"enabled":true,"interval_s":999999},"reports":{"enabled":true},"client_ok":true}"#.utf8))?.intervalSeconds == 86400)
    }

    @Test(arguments: [
        "",
        "not json",
        "[]",
        #"{"schema":2,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true},"client_ok":true}"#,
        #"{"schema":1,"telemetry":{"enabled":"yes","interval_s":600},"reports":{"enabled":true},"client_ok":true}"#,
        #"{"schema":1,"telemetry":{"enabled":true,"interval_s":"600"},"reports":{"enabled":true},"client_ok":true}"#,
        #"{"schema":1,"telemetry":{"enabled":true},"reports":{"enabled":true},"client_ok":true}"#,
        #"{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"client_ok":true}"#,
        #"{"schema":1,"telemetry":{"enabled":1,"interval_s":600},"reports":{"enabled":true},"client_ok":true}"#,
    ])
    func aMissingOrMalformedConfigIsNotAConfig(json: String) {
        #expect(TelemetryConfig.parse(Data(json.utf8)) == nil)
    }

    @Test func backoffFollowsFullJitterWithAFloorAndACap() {
        #expect(Backoff.next(failures: 1, random: 0).seconds == 60)
        #expect(Backoff.next(failures: 1, random: 1).seconds == 120)
        #expect(Backoff.next(failures: 3, random: 1).seconds == 480)
        #expect(Backoff.next(failures: 40, random: 1).seconds == 21600)
        #expect(Backoff.next(failures: 40, random: 0.5).seconds == 10800)
        #expect(Backoff.retryAfter(5, random: 0, failures: 1).seconds == 60)
        #expect(Backoff.retryAfter(120, random: 0, failures: 1).seconds == 120)
        #expect(Backoff.retryAfter(10 * 86400, random: 0, failures: 1).seconds == 86400)
        #expect(Backoff.startDelay(random: 0).seconds == 60)
        #expect(Backoff.startDelay(random: 1).seconds == 180)
        #expect(abs(Backoff.jitter(.seconds(600), random: 0).seconds - 540) < 0.001)
        #expect(abs(Backoff.jitter(.seconds(600), random: 1).seconds - 660) < 0.001)
    }

    @Test func theClientRefusesAnInsecureAddress() async {
        #expect(throws: TelemetryClientError.self) {
            _ = try TelemetryClient(baseUrl: URL(string: "http://api.osb.lol/v1") ?? URL(fileURLWithPath: "/"), userAgent: "x")
        }
        #expect(throws: TelemetryClientError.self) {
            _ = try TelemetryClient(baseUrl: URL(string: "ftp://127.0.0.1/v1") ?? URL(fileURLWithPath: "/"), userAgent: "x")
        }
    }

    @Test func theClientConfigurationIsEphemeralWithoutCookiesOrCache() {
        let configuration = TelemetryClient.makeConfiguration()

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 15)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.httpShouldSetCookies == false)
    }
}
