import CryptoKit
import Foundation

public struct AccountSnapshot: Equatable, Sendable {
    public let accountId: String
    public let server: String
    public let status: BotStatus
    public let receivedAt: Date

    public init(accountId: String, server: String, status: BotStatus, receivedAt: Date) {
        self.accountId = accountId
        self.server = server
        self.status = status
        self.receivedAt = receivedAt
    }
}

public protocol StatusSource: Sendable {
    func snapshot() async throws -> [AccountSnapshot]
}

struct ScrollsDto: Codable, Equatable {
    var returnScrolls: Int?
    var reverseScrolls: Int?

    enum CodingKeys: String, CodingKey {
        case returnScrolls = "return"
        case reverseScrolls = "reverse"
    }
}

struct CharacterDto: Codable, Equatable {
    var name: String?
    var server: String?
}

struct SessionDto: Codable, Equatable {
    var key: String
    var ms: Int64
    var kills: Int64
    var deaths: Int64
    var xp: String?
    var gold: String?
    var sox: Int64
}

struct AccountDto: Codable, Equatable {
    var slot: String
    var state: String
    var level: Int?
    var gold: String?
    var hpPct: Int?
    var mpPct: Int?
    var scrolls: ScrollsDto?
    var botVersion: String?
    var character: CharacterDto?
    var session: SessionDto?

    enum CodingKeys: String, CodingKey {
        case slot, state, level, gold, scrolls, character, session
        case hpPct = "hp_pct"
        case mpPct = "mp_pct"
        case botVersion = "bot_version"
    }
}

struct TelemetryDto: Codable, Equatable {
    var schema = TelemetryLimits.schema
    var appVersion: String
    var accounts: [AccountDto]

    enum CodingKeys: String, CodingKey {
        case schema, accounts
        case appVersion = "app_version"
    }
}

public struct TelemetryBatch {
    public let body: Data
    public let accounts: Int
    public let commit: () -> Void
}

public final class TelemetryPayloadBuilder {
    private struct SessionTrack {
        let key: String
        let milliseconds: Int64
        let kills: Int64
        let deaths: Int64
    }

    private struct Reported {
        let slot: String
        let fingerprint: String
        let sentAt: Date
    }

    private struct Entry {
        let dto: AccountDto
        let id: String
        let fingerprint: String
    }

    private let appVersion: String
    private let now: () -> Date
    private let randomBytes: (Int) -> [UInt8]
    private let maxBytes: Int
    private var sessions: [String: SessionTrack] = [:]
    private var reported: [String: Reported] = [:]

    public init(
        appVersion: String,
        now: @escaping () -> Date = { Date() },
        randomBytes: @escaping (Int) -> [UInt8] = PrivacySettings.randomBytes,
        maxBytes: Int = TelemetryLimits.softBodyBytes
    ) {
        self.appVersion = appVersion
        self.now = now
        self.randomBytes = randomBytes
        self.maxBytes = min(maxBytes, TelemetryLimits.maxBodyBytes)
    }

    public static func slot(installKey: Data, accountId: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(("slot:" + accountId).utf8), using: SymmetricKey(data: installKey))
        return hex(Array(code).prefix(8))
    }

    public func build(_ snapshots: [AccountSnapshot], installKey: Data, includeCharacters: Bool) -> TelemetryBatch? {
        let moment = now()
        let fresh = snapshots
            .filter { moment.timeIntervalSince($0.receivedAt) < TelemetryLimits.statusMaxAge }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(TelemetryLimits.maxAccounts)
        var entries: [Entry] = []
        for snapshot in fresh {
            let dto = describe(snapshot, installKey: installKey, includeCharacters: includeCharacters)
            let fingerprint = Self.fingerprint(of: dto)
            if let previous = reported[snapshot.accountId], previous.fingerprint == fingerprint, dto.session == nil,
               moment.timeIntervalSince(previous.sentAt) < TelemetryLimits.unchangedResend {
                continue
            }
            entries.append(Entry(dto: dto, id: snapshot.accountId, fingerprint: fingerprint))
        }
        let present = Set(fresh.map(\.accountId))
        for (id, previous) in reported.sorted(by: { $0.key < $1.key }) where !present.contains(id) {
            if entries.count < TelemetryLimits.maxAccounts {
                entries.append(Entry(dto: AccountDto(slot: previous.slot, state: AccountStates.offline), id: id, fingerprint: ""))
            }
        }
        guard !entries.isEmpty else { return nil }
        var body = serialize(entries.map(\.dto))
        while body.count > maxBytes && entries.count > 1 {
            entries.removeLast()
            body = serialize(entries.map(\.dto))
        }
        guard body.count <= TelemetryLimits.maxBodyBytes else { return nil }
        let sent = entries
        return TelemetryBatch(body: body, accounts: sent.count) { [self] in
            for entry in sent {
                if entry.dto.state == AccountStates.offline {
                    reported[entry.id] = nil
                    sessions[entry.id] = nil
                } else {
                    reported[entry.id] = Reported(slot: entry.dto.slot, fingerprint: entry.fingerprint, sentAt: moment)
                }
            }
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func fingerprint(of dto: AccountDto) -> String {
        var stable = dto
        stable.session = nil
        return (try? String(decoding: encoder().encode(stable), as: UTF8.self)) ?? ""
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func serialize(_ accounts: [AccountDto]) -> Data {
        (try? Self.encoder().encode(TelemetryDto(appVersion: appVersion, accounts: accounts))) ?? Data()
    }

    private func describe(_ snapshot: AccountSnapshot, installKey: Data, includeCharacters: Bool) -> AccountDto {
        let status = snapshot.status
        let world = status.inWorld
        let returnScrolls = Self.scroll(status.returnScrolls)
        let reverseScrolls = Self.scroll(status.reverseScrolls)
        let scrolls = world && (returnScrolls != nil || reverseScrolls != nil)
            ? ScrollsDto(returnScrolls: returnScrolls, reverseScrolls: reverseScrolls)
            : nil
        return AccountDto(
            slot: Self.slot(installKey: installKey, accountId: snapshot.accountId),
            state: AccountStates.map(status),
            level: status.level.flatMap { (1...255).contains($0) ? $0 : nil },
            gold: world ? status.gold.flatMap { $0 >= 0 ? String($0) : nil } : nil,
            hpPct: world ? Self.percent(status.hpPercent) : nil,
            mpPct: world ? Self.percent(status.mpPercent) : nil,
            scrolls: scrolls,
            botVersion: Self.botVersion(status.botVersion),
            character: includeCharacters ? Self.character(name: status.character, server: snapshot.server) : nil,
            session: session(for: snapshot.accountId, stats: status.session)
        )
    }

    private func session(for accountId: String, stats: SessionStats?) -> SessionDto? {
        guard let stats else {
            sessions[accountId] = nil
            return nil
        }
        let previous = sessions[accountId]
        let restarted = previous.map { stats.milliseconds < $0.milliseconds || stats.kills < $0.kills || stats.deaths < $0.deaths } ?? true
        let key = restarted ? Self.hex(randomBytes(8)) : (previous?.key ?? Self.hex(randomBytes(8)))
        sessions[accountId] = SessionTrack(key: key, milliseconds: stats.milliseconds, kills: stats.kills, deaths: stats.deaths)
        return SessionDto(
            key: key,
            ms: min(max(stats.milliseconds, 0), TelemetryLimits.maxSessionMilliseconds),
            kills: min(max(stats.kills, 0), TelemetryLimits.maxCounter),
            deaths: min(max(stats.deaths, 0), TelemetryLimits.maxCounter),
            xp: stats.experience.flatMap { $0 >= 0 ? String($0) : nil },
            gold: stats.gold.flatMap { $0 >= 0 ? String($0) : nil },
            sox: min(max(stats.sox, 0), TelemetryLimits.maxCounter)
        )
    }

    private static func botVersion(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 32,
              value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 43 || $0 == 45 })
        else { return nil }
        return value
    }

    private static func character(name: String?, server: String) -> CharacterDto? {
        let characterName = trimmedName(name)
        let serverName = trimmedName(server)
        return characterName == nil && serverName == nil ? nil : CharacterDto(name: characterName, server: serverName)
    }

    private static func trimmedName(_ value: String?) -> String? {
        guard let value else { return nil }
        return StrictJson.cleanText(value, maxLength: TelemetryLimits.maxNameLength)
    }

    private static func percent(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(min(max(value.rounded(.toNearestOrEven), 0), 100))
    }

    private static func scroll(_ value: Int?) -> Int? {
        guard let value, (0...TelemetryLimits.maxScrolls).contains(value) else { return nil }
        return value
    }
}
