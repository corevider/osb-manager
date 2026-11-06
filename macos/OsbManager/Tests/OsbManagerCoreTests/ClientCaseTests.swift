import Foundation
import Testing
@testable import OsbManagerCore

@Suite(.serialized)
struct ClientCaseTests {
    private func consentedKit(random: Double = 0.5, source: StatusSource? = nil, characters: Bool = false) throws -> TelemetryKit {
        let kit = try TelemetryKit(random: random, source: source, consent: characters)
        kit.publish("account-a", hunting())
        return kit
    }

    private func gaps(_ requests: [SeenRequest]) -> [Double] {
        zip(requests, requests.dropFirst()).map { ($1.at - $0.at).seconds }
    }

    @Test func c1_freshInstallWithConsentOffMakesNoRequestInThirtyMinutes() async throws {
        let kit = try TelemetryKit()
        kit.publish("account-a", hunting())
        await kit.service.start()

        await kit.advance(.seconds(30 * 60))

        #expect(kit.server.requests.isEmpty)
        #expect(kit.clock.sleeperCount == 0)
        await kit.stop()
    }

    @Test func c2_consentOnRegistersOnceThenSendsAfterTheStartDelayOffTheMainThread() async throws {
        let kit = try consentedKit()

        await kit.run(for: .seconds(14 * 60))

        let first = kit.server.requests.prefix(3).map(\.endpoint)
        #expect(first == ["GET /v1/config", "POST /v1/installs", "POST /v1/telemetry"])
        #expect(kit.server.to("POST /v1/installs").count == 1)
        let delay = try #require(kit.server.requests.first).at.seconds
        #expect(delay >= 60 && delay <= 180)
        #expect(kit.server.requests.allSatisfy { !$0.onMainThread })
        #expect(kit.server.requests.allSatisfy { $0.userAgent == "OSBManager/1.2.0 (macOS)" })
        let credentials = try #require(kit.settings.credentials)
        #expect(try #require(kit.server.to("POST /v1/telemetry").first).authorization == "Bearer " + credentials.bearer)
        #expect(kit.settings.state.registered)
        #expect(kit.server.to("POST /v1/telemetry").count >= 2)
        await kit.stop()
    }

    @Test(arguments: [0.0, 0.5, 1.0])
    func c3_repeatedServerErrorsBackOffWithFullJitterAndNeverWithinSixtySeconds(random: Double) async throws {
        let kit = try consentedKit(random: random)
        kit.server.failEverything(500)
        await kit.service.start()

        #expect(await kit.advanceStepByStep(.seconds(48 * 3600)))

        let spacing = gaps(kit.server.requests)
        try #require(spacing.count >= 8)
        #expect(spacing.allSatisfy { $0 >= 60 && $0 <= 6 * 3600 })
        if random == 1.0 {
            let expected: [Double] = [120, 240, 480, 960, 1920, 3840, 7680, 15360, 21600]
            try #require(spacing.count >= expected.count)
            #expect(Array(spacing.prefix(expected.count)) == expected)
            #expect(spacing.dropFirst(expected.count).allSatisfy { $0 == 21600 })
        }
        if random == 0.0 {
            #expect(spacing.count == 48 * 60 - 1)
            #expect(spacing.allSatisfy { $0 == 60 })
        }
        if random == 0.5 {
            let expected: [Double] = [60, 120, 240, 480, 960, 1920, 3840, 7680, 10800]
            try #require(spacing.count >= expected.count)
            #expect(Array(spacing.prefix(expected.count)) == expected)
        }
        #expect(kit.server.requests.allSatisfy { $0.endpoint == "GET /v1/config" })
        await kit.stop()
    }

    @Test func c4_aRequestThatNeverGetsAnAnswerIsAbortedAtFifteenSecondsAndNothingWaitsForIt() async throws {
        let kit = try consentedKit()
        kit.server.hangEverything()
        await kit.service.start()

        await kit.advance(.seconds(121))
        #expect(kit.server.inFlight == 1)
        let sentAt = kit.clock.elapsed

        await kit.advance(.seconds(13.5))
        #expect(kit.server.inFlight == 1)

        await kit.advance(.seconds(1))
        #expect(kit.server.inFlight == 0)
        #expect(kit.server.requests.count == 1)

        await kit.advance(.seconds(7 * 3600))
        try #require(kit.server.requests.count >= 2)
        #expect((kit.server.requests[1].at - sentAt).seconds >= 60)
        await kit.stop()
    }

    @Test func c5_retryAfterOnTooManyRequestsIsHonoured() async throws {
        let kit = try consentedKit()
        kit.server.routeSequence("POST /v1/telemetry", [
            .problem(429, "rate_limited", retryAfter: 120),
            .json(202, #"{"accepted":1,"next_after_s":600}"#),
        ])

        await kit.run(for: .seconds(15 * 60))

        let telemetry = kit.server.to("POST /v1/telemetry")
        try #require(telemetry.count >= 2)
        let gap = (telemetry[1].at - telemetry[0].at).seconds
        #expect(gap >= 120 && gap <= 121)
        await kit.stop()
    }

    @Test func c6_serviceUnavailableDisabledStopsTelemetryUntilTheNextConfigRead() async throws {
        let kit = try consentedKit()
        kit.server.routeSequence("POST /v1/telemetry", [
            .problem(503, "disabled", retryAfter: 3600),
            .json(202, #"{"accepted":1,"next_after_s":600}"#),
        ])

        await kit.run(for: .seconds(3 * 3600))

        let endpoints = kit.server.requests.map(\.endpoint)
        let firstTelemetry = try #require(endpoints.firstIndex(of: "POST /v1/telemetry"))
        try #require(endpoints.count > firstTelemetry + 2)
        #expect(endpoints[firstTelemetry + 1] == "GET /v1/config")
        #expect(endpoints[firstTelemetry + 2] == "POST /v1/telemetry")
        let gap = (kit.server.requests[firstTelemetry + 1].at - kit.server.requests[firstTelemetry].at).seconds
        #expect(gap >= 3600)
        await kit.stop()
    }

    @Test func c7_configThatDisablesTelemetryStopsEverythingExceptConfigReads() async throws {
        let kit = try consentedKit()
        kit.server.route("GET /v1/config") { _ in
            .json(200, #"{"schema":1,"telemetry":{"enabled":false,"interval_s":600},"reports":{"enabled":false,"screenshots":false},"client_ok":true,"message":null}"#)
        }

        await kit.run(for: .seconds(24 * 3600))

        #expect(kit.server.to("POST /v1/telemetry").isEmpty)
        #expect(kit.server.to("POST /v1/installs").isEmpty)
        let reads = kit.server.to("GET /v1/config").count
        #expect(reads >= 4 && reads <= 5)
        await kit.stop()
    }

    @Test func c7_aClientThatIsTooOldSendsNothingAndKeepsTheServerMessage() async throws {
        let kit = try consentedKit()
        kit.server.route("GET /v1/config") { _ in
            .json(200, #"{"schema":1,"telemetry":{"enabled":true,"interval_s":600},"reports":{"enabled":true,"screenshots":true},"client_ok":false,"message":"Update OSB Manager."}"#)
        }

        await kit.run(for: .seconds(12 * 3600))

        #expect(kit.server.to("POST /v1/telemetry").isEmpty)
        #expect(kit.settings.state.config?.message == "Update OSB Manager.")
        await kit.stop()
    }

    @Test func c8_configIntervalOfTenSecondsIsRaisedToThreeHundred() async throws {
        let kit = try consentedKit(random: 0.0)
        kit.server.route("GET /v1/config") { _ in
            .json(200, #"{"schema":1,"telemetry":{"enabled":true,"interval_s":10},"reports":{"enabled":true,"screenshots":true},"client_ok":true,"message":null}"#)
        }
        kit.server.route("POST /v1/telemetry") { _ in .json(202, #"{"accepted":1,"next_after_s":0}"#) }

        await kit.run(for: .seconds(2 * 3600))

        let spacing = gaps(kit.server.to("POST /v1/telemetry"))
        #expect(spacing.count >= 20)
        #expect(spacing.allSatisfy { $0 >= 269 && $0 <= 331 }, "\(spacing)")
        #expect(kit.settings.state.config?.intervalSeconds == 300)
        await kit.stop()
    }

    @Test func c9_anUnauthorizedAnswerReRegistersOnceAndTheSecondOneStopsSending() async throws {
        let kit = try consentedKit()
        kit.server.route("POST /v1/telemetry") { _ in .problem(401, "unauthorized") }

        await kit.run(for: .seconds(48 * 3600))

        #expect(kit.server.to("POST /v1/installs").count == 2)
        #expect(kit.server.to("POST /v1/telemetry").count == 2)
        #expect(kit.server.requests.last?.endpoint == "POST /v1/telemetry")
        #expect(kit.logs.lines.contains { $0.contains("stopped") })
        await kit.stop()
    }

    @Test func c10_aConflictOnRegistrationCreatesANewIdAndKeyAndRegistersAgain() async throws {
        let kit = try consentedKit()
        let originalId = try #require(kit.settings.credentials).id
        kit.server.routeSequence("POST /v1/installs", [
            .problem(409, "install_conflict"),
            .json(201, #"{"install_id":"x","status":"quarantined"}"#),
        ])

        await kit.run(for: .seconds(5 * 60))

        let registrations = kit.server.to("POST /v1/installs")
        try #require(registrations.count == 2)
        let first = try #require(registrations[0].json)
        let second = try #require(registrations[1].json)
        #expect(first["install_id"] as? String == originalId)
        #expect(first["install_id"] as? String != second["install_id"] as? String)
        #expect(first["install_key"] as? String != second["install_key"] as? String)
        let secondId = try #require(second["install_id"] as? String)
        #expect(kit.settings.credentials?.id == secondId)
        #expect(try #require(kit.server.to("POST /v1/telemetry").first).authorization.contains(secondId))
        #expect(kit.keys.key == second["install_key"] as? String)
        await kit.stop()
    }

    @Test func c11_charactersAreAbsentWithoutTheSecondConsentAndPresentWithIt() async throws {
        let kit = try consentedKit()
        await kit.run(for: .seconds(25 * 60))
        let without = kit.server.to("POST /v1/telemetry")
        #expect(!without.isEmpty)
        #expect(without.allSatisfy { !$0.bodyText.contains("character") && !$0.bodyText.contains("Example") })

        await kit.service.setCharacters(true)
        try #require(kit.server.to("PUT /v1/installs/me/consent").count == 1)
        #expect(kit.server.to("PUT /v1/installs/me/consent")[0].bodyText.contains("\"characters\":true"))
        var before = kit.server.to("POST /v1/telemetry").count
        await kit.run(for: .seconds(25 * 60), startService: false)
        let withConsent = Array(kit.server.to("POST /v1/telemetry").dropFirst(before))
        #expect(!withConsent.isEmpty)
        for request in withConsent {
            let accounts = request.json?["accounts"] as? [[String: Any]]
            let character = accounts?.first?["character"] as? [String: Any]
            #expect(character?["name"] as? String == "Example")
        }

        await kit.service.setCharacters(false)
        try #require(kit.server.to("PUT /v1/installs/me/consent").count == 2)
        #expect(kit.server.to("PUT /v1/installs/me/consent")[1].bodyText.contains("\"characters\":false"))
        before = kit.server.to("POST /v1/telemetry").count
        await kit.run(for: .seconds(25 * 60), startService: false)
        let afterWithdrawal = Array(kit.server.to("POST /v1/telemetry").dropFirst(before))
        #expect(!afterWithdrawal.isEmpty)
        #expect(afterWithdrawal.allSatisfy { !$0.bodyText.contains("character") })
        await kit.stop()
    }

    @Test func c12_withdrawingConsentSendsDeleteAndWipesTheLocalIdAndKeyEvenWhenDeleteFails() async throws {
        let kit = try consentedKit()
        kit.server.route("DELETE /v1/installs/me") { _ in .problem(500, "server_error") }
        await kit.run(for: .seconds(15 * 60))
        let credentials = try #require(kit.settings.credentials)
        #expect(kit.settings.state.registered)

        let result = await kit.service.withdraw()

        #expect(result == .failed)
        let deletes = kit.server.to("DELETE /v1/installs/me")
        try #require(deletes.count == 1)
        #expect(deletes[0].authorization == "Bearer " + credentials.bearer)
        #expect(kit.settings.credentials == nil)
        #expect(kit.settings.state.installId == nil)
        #expect(!kit.settings.state.granted)
        #expect(kit.keys.key == nil)
        let file = try String(contentsOf: kit.privacyFile, encoding: .utf8)
        #expect(!file.contains(credentials.id))
        #expect(!file.contains(credentials.key))
        #expect(kit.service.failedDeletionInstallId == credentials.id)
        let count = kit.server.requests.count
        await kit.run(for: .seconds(24 * 3600), startService: false)
        #expect(kit.server.requests.count == count)
        await kit.stop()
    }

    @Test func c12_withdrawingWhileTheServerNeverAnswersWipesLocallyAtOnce() async throws {
        let kit = try consentedKit()
        await kit.run(for: .seconds(15 * 60))
        kit.server.hang("DELETE /v1/installs/me")
        let id = try #require(kit.settings.credentials).id

        let pending = Task { await kit.service.withdraw() }
        await kit.settle()

        #expect(kit.settings.credentials == nil)
        #expect(!kit.settings.state.granted)
        #expect(kit.server.inFlight == 1)
        await kit.advance(.seconds(15.1))
        #expect(await pending.value == .failed)
        #expect(kit.service.failedDeletionInstallId == id)
        await kit.stop()
    }

    @Test func c13_aPayloadOverTheLimitIsCutToTheAccountsThatFit() {
        let moment = Date(timeIntervalSince1970: TelemetryKit.origin)
        let builder = TelemetryPayloadBuilder(appVersion: "1.2.0", now: { moment }, maxBytes: 3000)
        let snapshots = (0..<20).map {
            AccountSnapshot(accountId: "account-\($0)", server: "ExampleServer", status: hunting("Character\($0)"), receivedAt: moment.addingTimeInterval(Double(-$0)))
        }

        let batch = builder.build(snapshots, installKey: Data(count: 32), includeCharacters: true)

        #expect(batch != nil)
        #expect((batch?.body.count ?? Int.max) <= 3000)
        #expect((1...19).contains(batch?.accounts ?? 0))
        let accounts = (try? JSONSerialization.jsonObject(with: batch?.body ?? Data()) as? [String: Any])?["accounts"] as? [Any]
        #expect(accounts?.count == batch?.accounts)
        #expect(TelemetryLimits.softBodyBytes < TelemetryLimits.maxBodyBytes)
    }

    @Test func c13_twentyFullAccountsStayUnderTheServerLimit() {
        let moment = Date(timeIntervalSince1970: TelemetryKit.origin)
        let builder = TelemetryPayloadBuilder(appVersion: "1.2.0", now: { moment })
        let longName = String(repeating: "x", count: 32)
        let snapshots = (0..<40).map {
            AccountSnapshot(accountId: "account-\($0)", server: longName, status: hunting(longName), receivedAt: moment)
        }

        let batch = builder.build(snapshots, installKey: Data(count: 32), includeCharacters: true)

        #expect(batch?.accounts == 20)
        #expect((batch?.body.count ?? Int.max) <= TelemetryLimits.maxBodyBytes)
    }

    @Test func c14_aReportWhileOfflineWaitsInTheOutboxIsRetriedAndMovesToFailedAfterSeventyTwoHours() async throws {
        let kit = try TelemetryKit()
        kit.server.failEverything(500)
        await kit.service.start()
        let report = ReportPayload.build(kind: .bug, description: "Auto login stops.", diagnostics: [:], appVersion: "1.2.0", locale: "en")

        let outcome = await kit.service.sendReport(reportJson: report, screenshot: nil)

        #expect(outcome.result == .queued)
        #expect(kit.outbox.pending().count == 1)
        await kit.advance(.seconds(73 * 3600))
        let sent = kit.server.to("POST /v1/reports")
        #expect(sent.count >= 3)
        #expect(gaps(sent).allSatisfy { $0 >= 60 })
        #expect(kit.outbox.pending().isEmpty)
        #expect(kit.outbox.failed().count == 1)

        kit.server.route("POST /v1/reports") { _ in .json(201, #"{"code":"R-7K3Q9XAB","screenshot":"none"}"#) }
        let failedId = try #require(kit.outbox.failed().first).id
        #expect(kit.outbox.sendAgain(id: failedId))
        await kit.advance(.seconds(10 * 60))
        #expect(kit.outbox.pending().isEmpty)
        #expect(kit.outbox.failed().isEmpty)
        await kit.stop()
    }

    @Test func c14_aReportThatIsSentImmediatelyReturnsTheCodeAndIsNotQueued() async throws {
        let kit = try TelemetryKit()
        let report = ReportPayload.build(kind: .feature, description: "More slots.", diagnostics: [:], appVersion: "1.2.0", locale: "en")

        let outcome = await kit.service.sendReport(reportJson: report, screenshot: Data([1, 2, 3]))

        #expect(outcome.result == .sent)
        #expect(outcome.code == "R-7K3Q9XAB")
        #expect(outcome.anonymous)
        #expect(kit.outbox.pending().isEmpty)
        let request = try #require(kit.server.to("POST /v1/reports").first)
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(request.bodyText.contains("name=\"report\""))
        #expect(request.bodyText.contains("name=\"screenshot\""))
        await kit.stop()
    }

    @Test func c16_threeUnexpectedErrorsSwitchTelemetryOffAndTheRestKeepsWorking() async throws {
        let counter = CallCounter()
        let kit = try consentedKit(source: ThrowingStatuses(counter: counter))

        await kit.run(for: .seconds(48 * 3600))

        #expect(await kit.service.disabledByFailSafe)
        #expect(counter.value == 3)
        #expect(kit.logs.lines.filter { $0.contains("switched off") }.count == 1)
        #expect(kit.server.to("POST /v1/telemetry").isEmpty)
        kit.publish("account-b", hunting())
        #expect(((try? await kit.statuses.snapshot()) ?? []).count == 2)
        await kit.stop()
    }

    @Test func c17_aRedirectAnswerIsAFailureAndIsNotFollowed() async throws {
        let kit = try consentedKit()
        let stray = FakeServer(clock: kit.clock, host: "evil.example")
        kit.server.route("GET /v1/config") { _ in .redirect("https://evil.example/collect") }

        await kit.run(for: .seconds(6 * 3600))

        #expect(!kit.server.requests.isEmpty)
        #expect(kit.server.requests.allSatisfy { $0.path == "/v1/config" })
        #expect(gaps(kit.server.requests).allSatisfy { $0 >= 60 })
        #expect(kit.server.to("POST /v1/telemetry").isEmpty)
        #expect(stray.requests.isEmpty)
        await kit.stop()
    }
}
