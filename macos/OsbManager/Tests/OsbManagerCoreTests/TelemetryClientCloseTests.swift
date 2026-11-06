import Foundation
import Testing
@testable import OsbManagerCore

struct TelemetryClientCloseTests {
    private func report() -> Data {
        ReportPayload.build(kind: .bug, description: "Auto login stops.", diagnostics: [:], appVersion: "1.2.0", locale: "en")
    }

    @Test func aRequestAfterCloseIsCancelledAndNeverReachesTheServer() async throws {
        let kit = try TelemetryKit()
        await kit.client.close()

        let background = await kit.client.getConfig(version: "1.2.0", background: true)
        let foreground = await kit.client.sendReport(credentials: nil, reportJson: report(), screenshot: nil)

        #expect(background.outcome == .cancelled)
        #expect(foreground.outcome == .cancelled)
        #expect(kit.server.requests.isEmpty)
        await kit.stop()
    }

    @Test func closingDuringARequestCancelsItAndAQueuedRequestNeverStarts() async throws {
        let kit = try TelemetryKit()
        kit.server.hangEverything()
        let client = kit.client
        let first = Task { await client.getConfig(version: "1.2.0", background: false) }
        #expect(await kit.waitUntil { kit.server.inFlight == 1 })
        let payload = report()
        let second = Task { await client.sendReport(credentials: nil, reportJson: payload, screenshot: nil) }

        await client.close()

        #expect(await first.value.outcome == .cancelled)
        #expect(await second.value.outcome == .cancelled)
        #expect(await kit.waitUntil { kit.server.inFlight == 0 })
        #expect(kit.server.requests.map(\.endpoint) == ["GET /v1/config"])
        await kit.stop()
    }

    @Test func closingWhileRequestsAreStartingNeverCrashes() async throws {
        for _ in 0..<25 {
            let kit = try TelemetryKit()
            let client = kit.client
            let payload = report()
            let background = Task { await client.getConfig(version: "1.2.0", background: true) }
            let foreground = Task { await client.sendReport(credentials: nil, reportJson: payload, screenshot: nil) }

            await client.close()

            #expect([.success, .busy, .cancelled].contains(await background.value.outcome))
            #expect([.success, .cancelled].contains(await foreground.value.outcome))
            await kit.stop()
        }
    }
}
