import Foundation

public enum AppVersion {
    public static func text(from info: [String: Any]?) -> String {
        guard let version = (info?["CFBundleShortVersionString"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return "development build"
        }
        guard let build = (info?["CFBundleVersion"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return version
        }
        return "\(version) (build \(build))"
    }

    public static func shortText(from info: [String: Any]?) -> String {
        (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }

    public static func short(bundle: Bundle = .main) -> String {
        shortText(from: bundle.infoDictionary)
    }

    public static func current(bundle: Bundle = .main) -> String {
        text(from: bundle.infoDictionary)
    }
}
