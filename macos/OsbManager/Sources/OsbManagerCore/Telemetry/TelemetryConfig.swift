import Foundation

public struct TelemetryConfig: Codable, Equatable, Sendable {
    public var telemetryEnabled: Bool
    public var intervalSeconds: Int
    public var reportsEnabled: Bool
    public var screenshotsEnabled: Bool
    public var clientOk: Bool
    public var message: String?

    public init(telemetryEnabled: Bool, intervalSeconds: Int, reportsEnabled: Bool, screenshotsEnabled: Bool, clientOk: Bool, message: String?) {
        self.telemetryEnabled = telemetryEnabled
        self.intervalSeconds = intervalSeconds
        self.reportsEnabled = reportsEnabled
        self.screenshotsEnabled = screenshotsEnabled
        self.clientOk = clientOk
        self.message = message
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
            message: message
        )
    }
}
