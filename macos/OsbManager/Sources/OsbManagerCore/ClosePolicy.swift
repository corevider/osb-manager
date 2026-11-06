import Foundation

public enum ClosePolicy {
    public static func windowQuestion(accountName: String, inGame: Bool) -> String? {
        inGame ? "Close \(accountName)? The character leaves the game." : nil
    }

    public static func allWindowsQuestion(inGameCount: Int, verb: String) -> String? {
        guard inGameCount > 0, let first = verb.first else { return nil }
        let subject = inGameCount == 1 ? "1 character is" : "\(inGameCount) characters are"
        return "\(subject) in the game. \(first.uppercased() + verb.dropFirst()) all game windows?"
    }
}
