import Foundation

public struct NativeFrame: Equatable, Sendable {
    public var ownImage: Bool
    public var symbol: String?

    public init(ownImage: Bool, symbol: String?) {
        self.ownImage = ownImage
        self.symbol = symbol
    }
}

public enum FrameReducer {
    public static let external = "ext"
    public static let closureMark = "<closure>"
    public static let ownModules = ["OsbManagerCore", "OsbManagerApp", "OsbManagerCef", "OsbManager", "CefBridge"]
    static let maxLength = 96
    private static let discriminator = TextPattern("\\(([A-Za-z_][A-Za-z0-9_]*) in _[0-9A-Fa-f]+\\)")

    public static func reduce(_ frames: [NativeFrame]) -> [String] {
        var result: [String] = []
        for frame in frames {
            let text = frame.ownImage ? (frame.symbol.flatMap(name(of:)) ?? external) : external
            if text == external, result.last == external { continue }
            result.append(text)
            if result.count == DiagnosticFormats.maxFrames { break }
        }
        return result
    }

    public static func name(of symbol: String) -> String? {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        if let objc = objectiveC(trimmed) { return checked(objc) }
        if trimmed.contains("::") { return checked(cpp(trimmed)) }
        return checked(swift(trimmed))
    }

    private static func objectiveC(_ symbol: String) -> String? {
        guard symbol.count > 4, symbol.hasPrefix("-[") || symbol.hasPrefix("+["), symbol.hasSuffix("]") else { return nil }
        let inner = symbol.dropFirst(2).dropLast()
        let parts = inner.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return "" }
        var type = String(parts[0])
        if let open = type.firstIndex(of: "(") { type = String(type[..<open]) }
        let selector = parts[1].split(separator: ":").first.map(String.init) ?? ""
        return "CefBridge.\(type).\(selector)"
    }

    private static func cpp(_ symbol: String) -> String? {
        var text = symbol.replacingOccurrences(of: "(anonymous namespace)::", with: "")
        text = removingGenerics(text)
        if let open = text.firstIndex(of: "(") { text = String(text[..<open]) }
        if let space = text.lastIndex(of: " ") { text = String(text[text.index(after: space)...]) }
        let parts = text.components(separatedBy: "::").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return "CefBridge." + parts.suffix(2).joined(separator: ".")
    }

    private static func swift(_ symbol: String) -> String? {
        var text = discriminator.replacing(in: symbol, with: "$1")
        let closure = text.contains("closure #")
        if closure, let range = text.range(of: " in ", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        text = removingGenerics(text)
        guard let start = ownModuleStart(in: text) else { return nil }
        text = String(text[start...])
        if let end = text.firstIndex(where: { $0 == "(" || $0 == " " }) {
            text = String(text[..<end])
        }
        while text.hasSuffix(".") { text.removeLast() }
        return closure ? text + "." + closureMark : text
    }

    private static func ownModuleStart(in text: String) -> String.Index? {
        var best: String.Index?
        for module in ownModules {
            var search = text.startIndex
            while let range = text.range(of: module + ".", range: search..<text.endIndex) {
                let boundary = range.lowerBound == text.startIndex || !isIdentifier(text[text.index(before: range.lowerBound)])
                if boundary {
                    if best == nil || range.lowerBound < best! { best = range.lowerBound }
                    break
                }
                search = range.upperBound
            }
        }
        return best
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "."
    }

    private static func removingGenerics(_ text: String) -> String {
        var depth = 0
        var result = ""
        var previous: Character?
        for character in text {
            if character == "<", previous != "-" {
                depth += 1
            } else if character == ">", depth > 0 {
                depth -= 1
            } else if depth == 0 {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    private static func checked(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count <= maxLength,
              ownModules.contains(where: { name.hasPrefix($0 + ".") }),
              DiagnosticFormats.isFrame(name), !name.contains("@"), !name.contains("+IL_") else { return nil }
        return name
    }
}
