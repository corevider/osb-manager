import Foundation

public enum AccountStates {
    public static let offline = "offline"
    public static let login = "login"
    public static let loading = "loading"
    public static let idle = "idle"
    public static let hunting = "hunting"
    public static let town = "town"
    public static let dead = "dead"
    public static let stopped = "stopped"
    public static let unknown = "unknown"

    private static let loginStages: Set<String> = ["title", "server", "credentials", "connecting", "retry", "character", "entering", "choose", "failed"]

    public static func map(_ status: BotStatus) -> String {
        if status.inWorld {
            if status.dead { return dead }
            if status.botVersion == nil { return idle }
            if status.townTrip { return town }
            return status.hunting ? hunting : stopped
        }
        if let stage = status.loginStage, loginStages.contains(stage) {
            return login
        }
        switch status.phase {
        case nil, "world": return loading
        case "signed-out", "character-select": return login
        default: return unknown
        }
    }
}
