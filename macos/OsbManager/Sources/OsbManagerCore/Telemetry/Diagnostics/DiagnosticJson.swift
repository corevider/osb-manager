import Foundation

public struct DiagnosticBody: Sendable {
    public let body: Data
    public let events: [DiagnosticEvent]
    public let perfCount: Int
    public let dropped: DroppedCounts
    public var osbPerfCount = 0
}

public enum DiagnosticBatchError: Error, Equatable {
    case invalidVersionOrRun
}

struct JsonText {
    private(set) var text = ""
    private var needsComma: [Bool] = [false]

    mutating func beginObject(_ key: String? = nil) { open(key, "{") }
    mutating func endObject() { close("}") }
    mutating func beginArray(_ key: String? = nil) { open(key, "[") }
    mutating func endArray() { close("]") }

    mutating func string(_ key: String?, _ value: String) { put(key, Self.quoted(value)) }
    mutating func int(_ key: String?, _ value: Int) { put(key, String(value)) }
    mutating func bool(_ key: String?, _ value: Bool) { put(key, value ? "true" : "false") }
    mutating func tenth(_ key: String?, _ value: Double) {
        let rounded = (value * 10).rounded() / 10
        put(key, rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded))
    }

    mutating func optionalString(_ key: String, _ value: String?) { if let value { string(key, value) } }
    mutating func optionalInt(_ key: String, _ value: Int?) { if let value { int(key, value) } }
    mutating func optionalBool(_ key: String, _ value: Bool?) { if let value { bool(key, value) } }

    var data: Data { Data(text.utf8) }

    private mutating func open(_ key: String?, _ token: String) {
        put(key, token)
        needsComma.append(false)
    }

    private mutating func close(_ token: String) {
        needsComma.removeLast()
        text += token
    }

    private mutating func put(_ key: String?, _ value: String) {
        if needsComma[needsComma.count - 1] { text += "," }
        needsComma[needsComma.count - 1] = true
        if let key { text += Self.quoted(key) + ":" }
        text += value
    }

    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

public enum DiagnosticJson {
    public static func batch(_ batch: DiagnosticBatch, terms: PrivateTerms, now: Date) throws -> DiagnosticBody {
        guard DiagnosticFormats.isVersion(batch.appVersion), DiagnosticFormats.isHex16(batch.run) else {
            throw DiagnosticBatchError.invalidVersionOrRun
        }
        var oversize = max(0, batch.events.count - DiagnosticFormats.maxEvents)
        var events: [DiagnosticEvent] = []
        for candidate in batch.events.prefix(DiagnosticFormats.maxEvents) {
            guard inWindow(candidate.at, now), let clean = DiagnosticScrubber.scrub(candidate, terms) else { continue }
            if let fitted = fit(clean) {
                events.append(fitted)
            } else {
                oversize += 1
            }
        }
        var perf = batch.perf.prefix(DiagnosticFormats.maxPerf).filter { entry in
            inWindow(entry.at, now) && serialise({ writePerf(&$0, $1) }, entry).count <= DiagnosticFormats.maxPerfBytes
        }
        var osbPerf = batch.osbPerf.prefix(1).filter { item in
            inWindow(item.entry.at, now) && DiagnosticScrubber.version(item.appVersion, terms) != nil
                && serialise({ writePerf(&$0, $1.entry, appVersion: $1.appVersion) }, item).count <= OsbPageBatch.maxPerfBytes
        }
        while true {
            let dropped = batch.dropped.adding(DroppedCounts(oversize: oversize))
            var writer = JsonText()
            writeBatch(&writer, batch, events, perf, osbPerf, dropped)
            if writer.text.utf8.count <= DiagnosticFormats.softBodyBytes {
                var body = DiagnosticBody(body: writer.data, events: events, perfCount: perf.count, dropped: dropped)
                body.osbPerfCount = osbPerf.count
                return body
            }
            if let index = events.lastIndex(where: { $0.trail?.isEmpty == false }) {
                events[index].trail = nil
            } else if !events.isEmpty {
                events.removeFirst()
                oversize += 1
            } else if !perf.isEmpty {
                perf.removeLast()
            } else if !osbPerf.isEmpty {
                osbPerf.removeAll()
            } else {
                return DiagnosticBody(body: writer.data, events: events, perfCount: 0, dropped: dropped)
            }
        }
    }

    public static func event(_ candidate: DiagnosticEvent, terms: PrivateTerms) -> Data? {
        guard let clean = DiagnosticScrubber.scrub(candidate, terms), let fitted = fit(clean) else { return nil }
        return serialise({ writeEvent(&$0, $1) }, fitted)
    }

    public static func eventText(_ event: DiagnosticEvent) -> String {
        String(decoding: serialise({ writeEvent(&$0, $1) }, event), as: UTF8.self)
    }

    static func fit(_ event: DiagnosticEvent) -> DiagnosticEvent? {
        if serialise({ writeEvent(&$0, $1) }, event).count <= DiagnosticFormats.maxEventBytes { return event }
        var bare = event
        bare.trail = nil
        return serialise({ writeEvent(&$0, $1) }, bare).count <= DiagnosticFormats.maxEventBytes ? bare : nil
    }

    static func inWindow(_ at: Date, _ now: Date) -> Bool {
        at >= now.addingTimeInterval(-DiagnosticFormats.maxAge) && at <= now.addingTimeInterval(DiagnosticFormats.maxAhead)
    }

    private static func serialise<T>(_ write: (inout JsonText, T) -> Void, _ value: T) -> Data {
        var writer = JsonText()
        write(&writer, value)
        return writer.data
    }

    private static func writeBatch(_ w: inout JsonText, _ batch: DiagnosticBatch, _ events: [DiagnosticEvent], _ perf: [PerfEntry], _ osbPerf: [OsbPerfEntry], _ dropped: DroppedCounts) {
        w.beginObject()
        w.int("schema", 1)
        w.string("app", DiagnosticFormats.app)
        w.string("app_version", batch.appVersion)
        w.string("run", batch.run)
        writeEnv(&w, batch.env)
        w.beginArray("events")
        events.forEach { writeEvent(&w, $0) }
        w.endArray()
        if !perf.isEmpty {
            w.beginArray("perf")
            perf.forEach { writePerf(&w, $0) }
            w.endArray()
        }
        if !osbPerf.isEmpty {
            w.beginArray("osb_perf")
            osbPerf.forEach { writePerf(&w, $0.entry, appVersion: $0.appVersion) }
            w.endArray()
        }
        w.beginObject("dropped")
        w.int("rate_limited", DiagnosticFormats.clamp(dropped.rateLimited, 0, DiagnosticFormats.maxCount))
        w.int("oversize", DiagnosticFormats.clamp(dropped.oversize, 0, DiagnosticFormats.maxCount))
        w.int("sampled_out", DiagnosticFormats.clamp(dropped.sampledOut, 0, DiagnosticFormats.maxCount))
        w.endObject()
        w.endObject()
    }

    private static func writeEnv(_ w: inout JsonText, _ env: DiagnosticEnv) {
        w.beginObject("env")
        if DiagnosticFormats.isOsBuild(env.osBuild) { w.optionalString("os_build", env.osBuild) }
        if DiagnosticFormats.isVersion(env.webview2) { w.optionalString("webview2", env.webview2) }
        if DiagnosticFormats.isVersion(env.dotnet) { w.optionalString("dotnet", env.dotnet) }
        if let ram = env.ramGb, DiagnosticFormats.ramBuckets.contains(ram) { w.int("ram_gb", ram) }
        if let cores = env.cores, DiagnosticFormats.coreBuckets.contains(cores) { w.int("cores", cores) }
        if let vendor = env.gpuVendor, DiagnosticFormats.gpuVendors.contains(vendor) { w.string("gpu_vendor", vendor) }
        w.endObject()
    }

    static func writeEvent(_ w: inout JsonText, _ e: DiagnosticEvent) {
        w.beginObject()
        w.string("kind", e.kind.rawValue)
        w.string("source", e.source.rawValue)
        w.string("fp", e.fingerprint)
        w.string("at", DiagnosticFormats.minuteText(e.at))
        w.int("count", e.count)
        switch e.detail {
        case .error(let error):
            w.beginObject("error")
            w.string("type", error.type)
            w.optionalString("template", error.template)
            w.beginArray("inner")
            error.inner.forEach { w.string(nil, $0) }
            w.endArray()
            w.optionalString("module", error.module)
            w.bool("handled", error.handled)
            w.string("origin", error.origin)
            w.beginArray("frames")
            error.frames.forEach { w.string(nil, $0) }
            w.endArray()
            w.endObject()
        case .process(let process):
            w.beginObject("process")
            w.string("kind", process.kind)
            w.string("reason", process.reason)
            w.string("exit_code", process.exitCode)
            w.optionalString("description", process.description)
            w.endObject()
        case .hang(let hang):
            w.beginObject("hang")
            w.string("outcome", hang.outcome)
            w.int("waited_s", hang.waitedSeconds)
            w.endObject()
        case .gpu(let gpu):
            w.beginObject("gpu")
            w.string("code", gpu.code)
            w.int("retries", gpu.retries)
            w.endObject()
        case .stop(let stop):
            w.beginObject("stop")
            w.string("code", stop.code)
            w.string("source", stop.source)
            w.endObject()
        case .warn(let warn):
            w.beginObject("warn")
            w.string("category", warn.category)
            w.string("code", warn.code)
            w.optionalString("error_class", warn.errorClass)
            if let refusal = warn.refusal {
                w.beginObject("refusal")
                w.string("source", refusal.source)
                w.string("reason", refusal.reason)
                w.int("native", refusal.native)
                w.endObject()
            }
            w.endObject()
        case .runEnd(let end):
            w.beginObject("run_end")
            w.string("outcome", end.outcome)
            w.int("uptime_s", end.uptimeSeconds)
            w.optionalString("previous_version", end.previousVersion)
            w.optionalString("signal", end.signal)
            w.endObject()
        }
        if let context = e.context {
            w.beginObject("context")
            w.optionalString("phase", context.phase)
            w.optionalString("mode", context.mode)
            w.optionalString("town_phase", context.townPhase)
            w.optionalBool("dead", context.dead)
            w.optionalString("login_stage", context.loginStage)
            w.optionalInt("window", context.window)
            w.optionalInt("windows", context.windows)
            w.optionalBool("light", context.light)
            w.optionalBool("hidden", context.hidden)
            w.optionalInt("uptime_s", context.uptimeSeconds)
            w.endObject()
        }
        if let trail = e.trail, !trail.isEmpty {
            w.beginArray("trail")
            for item in trail {
                w.beginObject()
                w.int("s", item.secondsBefore)
                w.string("l", item.level)
                w.string("c", item.category)
                w.string("k", item.code)
                w.optionalString("o", item.outcome)
                w.optionalString("e", item.errorClass)
                if item.count > 1 { w.int("n", item.count) }
                w.optionalInt("w", item.window)
                if item.numbers?.isEmpty == false || item.flags?.isEmpty == false {
                    w.beginObject("d")
                    for (key, value) in (item.numbers ?? [:]).sorted(by: { $0.key < $1.key }) { w.tenth(key, value) }
                    for (key, value) in (item.flags ?? [:]).sorted(by: { $0.key < $1.key }) { w.bool(key, value) }
                    w.endObject()
                }
                w.endObject()
            }
            w.endArray()
        }
        w.endObject()
    }

    private static func writePerf(_ w: inout JsonText, _ p: PerfEntry, appVersion: String? = nil) {
        w.beginObject()
        w.optionalString("app_version", appVersion)
        w.string("at", DiagnosticFormats.minuteText(p.at))
        w.int("span_s", DiagnosticFormats.clamp(p.spanSeconds, 60, 86_400))
        w.int("samples", DiagnosticFormats.clamp(p.samples, 1, 1440))
        if let windows = p.windows {
            w.beginObject("windows")
            w.int("open", DiagnosticFormats.clamp(windows.open, 0, 64))
            w.int("light", DiagnosticFormats.clamp(windows.light, 0, 64))
            w.int("hidden", DiagnosticFormats.clamp(windows.hidden, 0, 64))
            w.int("in_world", DiagnosticFormats.clamp(windows.inWorld, 0, 64))
            w.endObject()
        }
        if let memory = p.memory {
            w.beginObject("mem_mb")
            if memory.renderer != nil || memory.rendererEach != nil {
                w.beginObject("renderer")
                if let renderer = memory.renderer {
                    w.int("p50", DiagnosticFormats.megabytes(renderer.p50))
                    w.int("max", DiagnosticFormats.megabytes(renderer.max))
                }
                if let each = memory.rendererEach { megabytesArray(&w, "each", each) }
                w.endObject()
            }
            role(&w, "gpu", memory.gpu)
            role(&w, "browser_total", memory.browserTotal)
            role(&w, "utility", memory.utility)
            role(&w, "app", memory.app)
            w.endObject()
        }
        if p.jsHeapUsedEach != nil || p.jsHeapTotalEach != nil || p.jsHeapUsed != nil || p.jsHeapTotal != nil {
            w.beginObject("js_heap_mb")
            if let used = p.jsHeapUsedEach { megabytesArray(&w, "used_each", used) }
            if let total = p.jsHeapTotalEach { megabytesArray(&w, "total_each", total) }
            if let used = p.jsHeapUsed { w.int("used", DiagnosticFormats.megabytes(used)) }
            if let total = p.jsHeapTotal { w.int("total", DiagnosticFormats.megabytes(total)) }
            w.endObject()
        }
        if let cpu = p.cpu {
            w.beginObject("cpu_pct")
            if let each = cpu.rendererEach {
                w.beginArray("renderer_each")
                each.map(DiagnosticFormats.corePercent).sorted().prefix(DiagnosticFormats.maxEach).forEach { w.tenth(nil, $0) }
                w.endArray()
            }
            if let gpu = cpu.gpu { w.tenth("gpu", DiagnosticFormats.corePercent(gpu)) }
            if let total = cpu.browserTotal { w.tenth("browser_total", DiagnosticFormats.corePercent(total)) }
            if let app = cpu.app { w.tenth("app", DiagnosticFormats.corePercent(app)) }
            w.endObject()
        }
        timing(&w, "tick_ms", p.tick)
        timing(&w, "gap_ms", p.gap)
        if let tasks = p.longTasks {
            w.beginObject("long_tasks")
            w.int("count", DiagnosticFormats.clamp(tasks.count, 0, DiagnosticFormats.maxCount))
            w.tenth("total_ms", oneDecimal(tasks.totalMs, OsbPageBatch.maxLongTaskMilliseconds))
            w.endObject()
        }
        w.endObject()
    }

    private static func timing(_ w: inout JsonText, _ name: String, _ timing: PerfTiming?) {
        guard let timing else { return }
        w.beginObject(name)
        w.tenth("p50", oneDecimal(timing.p50, DiagnosticFormats.maxMilliseconds))
        w.tenth("p95", oneDecimal(timing.p95, DiagnosticFormats.maxMilliseconds))
        w.tenth("p99", oneDecimal(timing.p99, DiagnosticFormats.maxMilliseconds))
        w.tenth("max", oneDecimal(timing.max, DiagnosticFormats.maxMilliseconds))
        w.tenth("late_pct", oneDecimal(timing.latePercent, 100))
        w.endObject()
    }

    private static func oneDecimal(_ value: Double, _ max: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (Swift.min(Swift.max(value, 0), max) * 10).rounded() / 10
    }

    private static func role(_ w: inout JsonText, _ name: String, _ memory: RoleMemory?) {
        guard let memory else { return }
        w.beginObject(name)
        w.int("p50", DiagnosticFormats.megabytes(memory.p50))
        w.int("max", DiagnosticFormats.megabytes(memory.max))
        w.endObject()
    }

    private static func megabytesArray(_ w: inout JsonText, _ name: String, _ values: [Double]) {
        w.beginArray(name)
        values.map(DiagnosticFormats.megabytes).sorted().prefix(DiagnosticFormats.maxEach).forEach { w.int(nil, $0) }
        w.endArray()
    }
}
