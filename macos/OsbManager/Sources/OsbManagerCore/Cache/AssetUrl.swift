import Foundation

public enum AssetUrl {
    public static let host = "opensro.online"
    private static let packPrefix = "/assets/packs/"
    private static let packName = try! NSRegularExpression(pattern: #"^[a-z0-9][a-z0-9-]{0,100}-([0-9a-f]{12})\.bin$"#)

    public static func packUrl(for name: String) -> String {
        "https://\(host)\(packPrefix)\(name)"
    }

    public static func tryGetPackName(_ url: String?) -> String? {
        guard let url, let components = URLComponents(string: url),
              components.scheme == "https",
              components.port == nil || components.port == 443,
              components.host?.lowercased() == host,
              components.user == nil, components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.hasPrefix(packPrefix) else { return nil }
        let candidate = String(components.percentEncodedPath.dropFirst(packPrefix.count))
        return isValidPackName(candidate) ? candidate : nil
    }

    public static func isValidPackName(_ name: String) -> Bool {
        packName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    public static func hashPrefix(_ name: String) -> String {
        guard let match = packName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return "" }
        return String(name[range])
    }
}
