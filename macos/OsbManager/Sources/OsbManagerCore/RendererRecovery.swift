import Foundation

public enum RendererStep: Equatable {
    case none
    case reload
    case restart
    case giveUp
}

/// One account's way back when the game's renderer cannot start even after the page's own retries: reload the page
/// once, then restart the window once (when the setting allows it), then stop and ask the player. Reaching the game
/// world again proves the renderer works and starts the ladder over.
public final class RendererRecovery {
    public private(set) var reloaded = false
    public private(set) var restarted = false
    public private(set) var gaveUp = false

    public init() {}

    public func observe(previous: BotStatus?, report: BotStatus, restartAllowed: Bool) -> RendererStep {
        if report.inWorld {
            reloaded = false
            restarted = false
            gaveUp = false
            return .none
        }
        guard report.gpuFailed != nil, previous?.gpuFailed == nil else { return .none }
        if !reloaded {
            reloaded = true
            return .reload
        }
        if !restarted && restartAllowed {
            restarted = true
            return .restart
        }
        gaveUp = true
        return .giveUp
    }

    public func stateText(status: BotStatus?, waitingForSlot: Bool, normal: String) -> String? {
        if let status, status.gpuFailed != nil {
            return gaveUp ? RendererTexts.gaveUpState : RendererTexts.recoveringState
        }
        if let status, status.gpuRetryIn > 0 {
            return RendererTexts.retryingState(seconds: status.gpuRetryIn)
        }
        if waitingForSlot {
            return RendererTexts.waitingState
        }
        if status?.inWorld == true {
            return nil
        }
        if restarted {
            return "\(RendererTexts.restartedState) (\(normal))"
        }
        return reloaded ? "\(RendererTexts.reloadedState) (\(normal))" : nil
    }
}

public enum RendererTexts {
    public static let recoveringState = "Renderer failed, recovering"
    public static let gaveUpState = "Renderer failed, use Reload"
    public static let waitingState = "Waiting for another window's renderer"
    public static let restartedState = "Restarted after renderer failure"
    public static let reloadedState = "Reloaded after renderer failure"

    public static func retryingState(seconds: Int) -> String {
        "Renderer failed, retrying in \(seconds) s"
    }

    public static func retrying(account: String, retries: Int, limit: Int, seconds: Int) -> String {
        "\(account): the graphics card was full when the game started its renderer; trying again in \(seconds) s (\(retries) of \(limit > 0 ? limit : retries))."
    }

    public static func failed(account: String, reason: String) -> String {
        "\(account): the game's renderer could not start (\(reason))."
    }

    public static func step(account: String, step: RendererStep, restarted: Bool) -> String {
        switch step {
        case .reload:
            return "\(account): reloading the game page to start the renderer again."
        case .restart:
            return "\(account): restarting the game window with the same profile and saved login to start the renderer again."
        case .giveUp:
            let done = restarted ? " and a window restart" : "; automatic window restart is off"
            return "\(account): the renderer still could not start after a reload\(done). Close a game window or wait until the others have loaded, then use Reload."
        case .none:
            return ""
        }
    }
}
