import CryptoKit
import Foundation

public struct UpdateChecker: Sendable {
    public static let maxReleaseJsonBytes: Int64 = 1024 * 1024
    public static let maxTitleLength = 100
    public static let metadataTimeout: TimeInterval = 20
    public static let downloadTimeout: TimeInterval = 30 * 60

    private static let jsonType = "application/vnd.github+json"
    private static let binaryType = "application/octet-stream"

    private let http: UpdateHttp
    private let platform: UpdatePlatform
    private let current: UpdateVersion
    private let signature: UpdateSignature
    public var metadataTimeout = UpdateChecker.metadataTimeout
    public var downloadTimeout = UpdateChecker.downloadTimeout

    public init(http: UpdateHttp, platform: UpdatePlatform, current: UpdateVersion, signature: UpdateSignature) {
        self.http = http
        self.platform = platform
        self.current = current
        self.signature = signature
    }

    public func check() async -> UpdateCheckResult {
        do {
            let release = try Self.parseRelease(try await http.data(UpdateSource.latestReleaseApi, limit: Self.maxReleaseJsonBytes, timeout: metadataTimeout, accept: Self.jsonType))
            guard release.assets.contains(platform.manifestName), release.assets.contains(platform.signatureName),
                  let manifestUrl = UpdateSource.assetUrl(tag: release.tag, name: platform.manifestName),
                  let signatureUrl = UpdateSource.assetUrl(tag: release.tag, name: platform.signatureName),
                  let zipUrl = UpdateSource.assetUrl(tag: release.tag, name: platform.zipName) else {
                return UpdateCheckResult(.notSigned, "The latest release \(release.tag) has no signed update for \(platform.name).")
            }
            let signatureFile = try await http.data(signatureUrl, limit: Int64(UpdateSignature.maxFileBytes), timeout: metadataTimeout, accept: Self.binaryType)
            let manifestFile = try await http.data(manifestUrl, limit: Int64(UpdateManifest.maxBytes), timeout: metadataTimeout, accept: Self.binaryType)
            guard signature.verify(manifest: manifestFile, signatureFile: signatureFile) else {
                return UpdateCheckResult(.failed, "The update manifest of \(release.tag) does not have a valid signature. Nothing was installed.")
            }
            let manifest = try UpdateManifest.parse(manifestFile, platform: platform)
            guard manifest.version > current else {
                return UpdateCheckResult(.upToDate, "OSB Manager \(current) is up to date (latest signed release \(manifest.version)).")
            }
            let title = release.title.isEmpty ? "OSB Manager \(manifest.version)" : release.title
            let offer = UpdateOffer(manifest: manifest, tag: release.tag, title: title, zipUrl: zipUrl, releasePage: UpdateSource.releasePage(tag: release.tag))
            return UpdateCheckResult(.available, "OSB Manager \(manifest.version) is available.", offer: offer)
        } catch let error as UpdateError {
            return UpdateCheckResult(.failed, error.message)
        } catch {
            return UpdateCheckResult(.failed, error.localizedDescription)
        }
    }

    public func download(_ offer: UpdateOffer, into folder: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(platform.zipName)
        do {
            try await http.download(offer.zipUrl, to: file, limit: offer.manifest.size, timeout: downloadTimeout, accept: Self.binaryType)
            try Self.verify(file, manifest: offer.manifest)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    public static func verify(_ file: URL, manifest: UpdateManifest) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += Int64(chunk.count)
            hash.update(data: chunk)
        }
        guard total == manifest.size else {
            throw UpdateError("The download has \(total) bytes, the signed manifest says \(manifest.size).")
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == manifest.sha256 else { throw UpdateError("The download's SHA-256 does not match the signed manifest.") }
    }

    public static func cleanTitle(_ title: String?) -> String {
        guard let title else { return "" }
        var result = ""
        var space = false
        for scalar in title.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) && scalar.properties.generalCategory != .format {
                space = !result.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .format {
                continue
            }
            if space {
                result.unicodeScalars.append(" ")
                space = false
            }
            result.unicodeScalars.append(scalar)
        }
        guard result.count > maxTitleLength else { return result }
        return String(result.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private struct Release {
        let tag: String
        let title: String
        let assets: Set<String>
    }

    private static func parseRelease(_ data: Data) throws -> Release {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UpdateError("The release information is not valid JSON.")
        }
        guard let tag = root["tag_name"] as? String, UpdateSource.isValidTag(tag) else {
            throw UpdateError("The release tag is missing or not valid.")
        }
        let assets = (root["assets"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String }
        return Release(tag: tag, title: cleanTitle(root["name"] as? String), assets: Set(assets))
    }
}
