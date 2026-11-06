import Foundation

public struct FetchedRange: Sendable {
    public let bytes: Data
    public let total: Int64

    public init(bytes: Data, total: Int64) {
        self.bytes = bytes
        self.total = total
    }
}

public struct RangeFetchError: Error, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public protocol RangeFetcher: Sendable {
    func fetch(url: String, range: ByteRange) async throws -> FetchedRange
}

public final class URLSessionRangeFetcher: RangeFetcher, @unchecked Sendable {
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 12
        configuration.waitsForConnectivity = false
        return configuration
    }

    private static let contentRange = try! NSRegularExpression(pattern: #"^bytes (\d+)-(\d+)/(\d+)$"#)

    private let session: URLSession

    public init(configuration: URLSessionConfiguration = URLSessionRangeFetcher.makeConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    public func fetch(url: String, range: ByteRange) async throws -> FetchedRange {
        guard AssetUrl.tryGetPackName(url) != nil, let address = URL(string: url) else {
            throw RangeFetchError("Only game pack files are downloaded.")
        }
        var request = URLRequest(url: address)
        request.httpMethod = "GET"
        request.setValue(range.header, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("OsbManager/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let header = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.parse(contentRange: header),
              parsed.start == range.start, parsed.end == range.end,
              (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity" else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RangeFetchError("Unexpected answer \(status) for \(range.start)-\(range.end).")
        }
        guard Int64(data.count) == range.length else {
            throw RangeFetchError("The download ended early.")
        }
        return FetchedRange(bytes: data, total: parsed.total)
    }

    static func parse(contentRange header: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard let match = contentRange.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        func value(_ index: Int) -> Int64? {
            Range(match.range(at: index), in: header).flatMap { Int64(header[$0]) }
        }
        guard let start = value(1), let end = value(2), let total = value(3) else { return nil }
        return (start, end, total)
    }
}
