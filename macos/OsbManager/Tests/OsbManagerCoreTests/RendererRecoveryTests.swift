import Foundation
import Testing
@testable import OsbManagerCore

struct RendererQueueTests {
    private final class Fixture {
        var now = Date(timeIntervalSince1970: 1_762_436_040)
        var granted: [String] = []
        lazy var queue = RendererQueue(gap: 2, lease: 20, clock: { [unowned self] in self.now })

        func ask(_ window: String, _ id: String) {
            queue.request(window: window, id: id) { [unowned self] in self.granted.append("\(window):\(id)") }
        }
    }

    @Test func letsOneWindowStartItsRendererAtATimeWithAGap() {
        let f = Fixture()
        f.ask("a", "1")
        f.ask("b", "1")
        f.ask("c", "1")
        #expect(f.granted == ["a:1"])
        #expect(f.queue.isWaiting("b"))

        f.queue.release(window: "a", id: "1")
        f.now.addTimeInterval(1)
        f.queue.pump()
        #expect(f.granted == ["a:1"])
        f.now.addTimeInterval(1)
        f.queue.pump()
        #expect(f.granted == ["a:1", "b:1"])
        #expect(f.queue.holderWindow == "b")
        #expect(f.queue.isWaiting("c"))
    }

    @Test func takesTheSlotBackFromAPageThatDiedHoldingIt() {
        let f = Fixture()
        f.ask("a", "1")
        f.ask("b", "1")
        f.now.addTimeInterval(19)
        f.queue.pump()
        #expect(f.queue.holderWindow == "a")

        f.now.addTimeInterval(1)
        f.queue.pump()
        #expect(f.queue.holderWindow == nil)
        f.now.addTimeInterval(2)
        f.queue.pump()
        #expect(f.granted == ["a:1", "b:1"])
    }

    @Test func aClosedWindowFreesItsSlotAtOnceAndLeavesTheOthersQueued() {
        let f = Fixture()
        f.ask("a", "1")
        f.ask("b", "1")
        f.ask("c", "1")
        f.queue.forget("a")
        #expect(f.queue.holderWindow == nil)
        #expect(f.queue.isWaiting("b"))
        #expect(f.queue.isWaiting("c"))
        f.now.addTimeInterval(2)
        f.queue.pump()
        #expect(f.granted == ["a:1", "b:1"])
    }

    @Test func aWindowForgottenWhileWaitingDoesNotTouchTheHolder() {
        let f = Fixture()
        f.ask("a", "1")
        f.ask("b", "1")
        f.queue.forget("b")
        #expect(f.queue.holderWindow == "a")
        #expect(!f.queue.isWaiting("b"))
    }

    @Test func ignoresAHandBackForAnOlderRequest() {
        let f = Fixture()
        f.ask("a", "1")
        f.ask("b", "1")
        f.queue.release(window: "a", id: "old")
        f.queue.release(window: "b", id: "1")
        #expect(f.queue.holderWindow == "a")
        #expect(!f.queue.isWaiting("b"))
    }

    @Test func aNewRequestOfAWindowReplacesItsOlderOne() {
        let f = Fixture()
        f.ask("a", "1")
        f.ask("b", "1")
        f.ask("b", "2")
        f.queue.release(window: "a", id: "1")
        f.now.addTimeInterval(2)
        f.queue.pump()
        #expect(f.granted == ["a:1", "b:2"])
    }
}

struct RendererRecoveryTests {
    private static var loading: BotStatus {
        var status = BotStatus()
        status.phase = "signed-out"
        return status
    }

    private static var failed: BotStatus {
        var status = BotStatus()
        status.gpuRetries = 6
        status.gpuRetryLimit = 6
        status.gpuFailed = "requestDevice: CheckOutOfMemory"
        return status
    }

    private static var inWorld: BotStatus {
        var status = BotStatus()
        status.inWorld = true
        status.phase = "world"
        return status
    }

    @Test func reloadsThenRestartsThenGivesUp() {
        let recovery = RendererRecovery()
        #expect(recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: true) == .reload)
        #expect(recovery.observe(previous: Self.failed, report: Self.failed, restartAllowed: true) == .none)
        #expect(recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: true) == .restart)
        #expect(recovery.observe(previous: nil, report: Self.failed, restartAllowed: true) == .giveUp)
        #expect(recovery.gaveUp)
    }

    @Test func withRestartOffItGivesUpAfterTheReload() {
        let recovery = RendererRecovery()
        #expect(recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: false) == .reload)
        #expect(recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: false) == .giveUp)
        #expect(!recovery.restarted)
    }

    @Test func reachingTheWorldStartsTheLadderOver() {
        let recovery = RendererRecovery()
        _ = recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: true)
        _ = recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: true)
        #expect(recovery.observe(previous: Self.loading, report: Self.inWorld, restartAllowed: true) == .none)
        #expect(!recovery.reloaded && !recovery.restarted && !recovery.gaveUp)
        #expect(recovery.observe(previous: Self.inWorld, report: Self.failed, restartAllowed: true) == .reload)
    }

    @Test func oneAccountsRecoveryLeavesAnotherAlone() {
        let failing = RendererRecovery()
        let healthy = RendererRecovery()
        _ = failing.observe(previous: Self.loading, report: Self.failed, restartAllowed: true)
        _ = failing.observe(previous: Self.loading, report: Self.failed, restartAllowed: true)
        #expect(failing.restarted)
        #expect(!healthy.reloaded && !healthy.restarted && !healthy.gaveUp)
        #expect(healthy.stateText(status: Self.inWorld, waitingForSlot: false, normal: "In game") == nil)
    }

    @Test func showsTheRecoveryInTheStatusTab() {
        let recovery = RendererRecovery()
        var retrying = BotStatus()
        retrying.gpuRetries = 5
        retrying.gpuRetryIn = 60
        #expect(recovery.stateText(status: retrying, waitingForSlot: false, normal: "Loading") == "Renderer failed, retrying in 60 s")
        #expect(recovery.stateText(status: Self.loading, waitingForSlot: true, normal: "Login") == "Waiting for another window's renderer")
        #expect(recovery.stateText(status: Self.loading, waitingForSlot: false, normal: "Login") == nil)

        _ = recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: true)
        #expect(recovery.stateText(status: Self.failed, waitingForSlot: false, normal: "Loading") == "Renderer failed, recovering")
        #expect(recovery.stateText(status: Self.loading, waitingForSlot: false, normal: "Loading") == "Reloaded after renderer failure (Loading)")

        _ = recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: true)
        #expect(recovery.stateText(status: nil, waitingForSlot: false, normal: "Logging in") == "Restarted after renderer failure (Logging in)")
        #expect(recovery.stateText(status: Self.inWorld, waitingForSlot: false, normal: "In game") == nil)

        _ = recovery.observe(previous: Self.loading, report: Self.failed, restartAllowed: true)
        #expect(recovery.stateText(status: Self.failed, waitingForSlot: false, normal: "Loading") == "Renderer failed, use Reload")
    }

    @Test func writesTheRecoveryToTheLog() {
        #expect(RendererTexts.retrying(account: "test", retries: 5, limit: 6, seconds: 60)
            == "test: the graphics card was full when the game started its renderer; trying again in 60 s (5 of 6).")
        #expect(RendererTexts.failed(account: "test", reason: "OutOfMemory") == "test: the game's renderer could not start (OutOfMemory).")
        #expect(RendererTexts.step(account: "test", step: .reload, restarted: false) == "test: reloading the game page to start the renderer again.")
        #expect(RendererTexts.step(account: "test", step: .giveUp, restarted: true).contains("after a reload and a window restart."))
        #expect(RendererTexts.step(account: "test", step: .giveUp, restarted: false).contains("after a reload; automatic window restart is off."))
    }
}

struct RendererMessageTests {
    @Test func readsTheRetryScheduleFromTheStatusAndBoundsIt() {
        let status = BotStatus.parse(#"{"type":"status","gpu":{"retries":5,"limit":6,"failed":null,"retryIn":60}}"#)
        #expect(status?.gpuRetries == 5)
        #expect(status?.gpuRetryLimit == 6)
        #expect(status?.gpuRetryIn == 60)

        let old = BotStatus.parse(#"{"type":"status","gpu":{"retries":1,"failed":null}}"#)
        #expect(old?.gpuRetryLimit == 0)
        #expect(old?.gpuRetryIn == 0)

        let wild = BotStatus.parse(#"{"type":"status","gpu":{"retries":1,"limit":5000,"retryIn":-3}}"#)
        #expect(wild?.gpuRetryLimit == 0)
        #expect(wild?.gpuRetryIn == 0)
    }

    @Test func acceptsSlotMessagesFromTheGamePageOnly() {
        let request = #"{"type":"gpu-slot","id":"k3j2h1"}"#
        #expect(PageMessageInbox.accept(body: request, isMainFrame: true, scheme: "https", host: "opensro.online", port: 0) == .rendererSlot(RendererSlotMessage(done: false, id: "k3j2h1")))
        #expect(PageMessageInbox.accept(body: #"{"type":"gpu-slot-done","id":"k3j2h1"}"#, isMainFrame: true, scheme: "https", host: "opensro.online", port: 0) == .rendererSlot(RendererSlotMessage(done: true, id: "k3j2h1")))
        #expect(PageMessageInbox.accept(body: request, isMainFrame: true, scheme: "https", host: "example.com", port: 0) == nil)
        #expect(PageMessageInbox.accept(body: request, isMainFrame: false, scheme: "https", host: "opensro.online", port: 0) == nil)
    }

    @Test(arguments: [
        #"{"type":"gpu-slot"}"#,
        #"{"type":"gpu-slot","id":""}"#,
        #"{"type":"gpu-slot","id":"a b"}"#,
        #"{"type":"gpu-slot","id":"<script>"}"#,
        #"{"type":"gpu-slot","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
        #"{"type":"gpu-slot","id":7}"#,
        #"{"type":"status","id":"a"}"#,
        #"["gpu-slot"]"#,
        "not json",
    ])
    func rejectsAnythingElse(json: String) {
        #expect(RendererSlotMessage.parse(json) == nil)
    }

    @Test func grantsWithTheRequestId() {
        let grant = PageMessages.rendererSlotGrant(id: "k3j2h1")
        #expect(grant["type"] as? String == "gpu-slot")
        #expect(grant["id"] as? String == "k3j2h1")
    }

    @Test func restartsAfterARendererFailureByDefaultAndKeepsTheChoice() throws {
        let temp = TemporaryDirectory()
        try #"{"frameLimit":60}"#.write(to: temp.file("settings.json"), atomically: true, encoding: .utf8)
        let settings = AppSettings.load(from: temp.file("settings.json"))
        #expect(settings.restartAfterRendererFailure)
        #expect(AppSettings.load(from: temp.file("missing.json")).restartAfterRendererFailure)

        settings.restartAfterRendererFailure = false
        try settings.save()

        #expect(!AppSettings.load(from: temp.file("settings.json")).restartAfterRendererFailure)
    }
}
