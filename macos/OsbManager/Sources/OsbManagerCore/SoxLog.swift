import Foundation

public struct SoxDrop: Codable, Equatable, Sendable {
    public var at: Date
    public var character: String
    public var item: String
    public var seal: String
    public var monster: String
    public var text: String
    public var ours: Bool
    public var seenBy: String
    public var receivedBy: String

    public init(at: Date, character: String, item: String, seal: String, monster: String, text: String, ours: Bool, seenBy: String, receivedBy: String = "") {
        self.at = at
        self.character = character
        self.item = item
        self.seal = seal
        self.monster = monster
        self.text = text
        self.ours = ours
        self.seenBy = seenBy
        self.receivedBy = receivedBy
    }

    private enum CodingKeys: String, CodingKey {
        case at, character, item, seal, monster, text, ours, seenBy, receivedBy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let date = SoxDateCoding.date(from: try values.decode(String.self, forKey: .at)) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: values, debugDescription: "Not a date.")
        }
        at = date
        character = try values.decode(String.self, forKey: .character)
        item = try values.decode(String.self, forKey: .item)
        seal = try values.decode(String.self, forKey: .seal)
        monster = try values.decodeIfPresent(String.self, forKey: .monster) ?? ""
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        ours = try values.decodeIfPresent(Bool.self, forKey: .ours) ?? false
        seenBy = try values.decodeIfPresent(String.self, forKey: .seenBy) ?? ""
        receivedBy = try values.decodeIfPresent(String.self, forKey: .receivedBy) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(SoxDateCoding.string(from: at), forKey: .at)
        try values.encode(character, forKey: .character)
        try values.encode(item, forKey: .item)
        try values.encode(seal, forKey: .seal)
        try values.encode(monster, forKey: .monster)
        try values.encode(text, forKey: .text)
        try values.encode(ours, forKey: .ours)
        try values.encode(seenBy, forKey: .seenBy)
        try values.encode(receivedBy, forKey: .receivedBy)
    }
}

enum SoxDateCoding {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        return formatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let baseRange = Range(match.range(at: 1), in: text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let zoneRange = Range(match.range(at: 3), in: text) {
            let zone = String(text[zoneRange])
            formatter.timeZone = zone == "Z" ? TimeZone(secondsFromGMT: 0) : offsetZone(zone)
        }
        guard let base = formatter.date(from: String(text[baseRange])) else { return nil }
        var fraction = 0.0
        if let fractionRange = Range(match.range(at: 2), in: text) {
            fraction = Double("0" + text[fractionRange]) ?? 0
        }
        return base.addingTimeInterval(fraction)
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#)

    private static func offsetZone(_ text: String) -> TimeZone? {
        let sign = text.hasPrefix("-") ? -1 : 1
        let parts = text.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60))
    }
}

public struct SoxAnnouncement: Equatable {
    public let character: String
    public let item: String
    public let seal: String
    public let monster: String
}

public struct SoxReceipt: Equatable, Sendable {
    public static let knownKeys: Set<String> = ["UIIT_MSG_STATE_GET_ITEM_EXPENDABLE", "UIIT_MSG_PARTYGET_ITEM_EXPENDABLE"]
    private static let receiveKey = try! NSRegularExpression(pattern: "^UIIT_MSG_(PARTYGET|STATE_GET)_ITEM[A-Z_]{0,40}$")

    public let key: String
    public let item: String
    public let member: String
    public let inParty: Bool
    public let count: Int64?

    public init(key: String, item: String, member: String, inParty: Bool, count: Int64?) {
        self.key = key
        self.item = item
        self.member = member
        self.inParty = inParty
        self.count = count
    }

    public var partyGet: Bool { key.hasPrefix("UIIT_MSG_PARTYGET_ITEM") }

    public static func isReceiveKey(_ key: String) -> Bool {
        receiveKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    public func receiver(ownCharacter: String?) -> String? {
        let name = partyGet ? (inParty ? member : nil) : ownCharacter
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum SoxReceiptOutcome: Equatable, Sendable {
    case unknown, repeated, matched, waiting
}

public struct SoxReceiptResult: Equatable {
    public let outcome: SoxReceiptOutcome
    public let receiver: String?
    public let drop: SoxDrop?
    public let newKey: Bool
    public let soxItem: Bool

    public var shouldLog: Bool {
        newKey || soxItem && (outcome == .unknown || outcome == .waiting)
    }
}

public final class SoxLog {
    public static let capacity = 1000
    private static let sameWindow: TimeInterval = 120
    private static let receivedAfter: TimeInterval = 600
    private static let receivedBefore: TimeInterval = 120
    private static let samePickup: TimeInterval = 10
    private static let receiptCapacity = 500
    private static let sunBanner = "SEAL OF SUN: "
    private static let seals = ["Star", "Moon", "Sun"]
    private static let announcement = try! NSRegularExpression(
        pattern: #"^(?:\(Notice\):\s*)?(?<who>.+?) has dropped (?<item>.+?)(?: \(Seal Of (?<seal>Star|Moon|Sun)\))?(?: from (?<from>.+?))?\.?$"#,
        options: [.caseInsensitive]
    )

    private let url: URL
    private let clock: () -> Date
    public private(set) var drops: [SoxDrop]
    public var onAdded: ((SoxDrop) -> Void)?
    public var onUpdated: ((SoxDrop) -> Void)?
    private var receipts: [PendingReceipt] = []
    private var keysSeen: Set<String> = []

    private struct PendingReceipt {
        let item: String
        let receiver: String
        let at: Date
        var matched = false
    }

    public init(url: URL, clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
        let stored = (try? JsonFile.read([LossyElement<SoxDrop>].self, from: url)) ?? []
        drops = Array(stored.compactMap(\.value).suffix(Self.capacity))
    }

    public static func parse(_ text: String?) -> SoxAnnouncement? {
        guard var line = text?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        let banner = line.range(of: sunBanner, options: [.caseInsensitive, .anchored]) != nil
        if banner {
            line = String(line.dropFirst(sunBanner.count))
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = announcement.firstMatch(in: line, range: range) else { return nil }
        func group(_ name: String) -> String? {
            Range(match.range(withName: name), in: line).map { String(line[$0]) }
        }
        guard group("seal") != nil || banner else { return nil }
        let seal = group("seal").flatMap { found in seals.first { $0.caseInsensitiveCompare(found) == .orderedSame } } ?? "Sun"
        return SoxAnnouncement(
            character: (group("who") ?? "").trimmingCharacters(in: .whitespaces),
            item: (group("item") ?? "").trimmingCharacters(in: .whitespaces),
            seal: seal,
            monster: (group("from") ?? "").trimmingCharacters(in: .whitespaces)
        )
    }

    @discardableResult
    public func add(_ text: String, seenBy: String, ours: [String]) -> SoxDrop? {
        guard let parsed = Self.parse(text) else { return nil }
        let now = clock()
        let duplicate = drops.contains { drop in
            let same = drop.text == text
                || drop.character.caseInsensitiveCompare(parsed.character) == .orderedSame
                && drop.item.caseInsensitiveCompare(parsed.item) == .orderedSame
                && drop.seal == parsed.seal
            return same && now.timeIntervalSince(drop.at) < Self.sameWindow
        }
        if duplicate {
            return nil
        }
        let mine = ours.contains { $0.caseInsensitiveCompare(parsed.character) == .orderedSame }
        var drop = SoxDrop(at: now, character: parsed.character, item: parsed.item, seal: parsed.seal, monster: parsed.monster, text: text, ours: mine, seenBy: seenBy)
        prune(now)
        if let index = receipts.lastIndex(where: { !$0.matched && Self.sameItem($0.item, drop.item) && now.timeIntervalSince($0.at) <= Self.receivedBefore }) {
            receipts[index].matched = true
            drop.receivedBy = receipts[index].receiver
        }
        drops.append(drop)
        if drops.count > Self.capacity {
            drops.removeFirst(drops.count - Self.capacity)
        }
        try? JsonFile.write(drops, to: url)
        onAdded?(drop)
        return drop
    }

    @discardableResult
    public func receive(_ receipt: SoxReceipt, ownCharacter: String?) -> SoxReceiptResult {
        let now = clock()
        let newKey = !SoxReceipt.knownKeys.contains(receipt.key) && keysSeen.insert(receipt.key).inserted
        let soxItem = drops.contains { Self.sameItem($0.item, receipt.item) }
        prune(now)
        guard let receiver = receipt.receiver(ownCharacter: ownCharacter) else {
            return SoxReceiptResult(outcome: .unknown, receiver: nil, drop: nil, newKey: newKey, soxItem: soxItem)
        }
        let repeated = receipts.contains {
            Self.sameItem($0.item, receipt.item) && $0.receiver.caseInsensitiveCompare(receiver) == .orderedSame && now.timeIntervalSince($0.at) < Self.samePickup
        }
        if repeated {
            return SoxReceiptResult(outcome: .repeated, receiver: receiver, drop: nil, newKey: newKey, soxItem: soxItem)
        }
        receipts.append(PendingReceipt(item: receipt.item, receiver: receiver, at: now))
        if receipts.count > Self.receiptCapacity {
            receipts.removeFirst(receipts.count - Self.receiptCapacity)
        }
        guard let index = drops.lastIndex(where: {
            $0.receivedBy.isEmpty && Self.sameItem($0.item, receipt.item) && now >= $0.at && now.timeIntervalSince($0.at) <= Self.receivedAfter
        }) else {
            return SoxReceiptResult(outcome: .waiting, receiver: receiver, drop: nil, newKey: newKey, soxItem: soxItem)
        }
        receipts[receipts.count - 1].matched = true
        drops[index].receivedBy = receiver
        try? JsonFile.write(drops, to: url)
        let updated = drops[index]
        onUpdated?(updated)
        return SoxReceiptResult(outcome: .matched, receiver: receiver, drop: updated, newKey: newKey, soxItem: soxItem)
    }

    public func clear() throws {
        drops.removeAll()
        receipts.removeAll()
        try JsonFile.write(drops, to: url)
    }

    private static func sameItem(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    private func prune(_ now: Date) {
        receipts.removeAll { now.timeIntervalSince($0.at) > Self.receivedAfter }
    }
}
