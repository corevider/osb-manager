import Foundation

public enum ProcessRole: Equatable, Sendable {
    case app
    case renderer
    case gpu
    case utility
    case other
}

public struct ProcessReading: Equatable, Sendable {
    public var pid: Int32
    public var role: ProcessRole
    public var footprintBytes: Double
    public var cpuSeconds: Double

    public init(pid: Int32, role: ProcessRole, footprintBytes: Double, cpuSeconds: Double) {
        self.pid = pid
        self.role = role
        self.footprintBytes = footprintBytes
        self.cpuSeconds = cpuSeconds
    }
}

public struct PerfSample: Equatable, Sendable {
    public var at: Date
    public var app: ProcessReading?
    public var helpers: [ProcessReading]
    public var windows: PerfWindows

    public init(at: Date, app: ProcessReading?, helpers: [ProcessReading], windows: PerfWindows) {
        self.at = at
        self.app = app
        self.helpers = helpers
        self.windows = windows
    }
}

public final class PerfCollector: @unchecked Sendable {
    public static let sampleStep: TimeInterval = 60
    static let tolerance: TimeInterval = 5
    private static let megabyte = 1024.0 * 1024.0

    private struct CpuSpan {
        var role: ProcessRole
        var firstCpu: Double
        var firstAt: Date
        var lastCpu: Double
        var lastAt: Date

        var percent: Double? {
            let wall = lastAt.timeIntervalSince(firstAt)
            return wall <= 0 ? nil : max(0, (lastCpu - firstCpu) / wall * 100)
        }
    }

    private let lock = NSLock()
    private var ready: [PerfEntry] = []
    private var rendererAll: [Double] = []
    private var gpu: [Double] = []
    private var utility: [Double] = []
    private var browserTotal: [Double] = []
    private var app: [Double] = []
    private var cpu: [Int32: CpuSpan] = [:]
    private var rendererEach: [Double] = []
    private var windows = PerfWindows(open: 0, light: 0, hidden: 0, inWorld: 0)
    private var spanStart = Date(timeIntervalSince1970: 0)
    private var lastSampleAt = Date(timeIntervalSince1970: 0)
    private var samples = 0
    private var jsUsed: [Double]?
    private var jsTotal: [Double]?
    private var pageMemoryRequested = false

    public init() {}

    public var sampleCount: Int { lock.withLock { samples } }

    public var readyCount: Int { lock.withLock { ready.count } }

    public func add(_ sample: PerfSample) {
        lock.withLock {
            if samples == 0 { spanStart = sample.at }
            samples += 1
            lastSampleAt = sample.at
            windows = sample.windows
            let renderers = sample.helpers.filter { $0.role == .renderer }.map { $0.footprintBytes / Self.megabyte }
            rendererEach = renderers
            rendererAll += renderers
            gpu.append(Self.sum(sample.helpers, .gpu))
            utility.append(Self.sum(sample.helpers, .utility))
            let helpersTotal = sample.helpers.reduce(0) { $0 + $1.footprintBytes }
            browserTotal.append((helpersTotal + (sample.app?.footprintBytes ?? 0)) / Self.megabyte)
            if let own = sample.app {
                app.append(own.footprintBytes / Self.megabyte)
            }
            for reading in sample.helpers + [sample.app].compactMap({ $0 }) {
                if var span = cpu[reading.pid] {
                    span.role = reading.role
                    span.lastCpu = reading.cpuSeconds
                    span.lastAt = sample.at
                    cpu[reading.pid] = span
                } else {
                    cpu[reading.pid] = CpuSpan(role: reading.role, firstCpu: reading.cpuSeconds, firstAt: sample.at, lastCpu: reading.cpuSeconds, lastAt: sample.at)
                }
            }
        }
    }

    public func needsPageMemory(interval: TimeInterval, lead: TimeInterval) -> Bool {
        lock.withLock {
            guard samples > 0, !pageMemoryRequested,
                  lastSampleAt.timeIntervalSince(spanStart) + Self.sampleStep >= interval - lead else { return false }
            pageMemoryRequested = true
            return true
        }
    }

    public func setPageMemory(used: [Double], total: [Double]) {
        lock.withLock {
            guard samples > 0 else { return }
            jsUsed = used
            jsTotal = total
        }
    }

    @discardableResult
    public func tryComplete(interval: TimeInterval) -> Bool {
        lock.withLock {
            guard samples > 0, lastSampleAt.timeIntervalSince(spanStart) + Self.sampleStep + Self.tolerance >= interval else { return false }
            ready.append(build())
            if ready.count > DiagnosticFormats.maxPerf {
                ready.removeFirst(ready.count - DiagnosticFormats.maxPerf)
            }
            reset()
            return true
        }
    }

    public func peekReady() -> [PerfEntry] {
        lock.withLock { ready }
    }

    public func takeReady() -> [PerfEntry] {
        lock.withLock {
            let taken = ready
            ready.removeAll()
            return taken
        }
    }

    public func giveBack(_ entries: [PerfEntry]) {
        lock.withLock {
            ready.insert(contentsOf: entries, at: 0)
            if ready.count > DiagnosticFormats.maxPerf {
                ready.removeFirst(ready.count - DiagnosticFormats.maxPerf)
            }
        }
    }

    public func clear() {
        lock.withLock {
            ready.removeAll()
            reset()
        }
    }

    private func build() -> PerfEntry {
        let span = DiagnosticFormats.clamp(Int((lastSampleAt.timeIntervalSince(spanStart) + Self.sampleStep).rounded()), 60, 86_400)
        let rendererCpu = cpu.values.filter { $0.role == .renderer }.compactMap(\.percent)
        return PerfEntry(
            at: DiagnosticFormats.minute(spanStart),
            spanSeconds: span,
            samples: DiagnosticFormats.clamp(samples, 1, 1440),
            windows: windows,
            memory: PerfMemory(
                renderer: rendererAll.isEmpty ? nil : Self.role(rendererAll),
                rendererEach: rendererEach,
                gpu: gpu.contains { $0 > 0 } ? Self.role(gpu) : nil,
                browserTotal: browserTotal.isEmpty ? nil : Self.role(browserTotal),
                utility: utility.contains { $0 > 0 } ? Self.role(utility) : nil,
                app: app.isEmpty ? nil : Self.role(app)
            ),
            jsHeapUsedEach: jsUsed,
            jsHeapTotalEach: jsTotal,
            cpu: PerfCpu(
                rendererEach: rendererCpu,
                gpu: roleCpu { $0 == .gpu },
                browserTotal: roleCpu { _ in true },
                app: roleCpu { $0 == .app }
            )
        )
    }

    private func roleCpu(_ matches: (ProcessRole) -> Bool) -> Double? {
        let values = cpu.values.filter { matches($0.role) }.compactMap(\.percent)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private static func role(_ values: [Double]) -> RoleMemory {
        let sorted = values.sorted()
        return RoleMemory(p50: sorted[(sorted.count - 1) / 2], max: sorted[sorted.count - 1])
    }

    private static func sum(_ readings: [ProcessReading], _ role: ProcessRole) -> Double {
        readings.filter { $0.role == role }.reduce(0) { $0 + $1.footprintBytes } / megabyte
    }

    private func reset() {
        rendererAll.removeAll()
        gpu.removeAll()
        utility.removeAll()
        browserTotal.removeAll()
        app.removeAll()
        cpu.removeAll()
        rendererEach = []
        jsUsed = nil
        jsTotal = nil
        samples = 0
        pageMemoryRequested = false
    }
}
