import Foundation
import Testing
@testable import OsbManagerCore

final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSince1970: 1_800_000_000)

    var value: Date { lock.withLock { moment } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { moment = moment.addingTimeInterval(seconds) }
    }
}

struct ReportOutboxTests {
    private func makeOutbox(_ temp: TemporaryDirectory, now: TestNow = TestNow()) -> (ReportOutbox, TestNow) {
        (ReportOutbox(directory: temp.file("outbox"), now: { now.value }), now)
    }

    private func report(_ text: String = "report") -> Data {
        Data("{\"description\":\"\(text)\"}".utf8)
    }

    @Test func holdsAtMostFivePendingReports() {
        let (outbox, _) = makeOutbox(TemporaryDirectory())

        let outcomes = (0..<6).map { outbox.enqueue(reportJson: report("r\($0)"), screenshot: nil, anonymous: true).outcome }

        #expect(outcomes == [.queued, .queued, .queued, .queued, .queued, .full])
        #expect(outbox.pending().count == 5)
    }

    @Test func refusesAReportOverNineHundredKilobytesWithItsScreenshot() {
        let (outbox, _) = makeOutbox(TemporaryDirectory())

        let outcome = outbox.enqueue(reportJson: report(), screenshot: Data(count: 900 * 1024), anonymous: true).outcome

        #expect(outcome == .tooLarge)
        #expect(outbox.pending().isEmpty)
    }

    @Test func keepsTheReportAndItsScreenshotAsFilesAndReadsThemBack() throws {
        let temp = TemporaryDirectory()
        let (outbox, _) = makeOutbox(temp)
        let result = outbox.enqueue(reportJson: report("with picture"), screenshot: Data([9, 8, 7]), anonymous: false, retryIn: 90, note: "HTTP 500")

        let entry = try #require(outbox.pending().first)

        #expect(entry.id == result.id)
        #expect(entry.hasScreenshot)
        #expect(entry.attempts == 1)
        #expect(entry.lastNote == "HTTP 500")
        #expect(entry.reportJson.contains("with picture"))
        #expect(outbox.screenshot(for: entry, failed: false) == Data([9, 8, 7]))
        #expect(FileManager.default.fileExists(atPath: temp.file("outbox/\(entry.id).json").path))
        #expect(FileManager.default.fileExists(atPath: temp.file("outbox/\(entry.id).png").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.file("outbox").path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func schedulesTheNextAttemptAndRecordsFailedTries() throws {
        let (outbox, now) = makeOutbox(TemporaryDirectory())
        let result = outbox.enqueue(reportJson: report(), screenshot: nil, anonymous: true, retryIn: 100)
        #expect(outbox.nextAttemptAt() == now.value.addingTimeInterval(100))

        now.advance(100)
        outbox.recordAttempt(id: result.id, retryIn: 500, note: "timed out", anonymous: false)

        let entry = try #require(outbox.pending().first)
        #expect(entry.attempts == 1)
        #expect(entry.lastNote == "timed out")
        #expect(entry.anonymous)
        #expect(outbox.nextAttemptAt() == now.value.addingTimeInterval(500))
    }

    @Test func movesAReportToFailedAfterSeventyTwoHoursAndOffersItAgain() throws {
        let temp = TemporaryDirectory()
        let (outbox, now) = makeOutbox(temp)
        let result = outbox.enqueue(reportJson: report(), screenshot: Data([1]), anonymous: true)

        now.advance(72 * 3600 - 5)
        #expect(outbox.moveExpired() == 0)
        now.advance(10)
        #expect(outbox.moveExpired() == 1)

        #expect(outbox.pending().isEmpty)
        let failed = try #require(outbox.failed().first)
        #expect(failed.id == result.id)
        #expect(outbox.screenshot(for: failed, failed: true) == Data([1]))
        #expect(FileManager.default.fileExists(atPath: temp.file("outbox/failed/\(result.id).json").path))

        #expect(outbox.sendAgain(id: result.id))
        #expect(outbox.failed().isEmpty)
        let again = try #require(outbox.pending().first)
        #expect(again.attempts == 0)
        #expect(again.nextAttemptAt == now.value)
        #expect(outbox.screenshot(for: again, failed: false) == Data([1]))
    }

    @Test func sendAgainIsRefusedWhileFiveReportsWait() throws {
        let (outbox, now) = makeOutbox(TemporaryDirectory())
        let old = outbox.enqueue(reportJson: report("old"), screenshot: nil, anonymous: true)
        now.advance(73 * 3600)
        outbox.moveExpired()
        for index in 0..<5 {
            _ = outbox.enqueue(reportJson: report("new\(index)"), screenshot: nil, anonymous: true)
        }

        #expect(!outbox.sendAgain(id: old.id))
        #expect(outbox.failed().count == 1)
    }

    @Test func deletingAFailedReportAndClearingEverythingWork() {
        let (outbox, now) = makeOutbox(TemporaryDirectory())
        let first = outbox.enqueue(reportJson: report("a"), screenshot: Data([1]), anonymous: true)
        now.advance(73 * 3600)
        outbox.moveExpired()
        _ = outbox.enqueue(reportJson: report("b"), screenshot: nil, anonymous: true)

        outbox.deleteFailed(id: first.id)
        #expect(outbox.failed().isEmpty)
        #expect(outbox.pending().count == 1)

        outbox.clearAll()
        #expect(outbox.pending().isEmpty)
        #expect(outbox.failed().isEmpty)
    }

    @Test func ignoresFilesThatAreNotValidEntries() throws {
        let temp = TemporaryDirectory()
        let (outbox, _) = makeOutbox(temp)
        _ = outbox.enqueue(reportJson: report(), screenshot: nil, anonymous: true)
        try "garbage".write(to: temp.file("outbox/garbage.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: temp.file("outbox/other.json"), atomically: true, encoding: .utf8)

        #expect(outbox.pending().count == 1)
    }

    @Test func tellsObserversWhenTheOutboxChanges() {
        let (outbox, _) = makeOutbox(TemporaryDirectory())
        let counter = CallCounter()
        outbox.addObserver { counter.increment() }

        let result = outbox.enqueue(reportJson: report(), screenshot: nil, anonymous: true)
        outbox.remove(id: result.id)

        #expect(counter.value == 2)
    }
}
