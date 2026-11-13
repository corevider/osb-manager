import Foundation

public indirect enum PageJson {
    case object([String: PageJson], bytes: Int)
    case array([PageJson])
    case string(String)
    case number(Double, whole: Bool)
    case bool(Bool)
    case null

    public static func parse(_ text: String, maxDepth: Int) -> PageJson? {
        var parser = PageJsonParser(bytes: Array(text.utf8), maxDepth: maxDepth)
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipSpace()
        return parser.atEnd ? value : nil
    }

    public var members: [String: PageJson]? {
        if case .object(let members, _) = self { return members }
        return nil
    }

    public var items: [PageJson]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var text: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var flag: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var byteCount: Int? {
        if case .object(_, let bytes) = self { return bytes }
        return nil
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
}

struct PageJsonParser {
    let bytes: [UInt8]
    let maxDepth: Int
    private var index = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    var atEnd: Bool { index == bytes.count }

    mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func value(depth: Int) -> PageJson? {
        skipSpace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return object(depth: depth + 1)
        case UInt8(ascii: "["): return array(depth: depth + 1)
        case UInt8(ascii: "\""): return string().map(PageJson.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    private mutating func object(depth: Int) -> PageJson? {
        guard depth <= maxDepth else { return nil }
        let start = index
        index += 1
        var members: [String: PageJson] = [:]
        skipSpace()
        if take(UInt8(ascii: "}")) { return .object(members, bytes: index - start) }
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipSpace()
            guard take(UInt8(ascii: ":")), let item = value(depth: depth), members[key] == nil else { return nil }
            members[key] = item
            skipSpace()
            if take(UInt8(ascii: "}")) { return .object(members, bytes: index - start) }
            guard take(UInt8(ascii: ",")) else { return nil }
        }
    }

    private mutating func array(depth: Int) -> PageJson? {
        guard depth <= maxDepth else { return nil }
        index += 1
        var items: [PageJson] = []
        skipSpace()
        if take(UInt8(ascii: "]")) { return .array(items) }
        while true {
            guard let item = value(depth: depth) else { return nil }
            items.append(item)
            skipSpace()
            if take(UInt8(ascii: "]")) { return .array(items) }
            guard take(UInt8(ascii: ",")) else { return nil }
        }
    }

    private mutating func string() -> String? {
        index += 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() {
            guard !raw.isEmpty else { return }
            scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
            raw.removeAll()
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") {
                flush()
                return scalars.contains(where: PageJson.isControl) ? nil : String(scalars)
            }
            if byte < 0x20 { return nil }
            guard byte == UInt8(ascii: "\\") else {
                raw.append(byte)
                continue
            }
            flush()
            guard index < bytes.count else { return nil }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{8}")
            case UInt8(ascii: "f"): scalars.append("\u{C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                guard let scalar = unicodeEscape() else { return nil }
                scalars.append(scalar)
            default:
                return nil
            }
        }
        return nil
    }

    private mutating func unicodeEscape() -> Unicode.Scalar? {
        guard let first = hex4() else { return nil }
        if (0xDC00...0xDFFF).contains(first) { return nil }
        guard (0xD800...0xDBFF).contains(first) else { return Unicode.Scalar(first) }
        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
        index += 2
        guard let second = hex4(), (0xDC00...0xDFFF).contains(second) else { return nil }
        return Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            guard let digit = Self.hexDigit(byte) else { return nil }
            value = value * 16 + digit
        }
        index += 4
        return value
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    private mutating func number() -> PageJson? {
        let start = index
        _ = take(UInt8(ascii: "-"))
        if !take(UInt8(ascii: "0")), digits() == 0 {
            return nil
        }
        var whole = true
        if take(UInt8(ascii: ".")) {
            whole = false
            guard digits() > 0 else { return nil }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            whole = false
            index += 1
            if !take(UInt8(ascii: "+")) { _ = take(UInt8(ascii: "-")) }
            guard digits() > 0 else { return nil }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(text), value.isFinite else { return nil }
        return .number(value, whole: whole)
    }

    private mutating func digits() -> Int {
        let start = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
            index += 1
        }
        return index - start
    }

    private mutating func literal(_ word: String, _ result: PageJson) -> PageJson? {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { return nil }
        index += expected.count
        return result
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
