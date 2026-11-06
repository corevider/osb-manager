import Foundation

public enum Format {
    public static let missing = "—"

    public static func percent(_ value: Double?) -> String {
        guard let value else { return missing }
        return "\(Int(value.rounded(.toNearestOrEven)))%"
    }

    public static func number(_ value: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func compact(_ value: Int64?, locale: Locale = .current) -> String {
        guard let value else { return missing }
        let magnitude = abs(Double(value))
        switch magnitude {
        case 1e9...: return decimal(Double(value) / 1e9, maxFraction: 2, locale: locale) + "B"
        case 1e6...: return decimal(Double(value) / 1e6, maxFraction: 2, locale: locale) + "M"
        case 1e5...: return decimal(Double(value) / 1e3, maxFraction: 1, locale: locale) + "K"
        default: return number(value, locale: locale)
        }
    }

    public static func duration(milliseconds: Int64) -> String {
        let totalMinutes = max(0, milliseconds) / 60_000
        let hours = totalMinutes / 60
        return hours > 0 ? "\(hours)h \(String(format: "%02d", totalMinutes % 60))m" : "\(totalMinutes)m"
    }

    public static func perHour(_ value: Int64?, milliseconds: Int64, locale: Locale = .current) -> String {
        guard let value, milliseconds >= 30_000 else { return missing }
        return compact(Int64((Double(value) * 3_600_000 / Double(milliseconds)).rounded(.toNearestOrEven)), locale: locale)
    }

    public static func perHour(rate: Double?, locale: Locale = .current) -> String {
        guard let rate else { return missing }
        return compact(Int64(rate.rounded(.toNearestOrEven)), locale: locale)
    }

    public static func bytes(_ value: Int64, locale: Locale = .current) -> String {
        switch value {
        case (1 << 30)...: return decimal(Double(value) / Double(1 << 30), fraction: 1, locale: locale) + " GB"
        case (1 << 20)...: return decimal(Double(value) / Double(1 << 20), fraction: 0, locale: locale) + " MB"
        case (1 << 10)...: return decimal(Double(value) / Double(1 << 10), fraction: 0, locale: locale) + " KB"
        default: return "\(value) B"
        }
    }

    private static func decimal(_ value: Double, fraction: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fraction
        formatter.maximumFractionDigits = fraction
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func decimal(_ value: Double, maxFraction: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFraction
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
