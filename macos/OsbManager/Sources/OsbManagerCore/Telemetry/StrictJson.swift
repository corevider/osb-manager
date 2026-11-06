import Foundation

enum StrictJson {
    static func object(_ data: Data, maxDepth: Int = 6) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              BoundedJson.depth(of: value) <= maxDepth else { return nil }
        return value as? [String: Any]
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9.0e18 else { return nil }
        return number.int64Value
    }

    static func cleanText(_ text: String, maxLength: Int) -> String? {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        let cleaned = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxLength)))
        return cleaned.isEmpty ? nil : cleaned
    }
}
