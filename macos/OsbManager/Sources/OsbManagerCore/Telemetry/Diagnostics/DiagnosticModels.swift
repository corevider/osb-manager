import Foundation

public enum DiagnosticKind: String, Sendable, CaseIterable {
    case jsError = "js_error"
    case dotnetException = "dotnet_exception"
    case processFailed = "process_failed"
    case unresponsive
    case gpuFailed = "gpu_failed"
    case botStop = "bot_stop"
    case warn
    case runEnd = "run_end"
}

public enum DiagnosticSource: String, Sendable {
    case manager
    case osb
}

public struct DiagnosticEnv: Equatable, Sendable {
    public var osBuild: String?
    public var webview2: String?
    public var dotnet: String?
    public var ramGb: Int?
    public var cores: Int?
    public var gpuVendor: String?

    public init(osBuild: String? = nil, webview2: String? = nil, dotnet: String? = nil, ramGb: Int? = nil, cores: Int? = nil, gpuVendor: String? = nil) {
        self.osBuild = osBuild
        self.webview2 = webview2
        self.dotnet = dotnet
        self.ramGb = ramGb
        self.cores = cores
        self.gpuVendor = gpuVendor
    }
}

public struct ErrorDetail: Equatable, Sendable {
    public var type: String
    public var origin: String
    public var handled: Bool
    public var frames: [String]
    public var inner: [String]
    public var template: String?
    public var module: String?

    public init(type: String, origin: String, handled: Bool, frames: [String], inner: [String] = [], template: String? = nil, module: String? = nil) {
        self.type = type
        self.origin = origin
        self.handled = handled
        self.frames = frames
        self.inner = inner
        self.template = template
        self.module = module
    }
}

public struct ProcessDetail: Equatable, Sendable {
    public var kind: String
    public var reason: String
    public var exitCode: String
    public var description: String?

    public init(kind: String, reason: String, exitCode: String, description: String? = nil) {
        self.kind = kind
        self.reason = reason
        self.exitCode = exitCode
        self.description = description
    }
}

public struct HangDetail: Equatable, Sendable {
    public var outcome: String
    public var waitedSeconds: Int

    public init(outcome: String, waitedSeconds: Int) {
        self.outcome = outcome
        self.waitedSeconds = waitedSeconds
    }
}

public struct GpuDetail: Equatable, Sendable {
    public var code: String
    public var retries: Int

    public init(code: String, retries: Int) {
        self.code = code
        self.retries = retries
    }
}

public struct StopDetail: Equatable, Sendable {
    public var code: String
    public var source: String

    public init(code: String, source: String) {
        self.code = code
        self.source = source
    }
}

public struct RefusalDetail: Equatable, Sendable {
    public var source: String
    public var reason: String
    public var native: Int

    public init(source: String, reason: String, native: Int) {
        self.source = source
        self.reason = reason
        self.native = native
    }
}

public struct WarnDetail: Equatable, Sendable {
    public var category: String
    public var code: String
    public var errorClass: String?
    public var refusal: RefusalDetail?

    public init(category: String, code: String, errorClass: String? = nil, refusal: RefusalDetail? = nil) {
        self.category = category
        self.code = code
        self.errorClass = errorClass
        self.refusal = refusal
    }
}

public struct RunEndDetail: Equatable, Sendable {
    public var outcome: String
    public var uptimeSeconds: Int
    public var previousVersion: String?
    public var signal: String?

    public init(outcome: String, uptimeSeconds: Int, previousVersion: String?, signal: String? = nil) {
        self.outcome = outcome
        self.uptimeSeconds = uptimeSeconds
        self.previousVersion = previousVersion
        self.signal = signal
    }
}

public enum DiagnosticDetail: Equatable, Sendable {
    case error(ErrorDetail)
    case process(ProcessDetail)
    case hang(HangDetail)
    case gpu(GpuDetail)
    case stop(StopDetail)
    case warn(WarnDetail)
    case runEnd(RunEndDetail)

    public var kind: DiagnosticKind {
        switch self {
        case .error: .dotnetException
        case .process: .processFailed
        case .hang: .unresponsive
        case .gpu: .gpuFailed
        case .stop: .botStop
        case .warn: .warn
        case .runEnd: .runEnd
        }
    }
}

public struct DiagnosticContext: Equatable, Sendable {
    public var phase: String?
    public var mode: String?
    public var townPhase: String?
    public var dead: Bool?
    public var loginStage: String?
    public var window: Int?
    public var windows: Int?
    public var light: Bool?
    public var hidden: Bool?
    public var uptimeSeconds: Int?

    public init(phase: String? = nil, mode: String? = nil, townPhase: String? = nil, dead: Bool? = nil, loginStage: String? = nil, window: Int? = nil, windows: Int? = nil, light: Bool? = nil, hidden: Bool? = nil, uptimeSeconds: Int? = nil) {
        self.phase = phase
        self.mode = mode
        self.townPhase = townPhase
        self.dead = dead
        self.loginStage = loginStage
        self.window = window
        self.windows = windows
        self.light = light
        self.hidden = hidden
        self.uptimeSeconds = uptimeSeconds
    }
}

public struct TrailItem: Equatable, Sendable {
    public var secondsBefore: Int
    public var level: String
    public var category: String
    public var code: String
    public var count: Int
    public var window: Int?
    public var outcome: String?
    public var errorClass: String?
    public var numbers: [String: Double]?
    public var flags: [String: Bool]?

    public init(secondsBefore: Int, level: String, category: String, code: String, count: Int = 1, window: Int? = nil, outcome: String? = nil, errorClass: String? = nil, numbers: [String: Double]? = nil, flags: [String: Bool]? = nil) {
        self.secondsBefore = secondsBefore
        self.level = level
        self.category = category
        self.code = code
        self.count = count
        self.window = window
        self.outcome = outcome
        self.errorClass = errorClass
        self.numbers = numbers
        self.flags = flags
    }
}

public struct DiagnosticEvent: Equatable, Sendable {
    public var detail: DiagnosticDetail
    public var source: DiagnosticSource
    public var fingerprint: String
    public var at: Date
    public var count: Int
    public var context: DiagnosticContext?
    public var trail: [TrailItem]?

    public var kind: DiagnosticKind {
        if case .error = detail, source == .osb { return .jsError }
        return detail.kind
    }

    public init(detail: DiagnosticDetail, source: DiagnosticSource = .manager, fingerprint: String, at: Date, count: Int = 1, context: DiagnosticContext? = nil, trail: [TrailItem]? = nil) {
        self.detail = detail
        self.source = source
        self.fingerprint = fingerprint
        self.at = at
        self.count = count
        self.context = context
        self.trail = trail
    }

    public static func make(_ detail: DiagnosticDetail, at: Date, count: Int = 1, context: DiagnosticContext? = nil, trail: [TrailItem]? = nil) -> DiagnosticEvent {
        DiagnosticEvent(detail: detail, fingerprint: DiagnosticFingerprint.of(detail), at: at, count: count, context: context, trail: trail)
    }
}

public struct RoleMemory: Equatable, Sendable {
    public var p50: Double
    public var max: Double

    public init(p50: Double, max: Double) {
        self.p50 = p50
        self.max = max
    }
}

public struct PerfWindows: Equatable, Sendable {
    public var open: Int
    public var light: Int
    public var hidden: Int
    public var inWorld: Int

    public init(open: Int, light: Int, hidden: Int, inWorld: Int) {
        self.open = open
        self.light = light
        self.hidden = hidden
        self.inWorld = inWorld
    }
}

public struct PerfMemory: Equatable, Sendable {
    public var renderer: RoleMemory?
    public var rendererEach: [Double]?
    public var gpu: RoleMemory?
    public var browserTotal: RoleMemory?
    public var utility: RoleMemory?
    public var app: RoleMemory?

    public init(renderer: RoleMemory? = nil, rendererEach: [Double]? = nil, gpu: RoleMemory? = nil, browserTotal: RoleMemory? = nil, utility: RoleMemory? = nil, app: RoleMemory? = nil) {
        self.renderer = renderer
        self.rendererEach = rendererEach
        self.gpu = gpu
        self.browserTotal = browserTotal
        self.utility = utility
        self.app = app
    }
}

public struct PerfCpu: Equatable, Sendable {
    public var rendererEach: [Double]?
    public var gpu: Double?
    public var browserTotal: Double?
    public var app: Double?

    public init(rendererEach: [Double]? = nil, gpu: Double? = nil, browserTotal: Double? = nil, app: Double? = nil) {
        self.rendererEach = rendererEach
        self.gpu = gpu
        self.browserTotal = browserTotal
        self.app = app
    }
}

public struct PerfTiming: Equatable, Sendable {
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var max: Double
    public var latePercent: Double

    public init(p50: Double, p95: Double, p99: Double, max: Double, latePercent: Double) {
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.max = max
        self.latePercent = latePercent
    }
}

public struct PerfLongTasks: Equatable, Sendable {
    public var count: Int
    public var totalMs: Double

    public init(count: Int, totalMs: Double) {
        self.count = count
        self.totalMs = totalMs
    }
}

public struct PerfEntry: Equatable, Sendable {
    public var at: Date
    public var spanSeconds: Int
    public var samples: Int
    public var windows: PerfWindows?
    public var memory: PerfMemory?
    public var jsHeapUsedEach: [Double]?
    public var jsHeapTotalEach: [Double]?
    public var jsHeapUsed: Double?
    public var jsHeapTotal: Double?
    public var cpu: PerfCpu?
    public var tick: PerfTiming?
    public var gap: PerfTiming?
    public var longTasks: PerfLongTasks?

    public init(at: Date, spanSeconds: Int, samples: Int, windows: PerfWindows? = nil, memory: PerfMemory? = nil, jsHeapUsedEach: [Double]? = nil, jsHeapTotalEach: [Double]? = nil, jsHeapUsed: Double? = nil, jsHeapTotal: Double? = nil, cpu: PerfCpu? = nil, tick: PerfTiming? = nil, gap: PerfTiming? = nil, longTasks: PerfLongTasks? = nil) {
        self.at = at
        self.spanSeconds = spanSeconds
        self.samples = samples
        self.windows = windows
        self.memory = memory
        self.jsHeapUsedEach = jsHeapUsedEach
        self.jsHeapTotalEach = jsHeapTotalEach
        self.jsHeapUsed = jsHeapUsed
        self.jsHeapTotal = jsHeapTotal
        self.cpu = cpu
        self.tick = tick
        self.gap = gap
        self.longTasks = longTasks
    }
}

public struct OsbPerfEntry: Equatable, Sendable {
    public var entry: PerfEntry
    public var appVersion: String

    public init(entry: PerfEntry, appVersion: String) {
        self.entry = entry
        self.appVersion = appVersion
    }
}

public struct DroppedCounts: Equatable, Sendable {
    public var rateLimited: Int
    public var oversize: Int
    public var sampledOut: Int

    public init(rateLimited: Int = 0, oversize: Int = 0, sampledOut: Int = 0) {
        self.rateLimited = rateLimited
        self.oversize = oversize
        self.sampledOut = sampledOut
    }

    public func adding(_ other: DroppedCounts) -> DroppedCounts {
        DroppedCounts(
            rateLimited: DiagnosticFormats.cappedSum(rateLimited, other.rateLimited),
            oversize: DiagnosticFormats.cappedSum(oversize, other.oversize),
            sampledOut: DiagnosticFormats.cappedSum(sampledOut, other.sampledOut)
        )
    }
}

public struct DiagnosticBatch: Sendable {
    public var appVersion: String
    public var run: String
    public var env: DiagnosticEnv
    public var events: [DiagnosticEvent]
    public var perf: [PerfEntry]
    public var osbPerf: [OsbPerfEntry]
    public var dropped: DroppedCounts

    public init(appVersion: String, run: String, env: DiagnosticEnv = DiagnosticEnv(), events: [DiagnosticEvent] = [], perf: [PerfEntry] = [], osbPerf: [OsbPerfEntry] = [], dropped: DroppedCounts = DroppedCounts()) {
        self.appVersion = appVersion
        self.run = run
        self.env = env
        self.events = events
        self.perf = perf
        self.osbPerf = osbPerf
        self.dropped = dropped
    }
}
