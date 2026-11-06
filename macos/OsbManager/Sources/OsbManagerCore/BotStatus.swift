import Foundation

public struct SessionStats: Equatable, Sendable {
    public var milliseconds: Int64
    public var kills: Int64
    public var deaths: Int64
    public var experience: Int64?
    public var gold: Int64?
    public var sox: Int64

    public init(milliseconds: Int64, kills: Int64, deaths: Int64, experience: Int64?, gold: Int64?, sox: Int64 = 0) {
        self.milliseconds = milliseconds
        self.kills = kills
        self.deaths = deaths
        self.experience = experience
        self.gold = gold
        self.sox = sox
    }
}

public struct BotStatus: Equatable, Sendable {
    public static let maxMessageLength = 16 * 1024
    static let maxText = 64
    static let maxDepth = 4

    public var botVersion: String?
    public var phase: String?
    public var character: String?
    public var inWorld = false
    public var dead = false
    public var level: Int?
    public var gold: Int64?
    public var hpPercent: Double?
    public var mpPercent: Double?
    public var region: Int?
    public var hunting = false
    public var townTrip = false
    public var light = false
    public var lightWaiting = false
    public var gpuRetries = 0
    public var gpuFailed: String?
    public var gpuRetryLimit = 0
    public var gpuRetryIn = 0
    public var returnScrolls: Int?
    public var reverseScrolls: Int?
    public var drops: [String] = []
    public var received: [SoxReceipt] = []
    public var linked = false
    public var session: SessionStats?
    public var loginStage: String?
    public var loginMessage: String?

    public init() {}

    public static func messageType(of json: String?) -> String? {
        guard let root = BoundedJson.object(json) else { return nil }
        return BoundedJson.text(root, "type")
    }

    public static func parse(_ json: String?) -> BotStatus? {
        guard let root = BoundedJson.object(json), BoundedJson.text(root, "type") == "status" else { return nil }
        var status = BotStatus()
        status.botVersion = BoundedJson.text(root, "bot")
        status.phase = BoundedJson.text(root, "phase")
        status.character = BoundedJson.text(root, "character")
        status.inWorld = BoundedJson.flag(root, "inWorld")
        status.dead = BoundedJson.flag(root, "dead")
        status.level = BoundedJson.whole(root, "level", min: 0, max: 1000).map { Int($0) }
        status.gold = BoundedJson.integer(root, "gold")
        status.hpPercent = BoundedJson.percent(root, "hp")
        status.mpPercent = BoundedJson.percent(root, "mp")
        status.region = BoundedJson.whole(root, "region", min: 0, max: Double(Int32.max)).map { Int($0) }
        status.hunting = BoundedJson.flag(root, "hunting")
        status.townTrip = BoundedJson.flag(root, "town")
        status.light = BoundedJson.flag(root, "light")
        status.lightWaiting = BoundedJson.flag(root, "lightWaiting")
        status.linked = BoundedJson.flag(root, "linked")
        if let gpu = root["gpu"] as? [String: Any] {
            status.gpuRetries = BoundedJson.whole(gpu, "retries", min: 0, max: 100).map { Int($0) } ?? 0
            status.gpuFailed = BoundedJson.text(gpu, "failed", maxLength: 200)
            status.gpuRetryLimit = BoundedJson.whole(gpu, "limit", min: 0, max: 100).map { Int($0) } ?? 0
            status.gpuRetryIn = BoundedJson.whole(gpu, "retryIn", min: 0, max: 3600).map { Int($0) } ?? 0
        }
        if let session = root["session"] as? [String: Any] {
            status.session = SessionStats(
                milliseconds: BoundedJson.whole(session, "ms", min: 0, max: BoundedJson.largest) ?? 0,
                kills: BoundedJson.whole(session, "kills", min: 0, max: BoundedJson.largest) ?? 0,
                deaths: BoundedJson.whole(session, "deaths", min: 0, max: BoundedJson.largest) ?? 0,
                experience: BoundedJson.integer(session, "xp"),
                gold: BoundedJson.integer(session, "gold"),
                sox: BoundedJson.whole(session, "sox", min: 0, max: BoundedJson.largest) ?? 0
            )
        }
        if let scrolls = root["scrolls"] as? [String: Any] {
            status.returnScrolls = BoundedJson.whole(scrolls, "ret", min: 0, max: 1_000_000).map { Int($0) }
            status.reverseScrolls = BoundedJson.whole(scrolls, "reverse", min: 0, max: 1_000_000).map { Int($0) }
        }
        if let drops = root["drops"] as? [Any] {
            status.drops = drops.compactMap { $0 as? String }
                .prefix(20)
                .map { BoundedJson.clean($0, maxLength: 300) }
                .filter { !$0.isEmpty }
        }
        if let received = root["received"] as? [Any] {
            status.received = received.compactMap { $0 as? [String: Any] }.prefix(20).compactMap(receipt)
        }
        if let login = root["login"] as? [String: Any] {
            status.loginStage = BoundedJson.text(login, "stage")
            status.loginMessage = BoundedJson.text(login, "message", maxLength: 200)
        }
        return status
    }

    private static func receipt(_ object: [String: Any]) -> SoxReceipt? {
        guard let key = BoundedJson.text(object, "key"), let item = BoundedJson.text(object, "item"), SoxReceipt.isReceiveKey(key) else { return nil }
        return SoxReceipt(
            key: key,
            item: item,
            member: BoundedJson.text(object, "member") ?? "",
            inParty: BoundedJson.flag(object, "inParty"),
            count: BoundedJson.whole(object, "count", min: 0, max: Double(Int32.max))
        )
    }
}

enum BoundedJson {
    static let largest = 9.0e18

    static func object(_ json: String?) -> [String: Any]? {
        guard let json, json.utf16.count <= BotStatus.maxMessageLength,
              let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              depth(of: value) <= BotStatus.maxDepth else { return nil }
        return value as? [String: Any]
    }

    static func depth(of value: Any) -> Int {
        if let dictionary = value as? [String: Any] {
            return 1 + (dictionary.values.map(depth(of:)).max() ?? 0)
        }
        if let array = value as? [Any] {
            return 1 + (array.map(depth(of:)).max() ?? 0)
        }
        return 0
    }

    static func clean(_ text: String, maxLength: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(maxLength)))
    }

    static func text(_ object: [String: Any], _ name: String, maxLength: Int = BotStatus.maxText) -> String? {
        guard let value = object[name] as? String else { return nil }
        let cleaned = clean(value, maxLength: maxLength)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func flag(_ object: [String: Any], _ name: String) -> Bool {
        guard let number = object[name] as? NSNumber, isBoolean(number) else { return false }
        return number.boolValue
    }

    static func number(_ object: [String: Any], _ name: String) -> Double? {
        guard let number = object[name] as? NSNumber, !isBoolean(number) else { return nil }
        let value = number.doubleValue
        return value.isNaN ? nil : value
    }

    static func whole(_ object: [String: Any], _ name: String, min: Double, max: Double) -> Int64? {
        guard let value = number(object, name), value >= min, value <= max, value < largest else { return nil }
        return Int64(value.rounded(.down))
    }

    static func percent(_ object: [String: Any], _ name: String) -> Double? {
        guard let value = number(object, name), value.isFinite else { return nil }
        return Swift.min(Swift.max(value, 0), 100)
    }

    static func integer(_ object: [String: Any], _ name: String) -> Int64? {
        guard let value = text(object, name) else { return nil }
        let digits = value.hasPrefix("-") || value.hasPrefix("+") ? String(value.dropFirst()) : value
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int64(value)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
