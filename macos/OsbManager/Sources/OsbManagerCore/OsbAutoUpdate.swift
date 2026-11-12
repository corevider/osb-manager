import Foundation

public enum OsbUpdateOutcome: Equatable, Sendable {
    case notApplicable
    case disabled
    case busy
    case upToDate
    case updated
    case failed
}

public struct OsbUpdateResult {
    public let outcome: OsbUpdateOutcome
    public let oldVersion: String?
    public let newVersion: String?
    public let error: Error?
    public let firstFailureInStreak: Bool

    init(_ outcome: OsbUpdateOutcome, oldVersion: String? = nil, newVersion: String? = nil, error: Error? = nil, firstFailureInStreak: Bool = false) {
        self.outcome = outcome
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.error = error
        self.firstFailureInStreak = firstFailureInStreak
    }
}

public struct OsbUpdateSchedule: Equatable {
    public static let production = OsbUpdateSchedule(firstDelay: 60, interval: 6 * 3600, busyRetry: 60)
    public static let testing = OsbUpdateSchedule(firstDelay: 3, interval: 15, busyRetry: 60)

    public let firstDelay: TimeInterval
    public let interval: TimeInterval
    public let busyRetry: TimeInterval

    public func nextDelay(after outcome: OsbUpdateOutcome) -> TimeInterval {
        outcome == .busy ? busyRetry : interval
    }
}

@MainActor
public final class OsbAutoUpdate {
    public static let maxMetaBytes = 256 << 10
    public static let metaFileName = "osb.meta.js"

    private let scripts: ScriptStore
    private let downloader: ScriptDownloading
    private let jobs: ScriptJobs
    private let enabled: () -> Bool
    private let addressOverride: String?
    private var running = false
    private var failing = false

    public init(scripts: ScriptStore, downloader: ScriptDownloading, jobs: ScriptJobs, enabled: @escaping () -> Bool, addressOverride: String? = nil) {
        self.scripts = scripts
        self.downloader = downloader
        self.jobs = jobs
        self.enabled = enabled
        self.addressOverride = addressOverride
    }

    public func check() async -> OsbUpdateResult {
        guard enabled() else { return OsbUpdateResult(.disabled) }
        guard !jobs.busy, !running else { return OsbUpdateResult(.busy) }
        running = true
        let job = jobs.begin()
        defer {
            job.end()
            running = false
        }
        return await run()
    }

    private func run() async -> OsbUpdateResult {
        guard let osb = scripts.scripts.first(where: BotScripts.isOsb), let addresses = resolveAddresses(osb) else {
            return OsbUpdateResult(.notApplicable)
        }
        let installed = osb.meta.version
        let loopback = addressOverride != nil
        do {
            let announced = try await readAnnouncedVersion(addresses.meta, osb: osb, allowLoopbackHttp: loopback)
            guard let current = UpdateVersion(installed) else {
                throw ScriptFormatError("The installed OSB version \"\(installed)\" is not understood.")
            }
            if announced <= current {
                failing = false
                return OsbUpdateResult(.upToDate, oldVersion: installed, newVersion: installed)
            }
            let updated = try await scripts.install(fromUrl: addresses.download, downloader: downloader, allowLoopbackHttp: loopback) { [scripts] meta in
                scripts.scripts.contains { $0.id == osb.id } && Self.isAcceptable(meta, osb: osb, announced: announced)
            }
            failing = false
            return OsbUpdateResult(.updated, oldVersion: installed, newVersion: updated.meta.version)
        } catch {
            let first = !failing
            failing = true
            return OsbUpdateResult(.failed, oldVersion: installed, error: error, firstFailureInStreak: first)
        }
    }

    private func resolveAddresses(_ osb: InstalledScript) -> (meta: String, download: String)? {
        if let addressOverride {
            guard let base = URL(string: addressOverride), let meta = URL(string: Self.metaFileName, relativeTo: base) else { return nil }
            return (meta.absoluteString, addressOverride)
        }
        guard let update = osb.meta.updateUrl, let download = osb.meta.downloadUrl, BotScripts.isOsbUrl(update), BotScripts.isOsbUrl(download) else {
            return nil
        }
        return (update, download)
    }

    private func readAnnouncedVersion(_ address: String, osb: InstalledScript, allowLoopbackHttp: Bool) async throws -> UpdateVersion {
        let text = try await ScriptAddress.download(address, downloader: downloader, maxBytes: Self.maxMetaBytes, allowLoopbackHttp: allowLoopbackHttp)
        let meta = try UserScriptMeta.parse(text)
        guard Self.isOsbIdentity(meta, osb: osb), let version = UpdateVersion(meta.version) else {
            throw ScriptFormatError("The update file does not announce an OSB version.")
        }
        return version
    }

    private static func isAcceptable(_ meta: UserScriptMeta, osb: InstalledScript, announced: UpdateVersion) -> Bool {
        guard isOsbIdentity(meta, osb: osb), let version = UpdateVersion(meta.version) else { return false }
        return version >= announced
    }

    private static func isOsbIdentity(_ meta: UserScriptMeta, osb: InstalledScript) -> Bool {
        meta.name == osb.meta.name && meta.namespace.caseInsensitiveCompare(BotScripts.osbNamespace) == .orderedSame
    }
}
