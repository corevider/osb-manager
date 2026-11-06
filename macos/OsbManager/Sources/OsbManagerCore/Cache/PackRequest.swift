import Foundation

public struct PackRequest: Equatable, Sendable {
    public let url: String
    public let pack: String
    public let range: ByteRange

    public init(url: String, pack: String, range: ByteRange) {
        self.url = url
        self.pack = pack
        self.range = range
    }

    public static func match(method: String, url: String, rangeHeader: String?) -> PackRequest? {
        guard method.uppercased() == "GET",
              let pack = AssetUrl.tryGetPackName(url),
              let range = ByteRange.parse(header: rangeHeader) else { return nil }
        return PackRequest(url: url, pack: pack, range: range)
    }
}

public enum PackResponse {
    public static let status = 206
    public static let statusText = "Partial Content"
    public static let mimeType = "application/octet-stream"

    public static func headers(range: ByteRange, total: Int64) -> [String: String] {
        [
            "Content-Type": mimeType,
            "Content-Length": String(range.length),
            "Content-Range": "bytes \(range.start)-\(range.end)/\(total)",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
    }

    public static func isServable(_ cached: CachedRange, for range: ByteRange) -> Bool {
        Int64(cached.bytes.count) == range.length && range.end < cached.total
    }
}
