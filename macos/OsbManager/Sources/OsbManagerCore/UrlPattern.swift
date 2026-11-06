import Foundation

public enum UrlPattern {
    public static func fromMatch(_ pattern: String) throws -> String {
        if pattern == "<all_urls>" {
            return "^(https?|file|ftp)://.*$"
        }
        guard let schemeEnd = pattern.range(of: "://"), schemeEnd.lowerBound > pattern.startIndex else {
            throw ScriptFormatError("Invalid @match pattern: \(pattern)")
        }
        let scheme = String(pattern[..<schemeEnd.lowerBound])
        let rest = String(pattern[schemeEnd.upperBound...])
        let slash = rest.firstIndex(of: "/")
        let host = slash.map { String(rest[..<$0]) } ?? rest
        let path = slash.map { String(rest[$0...]) } ?? "/"

        var regex = "^" + (scheme == "*" ? "https?" : escape(scheme)) + "://"
        if host == "*" {
            regex += "[^/]*"
        } else if host.hasPrefix("*.") {
            regex += "([^/]*\\.)?" + escape(String(host.dropFirst(2)))
        } else {
            regex += escape(host)
        }
        return regex + wildcards(path) + "$"
    }

    public static func fromGlob(_ glob: String) -> String {
        if glob.count > 2, glob.hasPrefix("/"), glob.hasSuffix("/") {
            return String(glob.dropFirst().dropLast())
        }
        return "^" + wildcards(glob) + "$"
    }

    private static func wildcards(_ text: String) -> String {
        text.split(separator: "*", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: ".*")
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\^$.|?*+()[]{}/".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
