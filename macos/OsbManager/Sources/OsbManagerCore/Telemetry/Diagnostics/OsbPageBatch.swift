import Foundation

public enum OsbPageBatch {
    public static let batchType = "osb-diagnostics-batch"
    public static let switchType = "osb-diagnostics"
    public static let perfType = "osb-diagnostics-perf"
    public static let maxPerfBytes = 2 * 1024
    public static let maxBytes = 12 * 1024
    public static let maxEvents = 10
    public static let maxDepth = 8
    public static let maxLongTaskMilliseconds = 86_400_000.0

    private static let head = "{\"type\":\"" + batchType + "\""
    private static let tail = ",\"type\":\"" + batchType + "\"}"
    private static let perfHead = "{\"type\":\"" + perfType + "\""
    private static let perfTail = ",\"type\":\"" + perfType + "\"}"
    private static let kinds: Set<String> = ["js_error", "bot_stop", "warn"]

    public static func isBatch(_ json: String?) -> Bool {
        guard let json else { return false }
        return json.hasPrefix(head) || json.hasSuffix(tail)
    }

    public static func isPerf(_ json: String?) -> Bool {
        guard let json else { return false }
        return json.hasPrefix(perfHead) || json.hasSuffix(perfTail)
    }

    public static func switchMessage(on: Bool, perf: Bool = false) -> [String: Any] {
        on ? ["type": switchType, "on": true, "perf": perf] : ["type": switchType, "on": false]
    }

    public static func parse(_ json: String, now: Date, vocabulary: OsbVocabulary) -> (events: [DiagnosticEvent], mapped: Int)? {
        guard json.utf8.count <= maxBytes, let root = PageJson.parse(json, maxDepth: maxDepth) else { return nil }
        var reader = Reader(now: now)
        let events = reader.batch(root)
        guard !reader.failed else { return nil }
        var mapped = 0
        return (events.map { vocabulary.map($0, changed: &mapped) }, mapped)
    }

    public static func parsePerf(_ json: String, now: Date) -> PerfEntry? {
        guard json.utf8.count <= maxPerfBytes, let root = PageJson.parse(json, maxDepth: maxDepth) else { return nil }
        var reader = Reader(now: now)
        let entry = reader.perfMessage(root)
        return reader.failed ? nil : entry
    }

    struct Reader {
        let now: Date
        private(set) var failed = false

        init(now: Date) {
            self.now = now
        }

        mutating func batch(_ root: PageJson) -> [DiagnosticEvent] {
            guard let members = keys(root, ["type", "events"], ["type", "events"]), text(members, "type") == OsbPageBatch.batchType,
                  let items = array(members, "events", OsbPageBatch.maxEvents), !items.isEmpty else { return fail([]) }
            return items.compactMap { event($0) }
        }

        mutating func perfMessage(_ root: PageJson) -> PerfEntry? {
            guard let members = keys(root, ["type", "perf"], ["type", "perf"]), text(members, "type") == OsbPageBatch.perfType,
                  let perf = members["perf"],
                  let p = keys(perf, ["at", "span_s", "samples", "js_heap_mb", "tick_ms", "gap_ms", "long_tasks"], ["at", "span_s", "samples"]) else { return fail(nil) }
            let at = minute(p, "at")
            let span = int(p, "span_s", 60, 86_400)
            let samples = int(p, "samples", 1, 1440)
            var used: Double?
            var total: Double?
            if let heap = p["js_heap_mb"] {
                guard let h = keys(heap, ["used", "total"], ["used", "total"]) else { return fail(nil) }
                used = int(h, "used", 0, Int(DiagnosticFormats.maxMegabytes)).map(Double.init)
                total = int(h, "total", 0, Int(DiagnosticFormats.maxMegabytes)).map(Double.init)
            }
            var tasks: PerfLongTasks?
            if let longTasks = p["long_tasks"] {
                guard let t = keys(longTasks, ["count", "total_ms"], ["count", "total_ms"]) else { return fail(nil) }
                let count = int(t, "count", 0, DiagnosticFormats.maxCount)
                let totalMs = oneDecimal(t["total_ms"], OsbPageBatch.maxLongTaskMilliseconds)
                if let count, let totalMs, totalMs >= 0 {
                    tasks = PerfLongTasks(count: count, totalMs: totalMs)
                } else {
                    failed = true
                }
            }
            let tick = p["tick_ms"].flatMap { timing($0) }
            let gap = p["gap_ms"].flatMap { timing($0) }
            guard let at, let span, let samples, !failed else { return fail(nil) }
            return PerfEntry(at: at, spanSeconds: span, samples: samples, jsHeapUsed: used, jsHeapTotal: total, tick: tick, gap: gap, longTasks: tasks)
        }

        private mutating func timing(_ value: PageJson) -> PerfTiming? {
            let names = ["p50", "p95", "p99", "max", "late_pct"]
            guard let t = keys(value, Set(names), Set(names)) else { return nil }
            let values = names.dropLast().compactMap { oneDecimal(t[$0], DiagnosticFormats.maxMilliseconds) }.filter { $0 >= 0 }
            let late = oneDecimal(t["late_pct"], 100)
            guard values.count == 4, let late, late >= 0 else { return fail(nil) }
            return PerfTiming(p50: values[0], p95: values[1], p99: values[2], max: values[3], latePercent: late)
        }

        private mutating func event(_ value: PageJson) -> DiagnosticEvent? {
            guard let raw = value.members, let kind = raw["kind"]?.text, OsbPageBatch.kinds.contains(kind) else { return fail(nil) }
            let detailName = kind == "js_error" ? "error" : kind == "bot_stop" ? "stop" : "warn"
            guard let e = keys(value, ["kind", "source", "fp", "at", "count", detailName, "context", "trail"], ["kind", "source", "fp", "at", "count", detailName]),
                  (value.byteCount ?? Int.max) <= DiagnosticFormats.maxEventBytes,
                  text(e, "source") == DiagnosticSource.osb.rawValue else { return fail(nil) }
            let fingerprint = text(e, "fp")
            guard DiagnosticFormats.isHex16(fingerprint), fingerprint != DiagnosticFormats.reservedFingerprint, let fingerprint else { return fail(nil) }
            let at = minute(e, "at")
            let count = int(e, "count", 1, DiagnosticFormats.maxCount)
            guard let at, let count else { return fail(nil) }
            let context = e["context"].flatMap { self.context($0) }
            let trail = e["trail"].flatMap { self.trail($0) }
            guard let body = e[detailName] else { return fail(nil) }
            let detail: DiagnosticDetail?
            switch kind {
            case "js_error": detail = error(body).map(DiagnosticDetail.error)
            case "bot_stop": detail = stop(body).map(DiagnosticDetail.stop)
            default: detail = warn(body).map(DiagnosticDetail.warn)
            }
            guard let detail, !failed else { return fail(nil) }
            return DiagnosticEvent(detail: detail, source: .osb, fingerprint: fingerprint, at: at, count: count, context: context, trail: trail)
        }

        private mutating func error(_ value: PageJson) -> ErrorDetail? {
            guard let e = keys(value, ["type", "template", "inner", "module", "handled", "origin", "frames"], ["type", "handled", "origin"]) else { return nil }
            let type = text(e, "type")
            let origin = text(e, "origin")
            let handled = bool(e, "handled")
            guard DiagnosticFormats.isTypeName(type), let type, let origin, DiagnosticFormats.pageOrigins.contains(origin), let handled else { return fail(nil) }
            let template = optional(e, "template", DiagnosticFormats.isTemplate)
            let module = optional(e, "module", DiagnosticFormats.isCode)
            let inner = e["inner"] == nil ? [] : strings(e, "inner", DiagnosticFormats.maxInner, DiagnosticFormats.isTypeName)
            let frames = e["frames"] == nil ? [] : strings(e, "frames", DiagnosticFormats.maxFrames, DiagnosticFormats.isFrame)
            guard !failed else { return nil }
            return ErrorDetail(type: type, origin: origin, handled: handled, frames: frames ?? [], inner: inner ?? [], template: template, module: module)
        }

        private mutating func stop(_ value: PageJson) -> StopDetail? {
            guard let e = keys(value, ["code", "source"], ["code", "source"]) else { return nil }
            let code = text(e, "code")
            let source = text(e, "source")
            guard DiagnosticFormats.isCode(code), let code, let source, DiagnosticFormats.stopSources.contains(source) else { return fail(nil) }
            return StopDetail(code: code, source: source)
        }

        private mutating func warn(_ value: PageJson) -> WarnDetail? {
            guard let e = keys(value, ["category", "code", "error_class", "refusal"], ["category", "code"]) else { return nil }
            let category = text(e, "category")
            let code = text(e, "code")
            let errorClass = optional(e, "error_class", DiagnosticFormats.isCode)
            var refusal: RefusalDetail?
            if let r = e["refusal"] {
                guard let members = keys(r, ["source", "reason", "native"], ["source", "reason", "native"]) else { return nil }
                let source = text(members, "source")
                let reason = text(members, "reason")
                let native = int(members, "native", 0, 65_535)
                guard DiagnosticFormats.isCode(source), DiagnosticFormats.isCode(reason), let source, let reason, let native else { return fail(nil) }
                refusal = RefusalDetail(source: source, reason: reason, native: native)
            }
            guard DiagnosticFormats.isCode(category), DiagnosticFormats.isCode(code), let category, let code, !failed else { return fail(nil) }
            return WarnDetail(category: category, code: code, errorClass: errorClass, refusal: refusal)
        }

        private mutating func context(_ value: PageJson) -> DiagnosticContext? {
            guard let e = keys(value, ["phase", "mode", "town_phase", "dead", "uptime_s"], []) else { return nil }
            let mode = optional(e, "mode") { $0.map(DiagnosticFormats.modes.contains) ?? false }
            var uptime: Int?
            if e["uptime_s"] != nil {
                uptime = int(e, "uptime_s", 0, DiagnosticFormats.maxUptimeSeconds)
                guard let seconds = uptime, seconds % 60 == 0 else { return fail(nil) }
            }
            var dead: Bool?
            if e["dead"] != nil {
                dead = bool(e, "dead")
                guard dead != nil else { return fail(nil) }
            }
            return DiagnosticContext(
                phase: optional(e, "phase", DiagnosticFormats.isCode),
                mode: mode,
                townPhase: optional(e, "town_phase", DiagnosticFormats.isCode),
                dead: dead,
                uptimeSeconds: uptime
            )
        }

        private mutating func trail(_ value: PageJson) -> [TrailItem]? {
            guard let entries = value.items, entries.count <= DiagnosticFormats.maxOsbTrail else { return fail(nil) }
            var items: [TrailItem] = []
            for entry in entries {
                guard let e = keys(entry, ["s", "l", "c", "k", "o", "n", "e", "d"], ["s", "l", "c", "k"]) else { return nil }
                let seconds = int(e, "s", -86_400, 0)
                let level = text(e, "l")
                let category = text(e, "c")
                let code = text(e, "k")
                let outcome = optional(e, "o", DiagnosticFormats.isCode)
                let errorClass = optional(e, "e", DiagnosticFormats.isCode)
                let repeatCount = e["n"] == nil ? 1 : int(e, "n", 1, DiagnosticFormats.maxCount)
                let (numbers, flags) = e["d"].map { details($0) } ?? (nil, nil)
                guard let seconds, let level, DiagnosticFormats.trailLevels.contains(level), DiagnosticFormats.isCode(category), let category,
                      DiagnosticFormats.isCode(code), let code, let repeatCount, !failed else { return fail(nil) }
                items.append(TrailItem(secondsBefore: seconds, level: level, category: category, code: code, count: repeatCount, outcome: outcome, errorClass: errorClass, numbers: numbers, flags: flags))
            }
            return items
        }

        private mutating func details(_ value: PageJson) -> ([String: Double]?, [String: Bool]?) {
            guard let e = keys(value, DiagnosticFormats.detailNumbers.union(DiagnosticFormats.detailFlags), []) else { return (nil, nil) }
            var numbers: [String: Double]?
            var flags: [String: Bool]?
            for (name, item) in e {
                if DiagnosticFormats.detailFlags.contains(name) {
                    guard let flag = item.flag else { return fail((nil, nil)) }
                    flags = (flags ?? [:]).merging([name: flag]) { $1 }
                    continue
                }
                guard let number = oneDecimal(item, DiagnosticFormats.maxDetailMagnitude) else { return fail((nil, nil)) }
                numbers = (numbers ?? [:]).merging([name: number]) { $1 }
            }
            return (numbers, flags)
        }

        private mutating func keys(_ value: PageJson, _ allowed: Set<String>, _ required: Set<String>) -> [String: PageJson]? {
            guard let members = value.members,
                  members.allSatisfy({ allowed.contains($0.key) && !$0.value.isNull }),
                  required.allSatisfy({ members[$0] != nil }) else { return fail(nil) }
            return members
        }

        private mutating func text(_ members: [String: PageJson], _ name: String) -> String? {
            guard let value = members[name] else { return nil }
            guard let text = value.text else { return fail(nil) }
            return text
        }

        private mutating func optional(_ members: [String: PageJson], _ name: String, _ valid: (String?) -> Bool) -> String? {
            guard members[name] != nil else { return nil }
            let value = text(members, name)
            return valid(value) ? value : fail(nil)
        }

        private mutating func strings(_ members: [String: PageJson], _ name: String, _ max: Int, _ valid: (String?) -> Bool) -> [String]? {
            guard let items = array(members, name, max) else { return nil }
            var result: [String] = []
            for item in items {
                guard let text = item.text, valid(text) else { return fail(nil) }
                result.append(text)
            }
            return result
        }

        private mutating func array(_ members: [String: PageJson], _ name: String, _ max: Int) -> [PageJson]? {
            guard let items = members[name]?.items, items.count <= max else { return fail(nil) }
            return items
        }

        private mutating func bool(_ members: [String: PageJson], _ name: String) -> Bool? {
            guard let flag = members[name]?.flag else { return fail(nil) }
            return flag
        }

        private mutating func int(_ members: [String: PageJson], _ name: String, _ low: Int, _ high: Int) -> Int? {
            guard case .number(let value, let whole)? = members[name], whole, value >= Double(low), value <= Double(high) else { return fail(nil) }
            return Int(value)
        }

        private mutating func oneDecimal(_ value: PageJson?, _ magnitude: Double) -> Double? {
            guard case .number(let number, _)? = value, number.isFinite, abs(number) <= magnitude,
                  (number * 10).rounded() / 10 == number else { return fail(nil) }
            return number
        }

        private mutating func minute(_ members: [String: PageJson], _ name: String) -> Date? {
            guard let text = text(members, name), let at = OsbPageBatch.minute(text),
                  at >= now.addingTimeInterval(-DiagnosticFormats.maxAge), at <= now.addingTimeInterval(DiagnosticFormats.maxAhead) else { return fail(nil) }
            return at
        }

        private mutating func fail<T>(_ value: T) -> T {
            failed = true
            return value
        }
    }

    static func minute(_ text: String) -> Date? {
        let digits = Array(text.utf8)
        guard digits.count == 20, text.hasSuffix(":00Z") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in digits[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard digits[4] == UInt8(ascii: "-"), digits[7] == UInt8(ascii: "-"), digits[10] == UInt8(ascii: "T"), digits[13] == UInt8(ascii: ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10), let hour = number(11..<13), let minute = number(14..<16) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)),
              DiagnosticFormats.minuteText(date) == text else { return nil }
        return date
    }
}
