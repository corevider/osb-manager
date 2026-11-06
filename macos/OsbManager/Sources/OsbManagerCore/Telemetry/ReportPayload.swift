import Foundation

public enum ReportKind: String, CaseIterable, Sendable {
    case bug
    case feature
}

public struct WindowDiagnostics: Equatable, Sendable {
    public var phase: String?
    public var loginStage: String?
    public var loginMessage: String?
    public var botVersion: String?
    public var light: Bool
    public var gpuRetries: Int
    public var gpuFailed: String?

    public init(phase: String?, loginStage: String?, loginMessage: String?, botVersion: String?, light: Bool, gpuRetries: Int, gpuFailed: String?) {
        self.phase = phase
        self.loginStage = loginStage
        self.loginMessage = loginMessage
        self.botVersion = botVersion
        self.light = light
        self.gpuRetries = gpuRetries
        self.gpuFailed = gpuFailed
    }

    public static func from(_ status: BotStatus?, light: Bool) -> WindowDiagnostics {
        guard let status else {
            return WindowDiagnostics(phase: nil, loginStage: nil, loginMessage: nil, botVersion: nil, light: light, gpuRetries: 0, gpuFailed: nil)
        }
        return WindowDiagnostics(
            phase: status.phase,
            loginStage: status.loginStage,
            loginMessage: status.loginMessage,
            botVersion: status.botVersion,
            light: status.light || light,
            gpuRetries: status.gpuRetries,
            gpuFailed: status.gpuFailed
        )
    }
}

public struct ScriptDiagnostics: Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public enum ReportDiagnostics {
    private static let maxItems = 50

    public static func build(appVersion: String, osVersion: String, windows: [WindowDiagnostics], scripts: [ScriptDiagnostics]) -> [String: Any] {
        let windowList: [[String: Any]] = windows.prefix(maxItems).map { window in
            var entry: [String: Any] = [
                "phase": cut(window.phase, 64) ?? NSNull(),
                "bot_version": cut(window.botVersion, 32) ?? NSNull(),
                "light": window.light,
                "gpu": ["retries": window.gpuRetries, "failed": cut(window.gpuFailed, 200) ?? NSNull()] as [String: Any],
            ]
            if window.loginStage != nil || window.loginMessage != nil {
                entry["login"] = ["stage": cut(window.loginStage, 64) ?? NSNull(), "message": cut(window.loginMessage, 64) ?? NSNull()] as [String: Any]
            }
            return entry
        }
        let scriptList: [[String: Any]] = scripts.prefix(maxItems).map {
            ["name": cut($0.name, 64) ?? NSNull(), "version": cut($0.version, 32) ?? NSNull()]
        }
        return [
            "app": AppIdentity.name,
            "version": cut(appVersion, 32) ?? NSNull(),
            "os": cut(osVersion, 64) ?? NSNull(),
            "windows": windows.count,
            "game_windows": windowList,
            "scripts": scriptList,
        ]
    }

    static func cut(_ text: String?, _ length: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(length)
        let result = String(String.UnicodeScalarView(scalars))
        return result.isEmpty ? nil : result
    }
}

public enum ReportPayload {
    public static let maxDescription = 2000
    public static let maxScreenshotBytes = 768 * 1024
    public static let maxScreenshotWidth = 1920

    public static func cleanDescription(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = trimmed.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(kept.prefix(maxDescription)))
    }

    public static func build(kind: ReportKind, description: String, diagnostics: [String: Any], appVersion: String, locale: String) -> Data {
        let body: [String: Any] = [
            "schema": TelemetryLimits.schema,
            "kind": kind.rawValue,
            "app": TelemetryLimits.appName,
            "app_version": appVersion,
            "os": TelemetryLimits.osName,
            "locale": locale,
            "description": cleanDescription(description),
            "diagnostics": diagnostics,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public static func preview(_ reportJson: Data) -> String {
        String(decoding: reportJson, as: UTF8.self)
    }
}
