import Foundation

public enum PageStep: Equatable {
    case none
    case reload
    case restart
    case giveUp
}

public enum PageProblem: Equatable {
    case none
    case silent
    case crashed
}

/// One account's way back when its game page stops responding or its page process ends. It only ever acts on that
/// account's own window: wait, reload the page, restart the window with the same profile, then stop and ask the player.
/// A page that reports again is fine; reaching the game world starts the ladder over. It is kept across a window restart.
public final class PageHealth {
    public static let silenceLimit: TimeInterval = 60
    public static let proofLimit: TimeInterval = 90
    public static let quietShown: TimeInterval = 10

    public private(set) var reloaded = false
    public private(set) var restarted = false
    public private(set) var gaveUp = false
    public private(set) var lastProblem = PageProblem.none

    private let clock: () -> Date
    private var lastSign: Date
    private var reported = false
    private var unresponsiveSince: Date?
    private var crashed = false
    private var stepAt: Date?

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        lastSign = clock()
    }

    public var unresponsive: Bool { unresponsiveSince != nil }

    public func pageStarted() {
        let now = clock()
        lastSign = now
        reported = false
        crashed = false
        unresponsiveSince = nil
        if stepAt != nil {
            stepAt = now
        }
    }

    @discardableResult
    public func reported(inWorld: Bool) -> Bool {
        let wasUnresponsive = unresponsiveSince != nil
        lastSign = clock()
        reported = true
        unresponsiveSince = nil
        crashed = false
        stepAt = nil
        gaveUp = false
        if inWorld {
            reloaded = false
            restarted = false
        }
        return wasUnresponsive
    }

    @discardableResult
    public func markUnresponsive() -> Bool {
        guard unresponsiveSince == nil else { return false }
        unresponsiveSince = clock()
        return true
    }

    public func markCrashed() {
        crashed = true
    }

    public func tick() -> PageStep {
        guard !gaveUp else { return .none }
        let now = clock()
        if let stepAt {
            return now.timeIntervalSince(stepAt) >= Self.proofLimit ? next(.silent) : .none
        }
        if crashed {
            return next(.crashed)
        }
        let silent = now.timeIntervalSince(lastSign) >= Self.silenceLimit
        return silent && (reported || unresponsiveSince != nil) ? next(.silent) : .none
    }

    public func stateText(normal: String, inWorld: Bool) -> String? {
        if gaveUp {
            return PageTexts.gaveUpState
        }
        if crashed {
            return PageTexts.crashedState
        }
        let quiet = clock().timeIntervalSince(lastSign)
        if stepAt == nil && (unresponsiveSince != nil || reported && quiet >= Self.quietShown) {
            return PageTexts.waitingState(seconds: Int(quiet))
        }
        if inWorld {
            return nil
        }
        if restarted {
            return "\(PageTexts.restartedState) (\(normal))"
        }
        return reloaded ? "\(PageTexts.reloadedState) (\(normal))" : nil
    }

    private func next(_ problem: PageProblem) -> PageStep {
        lastProblem = problem
        crashed = false
        unresponsiveSince = nil
        if !reloaded {
            reloaded = true
            stepAt = clock()
            return .reload
        }
        if !restarted {
            restarted = true
            stepAt = clock()
            return .restart
        }
        gaveUp = true
        stepAt = nil
        return .giveUp
    }
}

public enum PageTexts {
    public static let crashedState = "Page crashed, reloading"
    public static let gaveUpState = "Not responding, use Reload"
    public static let reloadedState = "Reloaded after the page stopped responding"
    public static let restartedState = "Restarted after the page stopped responding"

    public static func waitingState(seconds: Int) -> String {
        "Not responding for \(seconds) s, waiting"
    }

    public static func responding(account: String) -> String {
        "\(account): the page responds again."
    }

    public static func step(account: String, step: PageStep, problem: PageProblem) -> String {
        switch step {
        case .reload where problem == .crashed:
            return "\(account): the page process ended; reloading this window only."
        case .reload:
            return "\(account): the page did not respond for \(Int(PageHealth.silenceLimit)) s; reloading this window only."
        case .restart:
            return "\(account): the page still did not respond after a reload; restarting this window with the same profile and saved login."
        case .giveUp:
            return "\(account): the page still does not respond after a reload and a window restart. Use Reload, or close and start this account again."
        case .none:
            return ""
        }
    }
}

/// The accounts whose game window was closed only to be opened again. A restart names exactly one account, so a
/// problem in one window never closes or restarts another. Closing all windows or quitting cancels every restart.
public final class WindowRestarts {
    private var restarting: Set<String> = []

    public init() {}

    public func isRestarting(_ accountId: String) -> Bool {
        restarting.contains(accountId)
    }

    @discardableResult
    public func request(_ accountId: String) -> Bool {
        restarting.insert(accountId).inserted
    }

    public func takeOnClose(_ accountId: String, quitting: Bool) -> Bool {
        restarting.remove(accountId) != nil && !quitting
    }

    public func clear() {
        restarting.removeAll()
    }
}
