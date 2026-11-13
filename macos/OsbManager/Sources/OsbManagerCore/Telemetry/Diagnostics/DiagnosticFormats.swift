import Foundation
import Security

struct TextPattern: @unchecked Sendable {
    private let expression: NSRegularExpression?

    init(_ pattern: String, caseInsensitive: Bool = false) {
        expression = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matchesWhole(_ text: String) -> Bool {
        guard let expression else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, options: [.anchored], range: range) else { return false }
        return match.range == range
    }

    func occurs(in text: String) -> Bool {
        guard let expression else { return true }
        return expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    func firstMatch(in text: String) -> String? {
        guard let expression,
              let match = expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    func replacingEach(in text: String, with replace: (String) -> String) -> String {
        guard let expression else { return text }
        var result = ""
        var last = text.startIndex
        for match in expression.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            result += replace(String(text[range]))
            last = range.upperBound
        }
        return result + text[last...]
    }

    func replacing(in text: String, with template: String) -> String {
        guard let expression else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

public enum DiagnosticFormats {
    public static let app = "manager-mac"
    public static let reservedFingerprint = "0000000000000000"
    public static let maxEvents = 50
    public static let maxPerf = 2
    public static let maxFrames = 16
    public static let maxInner = 3
    public static let maxTrail = 50
    public static let maxOsbTrail = 20
    public static let maxTemplateLength = 160
    public static let maxMilliseconds = 600_000.0
    public static let maxDetailMagnitude = 1e9
    public static let maxEach = 64
    public static let maxCount = 100_000
    public static let maxEventBytes = 4 * 1024
    public static let maxPerfBytes = 8 * 1024
    public static let softBodyBytes = 60 * 1024
    public static let maxBodyBytes = 64 * 1024
    public static let maxUptimeSeconds = 2_592_000
    public static let maxHangSeconds = 86_400
    public static let maxGpuRetries = 100
    public static let maxMegabytes = 262_144.0
    public static let maxCorePercent = 25_600.0
    public static let maxAge: TimeInterval = 7 * 24 * 3600
    public static let maxAhead: TimeInterval = 10 * 60

    public static let origins: Set<String> = ["appdomain", "ui_thread", "task", "caught"]
    public static let pageOrigins: Set<String> = ["guard", "tick", "data", "panel", "window", "rejection"]
    public static let stopSources: Set<String> = ["stop", "town", "stop_all"]
    public static let modes: Set<String> = [
        "idle", "hunting", "fight", "loot", "resting", "town", "returning", "travelling", "quest", "resurrect",
        "party-support", "recording", "shopping", "error", "other",
    ]
    public static let detailNumbers: Set<String> = [
        "durationMs", "distance", "attempt", "quantity", "hpPct", "mpPct", "delayMs", "kills", "deaths", "potions",
        "items", "revision", "visited", "progressAgeMs", "skillId", "leg", "legs",
    ]
    public static let detailFlags: Set<String> = ["attackingPlayer", "choice"]
    public static let processKinds: Set<String> = [
        "browser_process_exited", "render_process_exited", "render_process_unresponsive", "frame_render_process_exited",
        "utility_process_exited", "sandbox_helper_process_exited", "gpu_process_exited", "ppapi_plugin_process_exited",
        "ppapi_broker_process_exited", "unknown_process_exited",
    ]
    public static let processReasons: Set<String> = ["unexpected", "unresponsive", "terminated", "crashed", "launch_failed", "out_of_memory", "profile_deleted"]
    public static let hangOutcomes: Set<String> = ["responded", "reloaded", "restarted", "gave_up"]
    public static let runOutcomes: Set<String> = ["clean", "unclean", "crash"]
    public static let runSignals: Set<String> = ["sigabrt", "sigsegv", "sigbus", "sigill", "sigtrap", "sigfpe"]
    public static let trailLevels: Set<String> = ["info", "warn", "error", "cmd"]
    public static let gpuVendors: Set<String> = ["nvidia", "amd", "intel", "apple", "qualcomm", "other", "unknown"]
    public static let phases: Set<String> = [
        "signed-out", "listing-servers", "loading-roster", "authenticating", "connecting", "entering-world", "world",
        "reconnecting", "disconnected", "character-select", "other",
    ]
    public static let loginStages: Set<String> = [
        "off", "waiting", "title", "server", "credentials", "connecting", "retry", "character", "entering", "choose", "failed", "done", "other",
    ]
    public static let ramBuckets = [2, 4, 8, 16, 32, 64]
    public static let coreBuckets = [1, 2, 4, 8, 16, 32]

    private static let codePattern = TextPattern("^[a-z0-9][a-z0-9_.:-]{0,63}$")
    private static let versionPattern = TextPattern("^[0-9A-Za-z.+-]{1,32}$")
    private static let hex16Pattern = TextPattern("^[0-9a-f]{16}$")
    private static let framePattern = TextPattern("^[A-Za-z_$<?][A-Za-z0-9_$<>.+-]{0,95}(@[0-9]{1,7}:[0-9]{1,5}|\\+IL_[0-9A-F]{4,6})?$")
    private static let typePattern = TextPattern("^[A-Za-z_][A-Za-z0-9_.]{0,127}$")
    private static let templatePattern = TextPattern("^[A-Za-z0-9 .,:;()<>'_/-]*$")
    private static let exitCodePattern = TextPattern("^-?0x[0-9A-F]{1,8}$")
    private static let osBuildPattern = TextPattern("^[0-9]{1,5}(\\.[0-9]{1,6}){1,3}$")

    public static func isCode(_ value: String?) -> Bool { value.map { ascii($0) && codePattern.matchesWhole($0) } ?? false }
    public static func isVersion(_ value: String?) -> Bool { value.map { ascii($0) && versionPattern.matchesWhole($0) } ?? false }
    public static func isHex16(_ value: String?) -> Bool { value.map { ascii($0) && hex16Pattern.matchesWhole($0) } ?? false }
    public static func isFrame(_ value: String?) -> Bool { value.map { $0 == FrameReducer.external || (ascii($0) && framePattern.matchesWhole($0)) } ?? false }
    public static func isTypeName(_ value: String?) -> Bool { value.map { ascii($0) && typePattern.matchesWhole($0) } ?? false }
    public static func isTemplate(_ value: String?) -> Bool { value.map { $0.unicodeScalars.count <= maxTemplateLength && ascii($0) && templatePattern.matchesWhole($0) } ?? false }
    public static func isExitCode(_ value: String?) -> Bool { value.map { ascii($0) && exitCodePattern.matchesWhole($0) } ?? false }
    public static func isOsBuild(_ value: String?) -> Bool { value.map { ascii($0) && osBuildPattern.matchesWhole($0) } ?? false }

    public static func exitCode(_ value: Int32) -> String {
        "0x" + String(UInt32(bitPattern: value), radix: 16, uppercase: true)
    }

    public static func signalName(_ number: Int32) -> String? {
        switch number {
        case SIGABRT: "sigabrt"
        case SIGSEGV: "sigsegv"
        case SIGBUS: "sigbus"
        case SIGILL: "sigill"
        case SIGTRAP: "sigtrap"
        case SIGFPE: "sigfpe"
        default: nil
        }
    }

    public static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    public static func minuteText(_ date: Date) -> String {
        let seconds = Int64(minute(date).timeIntervalSince1970)
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:00Z", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday), Int(parts.tm_hour), Int(parts.tm_min))
    }

    public static func roundUptime(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let rounded = (seconds / 60).rounded() * 60
        return Int(Swift.min(Swift.max(rounded, 0), Double(maxUptimeSeconds)))
    }

    public static func ramBucket(bytes: UInt64) -> Int? {
        bucket(Double(bytes) / 1_073_741_824 + 1, ramBuckets)
    }

    public static func coreBucket(_ cores: Int) -> Int? {
        bucket(Double(cores), coreBuckets)
    }

    public static func osBuild(_ version: OperatingSystemVersion) -> String? {
        let text = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return isOsBuild(text) ? text : nil
    }

    public static func chromiumVersion(cefVersion: String) -> String? {
        guard let range = cefVersion.range(of: "chromium-") else { return nil }
        let text = String(cefVersion[range.upperBound...])
        return isVersion(text) ? text : nil
    }

    public static func gpuVendor(deviceName: String?) -> String {
        guard let name = deviceName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "unknown" }
        let lower = name.lowercased()
        if lower.hasPrefix("apple") { return "apple" }
        if lower.contains("amd") || lower.contains("radeon") { return "amd" }
        if lower.contains("intel") { return "intel" }
        if lower.contains("nvidia") || lower.contains("geforce") { return "nvidia" }
        return "other"
    }

    public static func newRunKey() -> String {
        PrivacySettings.randomBytes(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func megabytes(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(Swift.min(Swift.max(value.rounded(), 0), maxMegabytes))
    }

    public static func corePercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (Swift.min(Swift.max(value, 0), maxCorePercent) * 10).rounded() / 10
    }

    public static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        Swift.min(Swift.max(value, low), high)
    }

    public static func cappedSum(_ left: Int, _ right: Int) -> Int {
        clamp(left.addingReportingOverflow(right).overflow ? maxCount : left + right, 0, maxCount)
    }

    private static func bucket(_ value: Double, _ buckets: [Int]) -> Int? {
        buckets.last { value >= Double($0) }
    }

    private static func ascii(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }
}
