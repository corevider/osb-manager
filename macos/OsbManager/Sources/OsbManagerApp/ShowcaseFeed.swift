import Foundation
import OsbManagerCore

@MainActor
public protocol GameView: AnyObject {
    var stateText: String { get }
    var status: BotStatus? { get }
    var light: Bool { get }
    var muted: Bool { get }
    var isHidden: Bool { get }
    var isMinimised: Bool { get }
}

extension GameView {
    public var inGame: Bool { status?.inWorld == true }
}

extension GameWindowController: GameView {}

@MainActor
public struct ShowcaseFeed {
    public let views: [String: GameView]
    public let cache: CacheCounters?
    public let startedAt: Date
    public let log: [LogEntry]

    public init(views: [String: GameView], cache: CacheCounters?, startedAt: Date, log: [LogEntry]) {
        self.views = views
        self.cache = cache
        self.startedAt = startedAt
        self.log = log
    }
}
