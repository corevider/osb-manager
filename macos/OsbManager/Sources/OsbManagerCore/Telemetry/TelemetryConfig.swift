import Foundation

public struct TelemetryConfig: Codable, Equatable, Sendable {
    public var telemetryEnabled: Bool
    public var intervalSeconds: Int
    public var reportsEnabled: Bool
    public var screenshotsEnabled: Bool
    public var clientOk: Bool
    public var message: String?
    public var diagnostics: DiagnosticsConfig?

    public init(telemetryEnabled: Bool, intervalSeconds: Int, reportsEnabled: Bool, screenshotsEnabled: Bool, clientOk: Bool, message: String?, diagnostics: DiagnosticsConfig? = nil) {
        self.telemetryEnabled = telemetryEnabled
        self.intervalSeconds = intervalSeconds
        self.reportsEnabled = reportsEnabled
        self.screenshotsEnabled = screenshotsEnabled
        self.clientOk = clientOk
        self.message = message
        self.diagnostics = diagnostics
    }

    public var diagnosticsSettings: DiagnosticsConfig {
        clientOk ? (diagnostics ?? .disabled) : .disabled
    }

    public static let disabled = TelemetryConfig(
        telemetryEnabled: false,
        intervalSeconds: TelemetryLimits.defaultIntervalSeconds,
        reportsEnabled: false,
        screenshotsEnabled: false,
        clientOk: true,
        message: nil
    )

    public static func parse(_ data: Data) -> TelemetryConfig? {
        guard let root = StrictJson.object(data),
              StrictJson.integer(root["schema"]) == 1,
              let telemetry = root["telemetry"] as? [String: Any],
              let reports = root["reports"] as? [String: Any],
              let telemetryEnabled = StrictJson.bool(telemetry["enabled"]),
              let reportsEnabled = StrictJson.bool(reports["enabled"]),
              let clientOk = StrictJson.bool(root["client_ok"]),
              let interval = StrictJson.integer(telemetry["interval_s"]) else { return nil }
        let screenshots = StrictJson.bool(reports["screenshots"]) ?? false
        let message = (root["message"] as? String).flatMap { StrictJson.cleanText($0, maxLength: TelemetryLimits.maxMessageLength) }
        return TelemetryConfig(
            telemetryEnabled: telemetryEnabled,
            intervalSeconds: Int(min(max(interval, Int64(TelemetryLimits.minIntervalSeconds)), Int64(TelemetryLimits.maxIntervalSeconds))),
            reportsEnabled: reportsEnabled,
            screenshotsEnabled: screenshots,
            clientOk: clientOk,
            message: message,
            diagnostics: DiagnosticsConfig.parse(root["diagnostics"])
        )
    }
}

public struct DiagnosticsConfig: Codable, Equatable, Sendable {
    public static let minIntervalSeconds = 600
    public static let minPerfIntervalSeconds = 1800
    public static let maxIntervalSeconds = 86_400

    public var enabled: Bool
    public var perf: Bool
    public var intervalSeconds: Int
    public var perfIntervalSeconds: Int
    public var samplePercent: Int

    public init(enabled: Bool, perf: Bool, intervalSeconds: Int = minIntervalSeconds, perfIntervalSeconds: Int = minPerfIntervalSeconds, samplePercent: Int = 100) {
        self.enabled = enabled
        self.perf = perf
        self.intervalSeconds = min(max(intervalSeconds, Self.minIntervalSeconds), Self.maxIntervalSeconds)
        self.perfIntervalSeconds = min(max(perfIntervalSeconds, Self.minPerfIntervalSeconds), Self.maxIntervalSeconds)
        self.samplePercent = min(max(samplePercent, 0), 100)
    }

    public static let disabled = DiagnosticsConfig(enabled: false, perf: false)

    public static func parse(_ value: Any?) -> DiagnosticsConfig? {
        guard let block = value as? [String: Any],
              let enabled = StrictJson.bool(block["enabled"]),
              let perf = StrictJson.bool(block["perf"]),
              let interval = StrictJson.integer(block["interval_s"]),
              let perfInterval = StrictJson.integer(block["perf_interval_s"]),
              let sample = StrictJson.integer(block["sample_pct"]) else { return nil }
        return DiagnosticsConfig(
            enabled: enabled,
            perf: perf,
            intervalSeconds: Int(min(max(interval, Int64(minIntervalSeconds)), Int64(maxIntervalSeconds))),
            perfIntervalSeconds: Int(min(max(perfInterval, Int64(minPerfIntervalSeconds)), Int64(maxIntervalSeconds))),
            samplePercent: Int(min(max(sample, 0), 100))
        )
    }
}
