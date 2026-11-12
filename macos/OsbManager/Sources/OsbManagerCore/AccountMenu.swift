import Foundation

public enum AccountMenuState: Equatable, Sendable {
    case closed
    case queued
    case open
}

public enum AccountMenuAction: Equatable, Sendable {
    case add
    case startAll
    case startAllLight
    case closeAll
    case start
    case startLight
    case cancelStart
    case showWindow
    case reloadWindow
    case close
    case toggleLight
    case moveUp
    case moveDown
    case remove
}

public struct AccountMenuItem: Equatable {
    public let action: AccountMenuAction
    public let text: String
    public let target: Account?
    public let enabled: Bool
    public let separatorBefore: Bool

    public init(_ action: AccountMenuAction, _ text: String, target: Account?, enabled: Bool = true, separatorBefore: Bool = false) {
        self.action = action
        self.text = text
        self.target = target
        self.enabled = enabled
        self.separatorBefore = separatorBefore
    }
}

public enum AccountMenu {
    public static let add = "Add…"
    public static let remove = "Remove…"
    public static let moveUp = "Move up"
    public static let moveDown = "Move down"
    public static let start = "Start"
    public static let startLight = "Start light"
    public static let startAll = "Start all"
    public static let startAllLight = "Start all light"
    public static let toggleLight = "Toggle light mode"
    public static let close = "Close"
    public static let closeAll = "Close all"
    public static let showWindow = "Show window"
    public static let reloadWindow = "Reload window"
    public static let cancelStart = "Cancel start"

    public static func forRoot() -> [AccountMenuItem] {
        [
            AccountMenuItem(.add, add, target: nil),
            AccountMenuItem(.startAll, startAll, target: nil, separatorBefore: true),
            AccountMenuItem(.startAllLight, startAllLight, target: nil),
            AccountMenuItem(.closeAll, closeAll, target: nil, separatorBefore: true),
        ]
    }

    public static func forAccount(_ account: Account, state: AccountMenuState) -> [AccountMenuItem] {
        let lead: [AccountMenuItem]
        switch state {
        case .open:
            lead = [
                AccountMenuItem(.showWindow, showWindow, target: account),
                AccountMenuItem(.reloadWindow, reloadWindow, target: account),
                AccountMenuItem(.close, close, target: account),
            ]
        case .queued:
            lead = [
                AccountMenuItem(.cancelStart, cancelStart, target: account),
                AccountMenuItem(.start, start, target: account),
                AccountMenuItem(.startLight, startLight, target: account),
            ]
        case .closed:
            lead = [
                AccountMenuItem(.start, start, target: account),
                AccountMenuItem(.startLight, startLight, target: account),
            ]
        }
        return lead + [
            AccountMenuItem(.toggleLight, toggleLight, target: account, separatorBefore: true),
            AccountMenuItem(.moveUp, moveUp, target: account, separatorBefore: true),
            AccountMenuItem(.moveDown, moveDown, target: account),
            AccountMenuItem(.remove, remove, target: account, separatorBefore: true),
        ]
    }
}
