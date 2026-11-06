import Foundation

public struct UpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0",
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (left: UpdateVersion, right: UpdateVersion) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public struct UpdatePlatform: Equatable, Sendable {
    public static let windowsX64 = UpdatePlatform(name: "windows-x64")
    public static let macosArm64 = UpdatePlatform(name: "macos-arm64")

    public let name: String

    public var zipName: String { "OSB-Manager-\(name).zip" }
    public var manifestName: String { "OSB-Manager-\(name).update.json" }
    public var signatureName: String { manifestName + ".sig" }
}

public enum UpdateSource {
    public static let repository = "corevider/osb-manager"
    public static let latestReleaseApi = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let latestReleasePage = URL(string: "https://github.com/\(repository)/releases/latest")!

    public static func isValidTag(_ tag: String) -> Bool {
        guard let first = tag.first, (1...64).contains(tag.count), first.isASCII, first.isLetter || first.isNumber else { return false }
        return tag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    public static func assetUrl(tag: String, name: String) -> URL? {
        guard isValidTag(tag) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)")
    }

    public static func releasePage(tag: String) -> URL {
        guard isValidTag(tag), let url = URL(string: "https://github.com/\(repository)/releases/tag/\(tag)") else { return latestReleasePage }
        return url
    }
}

public struct UpdateHosts: Sendable {
    public static let gitHub = UpdateHosts(["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"])

    public let names: Set<String>

    public init(_ names: [String]) {
        self.names = Set(names.map { $0.lowercased() })
    }

    public func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "https",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { return false }
        return names.contains(host)
    }
}

public struct UpdateError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct UpdateManifest: Equatable, Sendable {
    public static let format = 1
    public static let product = "osb-manager"
    public static let maxBytes = 4096
    public static let maxAssetBytes: Int64 = 512 * 1024 * 1024
    private static let fields: Set<String> = ["format", "product", "platform", "version", "asset", "size", "sha256"]

    public let version: UpdateVersion
    public let platform: String
    public let asset: String
    public let size: Int64
    public let sha256: String

    public init(version: UpdateVersion, platform: String, asset: String, size: Int64, sha256: String) {
        self.version = version
        self.platform = platform
        self.asset = asset
        self.size = size
        self.sha256 = sha256
    }

    public static func parse(_ data: Data, platform: UpdatePlatform) throws -> UpdateManifest {
        guard data.count <= maxBytes else { throw UpdateError("The update manifest is too large.") }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw UpdateError("The update manifest is not a JSON object.")
        }
        guard Set(root.keys) == fields else { throw UpdateError("The update manifest has missing or unexpected fields.") }
        guard integer(root["format"]) == Int64(format) else { throw UpdateError("The update manifest has an unknown format.") }
        guard root["product"] as? String == product else { throw UpdateError("The update manifest is for another product.") }
        guard root["platform"] as? String == platform.name else { throw UpdateError("The update manifest is for another platform.") }
        guard let versionText = root["version"] as? String, let version = UpdateVersion(versionText) else {
            throw UpdateError("The update manifest has a malformed version.")
        }
        guard root["asset"] as? String == platform.zipName else { throw UpdateError("The update manifest names another file.") }
        guard let size = integer(root["size"]), size > 0, size <= maxAssetBytes else {
            throw UpdateError("The update manifest has a size out of range.")
        }
        guard let sha256 = root["sha256"] as? String, sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw UpdateError("The update manifest has a malformed SHA-256.")
        }
        return UpdateManifest(version: version, platform: platform.name, asset: platform.zipName, size: size, sha256: sha256)
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return number.int64Value
    }
}

public struct UpdateOffer: Equatable, Sendable {
    public let manifest: UpdateManifest
    public let tag: String
    public let title: String
    public let zipUrl: URL
    public let releasePage: URL

    public var version: UpdateVersion { manifest.version }
}

public enum UpdateCheckStatus: Equatable, Sendable {
    case upToDate
    case available
    case notSigned
    case failed
}

public struct UpdateCheckResult: Equatable, Sendable {
    public let status: UpdateCheckStatus
    public let message: String
    public let offer: UpdateOffer?

    public init(_ status: UpdateCheckStatus, _ message: String, offer: UpdateOffer? = nil) {
        self.status = status
        self.message = message
        self.offer = offer
    }
}
