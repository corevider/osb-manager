import Foundation

public enum LoginAction: Equatable {
    case none
    case sendSettings
    case reload
}

/// Watches one game window on its way into the world. It sends the login settings again while the page reports that
/// automatic login has not started, reloads a page stuck outside the login once (and gives the new page the same
/// time), and names the reason when the account is still not in the world a few minutes after the window started or
/// the character left the world.
public final class LoginWatch {
    public static let notLoggedInAfter: TimeInterval = 180
    public static let settingsGap: TimeInterval = 15

    private static let activeStages: Set<String> = ["title", "server", "credentials", "connecting", "retry", "character", "entering"]

    private let clock: () -> Date
    private var outSince: Date?
    private var lastSettings = Date.distantPast
    private var reloaded = false
    private var warned = false

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        outSince = clock()
    }

    public func takeWarning(_ status: BotStatus?) -> Bool {
        guard !warned, late(status) else { return false }
        warned = true
        return true
    }

    public func observe(_ report: BotStatus, autoLogin: Bool) -> LoginAction {
        let now = clock()
        if report.inWorld {
            outSince = nil
            reloaded = false
            warned = false
            return .none
        }
        let since = outSince ?? now
        outSince = since
        guard autoLogin else { return .none }
        let notStarted = report.loginStage == nil || report.loginStage == "off"
        if !reloaded && now.timeIntervalSince(since) >= Self.notLoggedInAfter && (notStarted || report.loginStage == "waiting") {
            reloaded = true
            outSince = now
            return .reload
        }
        if notStarted && now.timeIntervalSince(lastSettings) >= Self.settingsGap {
            lastSettings = now
            return .sendSettings
        }
        return .none
    }

    public func stateText(status: BotStatus?, autoLogin: Bool, hasLogin: Bool, normal: String) -> String? {
        guard let status, !status.inWorld, outSince != nil else { return nil }
        let why = reason(status: status, autoLogin: autoLogin, hasLogin: hasLogin)
        if late(status) {
            return "\(LoginTexts.notLoggedIn) (\(why))"
        }
        if !autoLogin || !hasLogin {
            let notStarted = status.loginStage == nil || status.loginStage == "off"
            return notStarted && status.phase == "signed-out" ? "\(normal) (\(why))" : nil
        }
        return status.loginStage == "waiting" ? "\(LoginTexts.loggingIn) (\(status.phase ?? "game busy"))" : nil
    }

    public func reason(status: BotStatus, autoLogin: Bool, hasLogin: Bool) -> String {
        if !autoLogin {
            return LoginTexts.autoLoginOff
        }
        if !hasLogin {
            return LoginTexts.noSavedLogin
        }
        switch status.loginStage {
        case "failed": return LoginTexts.stopped
        case "choose": return LoginTexts.chooseCharacter
        case "waiting": return LoginTexts.gameStayed(phase: status.phase)
        case let stage? where Self.activeStages.contains(stage): return LoginTexts.didNotFinish
        default: return LoginTexts.noLoginScreen
        }
    }

    private func late(_ status: BotStatus?) -> Bool {
        guard let status, !status.inWorld, let outSince else { return false }
        return clock().timeIntervalSince(outSince) >= Self.notLoggedInAfter
    }
}

public enum LoginTexts {
    public static let notLoggedIn = "Not logged in"
    public static let loggingIn = "Logging in"
    public static let autoLoginOff = "auto login off"
    public static let noSavedLogin = "no saved login"
    public static let stopped = "auto login stopped"
    public static let chooseCharacter = "choose a character"
    public static let didNotFinish = "login did not finish"
    public static let noLoginScreen = "login screen not found"

    public static func gameStayed(phase: String?) -> String {
        phase.map { "the game stayed at \($0)" } ?? "the game did not answer"
    }

    public static func warning(account: String, reason: String) -> String {
        "\(account): still not in the game after \(Int(LoginWatch.notLoggedInAfter / 60)) minutes (\(reason))."
    }

    public static func reloading(account: String, reason: String) -> String {
        "\(account): reloading the game page once, because the login did not start (\(reason))."
    }

    public static func inWorld(account: String, character: String?) -> String {
        character.map { "\(account): in the game as \($0)." } ?? "\(account): in the game."
    }
}
