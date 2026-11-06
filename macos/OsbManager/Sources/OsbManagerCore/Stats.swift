import Foundation

public struct StatsLine: Equatable {
    public var milliseconds: Int64
    public var kills: Int64
    public var experience: Int64?
    public var gold: Int64?
    public var deaths: Int64
    public var sox: Int64

    public init(milliseconds: Int64, kills: Int64, experience: Int64?, gold: Int64?, deaths: Int64, sox: Int64) {
        self.milliseconds = milliseconds
        self.kills = kills
        self.experience = experience
        self.gold = gold
        self.deaths = deaths
        self.sox = sox
    }
}

public struct StatsTotal: Equatable {
    public var milliseconds: Int64
    public var kills: Int64
    public var killsPerHour: Double?
    public var experience: Int64
    public var experiencePerHour: Double?
    public var gold: Int64
    public var goldPerHour: Double?
    public var deaths: Int64
    public var sox: Int64
}

public enum StatsTotals {
    public static func rate(_ value: Int64?, milliseconds: Int64) -> Double? {
        guard let value, milliseconds >= 30_000 else { return nil }
        return Double(value) * 3_600_000 / Double(milliseconds)
    }

    public static func sum(_ lines: [StatsLine]) -> StatsTotal {
        func total(_ rates: [Double?]) -> Double? {
            let known = rates.compactMap { $0 }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        return StatsTotal(
            milliseconds: lines.map(\.milliseconds).max() ?? 0,
            kills: lines.map(\.kills).reduce(0, +),
            killsPerHour: total(lines.map { rate($0.kills, milliseconds: $0.milliseconds) }),
            experience: lines.map { $0.experience ?? 0 }.reduce(0, +),
            experiencePerHour: total(lines.map { rate($0.experience, milliseconds: $0.milliseconds) }),
            gold: lines.map { $0.gold ?? 0 }.reduce(0, +),
            goldPerHour: total(lines.map { rate($0.gold, milliseconds: $0.milliseconds) }),
            deaths: lines.map(\.deaths).reduce(0, +),
            sox: lines.map(\.sox).reduce(0, +)
        )
    }
}

public struct TableRow: Equatable {
    public var cells: [String]
    public var bold: Bool

    public init(cells: [String], bold: Bool = false) {
        self.cells = cells
        self.bold = bold
    }
}

public struct StatsEntry {
    public var account: String
    public var character: String
    public var session: SessionStats

    public init(account: String, character: String, session: SessionStats) {
        self.account = account
        self.character = character
        self.session = session
    }
}

public enum StatsTable {
    public static let columns = ["Account", "Character", "Hunting", "Kills", "Kills/h", "XP", "XP/h", "Gold", "Gold/h", "Deaths", "SoX"]

    public static func rows(entries: [StatsEntry], drops: [SoxDrop], since: Date, locale: Locale = .current) -> [TableRow] {
        let ours = drops.filter { $0.ours && $0.at >= since }
        var rows: [TableRow] = []
        var lines: [StatsLine] = []
        for entry in entries {
            let session = entry.session
            let sox = Int64(ours.filter { $0.character.caseInsensitiveCompare(entry.character) == .orderedSame }.count)
            rows.append(TableRow(cells: [
                entry.account,
                entry.character,
                Format.duration(milliseconds: session.milliseconds),
                Format.number(session.kills, locale: locale),
                Format.perHour(session.kills, milliseconds: session.milliseconds, locale: locale),
                Format.compact(session.experience, locale: locale),
                Format.perHour(session.experience, milliseconds: session.milliseconds, locale: locale),
                Format.compact(session.gold, locale: locale),
                Format.perHour(session.gold, milliseconds: session.milliseconds, locale: locale),
                Format.number(session.deaths, locale: locale),
                Format.number(sox, locale: locale),
            ]))
            lines.append(StatsLine(milliseconds: session.milliseconds, kills: session.kills, experience: session.experience, gold: session.gold, deaths: session.deaths, sox: sox))
        }
        if rows.count > 1 {
            let total = StatsTotals.sum(lines)
            rows.append(TableRow(cells: [
                "All characters",
                "",
                Format.duration(milliseconds: total.milliseconds),
                Format.number(total.kills, locale: locale),
                Format.perHour(rate: total.killsPerHour, locale: locale),
                Format.compact(total.experience, locale: locale),
                Format.perHour(rate: total.experiencePerHour, locale: locale),
                Format.compact(total.gold, locale: locale),
                Format.perHour(rate: total.goldPerHour, locale: locale),
                Format.number(total.deaths, locale: locale),
                Format.number(total.sox, locale: locale),
            ], bold: true))
        }
        return rows
    }
}

public enum SoxTable {
    public static let columns = ["Time", "Character", "Item", "Seal", "From", "Seen by", "Went to"]

    public static func rows(drops: [SoxDrop], onlyMine: Bool, hideStar: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current) -> [TableRow] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return visible(drops, onlyMine: onlyMine, hideStar: hideStar).map {
            TableRow(cells: [formatter.string(from: $0.at), $0.character, $0.item, $0.seal, $0.monster, $0.seenBy, $0.receivedBy], bold: $0.seal == "Sun")
        }
    }

    public static func summary(drops: [SoxDrop], onlyMine: Bool, hideStar: Bool = false) -> String {
        let shown = visible(drops, onlyMine: onlyMine, hideStar: hideStar)
        let seals = hideStar ? ["Moon", "Sun"] : ["Star", "Moon", "Sun"]
        return seals.map { seal in "\(seal) \(shown.filter { $0.seal == seal }.count)" }.joined(separator: " · ")
            + (onlyMine ? " by your characters" : " announced")
            + ". The game announces SoX drops to the whole server."
    }

    public static func visible(_ drops: [SoxDrop], onlyMine: Bool, hideStar: Bool = false) -> [SoxDrop] {
        drops.filter { (!onlyMine || $0.ours) && !(hideStar && $0.seal == "Star") }.reversed()
    }
}

public enum OurCharacters {
    public static func names(reported: [String: String], accounts: [Account]) -> [String] {
        var seen: [String] = []
        for name in Array(reported.values) + accounts.map(\.character) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !seen.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                seen.append(name)
            }
        }
        return seen
    }
}

public enum CacheText {
    public static func line(_ counters: CacheCounters, locale: Locale = .current) -> String {
        "shared cache \(Format.bytes(counters.diskBytes, locale: locale)) (\(counters.packs) packs) · served from disk \(Format.bytes(counters.servedFromDisk, locale: locale)) · downloaded \(Format.bytes(counters.downloaded, locale: locale))"
            + (counters.failures > 0 ? " · \(counters.failures) fell back to the browser" : "")
    }
}

public enum FooterText {
    public static func line(botVersion: String?, cache: String? = nil) -> String {
        "Bot \(botVersion ?? Format.missing)" + (cache.map { " · \($0)" } ?? "")
    }
}
