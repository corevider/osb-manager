import Foundation
import OsbManagerApp
import OsbManagerCore

struct ShotSize: Decodable {
    let width: Double
    let height: Double
}

struct ShotCrop: Decodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct FixtureSession: Decodable {
    let milliseconds: Int64
    let kills: Int64
    let deaths: Int64
    let experience: Int64?
    let gold: Int64?
}

struct FixtureStatus: Decodable {
    let botVersion: String?
    let phase: String?
    let character: String?
    let inWorld: Bool?
    let level: Int?
    let gold: Int64?
    let hpPercent: Double?
    let mpPercent: Double?
    let region: Int?
    let hunting: Bool?
    let townTrip: Bool?
    let light: Bool?
    let returnScrolls: Int?
    let reverseScrolls: Int?
    let linked: Bool?
    let session: FixtureSession?

    var botStatus: BotStatus {
        var status = BotStatus()
        status.botVersion = botVersion
        status.phase = phase
        status.character = character
        status.inWorld = inWorld ?? false
        status.level = level
        status.gold = gold
        status.hpPercent = hpPercent
        status.mpPercent = mpPercent
        status.region = region
        status.hunting = hunting ?? false
        status.townTrip = townTrip ?? false
        status.light = light ?? false
        status.returnScrolls = returnScrolls
        status.reverseScrolls = reverseScrolls
        status.linked = linked ?? false
        status.session = session.map {
            SessionStats(milliseconds: $0.milliseconds, kills: $0.kills, deaths: $0.deaths, experience: $0.experience, gold: $0.gold)
        }
        return status
    }
}

struct FixtureWindow: Decodable {
    let state: String
    let light: Bool
    let hidden: Bool
    let status: FixtureStatus
}

struct FixtureAccount: Decodable {
    let id: String
    let name: String
    let loginId: String
    let server: String
    let character: String
    let autoLogin: Bool
    let savedPassword: Bool
    let startLight: Bool
    let dataStoreId: UUID
    let window: FixtureWindow?

    var account: Account {
        Account(id: id, name: name, startLight: startLight, dataStoreId: dataStoreId, loginId: loginId, server: server, character: character, autoLogin: autoLogin)
    }
}

struct FixtureLogLine: Decodable {
    let time: String
    let level: String
    let message: String
}

struct FixtureCache: Decodable {
    let diskBytes: Int64
    let packs: Int
    let servedFromDisk: Int64
    let downloaded: Int64
    let failures: Int64
}

struct FixtureShot: Decodable {
    let file: String
    let tab: String
    let size: ShotSize
    let crop: ShotCrop?
}

@MainActor
final class FixtureView: GameView {
    let stateText: String
    let status: BotStatus?
    let light: Bool
    let muted: Bool
    let isHidden: Bool
    let isMinimised = false

    init(window: FixtureWindow) {
        let status = window.status.botStatus
        self.status = status
        light = window.light
        muted = window.light
        isHidden = window.hidden
        let normal = GameWindowState.text(failure: nil, browserReady: true, everReported: true, status: status)
        stateText = GameWindowState.withVisibility(normal, hidden: window.hidden, minimised: false)
    }
}

struct ShotFixtureError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct ShotFixture: Decodable {
    static let passwordMarker = "screenshot-fixture-no-password"

    let scale: Double
    let sessionStart: String
    let selected: String
    let hideStar: Bool
    let accounts: [FixtureAccount]
    let sox: [SoxDrop]
    let cache: FixtureCache
    let log: [FixtureLogLine]
    let macShots: [FixtureShot]

    static func load(_ url: URL) throws -> ShotFixture {
        do {
            return try JSONDecoder().decode(ShotFixture.self, from: Data(contentsOf: url))
        } catch {
            throw ShotFixtureError("\(url.lastPathComponent) could not be read: \(error)")
        }
    }

    func writeData(paths: AppPaths) throws {
        try paths.ensureCreated()
        let settings = AppSettings.load(from: paths.settingsFile)
        settings.checkForUpdates = false
        settings.hideStarSox = hideStar
        try settings.save()
        try JSONEncoder().encode(sox).write(to: paths.soxFile, options: .atomic)
        try JSONEncoder().encode(accounts.map(\.account)).write(to: paths.accountsFile, options: .atomic)
    }

    func credentials() throws -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        for account in accounts where account.savedPassword {
            try store.save(password: Self.passwordMarker, accountId: account.id)
        }
        return store
    }

    var reportedCharacters: [String: String] {
        accounts.reduce(into: [:]) { names, account in
            if let character = account.window?.status.character {
                names[account.id] = character
            }
        }
    }

    var selectedId: String? {
        accounts.first { $0.name == selected }?.id
    }

    @MainActor
    func feed() throws -> ShowcaseFeed {
        var views: [String: GameView] = [:]
        for account in accounts {
            guard let window = account.window else { continue }
            let view = FixtureView(window: window)
            let expected = GameWindowState.withVisibility(window.state, hidden: window.hidden, minimised: false)
            guard view.stateText == expected else {
                throw ShotFixtureError("\(account.name): the state \"\(window.state)\" does not match its bot report (\"\(view.stateText)\").")
            }
            views[account.id] = view
        }
        let start = try date(sessionStart)
        let day = String(sessionStart.prefix(10))
        let entries = try log.map { line in
            LogEntry(time: try date("\(day)T\(line.time)"), level: line.level, message: macWording(line.message))
        }
        let counters = CacheCounters(diskBytes: cache.diskBytes, packs: cache.packs, servedFromDisk: cache.servedFromDisk, downloaded: cache.downloaded, failures: cache.failures)
        return ShowcaseFeed(views: views, cache: counters, startedAt: start, log: entries)
    }

    private func macWording(_ message: String) -> String {
        accounts.reduce(message) { text, account in
            text.replacingOccurrences(of: "profile acc-\(account.id)", with: "profile \(account.dataStoreId.uuidString.lowercased())")
        }
    }

    private func date(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = formatter.date(from: text) else { throw ShotFixtureError("\(text) is not a local date and time.") }
        return date
    }
}
