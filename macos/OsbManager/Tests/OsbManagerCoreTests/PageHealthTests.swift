import Foundation
import Testing
@testable import OsbManagerCore

struct PageHealthTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_762_600_430)

        func wait(_ seconds: TimeInterval) {
            now.addTimeInterval(seconds)
        }

        func health() -> PageHealth {
            PageHealth(clock: { [unowned self] in self.now })
        }
    }

    @Test func waitsForAPageThatStopsRespondingThenReloadsRestartsAndGivesUp() {
        let clock = Clock()
        let health = clock.health()
        health.pageStarted()
        health.reported(inWorld: true)

        #expect(health.markUnresponsive())
        #expect(!health.markUnresponsive())
        clock.wait(59)
        #expect(health.tick() == .none)
        #expect(health.stateText(normal: "Not responding", inWorld: false) == "Not responding for 59 s, waiting")

        clock.wait(1)
        #expect(health.tick() == .reload)
        #expect(health.lastProblem == .silent)
        health.pageStarted()
        clock.wait(89)
        #expect(health.tick() == .none)
        #expect(health.stateText(normal: "Loading", inWorld: false) == "Reloaded after the page stopped responding (Loading)")

        clock.wait(1)
        #expect(health.tick() == .restart)
        clock.wait(40)
        health.pageStarted()
        clock.wait(89)
        #expect(health.tick() == .none)
        #expect(health.stateText(normal: "Starting", inWorld: false) == "Restarted after the page stopped responding (Starting)")

        clock.wait(1)
        #expect(health.tick() == .giveUp)
        #expect(health.stateText(normal: "Not responding", inWorld: false) == "Not responding, use Reload")
        clock.wait(600)
        #expect(health.tick() == .none)
    }

    @Test func aPageThatRespondsAgainInTimeIsLeftAlone() {
        let clock = Clock()
        let health = clock.health()
        health.pageStarted()
        health.reported(inWorld: true)
        health.markUnresponsive()
        clock.wait(30)

        #expect(health.reported(inWorld: true))
        for _ in 0..<120 {
            clock.wait(1)
            #expect(!health.reported(inWorld: true))
            #expect(health.tick() == .none)
        }
        clock.wait(9)
        #expect(health.stateText(normal: "In game", inWorld: true) == nil)
        #expect(!health.reloaded)
    }

    @Test func aLoadingPageThatNeverReportedIsNotReloadedForBeingQuiet() {
        let clock = Clock()
        let health = clock.health()
        health.pageStarted()
        clock.wait(600)

        #expect(health.tick() == .none)
        #expect(health.stateText(normal: "Loading", inWorld: false) == nil)
    }

    @Test func anEndedPageProcessIsReloadedAtOnce() {
        let clock = Clock()
        let health = clock.health()
        health.pageStarted()
        health.reported(inWorld: true)
        health.markCrashed()

        #expect(health.stateText(normal: "In game", inWorld: false) == "Page crashed, reloading")
        #expect(health.tick() == .reload)
        #expect(health.lastProblem == .crashed)
        health.pageStarted()
        clock.wait(5)
        health.reported(inWorld: false)
        #expect(health.tick() == .none)
        #expect(health.stateText(normal: "Login", inWorld: false) == "Reloaded after the page stopped responding (Login)")
    }

    @Test func reachingTheWorldStartsTheLadderOver() {
        let clock = Clock()
        let health = clock.health()
        health.pageStarted()
        health.reported(inWorld: true)
        health.markCrashed()
        _ = health.tick()
        health.pageStarted()
        health.reported(inWorld: true)

        #expect(!health.reloaded)
        health.markCrashed()
        #expect(health.tick() == .reload)
    }

    @Test func oneUnresponsiveWindowDoesNotCloseOrRestartTheOthers() {
        let clock = Clock()
        let names = ["bot", "test", "runecaller", "emberveil", "bard", "lutewind", "ashmoor"]
        var health: [String: PageHealth] = [:]
        for name in names {
            health[name] = clock.health()
        }
        let restarts = WindowRestarts()
        var open = Set(names)
        var reloaded: [String] = []
        for page in health.values {
            page.pageStarted()
            page.reported(inWorld: true)
        }

        health["emberveil"]?.markUnresponsive()
        for _ in 0..<300 {
            clock.wait(1)
            for name in names where open.contains(name) {
                guard let page = health[name] else { continue }
                if name != "emberveil" {
                    page.reported(inWorld: true)
                }
                switch page.tick() {
                case .reload:
                    reloaded.append(name)
                    page.pageStarted()
                case .restart:
                    #expect(restarts.request(name))
                    open.remove(name)
                    #expect(restarts.takeOnClose(name, quitting: false))
                    open.insert(name)
                    page.pageStarted()
                default:
                    break
                }
            }
        }

        #expect(reloaded == ["emberveil"])
        #expect(open == Set(names))
        #expect(health["emberveil"]?.gaveUp == true)
        for name in names where name != "emberveil" {
            let page = health[name]
            #expect(page?.reloaded == false && page?.restarted == false && page?.gaveUp == false)
            #expect(!restarts.takeOnClose(name, quitting: false))
        }
    }

    @Test func closingAllWindowsOrQuittingCancelsAPendingRestart() {
        let restarts = WindowRestarts()

        #expect(restarts.request("emberveil"))
        #expect(!restarts.request("emberveil"))
        #expect(restarts.isRestarting("emberveil"))
        #expect(!restarts.isRestarting("bot"))
        restarts.clear()
        #expect(!restarts.takeOnClose("emberveil", quitting: false))

        restarts.request("emberveil")
        #expect(!restarts.takeOnClose("emberveil", quitting: true))
        #expect(!restarts.takeOnClose("bot", quitting: false))
    }

    @Test func writesTheStepsToTheLog() {
        #expect(PageTexts.step(account: "emberveil", step: .reload, problem: .silent) == "emberveil: the page did not respond for 60 s; reloading this window only.")
        #expect(PageTexts.step(account: "emberveil", step: .reload, problem: .crashed) == "emberveil: the page process ended; reloading this window only.")
        #expect(PageTexts.step(account: "emberveil", step: .restart, problem: .silent).contains("restarting this window with the same profile and saved login"))
        #expect(PageTexts.step(account: "emberveil", step: .giveUp, problem: .silent).contains("after a reload and a window restart"))
        #expect(PageTexts.responding(account: "emberveil") == "emberveil: the page responds again.")
    }
}

struct LoginWatchTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_762_600_455)

        func wait(_ seconds: TimeInterval) {
            now.addTimeInterval(seconds)
        }

        func watch() -> LoginWatch {
            LoginWatch(clock: { [unowned self] in self.now })
        }
    }

    private static func status(phase: String?, stage: String?, inWorld: Bool = false) -> BotStatus {
        var status = BotStatus()
        status.phase = phase
        status.loginStage = stage
        status.inWorld = inWorld
        status.linked = true
        status.character = inWorld ? "Hunter" : nil
        return status
    }

    private let notStarted = LoginWatchTests.status(phase: "signed-out", stage: "off")
    private let busy = LoginWatchTests.status(phase: "authenticating", stage: "waiting")
    private let typing = LoginWatchTests.status(phase: "signed-out", stage: "connecting")
    private let inWorld = LoginWatchTests.status(phase: "world", stage: "done", inWorld: true)

    @Test func sendsTheLoginSettingsAgainWhileThePageHasNotStartedTheLogin() {
        let clock = Clock()
        let watch = clock.watch()

        #expect(watch.observe(notStarted, autoLogin: true) == .sendSettings)
        clock.wait(1)
        #expect(watch.observe(notStarted, autoLogin: true) == .none)
        clock.wait(14)
        #expect(watch.observe(notStarted, autoLogin: true) == .sendSettings)
        #expect(watch.observe(typing, autoLogin: true) == .none)
        #expect(watch.observe(notStarted, autoLogin: false) == .none)
    }

    @Test func reloadsAPageStuckBeforeTheLoginOnceThenSaysWhy() {
        let clock = Clock()
        let watch = clock.watch()
        for _ in 0..<179 {
            #expect(watch.observe(busy, autoLogin: true) != .reload)
            clock.wait(1)
        }
        #expect(watch.stateText(status: busy, autoLogin: true, hasLogin: true, normal: "authenticating") == "Logging in (authenticating)")
        clock.wait(1)

        #expect(watch.observe(busy, autoLogin: true) == .reload)
        #expect(!watch.takeWarning(busy))

        clock.wait(180)
        #expect(watch.observe(notStarted, autoLogin: true) != .reload)
        #expect(watch.takeWarning(notStarted))
        #expect(!watch.takeWarning(notStarted))
        #expect(watch.stateText(status: notStarted, autoLogin: true, hasLogin: true, normal: "Login") == "Not logged in (login screen not found)")
        clock.wait(600)
        #expect(watch.observe(notStarted, autoLogin: true) != .reload)
    }

    @Test func aLoginThatIsRunningIsNeverReloaded() {
        let clock = Clock()
        let watch = clock.watch()
        clock.wait(600)
        var choose = typing
        choose.loginStage = "choose"
        var failed = typing
        failed.loginStage = "failed"

        #expect(watch.observe(typing, autoLogin: true) == .none)
        #expect(watch.observe(choose, autoLogin: true) == .none)
        #expect(watch.observe(failed, autoLogin: true) == .none)
        #expect(watch.observe(notStarted, autoLogin: false) == .none)
    }

    @Test func showsNotLoggedInWithTheReasonAfterThreeMinutes() {
        let clock = Clock()
        let watch = clock.watch()
        #expect(watch.stateText(status: notStarted, autoLogin: true, hasLogin: true, normal: "Login") == nil)
        #expect(watch.stateText(status: notStarted, autoLogin: false, hasLogin: true, normal: "Login") == "Login (auto login off)")
        #expect(watch.stateText(status: notStarted, autoLogin: true, hasLogin: false, normal: "Login") == "Login (no saved login)")
        #expect(watch.stateText(status: nil, autoLogin: true, hasLogin: true, normal: "Loading") == nil)

        clock.wait(180)
        var choose = typing
        choose.loginStage = "choose"
        var failed = typing
        failed.loginStage = "failed"
        #expect(watch.stateText(status: notStarted, autoLogin: false, hasLogin: true, normal: "Login") == "Not logged in (auto login off)")
        #expect(watch.stateText(status: notStarted, autoLogin: true, hasLogin: false, normal: "Login") == "Not logged in (no saved login)")
        #expect(watch.stateText(status: notStarted, autoLogin: true, hasLogin: true, normal: "Login") == "Not logged in (login screen not found)")
        #expect(watch.stateText(status: busy, autoLogin: true, hasLogin: true, normal: "authenticating") == "Not logged in (the game stayed at authenticating)")
        #expect(watch.stateText(status: typing, autoLogin: true, hasLogin: true, normal: "Logging in") == "Not logged in (login did not finish)")
        #expect(watch.stateText(status: choose, autoLogin: true, hasLogin: true, normal: "Choose a character") == "Not logged in (choose a character)")
        #expect(watch.stateText(status: failed, autoLogin: true, hasLogin: true, normal: "Auto login stopped") == "Not logged in (auto login stopped)")
        #expect(watch.stateText(status: inWorld, autoLogin: true, hasLogin: true, normal: "In game") == nil)
    }

    @Test func countsFromTheMomentTheCharacterLeftTheWorld() {
        let clock = Clock()
        let watch = clock.watch()
        clock.wait(170)
        _ = watch.observe(inWorld, autoLogin: true)
        clock.wait(3600)
        #expect(watch.stateText(status: inWorld, autoLogin: true, hasLogin: true, normal: "In game") == nil)

        _ = watch.observe(typing, autoLogin: true)
        clock.wait(179)
        #expect(!watch.takeWarning(typing))
        clock.wait(1)
        #expect(watch.takeWarning(typing))
        #expect(watch.stateText(status: typing, autoLogin: true, hasLogin: true, normal: "Logging in") == "Not logged in (login did not finish)")
    }

    @Test func aNewWindowAfterARestartStartsWithFreshLoginState() {
        let clock = Clock()
        let before = clock.watch()
        let gate = CredentialGate(clock: { [unowned clock] in clock.now })
        #expect(gate.tryTake())
        _ = before.observe(typing, autoLogin: true)
        clock.wait(180)
        _ = before.observe(typing, autoLogin: true)
        #expect(before.takeWarning(typing))

        clock.wait(12)
        let after = clock.watch()
        let freshGate = CredentialGate(clock: { [unowned clock] in clock.now })
        #expect(freshGate.tryTake())
        #expect(after.observe(notStarted, autoLogin: true) == .sendSettings)
        #expect(after.stateText(status: notStarted, autoLogin: true, hasLogin: true, normal: "Login") == nil)
        #expect(!after.takeWarning(notStarted))
    }

    @Test func writesTheLoginStateToTheLogWithoutTheLoginDetails() {
        #expect(LoginTexts.inWorld(account: "test", character: "Hunter") == "test: in the game as Hunter.")
        #expect(LoginTexts.inWorld(account: "test", character: nil) == "test: in the game.")
        #expect(LoginTexts.warning(account: "test", reason: LoginTexts.noLoginScreen) == "test: still not in the game after 3 minutes (login screen not found).")
        #expect(LoginTexts.reloading(account: "test", reason: LoginTexts.gameStayed(phase: "authenticating")) == "test: reloading the game page once, because the login did not start (the game stayed at authenticating).")
    }
}
