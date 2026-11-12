import Foundation

public enum FirstInstallOutcome: Equatable, Sendable {
    case notDue
    case skipped
    case installed
    case failed
}

public struct FirstInstallResult {
    public let outcome: FirstInstallOutcome
    public let script: InstalledScript?
    public let error: Error?
    public let settingsError: Error?

    init(_ outcome: FirstInstallOutcome, script: InstalledScript? = nil, error: Error? = nil, settingsError: Error? = nil) {
        self.outcome = outcome
        self.script = script
        self.error = error
        self.settingsError = settingsError
    }
}

@MainActor
public enum OsbFirstInstall {
    public static func run(scripts: ScriptStore, downloader: ScriptDownloading, settings: AppSettings, osbUrl: String = BotScripts.osbUrl, allowLoopbackHttp: Bool = false) async -> FirstInstallResult {
        guard settings.osbFirstInstall == .pending else {
            return FirstInstallResult(.notDue)
        }
        if scripts.scripts.contains(where: { BotScripts.isOsb($0) || BotScripts.isNixxane($0) }) {
            return FirstInstallResult(.skipped, settingsError: finish(settings, .skipped))
        }
        do {
            let osb = try await scripts.install(fromUrl: osbUrl, downloader: downloader, allowLoopbackHttp: allowLoopbackHttp)
            return FirstInstallResult(.installed, script: osb, settingsError: finish(settings, .done))
        } catch {
            return FirstInstallResult(.failed, error: error)
        }
    }

    private static func finish(_ settings: AppSettings, _ state: OsbFirstInstallState) -> Error? {
        settings.osbFirstInstall = state
        do {
            try settings.save()
            return nil
        } catch {
            return error
        }
    }
}
