import Foundation

public enum GameWindowState {
    public static func text(failure: String?, browserReady: Bool, everReported: Bool, status: BotStatus?) -> String {
        if let failure {
            return failure
        }
        guard let status else {
            return browserReady ? (everReported ? "Not responding" : "Loading") : "Starting"
        }
        let light = status.light ? " (light)" : status.lightWaiting ? " (light after loading)" : ""
        if status.inWorld {
            return (status.dead ? "Dead" : "In game") + light
        }
        let login: String? = switch status.loginStage {
        case "title", "server", "credentials", "connecting", "retry", "character", "entering": "Logging in"
        case "choose": "Choose a character"
        case "failed": "Auto login stopped"
        default: nil
        }
        if let login {
            return login + light
        }
        let phase: String = switch status.phase {
        case nil: "Loading"
        case "signed-out": "Login"
        case "character-select": "Character select"
        case "world": "Entering world"
        default: status.phase ?? "Loading"
        }
        return phase + light
    }

    public static func visibility(hidden: Bool, minimised: Bool) -> String {
        minimised ? "minimised" : hidden ? "hidden" : "visible"
    }

    public static func withVisibility(_ text: String, hidden: Bool, minimised: Bool) -> String {
        hidden || minimised ? "\(text) (\(visibility(hidden: hidden, minimised: minimised)))" : text
    }

    public static func botColumn(_ status: BotStatus?) -> String {
        guard let status else { return "" }
        if status.botVersion == nil { return "No bot" }
        if status.townTrip { return "Town trip" }
        return status.hunting ? "Hunting" : "Stopped"
    }
}
