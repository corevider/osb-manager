import Foundation
import Testing
@testable import OsbManagerCore

struct StartQueueTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    @Test func opensTheFirstWindowAtOnceAndTheNextOnesAGapApart() {
        let clock = Clock()
        let queue = StartQueue(gap: 15, clock: { clock.now })
        queue.add("a", light: false)
        queue.add("b", light: true)
        queue.add("c", light: false)
        queue.add("b", light: false)

        #expect(queue.takeDue()?.accountId == "a")
        #expect(queue.takeDue() == nil)
        #expect(queue.wait(for: "b") == 15)
        #expect(queue.wait(for: "c") == 30)

        clock.now.addTimeInterval(15)
        let second = queue.takeDue()
        #expect(second?.accountId == "b")
        #expect(second?.light == true)
        clock.now.addTimeInterval(14)
        #expect(queue.takeDue() == nil)
        clock.now.addTimeInterval(1)
        #expect(queue.takeDue()?.accountId == "c")
        #expect(queue.count == 0)
    }

    @Test func countsDownTheWaitWhileTimePasses() {
        let clock = Clock()
        let queue = StartQueue(gap: 15, clock: { clock.now })
        queue.add("a", light: false)
        queue.add("b", light: false)
        _ = queue.takeDue()

        clock.now.addTimeInterval(5)

        #expect(queue.wait(for: "b") == 10)
        clock.now.addTimeInterval(20)
        #expect(queue.wait(for: "b") == 0)
        #expect(queue.wait(for: "missing") == nil)
    }

    @Test func forgetsRemovedAndClearedAccounts() {
        let queue = StartQueue(gap: 15)
        queue.add("a", light: false)
        queue.add("b", light: false)

        #expect(queue.remove("a"))
        #expect(!queue.remove("a"))
        #expect(!queue.contains("a"))
        #expect(queue.wait(for: "a") == nil)
        queue.clear()
        #expect(queue.takeDue() == nil)
    }

    @Test func followsANewAccountOrderForTheWindowsStillWaiting() {
        let clock = Clock()
        let queue = StartQueue(gap: 15, clock: { clock.now })
        for id in ["a", "gone", "b", "c"] {
            queue.add(id, light: false)
        }

        queue.sort(by: ["c", "a", "b"])

        var opened: [String] = []
        for _ in 0..<4 {
            opened.append(queue.takeDue()?.accountId ?? "none")
            clock.now.addTimeInterval(15)
        }
        #expect(opened == ["c", "a", "b", "gone"])
    }
}
