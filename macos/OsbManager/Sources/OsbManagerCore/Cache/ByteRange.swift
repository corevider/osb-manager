import Foundation

public struct ByteRange: Equatable, Hashable, Sendable {
    public static let maxLength: Int64 = 64 << 20

    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var length: Int64 { end - start + 1 }

    public var endExclusive: Int64 { end + 1 }

    public var header: String { "bytes=\(start)-\(end)" }

    public static func parse(header: String?, maxLength: Int64 = ByteRange.maxLength) -> ByteRange? {
        guard let header, header.range(of: "bytes=", options: [.caseInsensitive, .anchored]) != nil else { return nil }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              let start = digits(parts[0]), let end = digits(parts[1]),
              end >= start, end - start + 1 <= maxLength else { return nil }
        return ByteRange(start: start, end: end)
    }

    private static func digits(_ text: Substring) -> Int64? {
        guard text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int64(text)
    }
}
