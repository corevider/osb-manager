import Foundation
import Testing
@testable import OsbManagerCore

@Suite(.serialized)
struct GoldenPayloadTests {
    static let goldenRegister = """
    {
      "install_id": "3f0b2c1e-7d4a-4c55-9a51-2b8f7e4c9d10",
      "install_key": "kq3Vt3N1rA8b0bq3QyU2sQj3XcYw8m3cXzq8b6F0wJs",
      "app": "osb",
      "app_version": "2.0.4",
      "os": "windows",
      "locale": "en",
      "consent": { "usage_version": 2, "characters": false }
    }
    """

    static let goldenTelemetry = """
    {
      "schema": 1,
      "app_version": "1.2.0",
      "accounts": [
        {
          "slot": "9c41e0a7b2d3f615",
          "state": "hunting",
          "level": 87,
          "gold": "123456789",
          "hp_pct": 92,
          "mp_pct": 70,
          "scrolls": { "return": 12, "reverse": 3 },
          "bot_version": "2.0.4",
          "session": { "key": "a1b2c3d4e5f60718", "ms": 5400000, "kills": 812, "deaths": 1, "xp": "48211933", "gold": "2210450", "sox": 0 }
        },
        {
          "slot": "07d2be6a91c4f033",
          "state": "offline",
          "bot_version": null
        }
      ]
    }
    """

    static let goldenTelemetryWithCharacter = """
    {
      "schema": 1,
      "app_version": "2.0.4",
      "accounts": [
        {
          "slot": "5e8a1c0f9b7d2346",
          "state": "town",
          "level": 64,
          "gold": "9800000",
          "hp_pct": 100,
          "mp_pct": 100,
          "scrolls": { "return": 4, "reverse": 0 },
          "bot_version": "2.0.4",
          "character": { "name": "ExampleHero", "server": "ExampleServer" },
          "session": { "key": "0f1e2d3c4b5a6978", "ms": 1200000, "kills": 95, "deaths": 0, "xp": "3100200", "gold": "410000", "sox": 1 }
        }
      ]
    }
    """

    static let goldenReport = """
    {
      "schema": 1,
      "kind": "bug",
      "app": "manager-mac",
      "app_version": "1.0.0",
      "os": "macos",
      "locale": "tr",
      "description": "Auto login stops at the server list.",
      "diagnostics": { "app": "OSB Manager", "windows": 3, "login": { "stage": "server-list", "message": "timeout" } }
    }
    """

    private func parse(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func kind(of value: Any) -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        }
        if value is String { return "string" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        return "other"
    }

    private func assertSameShape(golden: [String: Any], actual: [String: Any], path: String, strictKeys: Bool = true) {
        for (name, value) in actual {
            guard let expected = golden[name] else {
                if strictKeys { Issue.record("\(path).\(name) is not in the golden payload") }
                continue
            }
            if expected is NSNull || value is NSNull { continue }
            #expect(kind(of: expected) == kind(of: value), "\(path).\(name) has another type")
            if let expectedObject = expected as? [String: Any], let actualObject = value as? [String: Any] {
                assertSameShape(golden: expectedObject, actual: actualObject, path: "\(path).\(name)", strictKeys: strictKeys)
            }
        }
        for (name, expected) in golden where !(expected is NSNull) {
            #expect(actual[name] != nil && !(actual[name] is NSNull), "\(path).\(name) is missing")
        }
    }

    @Test func c15_registerBodyMatchesAppendixC1() async throws {
        let kit = try TelemetryKit()
        kit.settings.grant(characters: false)
        kit.publish("account-a", hunting())

        await kit.run(for: .seconds(5 * 60))

        let body = try #require(kit.server.to("POST /v1/installs").first?.json)
        assertSameShape(golden: try parse(Self.goldenRegister), actual: body, path: "register")
        #expect(body["app"] as? String == "manager-mac")
        #expect(body["os"] as? String == "macos")
        #expect((body["install_key"] as? String)?.count == 43)
        #expect((body["consent"] as? [String: Any])?["usage_version"] as? Int == 2)
        #expect((body["consent"] as? [String: Any])?["characters"] as? Bool == false)
        let id = try #require(body["install_id"] as? String)
        #expect(UUID(uuidString: id) != nil)
        #expect(Array(id)[14] == "4")
        await kit.stop()
    }

    @Test func c15_telemetryBodyMatchesAppendixC2() throws {
        let moment = Date(timeIntervalSince1970: TelemetryKit.origin)
        let builder = TelemetryPayloadBuilder(appVersion: "1.2.0", now: { moment })
        let key = Data(count: 32)
        var signedOut = BotStatus()
        signedOut.phase = "signed-out"
        let snapshots = [
            AccountSnapshot(accountId: "account-a", server: "ExampleServer", status: hunting(), receivedAt: moment),
            AccountSnapshot(accountId: "account-b", server: "", status: signedOut, receivedAt: moment.addingTimeInterval(-5)),
        ]
        builder.build(snapshots, installKey: key, includeCharacters: false)?.commit()

        let batch = try #require(builder.build([snapshots[0]], installKey: key, includeCharacters: false))
        let root = try #require(try JSONSerialization.jsonObject(with: batch.body) as? [String: Any])
        let accounts = try #require(root["accounts"] as? [[String: Any]])
        let golden = try parse(Self.goldenTelemetry)
        let goldenAccounts = try #require(golden["accounts"] as? [[String: Any]])

        #expect(accounts.count == 2)
        assertSameShape(golden: goldenAccounts[0], actual: accounts[0], path: "accounts[0]")
        assertSameShape(golden: goldenAccounts[1], actual: accounts[1], path: "accounts[1]")
        #expect(root["schema"] as? Int == 1)
        #expect(root["app_version"] as? String == "1.2.0")
        #expect(accounts[1]["state"] as? String == "offline")
        for account in accounts {
            let slot = try #require(account["slot"] as? String)
            #expect(slot.count == 16 && slot.allSatisfy { "0123456789abcdef".contains($0) })
        }
        let session = try #require(accounts[0]["session"] as? [String: Any])
        let sessionKey = try #require(session["key"] as? String)
        #expect(sessionKey.count == 16)
    }

    @Test func c15_telemetryBodyWithCharacterConsentMatchesAppendixC3() throws {
        let moment = Date(timeIntervalSince1970: TelemetryKit.origin)
        var status = hunting("ExampleHero")
        status.hunting = false
        status.townTrip = true
        status.level = 64
        status.gold = 9_800_000
        status.hpPercent = 100
        status.mpPercent = 100
        status.returnScrolls = 4
        status.reverseScrolls = 0
        let builder = TelemetryPayloadBuilder(appVersion: "2.0.4", now: { moment })

        let batch = try #require(builder.build([AccountSnapshot(accountId: "account-a", server: "ExampleServer", status: status, receivedAt: moment)], installKey: Data(count: 32), includeCharacters: true))

        let root = try #require(try JSONSerialization.jsonObject(with: batch.body) as? [String: Any])
        let account = try #require((root["accounts"] as? [[String: Any]])?.first)
        let golden = try #require((try parse(Self.goldenTelemetryWithCharacter)["accounts"] as? [[String: Any]])?.first)
        assertSameShape(golden: golden, actual: account, path: "accounts[0]")
        #expect(account["state"] as? String == "town")
        let character = try #require(account["character"] as? [String: Any])
        #expect(character["name"] as? String == "ExampleHero")
        #expect(character["server"] as? String == "ExampleServer")
    }

    @Test func c15_numbersTheServerWantsAsStringsAreStrings() throws {
        let moment = Date(timeIntervalSince1970: TelemetryKit.origin)
        let builder = TelemetryPayloadBuilder(appVersion: "1.2.0", now: { moment })

        let batch = try #require(builder.build([AccountSnapshot(accountId: "a", server: "", status: hunting(), receivedAt: moment)], installKey: Data(count: 32), includeCharacters: false))

        let root = try #require(try JSONSerialization.jsonObject(with: batch.body) as? [String: Any])
        let account = try #require((root["accounts"] as? [[String: Any]])?.first)
        let session = try #require(account["session"] as? [String: Any])
        #expect(account["gold"] is String)
        #expect(session["xp"] is String)
        #expect(session["gold"] is String)
        #expect(kind(of: account["level"] as Any) == "number")
        #expect(kind(of: session["ms"] as Any) == "number")
    }

    @Test func c15_reportBodyMatchesAppendixC4() throws {
        let diagnostics = ReportDiagnostics.build(appVersion: "1.0.0", osVersion: "26.5", windows: [], scripts: [])

        let json = ReportPayload.build(kind: .bug, description: "Auto login stops at the server list.", diagnostics: diagnostics, appVersion: "1.0.0", locale: "tr")

        let body = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let golden = try parse(Self.goldenReport)
        #expect(Set(body.keys) == Set(golden.keys))
        for (name, value) in body {
            #expect(kind(of: value) == kind(of: golden[name] as Any), "\(name)")
        }
        #expect(body["app"] as? String == "manager-mac")
        #expect(body["os"] as? String == "macos")
        #expect(body["schema"] as? Int == 1)
        #expect(body["kind"] as? String == "bug")
        let sentDiagnostics = try #require(body["diagnostics"] as? [String: Any])
        #expect(sentDiagnostics["app"] as? String == "OSB Manager")
    }

    @Test func theSlotIsTheFirstSixteenHexCharactersOfAnHmacOverSlotColonAccountId() {
        let key = Data((0..<32).map { UInt8($0) })

        #expect(TelemetryPayloadBuilder.slot(installKey: key, accountId: "account-a") == "9eb42ac1669e8180")
        #expect(TelemetryPayloadBuilder.slot(installKey: Data(count: 32), accountId: "account-a") == "5aedf8b54166aa4b")
        #expect(TelemetryPayloadBuilder.slot(installKey: key, accountId: "account-a") != TelemetryPayloadBuilder.slot(installKey: key, accountId: "account-b"))
    }
}
