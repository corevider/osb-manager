import Foundation

public enum TelemetryLimits {
    public static let consentVersion = 2
    public static let consentTextVersion = "2026-11-12.1"
    public static let appName = "manager-mac"
    public static let osName = "macos"
    public static let releaseBaseUrl = "https://api.osb.lol/v1"
    public static let keychainService = "com.corevider.osb-manager.install-key"
    public static let schema = 1

    public static let minIntervalSeconds = 300
    public static let maxIntervalSeconds = 86400
    public static let defaultIntervalSeconds = 600
    public static let maxMessageLength = 200
    public static let maxAccounts = 20
    public static let maxBodyBytes = 64 * 1024
    public static let softBodyBytes = 60_000
    public static let maxResponseBytes = 64 * 1024
    public static let maxExportBytes = 64 * 1024 * 1024
    public static let maxSessionMilliseconds: Int64 = 2_592_000_000
    public static let maxCounter: Int64 = 10_000_000
    public static let maxScrolls = 100_000
    public static let maxNameLength = 32

    public static let requestTimeout: Duration = .seconds(15)
    public static let configRefresh: Duration = .seconds(6 * 3600)
    public static let configMaxAge: TimeInterval = 24 * 3600
    public static let statusMaxAge: TimeInterval = 120
    public static let unchangedResend: TimeInterval = 3600
    public static let minWait: Duration = .seconds(60)
    public static let maxWait: Duration = .seconds(24 * 3600)
    public static let backoffBaseSeconds = 60.0
    public static let backoffCapSeconds = 6.0 * 3600
    public static let startDelayMinSeconds = 60.0
    public static let startDelayMaxSeconds = 180.0
    public static let forbiddenPause: Duration = .seconds(24 * 3600)
    public static let reportExpiry: TimeInterval = 72 * 3600
    public static let unexpectedLimit = 3
    public static let logInterval: Duration = .seconds(3600)
}
