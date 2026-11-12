import Foundation

public enum BotScripts {
    public static let osbUrl = "https://raw.githubusercontent.com/corevider/osb/main/osb.user.js"
    public static let osbNamespace = "https://github.com/corevider/osb"

    private static let repositoryHosts: Set<String> = ["raw.githubusercontent.com", "github.com"]

    public static func isOsbUrl(_ address: String?) -> Bool {
        inRepository(address, owner: "corevider", repository: "osb")
    }

    public static func isNixxaneUrl(_ address: String?) -> Bool {
        inRepository(address, owner: "nixxane", repository: "opensro-bot-lean")
    }

    public static func isOsb(_ script: InstalledScript) -> Bool {
        isOsbUrl(script.sourceUrl) || isOsbUrl(script.updateSource) || script.meta.namespace.caseInsensitiveCompare(osbNamespace) == .orderedSame
    }

    public static func isNixxane(_ script: InstalledScript) -> Bool {
        isNixxaneUrl(script.sourceUrl) || isNixxaneUrl(script.updateSource)
    }

    private static func inRepository(_ address: String?, owner: String, repository: String) -> Bool {
        guard let address, let url = URL(string: address), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), repositoryHosts.contains(host) else { return false }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        return segments.count >= 2
            && segments[0].caseInsensitiveCompare(owner) == .orderedSame
            && segments[1].caseInsensitiveCompare(repository) == .orderedSame
    }
}
